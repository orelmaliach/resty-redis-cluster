local redis = require "resty.redis"
local resty_lock = require "resty.lock"
local xmodem = require "resty.xmodem"
local cjson = require "cjson.safe"

local setmetatable = setmetatable
local tostring = tostring
local string = string
local type = type
local table = table
local ngx = ngx
local math = math
local rawget = rawget
local pairs = pairs
local unpack = unpack
local ipairs = ipairs
local table_insert = table.insert
local string_find = string.find
local redis_crc = xmodem.redis_crc

local DEFAULT_SHARED_DICT_NAME = "redis_cluster_slot_locks"
local DEFAULT_SLOTS_INFO_DICT_NAME = "redis_cluster_slots_info"
local DEFAULT_REFRESH_DICT_NAME = "refresh_lock"
local DEFAULT_MAX_REDIRECTION = 5
local DEFAULT_MAX_CONNECTION_ATTEMPTS = 3
local DEFAULT_KEEPALIVE_TIMEOUT = 55000
local DEFAULT_KEEPALIVE_CONS = 1000
local DEFAULT_CONNECTION_TIMEOUT = 1000
local DEFAULT_SEND_TIMEOUT = 1000
local DEFAULT_READ_TIMEOUT = 1000
local TOO_MANY_CONNECTIONS = "too many waiting connect operations"
local CONNECTION_POOL_TIMEOUT = "timeout"

local function parse_key(key_str)
    local left_tag_single_index = string_find(key_str, "{", 0)
    local right_tag_single_index = string_find(key_str, "}", 0)
    if left_tag_single_index and right_tag_single_index then
        --parse hashtag
        return key_str.sub(key_str, left_tag_single_index + 1, right_tag_single_index - 1)
    else
        return key_str
    end
end

local _M = {}

local mt = { __index = _M }

local slot_cache = {}

local cmds_for_all_master = {
    ["flushall"] = true,
    ["flushdb"] = true
}

local cluster_invalid_cmds = {
    ["config"] = true,
    ["shutdown"] = true
}

local function redis_slot(key)
    if key == "no_key" then
        return 1
    end
    return redis_crc(parse_key(key))
end

local function check_auth(self, redis_client)
    if type(self.config.auth) == "string" then
        local count, err = redis_client:get_reused_times()
        if count == 0 then
            local _
            _, err = redis_client:auth(self.config.auth)
        end

        if not err then
            return true, nil
        else
            return nil, err
        end
    else
        return true, nil
    end
end

local function release_connection(red, config)
    local ok, err = red:set_keepalive(config.keepalive_timeout
            or DEFAULT_KEEPALIVE_TIMEOUT, config.keepalive_cons or DEFAULT_KEEPALIVE_CONS)
    if not ok then
        ngx.log(ngx.ERR, "set keepalive failed: ", err)
    end
end

local function generate_full_slots_cache_info(slots_info)
    local slots = {}
    -- while slots are updated, create a list of servers present in cluster
    -- this can differ from self.config.serv_list if a cluster is resized (added/removed nodes)
    local servers = { serv_list = {} }
    for n = 1, #slots_info do
        local sub_info = slots_info[n]
        -- slot info item 1 and 2 are the subrange start end slots
        local start_slot, end_slot = sub_info[1], sub_info[2]
        local list = { serv_list = {} }
        -- from 3, here lists the host/port/nodeid of in charge nodes
        for j = 3, #sub_info do
            table.insert(list.serv_list, {
                ip = sub_info[j][1],
                port = sub_info[j][2],
                slave = (j > 3) -- first node in the list is the master
            })
        end

        for slot = start_slot, end_slot do
            slots[slot] = list
        end

        -- append to the list of all servers
        for _, serv in ipairs(list.serv_list) do
            table.insert(servers.serv_list, serv)
        end
    end

    return slots, servers
end

local function try_hosts_slots(self, serv_list)
    local start_time = ngx.now()
    local errors = {}
    local config = self.config
    if #serv_list < 1 then
        return nil, "failed to fetch slots, serv_list config is empty"
    end

    for i = 1, #serv_list do
        local ip = serv_list[i].ip
        local port = serv_list[i].port
        local redis_client = redis:new()
        local ok, err, max_connection_timeout_err
        redis_client:set_timeouts(config.connect_timeout or DEFAULT_CONNECTION_TIMEOUT,
                config.send_timeout or DEFAULT_SEND_TIMEOUT,
                config.read_timeout or DEFAULT_READ_TIMEOUT)

        --attempt to connect DEFAULT_MAX_CONNECTION_ATTEMPTS times to redis
        for k = 1, config.max_connection_attempts or DEFAULT_MAX_CONNECTION_ATTEMPTS do
            local total_connection_time_ms = (ngx.now() - start_time) * 1000
            if (config.max_connection_timeout and total_connection_time_ms > config.max_connection_timeout) then
                max_connection_timeout_err = "max_connection_timeout of " .. config.max_connection_timeout .. "ms reached."
                ngx.log(ngx.ERR, max_connection_timeout_err)
                table_insert(errors, max_connection_timeout_err)
                break
            end

            ok, err = redis_client:connect(ip, port, self.config.connect_opts)
            if ok then
                break
            end
            if err then
                ngx.log(ngx.ERR, "unable to connect, attempt number ", k, ", error: ", err)
                table_insert(errors, err)
            end
        end

        if ok then
            local _, auth_err = check_auth(self, redis_client)
            if auth_err then
                table_insert(errors, auth_err)
                return nil, errors
            end

            local slots_info, slots_err = redis_client:cluster("slots")
            release_connection(redis_client, config)

            if slots_info then
                local slots, servers = generate_full_slots_cache_info(slots_info)
                --ngx.log(ngx.NOTICE, "finished initializing slot cache...")
                slot_cache[self.config.name] = slots
                slot_cache[self.config.name .. "serv_list"] = servers

                -- cache slots_info to memory
                _, err = self:try_cache_slots_info_to_memory(slots_info)
                if err then
                    ngx.log(ngx.ERR, 'failed to cache slots to memory: ', err)
                end
            else
                table_insert(errors, slots_err)
            end

            -- refreshed slots successfully
            -- not required to connect/iterate over additional hosts
            if slots_info then
                return true, nil
            end
        elseif max_connection_timeout_err then
            break
        else
            table_insert(errors, err)
        end

        if #errors == 0 then
            return true, nil
        end
    end
    return nil, errors
end

function _M.fetch_slots(self)
    local serv_list = self.config.serv_list
    local serv_list_cached = slot_cache[self.config.name .. "serv_list"]
    local serv_list_combined

    -- if a cached serv_list is present, start with that
    if serv_list_cached then
        serv_list_combined = serv_list_cached.serv_list

        -- then append the serv_list from config, in the event that the entire
        -- cached serv_list no longer points to anything usable
        for _, s in ipairs(serv_list) do
            table_insert(serv_list_combined, s)
        end
    else
        -- otherwise we bootstrap with our serv_list from config
        serv_list_combined = serv_list
    end

    serv_list_cached = nil -- important!

    local _, errors = try_hosts_slots(self, serv_list_combined)
    if errors then
        local err = "failed to fetch slots: " .. table.concat(errors, ";")
        ngx.log(ngx.ERR, err)
        return nil, err
    end
end

function _M.try_load_slots_from_memory_cache(self)
    local dict_name = self.config.slots_info_dict_name or DEFAULT_SLOTS_INFO_DICT_NAME
    local slots_cache_dict = ngx.shared[dict_name]
    if slots_cache_dict == nil then
        return false, dict_name .. ' is nil'
    end

    local slots_info_str = slots_cache_dict:get(self.config.name)
    if not slots_info_str or slots_info_str == '' then
        return false, 'slots_info_str is nil or empty'
    end

    local slots_info = cjson.decode(slots_info_str)
    if not slots_info then
        return false, 'slots_info is nil'
    end

    local slots, servers = generate_full_slots_cache_info(slots_info)
    if not slots or not servers then
        return false, 'slots or servers is nil'
    end

    --ngx.log(ngx.NOTICE, "finished initializing slot cache...")
    slot_cache[self.config.name] = slots
    slot_cache[self.config.name .. "serv_list"] = servers
    return true
end

function _M.try_cache_slots_info_to_memory(self, slots_info)
    local dict_name = self.config.slots_info_dict_name or DEFAULT_SLOTS_INFO_DICT_NAME
    local slots_cache_dict = ngx.shared[dict_name]
    if slots_cache_dict == nil then
        return false, dict_name .. ' is nil'
    end

    if not slots_info then
        return false, 'slots_info is nil'
    end

    local slots_info_str = cjson.encode(slots_info)
    local success, err = slots_cache_dict:set(self.config.name, slots_info_str)
    if not success then
        ngx.log(ngx.ERR, 'error set slots_info: ', err, ', slots_info_str: ', slots_info_str)
        return false, err
    end
    return true
end

function _M.refresh_slots(self)
    local worker_id = ngx.worker.id()
    local lock, err, elapsed, ok
    lock, err = resty_lock:new(self.config.dict_name or DEFAULT_SHARED_DICT_NAME, { time_out = 0 })

    if not lock then
        ngx.log(ngx.ERR, "failed to create lock in refresh slot cache: ", err)
        return nil, err
    end

    local refresh_lock_key = (self.config.refresh_lock_key or DEFAULT_REFRESH_DICT_NAME) .. worker_id
    elapsed, err = lock:lock(refresh_lock_key)
    if not elapsed then
        return nil, "race refresh lock fail, " .. err
    end

    self:fetch_slots()
    ok, err = lock:unlock()
    if not ok then
        ngx.log(ngx.ERR, "failed to unlock in refresh slot cache: ", err)
        return nil, err
    end
end

function _M.init_slots(self)
    if slot_cache[self.config.name] then
        -- already initialized
        return true
    end

    local ok, lock, elapsed, err
    lock, err = resty_lock:new(self.config.dict_name or DEFAULT_SHARED_DICT_NAME)
    if not lock then
        ngx.log(ngx.ERR, "failed to create lock in initialization slot cache: ", err)
        return nil, err
    end

    elapsed, err = lock:lock("redis_cluster_slot_" .. self.config.name)
    if not elapsed then
        ngx.log(ngx.ERR, "failed to acquire the lock in initialization slot cache: ", err)
        return nil, err
    end

    if slot_cache[self.config.name] then
        ok, err = lock:unlock()
        if not ok then
            ngx.log(ngx.ERR, "failed to unlock in initialization slot cache: ", err)
        end
        -- already initialized
        return true
    end

    -- try to fetch slots from memory cache
    ok, err = self:try_load_slots_from_memory_cache()
    if ok then
        ok, err = lock:unlock()
        if not ok then
            ngx.log(ngx.ERR, "failed to unlock in initialization slot cache: ", err)
        end
        return true
    end

    local _, errs = self:fetch_slots()
    if errs then
        ok, err = lock:unlock()
        if not ok then
            ngx.log(ngx.ERR, "failed to unlock in initialization slot cache: ", err)
        end
        return nil, errs
    end

    ok, err = lock:unlock()
    if not ok then
        ngx.log(ngx.ERR, "failed to unlock in initialization slot cache: ", err)
    end
    -- initialized
    return true
end

function _M.new(_, config)
    if not config.name then
        return nil, "redis cluster config name is empty"
    end
    if not config.serv_list or #config.serv_list < 1 then
        return nil, "redis cluster config serv_list is empty"
    end

    local instance = { config = config }
    instance = setmetatable(instance, mt)
    local _, err = instance:init_slots()
    if err then
        return nil, err
    end
    return instance
end

local function pick_node(self, serv_list, magic_random_seed)
    if #serv_list < 1 then
        return nil, nil, nil, "serv_list is empty"
    end

    if not self.config.enable_slave_read then
        --ngx.log(ngx.NOTICE, "pickup node: ", cjson.encode(serv_list[1]))
        return serv_list[1].ip, serv_list[1].port, false
    end

    local index
    if magic_random_seed then
        index = magic_random_seed % #serv_list + 1
    else
        index = math.random(#serv_list)
    end

    --cluster slots will always put the master node as first
    return serv_list[index].ip, serv_list[index].port, index > 1
end

local function parse_signal(res, prefix)
    --ask signal sample:ASK 12191 127.0.0.1:7008, so we need to parse and get 127.0.0.1, 7008
    if res ~= ngx.null then
        if type(res) == "string" then
            res = { res }
        end

        if type(res) == "table" then
            for i = 1, #res do
                if type(res[i]) == "string" and string.sub(res[i], 1, #prefix) == prefix then
                    local matched = ngx.re.match(string.sub(res[i], #prefix + 1), "^ [^ ]+ ([^:]+):([^ ]+)", "jo", nil, nil)
                    if not matched then
                        ngx.log(ngx.ERR, "failed to parse redirection host and port. msg is: ", res[i])
                        return nil, nil, "failed to parse redirection host and port"
                    end
                    return matched[1], matched[2]
                end
            end
        end
    end

    return nil, nil
end

local function handle_command_with_retry(self, target_ip, target_port, asking, cmd, key, ...)
    local config = self.config
    key = tostring(key)
    local slot = redis_slot(key)

    for k = 1, config.max_redirection or DEFAULT_MAX_REDIRECTION do
        if k > 1 then
            ngx.log(ngx.NOTICE, "handle retry attempt " .. k .. " for cmd: " .. cmd .. ", key: " .. key)
        end

        local slots = slot_cache[self.config.name]
        if slots == nil or slots[slot] == nil then
            return nil, "no slots information present, nginx might have never successfully executed cluster(\"slots\")"
        end
        local serv_list = slots[slot].serv_list

        -- We must empty local reference to slots cache, otherwise there will be memory issue while
        -- coroutine switch happens(eg. ngx.sleep, cosocket), very important!
        slots = nil

        local ip, port, slave, err

        if target_ip ~= nil and target_port ~= nil then
            -- asking redirection should only happens at master nodes
            ip, port, slave = target_ip, target_port, false
        else
            ip, port, slave, err = pick_node(self, serv_list)
            if err then
                ngx.log(ngx.ERR, "pickup node failed, will return failed for this request. meanwhile refreshing slot cache " .. err)
                self:refresh_slots()
                return nil, err
            end
        end

        local redis_client = redis:new()
        redis_client:set_timeouts(config.connect_timeout or DEFAULT_CONNECTION_TIMEOUT,
                config.send_timeout or DEFAULT_SEND_TIMEOUT,
                config.read_timeout or DEFAULT_READ_TIMEOUT)
        local ok, connect_err = redis_client:connect(ip, port, self.config.connect_opts)

        if ok then
            local _, auth_err = check_auth(self, redis_client)
            if auth_err then
                return nil, auth_err
            end
            if slave then
                --set readonly
                ok, err = redis_client:readonly()
                if not ok then
                    self:refresh_slots()
                    return nil, err
                end
            end

            if asking then
                --executing asking
                ok, err = redis_client:asking()
                if not ok then
                    self:refresh_slots()
                    return nil, err
                end
            end

            local res
            if cmd == "eval" or cmd == "evalsha" then
                res, err = redis_client[cmd](redis_client, ...)
            else
                res, err = redis_client[cmd](redis_client, key, ...)
            end

            if not err then
                release_connection(redis_client, config)
                return res, err
            end

            local moved_host, moved_port, moved_err = parse_signal(err, "MOVED")
            if moved_err or (moved_host ~= nil and moved_port ~= nil) then
                --ngx.log(ngx.NOTICE, "found MOVED signal, trigger retry for normal commands. cmd: " .. cmd .. ", key: " .. key)
                if moved_host == ip and moved_port == tostring(port) then
                    -- there's some issue with connection returning bad responses continuously
                    -- even though this node is the master of the data.
                    -- close it instead of returning to pool
                    local _, close_err = redis_client:close()
                    if close_err then
                        ngx.log(ngx.ERR, "close connection failed: ", close_err)
                        return nil, "failed to close redis connection!"
                    end
                else
                    release_connection(redis_client, config)
                end

                target_ip = moved_host
                target_port = moved_port
                self:refresh_slots()
            else
                local ask_host, ask_port, ask_err = parse_signal(err, "ASK")
                if ask_err then
                    return nil, ask_err
                end

                if ask_host ~= nil and ask_port ~= nil then
                    --ngx.log(ngx.NOTICE, "handle asking for normal commands, cmd: " .. cmd .. ", key: " .. key)
                    release_connection(redis_client, config)

                    if asking then
                        --Should not happen after asking target ip,port and still return ask, if so, return error
                        return nil, "nested asking redirection occurred, client cannot retry"
                    end

                    target_ip = ask_host
                    target_port = ask_port
                    asking = true
                elseif string.sub(err, 1, 11) == "CLUSTERDOWN" then
                    release_connection(redis_client, config)
                    return nil, "cannot execute command, cluster status is failed!"
                else
                    release_connection(redis_client, config)
                    -- There might be a node failure, we should also refresh slot cache
                    self:refresh_slots()
                    return nil, err
                end
            end
        else
            -- `too many waiting connect operations` means queued connect operations is out of backlog
            -- `timeout` means timeout while wait for connection release
            -- If connect timeout caused by server's issue, the connect_err is `connection timed out`
            if connect_err ~= TOO_MANY_CONNECTIONS and connect_err ~= CONNECTION_POOL_TIMEOUT then
                -- There might be a node failure, we should also refresh slot cache
                self:refresh_slots()
            end

            if k == config.max_redirection or k == DEFAULT_MAX_REDIRECTION then
                -- only return after allowing for `k` attempts
                return nil, connect_err
            end
        end
    end

    return nil, "failed to execute command, reached maximum redirection attempts"
end

local function generate_magic_seed(self)
    -- For pipeline, we don't want request to be forwarded to all channels, e.g. if we have 3*3 cluster(3 master 2 replicas)
    -- we always want pick up specific 3 nodes for pipeline requests, instead of 9.
    -- Currently we simply use (num of allnode)%count as a randomly fetch. Might consider a better way in the future.
    -- Use the dynamic serv_list instead of the static config serv_list
    local node_count = #slot_cache[self.config.name .. "serv_list"].serv_list
    return math.random(node_count)
end

local function _do_cmd_master(self, cmd, key, ...)
    local errors = {}
    local serv_list = slot_cache[self.config.name .. "serv_list"].serv_list

    for _, server in ipairs(serv_list) do
        if not server.slave then
            local redis_client = redis:new()
            redis_client:set_timeouts(self.config.connect_timeout or DEFAULT_CONNECTION_TIMEOUT,
                    self.config.send_timeout or DEFAULT_SEND_TIMEOUT,
                    self.config.read_timeout or DEFAULT_READ_TIMEOUT)

            local ok, err = redis_client:connect(server.ip, server.port, self.config.connect_opts)
            if ok then
                _, err = redis_client[cmd](redis_client, key, ...)
            end
            if err then
                table_insert(errors, err)
            end
            release_connection(redis_client, self.config)
        end
    end

    return #errors == 0, table.concat(errors, ";")
end

local function _do_cmd(self, cmd, key, ...)
    if cluster_invalid_cmds[cmd] == true then
        return nil, "command not supported"
    end

    -- check if we're in middle of pipeline
    local _reqs = rawget(self, "_reqs")
    if _reqs then
        local execution = { cmd = cmd, key = key, args = { ... } }
        table_insert(_reqs, execution)
        return
    end

    if cmds_for_all_master[cmd] then
        return _do_cmd_master(self, cmd, key, ...)
    end

    return handle_command_with_retry(self, nil, nil, false, cmd, key, ...)
end

local function construct_final_pipeline_resp(self, node_res_map, node_req_map)
    --construct final result with original index
    local final_response = {}
    for k, v in pairs(node_res_map) do
        local reqs = node_req_map[k].reqs
        local res = v
        local need_to_fetch_slots = true

        for i = 1, #reqs do
            --deal with redis cluster ask redirection
            local ask_host, ask_port, ask_err = parse_signal(res[i], "ASK")
            if ask_err then
                return nil, ask_err
            end

            if ask_host ~= nil and ask_port ~= nil then
                --ngx.log(ngx.NOTICE, "handle ask signal for cmd: " .. reqs[i]["cmd"] .. ", key: " .. reqs[i]["key"] .. ", target host: " .. ask_host .. ", target port: " .. ask_port)
                local ask_res, err = handle_command_with_retry(self, ask_host, ask_port, true, reqs[i]["cmd"], reqs[i]["key"], unpack(reqs[i]["args"]))
                if err then
                    return nil, err
                end

                final_response[reqs[i].origin_index] = ask_res
            else
                local moved_host, moved_port, moved_err = parse_signal(res[i], "MOVED")
                if moved_err or (moved_host ~= nil and moved_port ~= nil) then
                    --ngx.log(ngx.NOTICE, "handle moved signal for cmd: " .. reqs[i]["cmd"] .. ", key: " .. reqs[i]["key"])
                    if need_to_fetch_slots then
                        -- if there are multiple signals for moved, we just need to fetch slot cache once and retry
                        self:refresh_slots()
                        need_to_fetch_slots = false
                    end

                    local moved_res, err = handle_command_with_retry(self, moved_host, moved_port, false, reqs[i]["cmd"], reqs[i]["key"], unpack(reqs[i]["args"]))
                    if err then
                        return nil, err
                    end

                    final_response[reqs[i].origin_index] = moved_res
                else
                    final_response[reqs[i].origin_index] = res[i]
                end
            end
        end
    end

    return final_response
end

local function has_cluster_fail_signal_in_pipeline(res)
    for i = 1, #res do
        if res[i] ~= ngx.null and type(res[i]) == "table" then
            for j = 1, #res[i] do
                if type(res[i][j]) == "string" and string.sub(res[i][j], 1, 11) == "CLUSTERDOWN" then
                    return true
                end
            end
        end
    end
    return false
end

function _M.init_pipeline(self)
    self._reqs = {}
end

function _M.commit_pipeline(self)
    local _reqs = rawget(self, "_reqs")
    if not _reqs or #_reqs == 0 then
        return nil, "no pipeline"
    end

    self._reqs = nil
    local config = self.config

    local slots = slot_cache[config.name]
    if slots == nil then
        return nil, "no slots information present, nginx might have never successfully executed cluster(\"slots\")"
    end

    local node_res_map = {}
    local node_req_map = {}
    local magic_random_seed = generate_magic_seed(self)

    --construct req to real node mapping
    for i = 1, #_reqs do
        -- Because we forward requests to different nodes, the result might not be the original order,
        -- we need to record the original index to be able to later construct the result with original order
        _reqs[i].origin_index = i
        local key = _reqs[i].key
        local slot = redis_slot(tostring(key))
        if slots[slot] == nil then
            return nil, "no slots information present, nginx might have never successfully executed cluster(\"slots\")"
        end
        local slot_item = slots[slot]

        local ip, port, slave, err = pick_node(self, slot_item.serv_list, magic_random_seed)
        if err then
            -- We must empty local reference to slots cache, otherwise there will be memory issue while
            -- coroutine switch happens (e.g. ngx.sleep, cosocket), very important!
            slots = nil
            self:refresh_slots()
            return nil, err
        end

        local node = ip .. tostring(port)
        if not node_req_map[node] then
            node_req_map[node] = { ip = ip, port = port, slave = slave, reqs = {} }
            node_res_map[node] = {}
        end
        local ins_req = node_req_map[node].reqs
        ins_req[#ins_req + 1] = _reqs[i]
    end

    -- We must empty local reference to slots cache, otherwise there will be memory issue while
    -- coroutine switch happens (e.g. ngx.sleep, cosocket), very important!
    slots = nil

    for k, v in pairs(node_req_map) do
        local ip = v.ip
        local port = v.port
        local reqs = v.reqs
        local slave = v.slave
        local redis_client = redis:new()
        redis_client:set_timeouts(config.connect_timeout or DEFAULT_CONNECTION_TIMEOUT,
                config.send_timeout or DEFAULT_SEND_TIMEOUT,
                config.read_timeout or DEFAULT_READ_TIMEOUT)
        local ok, connect_err = redis_client:connect(ip, port, self.config.connect_opts)

        if ok then
            local _, auth_err = check_auth(self, redis_client)
            if auth_err then
                return nil, auth_err
            end

            if slave then
                --set readonly
                local readonly_ok, readonly_err = redis_client:readonly()
                if not readonly_ok then
                    self:refresh_slots()
                    return nil, readonly_err
                end
            end

            redis_client:init_pipeline()
            for i = 1, #reqs do
                local req = reqs[i]
                if #req.args > 0 then
                    if req.cmd == "eval" or req.cmd == "evalsha" then
                        redis_client[req.cmd](redis_client, unpack(req.args))
                    else
                        redis_client[req.cmd](redis_client, req.key, unpack(req.args))
                    end
                else
                    redis_client[req.cmd](redis_client, req.key)
                end
            end

            local res, commit_err = redis_client:commit_pipeline()
            if commit_err then
                -- There might be a node failure, we should also refresh slot cache
                self:refresh_slots()
                return nil, commit_err .. " returned from " .. tostring(ip) .. ":" .. tostring(port)
            end

            release_connection(redis_client, config)
            if has_cluster_fail_signal_in_pipeline(res) then
                return nil, "cannot execute pipeline command, cluster status is failed!"
            end

            node_res_map[k] = res
        else
            -- `too many waiting connect operations` means queued connect operations is out of backlog
            -- `timeout` means timeout while wait for connection release
            -- If connect timeout caused by server's issue, the connect_err is `connection timed out`
            if connect_err ~= TOO_MANY_CONNECTIONS and connect_err ~= CONNECTION_POOL_TIMEOUT then
                -- There might be a node failure, we should also refresh slot cache
                self:refresh_slots()
            end
            return nil, connect_err .. " pipeline commit failed while connecting to " .. tostring(ip) .. ":" .. tostring(port)
        end
    end

    --construct final result with original index
    local final_res, err = construct_final_pipeline_resp(self, node_res_map, node_req_map)
    if err then
        return nil, err .. " failed to construct final pipeline result"
    end
    return final_res
end

function _M.cancel_pipeline(self)
    self._reqs = nil
end

local function _do_eval_cmd(self, cmd, ...)
    --[[
    eval command usage:
    eval(script, 1, key, arg1, arg2 ...)
    eval(script, 0, arg1, arg2 ...)
    ]]
    local args = { ... }
    local keys_num = args[2]
    if type(keys_num) ~= "number" then
        return nil, "cannot execute eval without keys number"
    end
    if keys_num > 1 then
        return nil, "cannot execute eval with more than one keys for redis cluster"
    end

    local key = (keys_num == 1 and args[3]) or "no_key"
    return _do_cmd(self, cmd, key, ...)
end

-- dynamic cmd
setmetatable(_M, {
    __index = function(_, cmd)
        local method = function(self, ...)
            if cmd == "eval" or cmd == "evalsha" then
                return _do_eval_cmd(self, cmd, ...)
            else
                return _do_cmd(self, cmd, ...)
            end
        end

        -- cache the lazily generated method in our module table
        _M[cmd] = method
        return method
    end
})

return _M

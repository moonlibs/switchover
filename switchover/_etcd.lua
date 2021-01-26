--- This module provides connector to ETCD
local M = {}
local uri = require 'net.url'

local log = require 'log'
local json = require 'json'
local base64 = {
	encode = require 'digest'.base64_encode,
	decode = require 'digest'.base64_decode,
}
local http = require 'http.client'
local clock = require 'clock'

local function deepmerge(t1, t2, seen)
	seen = seen or {}

	if type(t2) ~= 'table' or type(t1) ~= 'table' then
		return t2 or t1
	end

	if seen[t2] then
		return seen[t2]
	elseif seen[t1] then
		return seen[t1]
	end

	local r = {}

	-- from this point t1 and t2 are both tables
	seen[t1] = r
	seen[t2] = r
	-- and we have saw them

	for k2, v2 in pairs(t2) do
		if type(t1[k2]) == 'table' then
			r[k2] = deepmerge(t1[k2], v2, seen)
		else
			r[k2] = v2
		end
	end

	for k1, v1 in pairs(t1) do if r[k1] == nil then r[k1] = v1 end end
	return r, seen
end

local function trace(...)
	log.verbose(...)
end

local function __assert(cond, err, ...)
	if not cond then
		error(err, 2)
	end
	return cond, err, ...
end

--- Instances ETCD object
-- @tparam table cfg configuration of ETCD
-- @treturn ETCD new etcd object
function M.new(cfg)
	assert(cfg ~= M, "Usage: etcd.new({...}) not etcd:new({...})")
	assert(type(cfg.endpoints) == 'table', ".endpoints are required to be table")

	local self = setmetatable({
		prefix      = cfg.prefix or "/",
		endpoints   = {},
		__peers     = cfg.endpoints,
		timeout     = tonumber(cfg.timeout) or 1,
		http_params = cfg.http_params,
		boolean_auto = cfg.boolean_auto,
		integer_auto = cfg.integer_auto,
	}, { __index = M })

	self.http_params = self.http_params or { timeout = self.timeout }

	self.client = setmetatable({
		options = cfg.http_params or { timeout = self.timeout },
		headers = {
			authorization = cfg.login and ("Basic %s"):format(base64.encode(("%s:%s"):format(cfg.login and cfg.password or "")))
		}
	}, { __index = http })

	if cfg.autoconnect then
		self:connect()
	end

	return self
end

--- ETCD node.
-- @table etcdNode
-- @tfield[optional] string key key of the node
-- @tfield[optional] boolean dir is this node a directory
-- @tfield[optional] string value This is value of the node.
-- @tfield[optional] number ttl TTL of the node in seconds.
-- @tfield[optional] string expiration date of expiration in the following format: '2019-11-06T10:04:02.215117744Z'
-- @tfield number createdIndex This specific index reflects the point in the etcd state member at which a given key was created.
-- @tfield number modifiedIndex Actions that cause the value to change include set, delete, update, create, compareAndSwap and compareAndDelete.
-- @tfield[optional] Array(etcdNode) nodes keeps children nodes.

--- ETCD table
-- @table ETCD
-- @field action
-- @tfield etcdNode node

--- Performs general request to ETCD.
-- @param method http method.
-- @param path url path.
-- @param query url query (it is better to transmit a table).
-- @param options options of http request such as timeout and others. They will be directly forwarded to http client.
-- @return[1] false if request failed.
-- @return[1] error string error or table error (if succeeded to decode).
-- @return[1] headers table of headers (may be nil).
-- @return[2] body decoded response body (almost always a table).
-- @return[2] headers headers of http response.
function M:request(method, path, query, options, with_discovery)
	if with_discovery then
		self:discovery()
	end

	local endpoint = self.endpoints[math.random(#self.endpoints)]
	local url = uri.parse(endpoint .. "/" .. path)
	url:setQuery(deepmerge(url.query, query))
	url:normalize()

	local s = clock.time()
	local r, err = self.client.request(method, tostring(url), "", deepmerge(self.client, options))
	trace("%s %s => %s:%s (%.4f)", method, url, r and r.status, r and r.reason, clock.time() - s)

	if not r then
		return false, err or "Unexpected HTTP error", r
	end
	if not r.headers or r.status >= 500 then
		r.headers = {}
		if not with_discovery then
			return self:request(method, path, query, options, true)
		end
	end
	local body
	if r.headers["content-type"]:match("^application/json") then
		local ok, data = pcall(json.decode, r.body)
		if not ok then
			return false, data, r
		end
		body = data
	end
	body = body or ("%s:%s: %s"):format(r.status, r.reason, r.body)
	if r.status >= 500 then
		return false, body, r
	end
	return body, r
end

---
-- Discovers ClientURls from ETCD (updates self.endpoints)
function M:discovery()
	local endpoints = {}
	local peers = {}
	for _, p in ipairs(self.__peers) do
		peers[p] = true
	end
	for _, p in ipairs(self.endpoints) do
		peers[p] = true
	end
	for endpoint in pairs(peers) do
		local url = uri.parse(("%s/%s"):format(endpoint, "/v2/members"))
		url:normalize()

		local s = clock.time()
		local res = self.client.request("GET", tostring(url), "", self.client)

		trace("GET %s => %s:%s (%.4f)", tostring(url), res.status, res.reason, clock.time() - s)

		if res.status ~= 200 then
			goto continue
		end

		local ok, data = pcall(json.decode, res.body)
		if not ok then
			trace("JSON decode of '%s' failed with: %s", res.body, data)
			goto continue
		end

		for _, member in pairs(data.members) do
			for _, u in pairs(member.clientURLs) do
				if not endpoints[u] then
					table.insert(endpoints, u)
					endpoints[u] = #endpoints
				end
			end
		end
		::continue::
	end
	assert(#endpoints > 0, "No endpoints discovered")
	self.endpoints = { unpack(endpoints) }
	return self.endpoints
end

--- Connects to the ETCD cluster discovering all peers.
function M:connect()
	self:discovery()
	trace("Got endpoints: %s", table.concat(self.endpoints, ","))
end

--- Converts ETCD response to Lua table
-- @param root ETCD tree
-- @param prefix a prefix of the call
-- @param[optional] keys_only boolean flag forces to return only keys if true.
-- @param[optional] flatten boolean flag forces to return flat structure instead of subtree.
-- @usage unpacked = etcd:unpack(etcd:get("/some/prefix", { recursive = true }, { raw = true }), "/some/prefix")
-- @return unpacked lua table
function M:unpack(root, prefix, keys_only, flatten)
	local r = {}
	local flat = {}

	local stack = { root }
	repeat
		local node = table.remove(stack)
		if node.key then
			if self.integer_auto then
				if tostring(tonumber(node.key)) == node.key then
					node.key = tonumber(node.key)
				end
			end
			if node.dir then
				flat[node.key] = {}
			elseif keys_only then
				flat[node.key] = true
			else
				if self.boolean_auto then
					if node.value == "true" then
						node.value = true
					elseif node.value == "false" then
						node.value = false
					end
				end
				if self.integer_auto then
					if tostring(tonumber(node.value)) == node.value then
						node.value = tonumber(node.value)
					end
				end
				flat[node.key] = node.value
			end
		end
		if node.nodes then
			for i = 1, #node.nodes do
				table.insert(stack, node.nodes[i])
			end
		end
	until #stack == 0

	if flatten then
		return flat
	end

	r[prefix:sub(#"/"+1)] = flat[prefix]

	for key, value in pairs(flat) do
		local cur = r
		local len = 0
		for chunk in key:gmatch("([^/]+)/") do
			cur[chunk] = cur[chunk] or {}
			cur = cur[chunk]
			len = len + #"/" + #chunk
		end
		local tail = key:sub(#"/" + len + 1)
		if keys_only then
			table.insert(cur, tail)
		elseif cur[tail] == nil then
			cur[tail] = value
		end
	end

	local sub = r
	for chunk in prefix:gmatch("([^/]+)") do
		sub = sub[chunk]
	end

	return sub
end

function M:_path(path)
	return (("%s/%s"):format(self.prefix, path):gsub("/+", "/"):gsub("/$", ""))
end

--- Gets subtree from ETCD.
-- @param path path of subtree
-- @param flags flags of the request.
-- @param options options of request.
-- @return subtree from ETCD
function M:get(path, flags, options)
	options = options or {}
	flags = flags or {}

	path = self:_path(path)

	local res, hdrs = __assert(self:request("GET", "/v2/keys"..path, flags, options))
	if options.raw then
		return res
	end
	if hdrs.status == 404 then
		return nil
	end

	return self:unpack(res.node, path)
end

--- Returns whole subtree from ETCD
-- @param path path to subtree
-- @param options options of request.
-- @return subtree from ETCD
function M:getr(path, options)
	return self:get(path, { recursive = true }, options)
end

--- Returns listing of keys from subtree
-- @param path path to subtree
-- @param flags ls flags
-- @param options options of http
-- @return listing
function M:ls(path, flags, options)
	flags = flags or {}
	options = options or {}

	local res = self:get(path, flags, deepmerge(options, { raw = true }))
	if options.raw then
		return res
	end

	return self:unpack(res.node, path, true)
end

--- Returns recursive listing of subtree
-- @param path path to subtree
-- @param options options of http
-- @return listing
function M:lsr(path, options)
	return self:ls(path, { recursive = true }, options)
end

--- Waits for changes of given path in ETCD
-- @param path of subtree
-- @param timeout in seconds
-- @return etcd node
function M:wait(path, timeout)
	return __assert(self:request("GET", "/v2/keys"..self:_path(path), { wait = true }, { timeout = timeout }))
end

--- Provides 'mkdir -p' mechanism.
-- @param path path to the directory. All parent directories will be created if not exist.
-- @param[optional] options options of http request
-- @return etcd API response
function M:mkdir(path, options)
	return __assert(self:request("PUT", "/v2/keys"..self:_path(path), { dir = true }, options))
end

--- Provides 'rmdir' mechanism.
-- @param path path ro the directory to delete.
-- @param[optional] options options of http request
-- @return etcd API response
function M:rmdir(path, options)
	return __assert(self:request("DELETE", "/v2/keys"..self:_path(path), { dir = true }, options))
end

--- Provides 'rm' mechanism.
-- @param path path to the resource to delete.
-- @tparam[optional] rmFlags flags of command.
-- @param[optional] options options of http request.
-- @return etcd API response
function M:rm(path, flags, options)
	flags = flags or {}
	return __assert(self:request("DELETE", "/v2/keys"..self:_path(path), flags, options))
end

function M:rmrf(path, options)
	assert(path, "path is required")
	options = options or {}
	return __assert(self:request("DELETE", "/v2/keys"..self:_path(path), { recursive = true, force = true }, options))
end

--- Sets value by path into ETCD.
-- @param path path to the key
-- @param value value of the key
-- @param path_options options of the path
-- @param options options of http request
-- @return etcd API response
function M:set(path, value, path_options, options)
	return __assert(self:request("PUT", "/v2/keys"..self:_path(path), deepmerge(path_options, { value = value }), options))
end

--- Fills up the ETCD config.
-- PUTs structure key be key using CaS prevExists = false denying clearing previous value.
-- @param path path to subtree
-- @param subtree lua table describes subtree
-- @param options options of the request
-- @return etcd API response
function M:fill(path, subtree, options)
	path = path:gsub("/+$", "/")
	options = options or {}

	local flat = {}
	local stack = { subtree }
	local map = { [subtree] = path }
	repeat
		local node = table.remove(stack)
		for key, sub in pairs(node) do
			local fullpath = map[node] .. "/" .. key
			if map[sub] then
				error(("Caught recursive subtree. Key '%s' can be reached via '%s'"):format(map[sub], fullpath), 2)
			end
			if type(sub) == 'table' then
				map[sub] = fullpath
				table.insert(stack, sub)
			else
				flat[fullpath] = tostring(sub)
			end
		end
	until #stack == 0

	local rawlist = self:get(path, { recursive = true }, { raw = true }).node
	local current
	if rawlist then -- can be nil ;)
		current = self:unpack(rawlist, path, false, true)
	end

	for newkey, newvalue in pairs(flat) do
		local body, headers = self:request("PUT", "/v2/keys/" .. newkey, { prevExists = false, value = newvalue }, options)
		if headers.status ~= 201 then
			error(body, 2)
		end
	end

	return current
end

return M

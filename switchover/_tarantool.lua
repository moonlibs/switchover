local Tarantool = {}
Tarantool.__index = Tarantool

local netbox = require 'net.box'
local json = require 'json'

function Tarantool:__tostring()
	return ("Tarantool [%s/%s] vclock: %s ro: %s"):format(
		self:id(), self:uuid(), json.encode(self:vclock()), self:ro()
	)
end

function Tarantool:new(endpoint)
	return setmetatable({
		conn = netbox.connect(endpoint),
		endpoint = endpoint,
	}, self)
end

function Tarantool:id()
	return tonumber(self:info().id)
end

function Tarantool:uuid()
	return self:info().uuid
end

function Tarantool:cluster_uuid()
	return self:info().cluster.uuid
end

function Tarantool:vclock()
	return self:info().vclock
end

function Tarantool:ro()
	return self:info().ro
end

function Tarantool:upstreams()
	local ups = {}
	for id, r in pairs(self:info().replication) do
		if r.upstream and id ~= self:id() then
			table.insert(ups, r)
		end
	end
	return ups
end

function Tarantool:info(opts)
	opts = opts or {}
	if not self.cached_info or opts.update then
		self.cached_info = self.conn:call("box.info")
	end
	return self.cached_info
end

return setmetatable(Tarantool, { __call = Tarantool.new })
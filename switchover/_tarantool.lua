local Tarantool = {}
Tarantool.__index = Tarantool

local log = require 'log'
local fun = require 'fun'
local json = require 'json'
local fiber = require 'fiber'
local netbox = require 'net.box'
local v = require 'semver'

function Tarantool:__tostring()
	return ("Tarantool %s [%s/%s] vclock:%s %-7s replication: %s"):format(
		self.endpoint, self:id(), self:uuid(), json.encode(self:vclock()),
		self:role(), self:replication()
	)
end

function Tarantool:on_connect()
	log.verbose("Connected %s", self)
	self:start_discovery()
end

function Tarantool:new(endpoint, opts)
	log.verbose("Connecting to %s, async=%s", endpoint, opts.async)
	local conn = netbox.connect(endpoint, {
		wait_connected = opts.async ~= true,
		timeout = 30,
		reconnect_after = 0.1,
	})
	local tnt = setmetatable({
		conn = conn,
		endpoint = endpoint,
		discovery_timeout = opts.discovery_timeout or 0.1,
	}, self)
	conn:on_connect(function(_)
		fiber.create(function()
			Tarantool.on_connect(tnt)
			if opts.on_connect then
				opts.on_connect(tnt)
			end
		end)
	end)
	if not opts.async then
		(opts.on_connect or Tarantool.on_connect)(tnt)
	end
	return tnt
end

function Tarantool:start_discovery(to)
	to = to or self.discovery_timeout
	self.discovery_f = fiber.create(function(tnt)
		repeat
			tnt:_get{ update = true }
			fiber.sleep(to)
		until tnt.discovery_f ~= fiber.self()
		log.verbose("Leaving discovery of %s", self)
	end, self)
end

function Tarantool:id(opts)
	return tonumber(self:info(opts).id)
end

function Tarantool:uuid(opts)
	return self:info(opts).uuid
end

function Tarantool:cluster_uuid(opts)
	return self:info(opts).cluster.uuid
end

function Tarantool:version(opts)
	return v(self:info(opts).version)
end

function Tarantool:vclock(opts)
	return self:info(opts).vclock
end

function Tarantool:ro(opts)
	return self:info(opts).ro
end

function Tarantool:role(opts)
	return self:info(opts).ro == true and 'replica' or 'master'
end

function Tarantool:replication(opts)
	return table.concat(fun.iter(self:upstreams(opts))
		:map(function(r) return ("%s/%s:%.4fs"):format(r.id, r.upstream.status, r.upstream.lag) end)
		:totable(), ",")
end

function Tarantool:upstreams(opts)
	local ret = fun.iter(self:info(opts).replication):grep(function(r)
		return r.upstream and r.id ~= self:id()
	end):totable()
	table.sort(ret, function(a, b) return a.id < b.id end)
	return ret
end

function Tarantool:downstreams(opts)
	local ret = fun.iter(self:info(opts).replication):grep(function(r)
		return r.downstream and r.id ~= self:id()
	end):totable()
	table.sort(ret, function(a, b) return a.id < b.id end)
	return ret
end

function Tarantool:followed_downstreams(opts)
	local ret = fun.iter(self:info(opts).replication):grep(function(r)
		return r.downstream and r.id ~= self:id() and r.downstream.status == 'follow'
	end):totable()
	table.sort(ret, function(a, b) return a.id < b.id end)
	return ret
end

function Tarantool:followed_upstreams(opts)
	local ret = fun.iter(self:info(opts).replication):grep(function(r)
		return r.upstream and r.id ~= self:id() and r.upstream.status == 'follow'
	end):totable()
	table.sort(ret, function(a, b) return a.id < b.id end)
	return ret
end

function Tarantool:replicates_from(instance_uuid)
	return fun.iter(self:upstreams()):grep(function(r)
		return r.uuid == instance_uuid and r.upstream.status == 'follow'
	end):nth(1)
end

function Tarantool:replicated_by(instance_uuid)
	return fun.iter(self:downstreams()):grep(function(r)
		return r.uuid == instance_uuid and r.downstream.status == 'follow'
	end):nth(1)
end

function Tarantool:info(opts)
	self:_get(opts)
	return self.cached_info
end

function Tarantool:cfg(opts)
	self:_get(opts)
	return self.cached_cfg
end

function Tarantool:_get(opts)
	if not self.cached_info or not self.cached_cfg or (opts or {}).update then
		self.cached_info, self.cached_cfg, self.can_package_reload, self.has_vshard, self.has_etcd =
			self.conn:eval [[
				return
					box.info,
					box.cfg,
					type(package.reload) ~= 'nil',
					rawget(_G, 'vshard') ~= nil,
					type((package.loaded.config or {}).etcd) ~= 'nil'
			]]
	end
	return self.cached_info, self.cached_cfg
end

function Tarantool:force_promote()
	self.cached_info, self.cached_cfg = self.conn:eval "box.cfg{ read_only = false } return box.info, box.cfg"
end

function Tarantool:package_reload()
	if not self.can_package_reload then
		error(("Instance %s does not support package.reload"):format(self.endpoint), 0)
	end

	log.info("Calling package.reload on %s", self)
	self.cached_info, self.cached_cfg = self.conn:eval [[
		package.reload()
		return box.info, box.cfg
	]]
	return true
end

return setmetatable(Tarantool, { __call = Tarantool.new })
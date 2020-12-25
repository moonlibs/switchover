local M = {}
local fun = require 'fun'
local log = require 'log'
local json = require 'json'
local fiber = require 'fiber'
local Tarantool = require "switchover._tarantool"
local Replicaset = require "switchover._replicaset"
json.cfg{ encode_use_tostring = true, encode_invalid_string = true }

function M.discovery(args)
	local endpoints = args.endpoints
	local tnts = { list = {}, kv = {} }

	local discovery_queue = {
		deadline = fiber.time() + (args.timeout or 5),
		chan = fiber.channel(math.max(#endpoints, 3)),
		count = 0,
		seen = {},
		put = function(self, task)
			if self.deadline < fiber.time() then return false end
			if self.seen[task] then return end

			log.verbose("putting %s", task)
			self.count = self.count + 1
			assert(self.chan:put(task))

			self.seen[task] = true
		end,
		get = function(self)
			local timeout = self.deadline - fiber.time()
			if timeout < 0 then return false end
			local t = self.chan:get(timeout)
			if t then
				self.count = self.count - 1
				return t
			end
		end,
		close = function(self)
			self.chan:close()
		end,
		deadline_reached = function(self) return self.deadline < fiber.time() end,
	}

	for _, e in ipairs(endpoints) do
		discovery_queue:put(e)
	end

	local connecting = {}
	while true do
		local task = discovery_queue:get()
		if not task then break end

		-- we save Tarantool objects to prevent them from erase (gc issue)
		connecting[task] = Tarantool(task, {
			async = true,
			on_connect = function(tnt)
				local uuid = tnt:uuid()
				connecting[task] = nil

				if tnts.kv[uuid] then return end

				table.insert(tnts.list, tnt)
				tnts.kv[uuid] = tnt

				for _, r in ipairs(tnt:cfg().replication) do
					discovery_queue:put(r)
				end

				if discovery_queue.count == 0 and not next(connecting) then
					discovery_queue:close()
				end
			end,
		})
	end

	if discovery_queue:deadline_reached() then
		log.warn("Took to long to discovery all instances. "
			.."Continuing with instances which were discovered")
	end

	if not args.show_graph and #tnts.list > 0 then
		log.info("Discovered %s nodes from %s: %s in %.3fs",
			#tnts.list, table.concat(args.endpoints, ','),
			table.concat(fun.iter(tnts.list)
				:map(function(t) return ("%s/%s"):format(t.endpoint, t:role()) end)
				:totable(),
				","
			),
			fiber.time()-_G.global.start_at
		)
	end

	return tnts
end

function M.run(args)
	assert(args.command == "discovery")

	local tnts = M.discovery(args)
	if #tnts.list == 0 then
		error("No nodes discovered", 0)
	end

	local replicaset = Replicaset(tnts.list)

	if args.show_graph then
		print(replicaset:graph())
		return
	end

	for _, r in ipairs(replicaset:scored()) do
		log.info("%d %s", r:id(), r)
	end
end

return M
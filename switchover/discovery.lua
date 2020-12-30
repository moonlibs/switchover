local M = {}
local fun = require 'fun'
local log = require 'log'
local json = require 'json'
local yaml = require 'yaml'
local fiber = require 'fiber'
local Tree = require "switchover._tree"
local Tarantool = require "switchover._tarantool"
local Replicaset = require "switchover._replicaset"
json.cfg{ encode_use_tostring = true, encode_invalid_string = true }


function M.discovery(args)
	local tnts = { list = {}, kv = {} }
	local endpoints = args.endpoints

	local tree
	if #args.endpoints == 0 or not args.endpoints[1]:match ":" then
		if not global.etcd then
			error(("Cannot discovery instance %s without etcd"):format(args.endpoints[1]), 0)
		end
		if #args.endpoints > 1 then
			log.error("Too many endpoints to discovery in ETCD. Use cluster_name")
			os.exit(1)
		end

		local path = args.endpoints[1]
		log.info("Fetching %s from ETCD", path)

		local etcd_tree = global.etcd:getr(path)
		if not etcd_tree then
			log.error("Path %s not found in ETCD: fullpath: %s/%s", path, global.etcd.prefix, path)
			os.exit(1)
		end

		tree = Tree {
			path = path,
			etcd = global.etcd,
			tree = etcd_tree,
		}
		if not tree.instances then
			error(("Cannot find %s in ETCD"):format(path), 0)
		end

		log.verbose(yaml.encode(tree.tree))

		local master, master_name = tree:master()
		log.verbose("ETCD master of replicaset %s is %s (at %s)", path, master_name, master.box.listen)

		endpoints = tree:instances()
		global.tree = tree
	end

	local discovery_queue = {
		deadline = fiber.time() + (args.discovery_timeout or 5),
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

	if not args.endpoints and not global.etcd then
		error("endpoints or etcd must be specified", 0)
	end

	if not args.endpoints then args.endpoints = {''} end

	local tnts = M.discovery(args)
	if #tnts.list == 0 then
		error("No nodes discovered", 0)
	end

	local replicaset = Replicaset(tnts.list)

	if args.show_graph then
		local graphviz = replicaset:graph()
		if args.link_graph then
			print('https://dreampuf.github.io/GraphvizOnline/#'..(graphviz:gsub("([^A-Za-z0-9%_%.%-%~])", function(v)
				return ("%%%02x"):format(v:byte()):upper()
			end)))
		else
			print(graphviz)
		end
		return
	end

	local etcd_master
	if global.tree then
		etcd_master = global.tree:master()
	end

	for _, r in ipairs(replicaset:scored()) do
		if etcd_master then
			if etcd_master.box.instance_uuid == r:uuid() then
				log.info("%d etcd_master  %s", r:id(), r)
			else
				log.info("%d etcd_replica %s", r:id(), r)
			end
		else
			log.info("%d %s", r:id(), r)
		end
	end
end

return M
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
	assert(#endpoints > 0, "You muyst specify at least 1 endpoint for discovery")

	local discovery_timeout = args.discovery_timeout or args.timeout or 5

	local tree
	if #args.endpoints == 1 and not args.endpoints[1]:match ":" then
		if not global.etcd then
			error(("Cannot discovery instance %s without etcd"):format(args.endpoints[1]), 0)
		end

		local appname = args.endpoints[1]
		local shard
		if appname:match("/") then
			appname, shard = assert(appname:match("^(.+)/(.+)$"))
			log.info("Discovering shard:%s inside app:%s", shard, appname)
		end
		log.info("Fetching %s from ETCD", appname)

		local etcd_tree = global.etcd:getr(appname)
		if not etcd_tree then
			log.error("Path %s not found in ETCD: fullpath: %s/%s", appname, global.etcd.prefix, appname)
			os.exit(1)
		end

		tree = Tree {
			path = appname,
			etcd = global.etcd,
			tree = etcd_tree,
			shard = shard, -- can be nil, it means that Tree must contain single shard
		}
		log.verbose(yaml.encode(tree.tree))

		local master, master_name = tree:master()
		log.verbose("ETCD master of replicaset %s is %s (at %s)", appname, master_name, master.box.listen)

		endpoints = tree:instances()
		global.tree = tree
	end

	local discovery_queue = {
		deadline = fiber.time() + discovery_timeout,
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

function M.resolve_and_discovery(instance, timeout, cluster_name)
	local endpoints, look_at_etcd
	if instance:match(":") then
		endpoints = { instance }
	elseif instance:match("/") then
		look_at_etcd = true
	else
		look_at_etcd = true
		endpoints = { cluster_name }
		if not cluster_name then
			error("You must specify cluster_name (--cluster option)", 0)
		end
	end

	local tnts = M.discovery {
		endpoints = endpoints,
		timeout   = timeout,
	}

	if #tnts.list == 0 then
		error(("Noone discovered from %s. Node is unreachable?"):format(instance), 0)
	end

	if look_at_etcd then
		local instance_info = assert(global.tree:instance(instance),
			("instance %s wasnt discovered at ETCD"):format(instance))
		instance = assert(instance_info.box.listen)
	end

	local candidate = fun.iter(tnts.list)
		:grep(function(tnt) return tnt.endpoint == instance end)
		:nth(1)

	if not candidate then
		error(("Candidate %s was not discovered"):format(instance), 0)
	end

	return tnts, candidate
end

function M.run(args)
	assert(args.command == "discovery")

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
		global.tree:refresh()
		etcd_master = global.tree:master()
	end

	for _, r in ipairs(replicaset:scored()) do
		if etcd_master then
			local _, name = global.tree:by_uuid(r:uuid())
			if etcd_master.box.instance_uuid == r:uuid() then
				log.info("%d/%s etcd_master %s", r:id(), name, r)
			else
				log.info("%d/%s etcd_replica %s", r:id(), name, r)
			end
		else
			log.info("%d %s", r:id(), r)
		end
	end
end

return M
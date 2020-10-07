local M = {}
local log = require 'log'
local json = require 'json'
local Tarantool = require "switchover._tarantool"
local Cluster = require "switchover._cluster"
json.cfg{ encode_use_tostring = true, encode_invalid_string = true }


function M.run(args)
	assert(args.command == "discovery")
	local endpoints = args.endpoints

	local tnts = {}
	local clusters = {}
	local n_clusters = 0

	local upstreams = {}
	for _, e in ipairs(endpoints) do
		local t = Tarantool(e)
		table.insert(tnts, t)

		upstreams[t:uuid()] = true

		local cluster_uuid = t:cluster_uuid()
		local cls = clusters[cluster_uuid]
		if not cls then
			cls = Cluster(cluster_uuid)
			clusters[cluster_uuid] = cls
			n_clusters = n_clusters + 1
		end

		cls:add_replica(t)
	end

	log.info("Discovered %s clusters from %s", n_clusters, table.concat(endpoints, ','))
	-- log.info("Discovering rest part of the cluster through upstreams")
	-- for _, cluster in pairs(clusters) do
	-- 	for _, replica in pairs(cluster.replicas) do
	-- 		for _, r in ipairs(replica:upstreams()) do
	-- 			if not upstreams[r.uuid] then
	-- 				log.info("Upstream %s discovered at %s through replica %s/%s",
	-- 					r.uuid, r.upstream.peer, replica:uuid(), replica:id())

	-- 				local t = Tarantool(r.upstream.peer)
	-- 				local c_uuid = t:cluster_uuid()

	-- 				clusters[c_uuid] = clusters[c_uuid] or Cluster(c_uuid)
	-- 				clusters[c_uuid]:add_replica(t)
	-- 			end
	-- 		end
	-- 	end
	-- end

	for _, cluster in pairs(clusters) do
		cluster:topology()
	end

end

return M
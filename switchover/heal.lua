local M = {}
local fun = require 'fun'
local log = require 'log'
local json = require 'json'
local Replicaset = require "switchover._replicaset"
json.cfg{ encode_use_tostring = true, encode_invalid_string = true }

function M.etcd_switch(args)
	local etcd_master = assert(args.etcd_master, "etcd_switch: .etcd_master required")
	local candidate_uuid = assert(args.candidate_uuid, "etcd_switch: .candidate_uuid required")
	local etcd_master_name = assert(args.etcd_master_name, "etcd_switch: .etcd_master_name required")

	assert(global.etcd, "etcd_switch: .etcd is required")

	if candidate_uuid == etcd_master.box.instance_uuid then
		log.info("%s already registered as master", candidate_uuid)
		return 0
	end

	local etcd_candidate, etcd_candidate_name = global.tree:by_uuid(candidate_uuid)
	if not etcd_candidate_name then
		log.error("Instance %s wasn't found in etcd (at %s)", candidate_uuid, global.tree.path)
		os.exit(1)
	end

	if etcd_candidate.cluster ~= etcd_master.cluster then
		log.error("Candidate (%s/cluster:%s) and master (%s/cluster:%s) are from different clusters. Fix ETCD by yourself!",
			etcd_candidate_name, etcd_candidate.cluster, etcd_master_name, etcd_master.cluster)
		os.exit(1)
	end

	log.info("Changing master in ETCD: %s -> %s", etcd_master_name, etcd_candidate_name)

	-- Perform CAS
	local r = global.etcd:set(global.tree.path.."/clusters/"..etcd_master.cluster.."/master", etcd_candidate_name, { prevValue = etcd_master_name })
	log.info("ETCD response: %s", json.encode(r))

	if r.action == 'compareAndSwap' then
		return true
	end

	log.error("ETCD unexpectedly failed.")
	os.exit(1)
end


function M.run(args)
	assert(args.command == "heal")

	if not global.etcd then
		error("ETCD configuration is required", 0)
	end

	local tnts = require 'switchover.discovery'.discovery {
		endpoints = { args.cluster },
	}

	if #tnts.list == 0 then
		error("No nodes discovered", 0)
	end

	local replicaset = Replicaset(tnts.list)
	local master = replicaset:master()

	-- Check liveness of replication of master
	local ups, downs = replicaset:score(master)

	-- We need quorum?
	local quorum = math.ceil((#tnts.list+1)/2)-1 -- N/2+1 except self
	if #ups < quorum then
		log.error("Master %s has too little upstreams: %s (required >= %s)", master.endpoint,
			table.concat(fun.iter(ups):map(function(r) return r.endpoint end):totable(), ","), quorum)
		return 1
	end
	if #downs < quorum then
		log.error("Master %s has too little downstreams: %s (required >= %s)", master.endpoint,
			table.concat(fun.iter(downs):map(function(r) return r.endpoint end):totable(), ","), quorum)
		return 1
	end

	local etcd_master, etcd_master_name = global.tree:master()

	return M.etcd_switch {
		etcd_master = etcd_master,
		etcd_master_name = etcd_master_name,
		candidate_uuid = master:uuid(),
	}
end

return M
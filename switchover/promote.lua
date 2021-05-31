local M = {}

local log = require 'log'
local fun = require 'fun'
local Mutex = require 'switchover._mutex'
local Replicaset = require 'switchover._replicaset'


local function fail(candidate)
	error(("Candidate %s cannot be the leader. Run `discovery` to choose another candidate"):format(
		candidate.endpoint), 0)
end

local function run_package_reload(tarantool, etcd)
	if not tarantool.can_package_reload then
		return true
	end
	if tarantool.has_etcd and not etcd then
		log.error("ERROR: Can't run package.reload for %s because it is configured from ETCD",
			tarantool)
		return false
	end
	return tarantool:package_reload()
end

function M.run(args)
	assert(args.command == "promote")

	local tnts, candidate = require "switchover.discovery".resolve_and_discovery(
		args.instance, args.discovery_timeout, args.cluster
	)

	local repl = Replicaset(tnts.list)
	if repl:master() then
		error("can't promote anyone because master exists. Use `switch`", 0)
	end

	if candidate.no_downstreams and not args.no_check_downstreams then
		log.error("Candidate '%s' does not have live downstreams", candidate.endpoint)
		log.warn("Candidate %s", candidate)
		fail(candidate)
	end
	if candidate.no_upstreams and not args.no_check_upstreams then
		log.error("Candidate '%s' does not have live upstreams", candidate.endpoint)
		log.warn("Candidate %s", candidate)
		fail(candidate)
	end
	if candidate.has_vshard and not args.allow_vshard then
		log.error("Can't promote: instance is in vshard cluster")
		return 1
	end

	-- Check that all nodes may receive data from candidate
	log.info("Candidate %s can be next leader", candidate)

	local etcd = _G.global.etcd
	if not etcd and not args.no_etcd then
		log.error("ETCD cfg is required")
		return 1
	end

	local ok, err
	if etcd and not args.no_etcd then
		ok, err = Mutex:new(etcd, global.tree:cluster_path()..'/switchover'):atomic({
				key = ('switchover:%s:%s'):format(repl.uuid, candidate:uuid()),
				ttl = 3*args.max_lag,
			},
			candidate.force_promote,
			candidate
		)
	else
		ok, err = pcall(candidate.force_promote, candidate)
	end

	if not err then
		log.info("Candidate %s/%s was promoted. Performing discovery",
			candidate:id(), candidate.endpoint)

		if etcd then
			global.tree:refresh()

			local etcd_master, etcd_master_name = global.tree:master()
			require 'switchover.heal'.etcd_switch {
				etcd_master = etcd_master,
				etcd_master_name = etcd_master_name,
				candidate_uuid = candidate:uuid(),
			}
		end

		if args.with_reload then
			if not run_package_reload(candidate, etcd) then
				log.error("ERROR: Failed to execute package.reload on new master")
			end
		end
	elseif ok then
		log.warn("Promote failed but replicaset is consistent. Reason: %s", err)
	else
		log.error("ALERT: Promote ruined your replicaset. Restore it by yourself. Reason: %s", err)
	end

	return require 'switchover.discovery'.run {
		command = 'discovery',
		endpoints = fun.iter(repl.replica_list)
			:map(function(t)return t.endpoint end)
			:totable(),
		timeout = args.discovery_timeout,
	}
end

return M
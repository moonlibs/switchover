local M = {}

local log = require 'log'
local fun = require 'fun'
local json = require 'json'
local Mutex = require 'switchover._mutex'
local Replicaset = require 'switchover._replicaset'
local v = require 'semver'
local minimal_supported_version = v'1.10.0'


local function fail(candidate)
	error(("Candidate %s cannot be the leader. Run `discovery` to choose another candidate"):format(
		candidate.endpoint), 0)
end

local function check_replication(opts)
	local src, dst = opts.src, opts.dst
	assert(opts.max_lag, "check_replication: max_lag is required")

	local vclock = src:vclock({ update = true })
	local need_lsn = vclock[src:id()] or 0

	local info, cfg, elapsed = dst.conn:eval([==[
		local lsn, id, timeout = ...
		local f = require 'fiber'
		local deadline = f.time()+timeout
		while (box.info.vclock[id] or 0) < lsn and f.time()<deadline do f.sleep(0.001) end
		return box.info, box.cfg, f.time()-(deadline-timeout)
	]==], { need_lsn, src:id(), opts.max_lag }, { timeout = 2*opts.max_lag })

	dst.cached_info = info
	dst.cached_cfg = cfg

	if need_lsn <= (dst:vclock()[src:id()] or 0) then
		log.info("wait_clock(%s, %s) on %s succeed %s => %.4fs", need_lsn, src:id(), dst:id(),
			json.encode(dst:vclock()), elapsed)
		return true
	else
		log.warn("wait_clock(%s, %s) on %s failed %s => %.4fs", need_lsn, src:id(), dst:id(),
			json.encode(dst:vclock()), elapsed)
		return false
	end
end

local function switch(opts)
	local src, dst = opts.src, opts.dst
	assert(opts.max_lag, "check_replication: max_lag is required")

	log.info("Running switch for: %s/%s (%s vclock:%s) -> %s/%s (%s vclock: %s)",
		src:id(), src:uuid(), src.endpoint, json.encode(src:vclock()),
		dst:id(), dst:uuid(), dst.endpoint, json.encode(dst:vclock())
	)

	local info, elapsed = src.conn:eval([==[
		local dst, lag = ...
		if lag < box.info.replication[dst].upstream.lag then
			return false, "lag too large. refusing to switch master to RO"
		end

		local f = require 'fiber'
		local log = require 'log'
		local deadline = f.time()+lag

		box.cfg{ read_only = true }
		f.yield()

		log.warn("switchover: Waiting for replication[%s].downstream.vclock[%s] == %s (box.info.lsn)",
			dst, box.info.id, box.info.lsn)

		while f.time() < deadline do
			if box.info.lsn <= (box.info.replication[dst].downstream.vclock[box.info.id] or 0) then
				break
			end
			f.sleep(math.min(
				deadline - f.time(),
				math.max(0.005, box.info.replication[dst].upstream.lag) )
			)
		end

		if deadline < f.time() then
			log.warn("switchover: (data safe %s) Timed out reached. Rollback the switch (calling box.cfg{ read_only = false }",
				dst)
			box.cfg{ read_only = false }
			return false, "timed out while wait of active transactions"
		end

		log.warn("switchover: Master was switched to RO state successfully")

		return box.info, f.time() - (deadline-lag)
	]==], { dst:id(), tonumber(opts.max_lag) }, { timeout = 2*opts.max_lag })

	if not info then
		-- Data is consistent, but switchover failed
		local err = elapsed
		return true, err
	end

	src.cached_info = info
	log.info("Master is in RO: %s took %.4fs", src, elapsed)

	info, elapsed = dst.conn:eval([==[
		local lsn, id, timeout = ...
		local log = require 'log'
		local clock = require 'clock'
		local f = require 'fiber' local s = f.time()
		local deadline = s+timeout

		while (box.info.vclock[id] or 0) < lsn and clock.time() < deadline do f.sleep(0.001) end

		if deadline < clock.time() then
			log.warn("switchover: (data safe) Timed out reached. Node wont be promoted to master")
			return false, ("timed out. no switch were done: %.4fs"):format(f.time()-s), box.info
		end

		if lsn <= (box.info.vclock[id] or 0) then
			log.warn("switchover: (success) LSN successfully reached. "
				.."Calling box.cfg{ read_only = false } (node will become master)")
			box.cfg{ read_only = false }
			return box.info, f.time()-s
		end

		log.error("switchover: (data safe) switchover failed. LSN %s:%s wasnt reached", id, lsn)
		return false, ("lsn was not reached in: %.4fs"):format(f.time()-s), box.info
	]==], { src:info().lsn or 0, src:id(), opts.max_lag }, { timeout = 2*opts.max_lag })

	if info and info.ro == false then
		dst.cached_info = info
		log.info("Candidate is in RW state took: %.4fs", elapsed)
		return true
	end

	-- Switchover failed
	local err = elapsed
	log.error("Waiting vclock on replica failed: %s", err)

	if dst:info{ update = true }.ro ~= true then
		return false, "Can't rollback the switchover. Candidate is already in RW"
	end

	log.info("Candidate is still ro: %s", dst)
	log.info('Rollback the switch')

	local rollback_ok, rollback_err = src.conn:eval([[
		local log = require 'log'
		log.warn("switchover: (unsafe) Calling box.cfg{ read_only = false }")
		box.cfg{ read_only = false }
		return box.info
	]], {}, { timeout = 2*opts.max_lag })

	if rollback_ok then
		log.info("Rollback succeed: %s", src)
	else
		log.error("Rollback failed: %s", rollback_err)
	end

	return true, err
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

local function run_switch(etcd, replicaset, args)
	local master = args.src
	local candidate = args.dst

	local ok, err
	if etcd then
		ok, err = Mutex:new(etcd, global.tree:cluster_path()..'/switchover')
			:atomic(
				{ -- key
					key = ('switchover:%s:%s:%s'):format(replicaset.uuid, master:uuid(), candidate:uuid()),
					ttl = 3*args.max_lag,
				},
				switch, -- function
				{ -- arguments of the function
					src = master,
					dst = candidate,
					max_lag = args.max_lag
				}
			)
	else
		log.warn("WARN: Doing switch %s -> %s without ETCD lock",
			master.endpoint, candidate.endpoint)

		local r = { pcall(switch, { src = master, dst = candidate, max_lag = args.max_lag }) }
		local pcall_ok = table.remove(r, 1)
		if pcall_ok then
			ok, err = unpack(r)
		else
			ok, err = pcall_ok, r[1]
		end
	end
	return ok, err
end

function M.run(args)
	assert(args.command == "switch")
	local tnts, candidate = require "switchover.discovery".resolve_and_discovery(
		args.instance, args.discovery_timeout, args.cluster)

	local repl = Replicaset(tnts.list)
	local master = repl:master()
	if not master then
		error("can't promote anyone because no master found", 0)
	end

	if candidate == master then
		log.info("Candidate %s already master", candidate.endpoint)
		return 1
	end

	if candidate.no_master_upstream and not args.no_check_master_upstream then
		log.error("Candidate '%s' does not replicate data from master '%s'", candidate.endpoint, master.endpoint)
		log.warn("Candidate %s", candidate)
		log.warn("Master    %s", master)
		fail(candidate)
	end
	if candidate.no_downstreams and not args.no_check_downstreams then
		log.error("Candidate '%s' does not have live downstreams", candidate.endpoint)
		log.warn("Candidate %s", candidate)
		fail(candidate)
	end

	-- Check that all nodes may receive data from candidate
	log.info("Candidate %s can be next leader (current: %s/%s). Running replication check (safe)",
		candidate, master:id(), master.endpoint)

	if master.has_vshard and not args.allow_vshard then
		log.error("Can't do switch because master is in vshard cluster")
		return 1
	end
	if candidate.has_vshard and not args.allow_vshard then
		log.error("Can't do switch because candidate is in vshard cluster")
		return 1
	end

	if master:version() < minimal_supported_version then
		log.error("Can't switch because master has unsupported Tarantool version: %s (required at least %s)",
			master:version(), minimal_supported_version)
		return 1
	end
	if candidate:version() < minimal_supported_version then
		log.error("Can't switch because candidate has unsupported Tarantool version: %s (required at least %s)",
			candidate:version(), minimal_supported_version)
		return 1
	end

	if not check_replication {src = master, dst = candidate, max_lag = args.max_lag} then
		log.error("Live replication monitoring failed %s -> %s",
			master.endpoint, candidate.endpoint)
		fail(candidate)
	end

	log.info("Replication %s/%s -> %s/%s is good. Lag=%.4fs",
		master:id(), master.endpoint,
		candidate:id(), candidate.endpoint,
		candidate:info().replication[master:id()].upstream.lag)

	local etcd = _G.global.etcd

	if not etcd and not args.no_etcd then
		log.error("ETCD cfg is required")
		return 1
	end

	if args.no_etcd then
		etcd = false
	end

	local ok, err = run_switch(etcd, repl, {
		src = master, dst = candidate, max_lag = args.max_lag,
	})

	if not err then
		log.info("Switch %s/%s -> %s/%s was successfully done",
			master:id(), master.endpoint, candidate:id(), candidate.endpoint)

		if etcd then
			global.tree:refresh()

			local etcd_master, etcd_master_name = global.tree:master()
			require 'switchover.heal'.etcd_switch {
				etcd_master = etcd_master,
				etcd_master_name = etcd_master_name,
				candidate_uuid = candidate:uuid(),
			}

			global.tree:refresh()
		end

		if args.with_reload then
			log.info("Perfoming package.reload")
			run_package_reload(candidate, etcd)
			run_package_reload(master, etcd)
		end
	elseif ok then
		log.warn("Switchover failed but replicaset is consistent. Reason: %s", err)
	else
		log.error("ALERT: Switchover ruined your replicaset. Restore it by yourself. Reason: %s", err)
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
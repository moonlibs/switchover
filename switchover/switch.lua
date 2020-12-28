local M = {}

local log = require 'log'
local fun = require 'fun'
local Mutex = require 'switchover._mutex'
local Replicaset = require 'switchover._replicaset'


local function fail(candidate)
	error(("Candidate %s cannot be the leader. Run `discovery` to choose another candidate"):format(
		candidate.endpoint), 0)
end

local function check_replication(opts)
	local src, dst = opts.src, opts.dst
	assert(opts.max_lag, "check_replication: max_lag is required")

	local vclock = src:vclock({ update = true })
	return dst:wait_clock(vclock[src:id()] or 0, src:id(), opts.max_lag)
end

local function switch(opts)
	local src, dst = opts.src, opts.dst
	assert(opts.max_lag, "check_replication: max_lag is required")

	log.info("Running switchover for:")
	log.info("src %s", src)
	log.info("dst %s", dst)


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

		while (box.info.replication[dst].downstream.vclock[ box.info.id ] < box.info.lsn) and (f.time() < deadline) do
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
		local f = require 'fiber' local s = f.time()
		local deadline = s+timeout

		while (box.info.vclock[id] or 0) < lsn and f.time() < deadline do f.sleep(0.001) end

		if deadline < f.time() then
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
		return false, ("lsn wasnot reached in: %.4fs"):format(f.time()-s), box.info
	]==], { src:info().lsn or 0, src:id(), opts.max_lag }, { timeout = 2*opts.max_lag })

	if info and info.ro == false then
		log.warn("Switch successfully done.")
		dst.cached_info = info
		return true
	end

	-- Switchover failed
	local err = elapsed
	log.error("Waiting vlock on replica failed: %s", err)

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

function M.run(args)
	assert(args.command == "switch")

	local endpoints, look_at_etcd
	if not args.instance:match(":") then
		look_at_etcd = true
		endpoints = { "" }
	else
		endpoints = { args.instance }
	end

	local tnts = require 'switchover.discovery'.discovery {
		endpoints = endpoints,
		timeout   = args.timeout,
	}

	if #tnts.list == 0 then
		error(("Noone discovered from %s. Node is unreachable?"):format(args.instance), 0)
	end

	if look_at_etcd then
		local instance_info = assert(global.tree:instance(args.instance), ("instance %s wasnt discovered at ETCD"):format(args.instance))
		args.instance = assert(instance_info.box.listen)
	end

	local candidate = fun.iter(tnts.list)
		:grep(function(tnt) return tnt.endpoint == args.instance end)
		:nth(1)

	if not candidate then
		error(("Candidate %s was not discovered"):format(args.instance), 0)
	end

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

	if not check_replication {src = master, dst = candidate, max_lag = args.max_lag} then
		log.error("Live replication monitoring failed %s -> %s",
			master.endpoint, candidate.endpoint)
		fail(candidate)
	end

	log.info("Replication %s/%s -> %s/%s is good. Lag=%.4fs",
		master:id(), master.endpoint,
		candidate:id(), candidate.endpoint,
		candidate:info().replication[master:id()].upstream.lag)

	-- TODO: work with ETCD
	local etcd = _G.global.etcd

	if not etcd and not args.no_etcd then
		log.error("ETCD cfg is required")
		return 1
	end

	local ok, err = Mutex:new(etcd, '/switchover'):atomic({
			key = ('switchover:%s:%s:%s'):format(repl.uuid, master:uuid(), candidate:uuid()),
			ttl = 3*args.max_lag,
		},
		switch,
		{
			src = master,
			dst = candidate,
			max_lag = args.max_lag
		}
	)

	if not err then
		log.info("Switch %s/%s -> %s/%s was successfully done. Performing discovery",
			master:id(), master.endpoint, candidate:id(), candidate.endpoint)

		if etcd then
			global.tree:refresh()

			local etcd_master, etcd_master_name = global.tree:master()
			require 'switchover.heal'.etcd_switch {
				etcd_master = etcd_master,
				etcd_master_name = etcd_master_name,
				candidate_uuid = candidate:uuid(),
			}
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
		timeout = args.timeout,
	}
end

return M
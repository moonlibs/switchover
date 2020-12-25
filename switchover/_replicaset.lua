local Replicaset = {}
Replicaset.__index = Replicaset

local log = require 'log'
local json = require 'json'


-- Vclock comparing function (copied from vshard/storage/init.lua)
local function vclock_lesseq(vc1, vc2)
	local lesseq = true
	for i, lsn in ipairs(vc1) do
		lesseq = lesseq and lsn <= (vc2[i] or 0)
		if not lesseq then
			break
		end
	end
	return lesseq
end

--- summarizes vclock of the replicas except self
local function vclock_signature(r1)
	local sum = 0
	for id, lsn in pairs(r1:vclock()) do
		if r1:id() ~= id then
			sum = sum + lsn
		end
	end
	return sum
end

local function vclock_gt(r1, r2)
	local v1, v2 = r1:vclock(), r2:vclock()
	-- how do we order vclock ?

	if vclock_lesseq(v1, v2) then
		return v2
	elseif vclock_lesseq(v2, v1) then
		return v1
	else
		-- choose the one with greatest signature?
		if vclock_signature(r1) < vclock_signature(r2) then
			return r2
		else
			return r1
		end
	end
end

function Replicaset:new(tnts)
	local replicaset = setmetatable({ replicas = {}, replica_list = {} }, self)
	for _, tnt in ipairs(tnts) do
		if not replicaset.uuid then
			replicaset.uuid = tnt:info().cluster.uuid
		end
		replicaset:add_replica(tnt)
	end
	replicaset:scored()
	return replicaset
end

function Replicaset:check_cluster_uuid(tnt)
	if tnt:info().cluster.uuid ~= self.uuid then
		error(("Cluster uuid missmatch for %s: expected %s got %s"):format(
			tnt, self.uuid, tnt:info().cluster.uuid
		), 3)
	end
end

function Replicaset:add_replica(t)
	self:check_cluster_uuid(t)

	if not self.replicas[t:uuid()] then
		self.replicas[ t:uuid() ] = t
		table.insert(self.replica_list, t)
		log.verbose("Replica %s/%s was registered (id: %s, vclock: %s, role: %-7s)",
			t:uuid(), self.uuid, t:id(), json.encode(t:vclock()), t:role())
	else
		log.warn("[Replicaset %s] Replica %s already exists", self.uuid, t:uuid())
	end
end

function Replicaset:master()
	for _, tnt in ipairs(self.replica_list) do
		if tnt:role() == 'master' then
			return tnt
		end
	end
end

local etonode = function(e)
	return (e:gsub("[^%w%d]", "_"))
end

function Replicaset:graph()
	local graphviz = {
		'digraph G {',
			'\tnode[shape="circle"]',
	}

	for _, r in pairs(self.replicas) do
		table.insert(graphviz,
			("\t"..[[%s [label="%s/%s: %s\n%s"] ]]):format(
				etonode(r.endpoint), r:id(), r:role(), (json.encode(r:vclock()):gsub([["]], "'")),
				r.endpoint
		))
	end

	for _, r in pairs(self.replicas) do
		for _, d in pairs(r:info().replication) do
			local down = self.replicas[d.uuid]
			if d.downstream and down then
				table.insert(graphviz,
					("\t"..[[%s -> %s [style=%s,label="%.3fs"] ]]):format(
						etonode(r.endpoint), etonode(down.endpoint),
						d.downstream.status == "follow" and "solid" or "dotted",
						(down:info().replication[r:id()].upstream or {}).lag or 0
					)
				)
			end
		end
	end

	table.insert(graphviz, '}')
	return table.concat(graphviz, "\n")
end

function Replicaset:scored()
	local master = self:master()
	if not master then
		log.warn("No master found in replicaset: %s", self.uuid)
	end

	for _, r in ipairs(self.replica_list) do
		local ds = r:followed_downstreams()
		if #ds == 0 then
			r.no_downstreams = true
		end
		if master and r ~= master and not r:replicates_from(master:uuid()) then
			r.no_master_upstream = true
		end
	end

	table.sort(self.replica_list, function(r1, r2)
		-- is r1 better than r2?
		if master then
			local u1 = r1:replicates_from(master:uuid())
			local u2 = r2:replicates_from(master:uuid())

			if r1 == master then
				return true
			elseif r2 == master then
				return false
			end

			-- If both of them replicating data then
			-- we order them with least lag
			if u1 and u2 then
				return u1.upstream.lag < u2.upstream.lag
			elseif not u2 then
				return true
			elseif not u1 then
				return false
			end
		end

		-- We need work out this heuristics

		-- Ookey, let's check how many instances of replicaset
		-- has working replication
		local d1 = r1:followed_downstreams()
		local d2 = r2:followed_downstreams()

		if #d1 == 0 and #d2 > 0 then
			-- r2 is better, it has at least 1 downstream
			log.verbose("%s has >1 downstream than %s", r2, r1)
			return false
		elseif #d1 > 0 and #d2 == 0 then
			-- r1 is better, it has at least 1 downstream
			log.verbose("%s has >1 downstream than %s", r1, r2)
			return true
		end

		local u1 = r1:followed_upstreams()
		local u2 = r2:followed_upstreams()

		-- very naive implementation
		if (#d1+#u1) > (#d2+#u2) then
			-- r1 < r2
			return true
		elseif (#d2+#u2) > (#d1+#u1) then
			-- r2 < r1
			return false
		end

		-- no master, fuck! we take the one with the greatest vclock
		return r1 == vclock_gt(r1, r2) and true or false
	end)

	return self.replica_list
end

function Replicaset:topology()
	local function vote(votes, dst, src, seen)
		log.info("Replication: %s/%s <= %s/%s",
			src:id(), src:uuid(),
			dst:id(), dst:uuid())
		seen = seen or {}
		seen[dst:uuid()] = true
		votes[dst:uuid()] = votes[dst:uuid()] or { n = 0 }
		if not votes[dst:uuid()][src:uuid()] then
			votes[dst:uuid()][src:uuid()] = true
			votes[dst:uuid()].n = votes[dst:uuid()].n + 1
		end

		for _, up in ipairs(dst:upstreams()) do
			local r = self.replicas[up.uuid]
			if not seen[ r:uuid() ] then
				vote(votes, r, src, seen)
			end
		end
		return
	end

	local votes = {}
	local n_replicas = 0
	for _, replica in pairs(self.replicas) do
		n_replicas = n_replicas + 1
		for _, up in ipairs(replica:upstreams()) do
			vote(votes, self.replicas[up.uuid], replica, {})
		end
	end

	local masters = {}
	for uuid, downs in pairs(votes) do
		if downs.n == n_replicas then
			log.info("Possible master %s", self.replicas[uuid])
			table.insert(masters, self.replicas[uuid])
		end
	end

	return masters
end

return setmetatable(Replicaset, { __call = Replicaset.new })
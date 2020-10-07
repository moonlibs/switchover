local Cluster = {}
Cluster.__index = Cluster

local log = require 'log'
local json = require 'json'

function Cluster:new(uuid)
	return setmetatable({
		uuid = uuid,
		replicas = {},
	}, self)
end

function Cluster:add_replica(t)
	if not self.replicas[t:uuid()] then
		self.replicas[ t:uuid() ] = t
		log.info("Replica %s was registered in Cluster %s (id: %s, vclock: %s)",
			t:uuid(), self.uuid, t:id(), json.encode(t:vclock()))
	else
		log.warn("[Cluster %s] Replica %s already exists", self.uuid, t:uuid())
	end
end

function Cluster:topology()
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

return setmetatable(Cluster, { __call = Cluster.new })
---
-- ETCD Tree
local Tree = {}
Tree.__index = Tree

local fun = require 'fun'
local fio = require 'fio'

function Tree:new(opts)
	local tree = assert(opts.tree, "Tree: .tree is required")
	local etcd = assert(opts.etcd, "Tree: .etcd is required")
	local path = assert(opts.path, "Tree: .path is required")

	assert(tree.clusters, "Cannot instance ETCD tree without /clusters")
	assert(tree.instances, "Cannot instance ETCD tree without /instances")
	if opts.shard then
		assert(tree.clusters[opts.shard], "Cannot instance ETCD tree without /clusters/"..opts.shard)
	end
	return setmetatable({ tree = tree, etcd = etcd, path = path, shard = opts.shard }, self)
end

function Tree:refresh()
	self.tree = self.etcd:getr(self.path, { quorum = true }, { leader = true })
	return self
end

function Tree:instance(instance_name)
	return self.tree.instances[instance_name], instance_name
end

function Tree:by_uuid(instance_uuid)
	local name = fun.iter(self.tree.instances):grep(function(_, inst)
		return inst.box.instance_uuid == instance_uuid
	end):nth(1)
	if not name then
		return
	end
	return self:instance(name)
end

function Tree:cluster_path()
	local master = self:master(self.shard)
	assert(self.tree.clusters[master.cluster], "cluster for "..master.cluster.." not found")
	return fio.pathjoin(self.path, 'clusters', assert(master.cluster))
end

function Tree:master()
	if self.shard then
		return self:instance(self.tree.clusters[self.shard].master)
	end
	assert(fun.length(self.tree.clusters) == 1, "ETCD tree must contain single cluster")

	local cluster_name = next(self.tree.clusters)
	return self:instance(self.tree.clusters[cluster_name].master)
end

function Tree:is_master(instance_name)
	for _, cluster in pairs(self.tree.clusters) do
		if cluster.master == instance_name then
			return cluster
		end
	end
end

function Tree:instances()
	local iterator = fun.iter(self.tree.instances)
	if self.shard then
		iterator = iterator:grep(function(_, inst) return inst.cluster == self.shard end)
	end
	return iterator:map(function(_, inst) return inst.box.listen end):totable()
end

return setmetatable(Tree, { __call = Tree.new })
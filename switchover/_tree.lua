---
-- ETCD Tree
local Tree = {}
Tree.__index = Tree

local fun = require 'fun'

function Tree:new(opts)
	local tree = assert(opts.tree, "Tree: .tree is required")
	local etcd = assert(opts.etcd, "Tree: .etcd is required")
	local path = assert(opts.path, "Tree: .path is required")

	assert(tree.clusters, "Cannot instance ETCD tree without /clusters")
	assert(tree.instances, "Cannot instance ETCD tree without /instances")
	return setmetatable({ tree = tree, etcd = etcd, path = path }, self)
end

function Tree:refresh()
	self.tree = self.etcd:getr(self.path)
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

function Tree:master(cluster_name)
	if cluster_name then
		return self:instance(self.tree.clusters[cluster_name].master)
	end
	assert(fun.length(self.tree.clusters) == 1, "ETCD tree must contain single cluster")

	local master = next(self.tree.clusters)
	return self:master(master)
end

function Tree:is_master(instance_name)
	for _, cluster in pairs(self.tree.clusters) do
		if cluster.master == instance_name then
			return cluster
		end
	end
end

function Tree:instances()
	return fun.iter(self.tree.instances):map(function(_, inst) return inst.box.listen end):totable()
end

return setmetatable(Tree, { __call = Tree.new })
etcd = {
	endpoints = {
		"http://etcd0:2379",
		"http://etcd1:2379",
		"http://etcd2:2379",
	},
	prefix = '/cloud/tarantool',
	timeout = 3,
	instance_name = assert(instance_name, "instance_name is required"),
}

box = {
	background = false,
	vinyl_memory = 0,
}

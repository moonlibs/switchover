etcd = {
	endpoints = {
		"http://etcd0:2379",
		"http://etcd1:2379",
		"http://etcd2:2379",
	},
	prefix = os.getenv("TARANTOOL_APP_ETCD_PREFIX"),
	timeout = 3,
	instance_name = assert(os.getenv("TARANTOOL_INSTANCE_NAME"), "instance_name is required"),
}

box = {
	background = false,
	vinyl_memory = 0,
}

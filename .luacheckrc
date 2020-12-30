std = "tarantool"

read_globals = {
	"global",
}

files["switchover/discovery.lua"] = {
	read_globals = {
		global = {
			read_only = false,
		}
	}
}

max_line_length = 200
exclude_files = { ".rocks", "test" }
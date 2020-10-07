rockspec_format = "3.0"
package = "switchover"
version = "dev-1"
source = {
   url = "https://gitlab.com/ochaton/tarantool-switchover"
}
description = {
   maintainer = "Grubov Vladislav",
   homepage = "https://gitlab.com/ochaton/tarantool-switchover",
   license = "WTFPL",
}
dependencies = {
	"argparse >= 0.7.1",
}
external_dependencies = {
    TARANTOOL = {
        header = 'tarantool/module.h',
    },
}
build = {
	install = {
		bin = {
			switchover = "switchover/init.lua",
		},
	},
}
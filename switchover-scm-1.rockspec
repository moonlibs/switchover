package = "switchover"
version = "scm-1"
source = {
   url = "https://gitlab.com/ochaton/switchover"
}
description = {
   homepage = "http://gitlab.com/ochaton/switchover",
   license = "WTFPL",
}
dependencies = {
   "argparse",
   "net-url",
   "semver >= 1.2",
}
build = {
   type = "builtin",
   modules = {
      switchover = "switchover.lua",
      ["switchover._etcd"] = "switchover/_etcd.lua",
      ["switchover._mutex"] = "switchover/_mutex.lua",
      ["switchover._replicaset"] = "switchover/_replicaset.lua",
      ["switchover._tarantool"] = "switchover/_tarantool.lua",
      ["switchover._tree"] = "switchover/_tree.lua",
      ["switchover.discovery"] = "switchover/discovery.lua",
      ["switchover.heal"] = "switchover/heal.lua",
      ["switchover.package-reload"] = "switchover/package-reload.lua",
      ["switchover.promote"] = "switchover/promote.lua",
      ["switchover.restart-replication"] = "switchover/restart-replication.lua",
      ["switchover.switch"] = "switchover/switch.lua",
   },
}
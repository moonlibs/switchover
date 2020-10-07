#!/usr/bin/env tarantool
local argparse = require 'argparse'()
	:name "switchover"
	:command_target "command"
	:description "Tarantool master <-> replica switchover"
	:epilog "Home: https://gitlab.com/ochaton/tarantool-switchover"
	:add_help_command()
	:help_vertical_space(1)
	:help_description_margin(40)

local discovery = argparse:command "discovery"
	:summary "Discovers all members of the replicaset"

discovery:option "-p" "--prefix"
	:target "etcd_prefix"
	:description "Prefix of the replicaset in ETCD"

discovery:argument "endpoints"
	:description "Host port to tarantool"
	:convert(function(s) return s:split "," end)

local args = argparse:parse()
require('switchover.'..args.command).run(args)
os.exit(0)

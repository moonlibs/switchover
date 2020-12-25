#!/usr/bin/env tarantool
local switchover = require 'argparse'()
	:name "switchover"
	:command_target "command"
	:description "Tarantool master <-> replica switchover"
	:epilog "Home: https://gitlab.com/ochaton/tarantool-switchover"
	:add_help_command()
	:help_vertical_space(1)
	:help_description_margin(40)

switchover:option "-c" "--config"
	:target "config"
	:default "/etc/switchover/config.yaml"
	:description "Path to config"

switchover:option "-e" "--etcd"
	:target "etcd"
	:description "Address to ETCD endpoint"

switchover:option "-p" "--prefix"
	:target "etcd_prefix"
	:description "Prefix of the replicaset in ETCD"

switchover:flag "-v" "--verbose"
	:description "Verbosity level"
	:count "0-2"
	:target "verbose"

local discovery = switchover:command "discovery"
	:summary "Discovers all members of the replicaset"

discovery:option "-t" "--timeout"
	:target "timeout"
	:description "Discovery timeout (in seconds)"
	:show_default(true)
	:default(5)

discovery:flag "-g" "--show-graph"
	:target "show_graph"
	:description "Prints topology to the console in dot format"
	:default(false)

discovery:argument "endpoints"
	:description "host:port to tarantool"
	:convert(function(s) return s:split "," end)

local attach = switchover:command "attach"
	:summary "Attaches to given endpoints and prints vclock and replication down to console"

attach:option "-d" "--discovery"
	:description "discovery timeout (in seconds)"
	:show_default(true)
	:default(0.1)

local switch = switchover:command "switch"
	:summary "Switches current master to given instance"
	:description "Fail when no master found in replicaset"

switch:argument "instance"
	:args(1)
	:description "Choose instance to become master"

switch:option "--max-lag"
	:target "max_lag"
	:description "Maximum available Replication lag of the future master (in seconds)"
	:show_default(true)
	:default(1)

switch:option "-t" "--timeout"
	:target "timeout"
	:description "Timeout of the switch (in seconds)"
	:show_default(true)
	:default(5)

rawset(_G, 'global', {
	start_at = require 'fiber'.time()
})

local args = switchover:parse()
require 'log'.level(5+args.verbose)
os.exit(require('switchover.'..args.command).run(args) or 0)

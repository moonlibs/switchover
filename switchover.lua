#!/usr/bin/env tarantool
local log = require 'log'
local fio = require 'fio'
local yaml = require 'yaml'
local json = require 'json'

local function comma_split(s) return s:split "," end

local switchover = require 'argparse'()
	:name "switchover"
	:command_target "command"
	:description "Tarantool master <-> replica switchover"
	:epilog "Home: https://gitlab.com/ochaton/tarantool-switchover"
	:add_help_command()
	:add_complete()
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

discovery:flag "-l" "--link-graph"
	:target "link_graph"
	:description "Build url to online visualization"
	:default(false)

discovery:argument "endpoints"
	:args "0-1"
	:description "host:port to tarantool"
	:convert(comma_split)

local promote = switchover:command "promote"
	:summary "Promotes given instance to master"
	:description "Fail when master exists in replicaset"

promote:argument "instance"
	:args(1)
	:description "Choose instance to become master"

promote:option "--max-lag"
	:target "max_lag"
	:description "Maximum allowed Replication lag of the future master (in seconds)"
	:show_default(true)
	:default(1)

promote:option "-t" "--timeout"
	:target "timeout"
	:description "Timeout of the promote (in seconds)"
	:show_default(true)
	:default(5)

local switch = switchover:command "switch"
	:summary "Switches current master to given instance"
	:description "Fail when no master found in replicaset"

switch:argument "instance"
	:args(1)
	:description "Choose instance to become master"

switch:option "--max-lag"
	:target "max_lag"
	:description "Maximum allowed Replication lag of the future master (in seconds)"
	:show_default(true)
	:default(1)

switch:option "-t" "--timeout"
	:target "timeout"
	:description "Timeout of the switch (in seconds)"
	:show_default(true)
	:default(5)

switchover:command "heal"
	:summary "Heals ETCD /cluster/master"
	:description "Sets current master of replicaset into ETCD if replication is good"

local restart_replication = switchover:command "restart-replication"
	:summary "Restarts replication on choosen instance"

restart_replication:argument "instance"
	:args(1)
	:description "Name or address of the instance"

rawset(_G, 'global', {
	start_at = require 'fiber'.time(),
})

local args = switchover:parse()
log.level(5+args.verbose)

if args.config and fio.stat(args.config) then
	for k, v in pairs(yaml.decode(assert(io.open(args.config, "r")):read("*all"))) do
		log.verbose("Setting %s to %s", k, json.encode(v))
		args[k] = v
	end
end

if args.link_graph and not args.show_graph then
	log.error("--link-graph must be used with --show-graph")
	print(switchover:get_help())
	os.exit(1)
end

if args.etcd then
	if type(args.etcd) == 'string' then
		args.etcd = {
			prefix = args.etcd_prefix,
			timeout = args.etcd_timeout,
			endpoints = args.etcd:split(","),
		}
	end
	_G.global.etcd = require 'switchover._etcd'.new {
		endpoints    = args.etcd.endpoints,
		prefix       = args.etcd.prefix,
		timeout      = args.etcd.timeout,
		boolean_auto = true,
		integer_auto = true,
		autoconnect  = true,
	}
end

os.exit(require('switchover.'..args.command).run(args) or 0)

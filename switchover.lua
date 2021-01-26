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
	:epilog "Home: https://gitlab.com/ochaton/switchover"
	:add_help_command()
	:add_complete()
	:help_vertical_space(1)
	:help_description_margin(60)

switchover:option "-c" "--config"
	:target "config"
	:default "/etc/switchover/config.yaml"
	:description "Path to config"

switchover:option "-e" "--etcd"
	:target "etcd"
	:description "Address to ETCD endpoint"

switchover:option "-p" "--prefix"
	:target "etcd_prefix"
	:description "Prefix to configuration of clusters in ETCD"

switchover:flag "-v" "--verbose"
	:description "Verbosity level"
	:count "0-2"
	:target "verbose"

switchover:option "--cluster"
	:target "cluster"
	:description "Name of replicaset in ETCD"

local discovery = switchover:command "discovery"
	:summary "Discovers all members of the replicaset"

discovery:option "-d" "--discovery-timeout"
	:target "discovery_timeout"
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
	:args "1"
	:description "host:port to tarantool or name of replicaset"
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

promote:flag "-r" "--with-reload"
	:target "with_reload"
	:description "In case of successfull promote calls package.reload on new master"
	:show_default(true)
	:default(false)

promote:flag "--no-etcd"
	:target "no_etcd"
	:description "Disables ETCD mutexes and discovery"
	:default(false)
	:show_default(true)

local switch = switchover:command "switch"
	:summary "Switches current master to given instance"
	:description "Switch fails when no master found in replicaset. Supports only tarantool >= 1.10.0"

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

switch:flag "--no-etcd"
	:target "no_etcd"
	:description "Disables ETCD mutexes and discovery"
	:default(false)
	:show_default(true)

switch:flag "-r" "--with-reload"
	:target "with_reload"
	:description "In case of successfull promote calls package.reload on new master"
	:show_default(true)
	:default(false)

local heal = switchover:command "heal"
	:summary "Heals ETCD /cluster/master"
	:description "Sets current master of replicaset into ETCD if replication is good"

heal:argument "cluster"
	:args(1)
	:description "Name of the replicaset"

local restart_replication = switchover:command "restart-replication" "rr"
	:summary "Restarts replication on choosen instance"

restart_replication:argument "instance"
	:args(1)
	:description "Name or address of the instance"

local package_reload = switchover:command "package-reload" "pr"
	:summary "Reload replication on given instance"

package_reload:argument "instance"
	:args "0-1"
	:description "Name or address of the instance"

package_reload:option "-a" "--all"
	:description "Discovers all instances and calls package.reload on every node"

rawset(_G, 'global', {
	start_at = require 'fiber'.time(),
})

local args = switchover:parse()
log.level(5+args.verbose)

if args.config and fio.stat(args.config) then
	for k, v in pairs(yaml.decode(assert(io.open(args.config, "r")):read("*all"))) do
		log.verbose("Setting %s to %s", k, json.encode(v))
		if args[k] == nil then
			args[k] = v
		end
	end
end

if args.link_graph and not args.show_graph then
	log.error("--link-graph must be used with --show-graph")
	print(switchover:get_help())
	os.exit(1)
end

if args.etcd then
	local etcd_prefix
	if type(args.etcd) == 'string' then
		args.etcd = {
			prefix = args.etcd_prefix,
			timeout = args.etcd_timeout,
			endpoints = args.etcd:split(","),
		}
	else
		etcd_prefix = ("%s/%s"):format(args.etcd.prefix, args.etcd_prefix and args.etcd_prefix or '')
	end
	_G.global.etcd = require 'switchover._etcd'.new {
		endpoints    = args.etcd.endpoints,
		prefix       = etcd_prefix and etcd_prefix or args.etcd.prefix,
		timeout      = args.etcd.timeout,
		boolean_auto = true,
		integer_auto = true,
		autoconnect  = true,
	}
end

os.exit(require('switchover.'..args.command).run(args) or 0)

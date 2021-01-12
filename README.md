# Name
Switchover - performs discovery and consistent Master/Replica switch with ETCD as coordinator.
Instance must be configured with https://github.com/moonlibs/config.

# Table of Contents
- [Name](#name)
- [Table of Contents](#table-of-contents)
- [Status](#status)
- [Version](#version)
- [Installation](#installation)
- [Development](#development)
- [Synopsis](#synopsis)
- [Usage](#usage)
	- [discovery](#discovery)
		- [with ETCD](#with-etcd)
		- [without ETCD](#without-etcd)
		- [graphviz](#graphviz)
	- [switch](#switch)
	- [promote](#promote)
	- [heal](#heal)
	- [restart-replication (rr)](#restart-replication-rr)
	- [package-reload (pr)](#package-reload-pr)
- [Configuration](#configuration)

# Status
Under early development

# Version
This document describes switchover 1.0.0

# Installation
You may get stable version from https://gitlab.com/ochaton/switchover/-/packages

# Development
Required packages:
* luarocks >= 2.4.0

```bash
git clone https://gitlab.com/ochaton/switchover && cd switchover

luarocks --tree .rocks install --only-deps switchover-scm-1.rockspec

tarantool switchover.lua help
```

# Synopsis
```bash
$ switchover help
Usage: switchover [-h] [--completion {bash,zsh,fish}] [-c <config>]
       [-e <etcd>] [-p <prefix>] [-v] [--cluster <cluster>] <command>
       ...

Tarantool master <-> replica switchover

Options:

   -h, --help                                               Show this help message and exit.

   --completion {bash,zsh,fish}                             Output a shell completion script for the specified shell.

         -c <config>,                                       Path to config (default: /etc/switchover/config.yaml)
   --config <config>

       -e <etcd>,                                           Address to ETCD endpoint
   --etcd <etcd>

         -p <prefix>,                                       Prefix of the replicaset in ETCD
   --prefix <prefix>

   -v, --verbose                                            Verbosity level

   --cluster <cluster>                                      Name of replicaset in ETCD

Commands:

   help                                                     Show help for commands.

   discovery                                                Discovers all members of the replicaset

   promote                                                  Promotes given instance to master

   switch                                                   Switches current master to given instance

   heal                                                     Heals ETCD /cluster/master

   restart-replication, rr                                  Restarts replication on choosen instance

   package-reload, pr                                       Reload replication on given instance

Home: https://gitlab.com/ochaton/switchover
```

Switchover is standalone script which allows SRE to change Leader role in any Tarantool replicaset.

Switchover shows topology of replication, determines lag, status of replication, auto discovers all members of replicaset (upstream-first search).

Additionally switchover can execute hot code reload on any instance of replicaset if it supports [package.reload](https://github.com/moonlibs/package-reload).

Switchover can restart replication on given instance (helpfull when replication was stopped because of network problems).

Mainly, switchover suggests best choice for the future leader according to topology of replication. Switchover provides 2 different mechanisms to promote node to leader:
* `switch`: downgrades current master to RO and promotes given replica to RW consistently as fast as possible. <b>Refuses switch if no master is found in replicaset.</b>
* `promote`: promotes given replica to RW. <b>Refuses operation if replicaset contains node in RW state.</b>

Both `promote` and `switch` by default requires ETCD to acquire mutex. Switchover may leave replicaset in RO-state if timeouts happened.

# Usage
This section describes usage of each command of switchover

## discovery
Discovers all reachable instances of replicaset and prints to the screen. Supports discovery from ETCD by name or by ip+port of given instances.

### with ETCD
```bash
$ switchover help discovery
Usage: switchover discovery [-h] [-d <discovery_timeout>] [-g] [-l]
       [<endpoints>]

Arguments:

   endpoints                                                host:port to tarantool or name of replicaset

Options:

   -h, --help                                               Show this help message and exit.

                    -d <discovery_timeout>,                 Discovery timeout (in seconds)
   --discovery-timeout <discovery_timeout>

   -g, --show-graph                                         Prints topology to the console in dot format

   -l, --link-graph

$ switchover -e http://etcd0:2379 -p /cloud discovery tarantool

Fetching tarantool from ETCD
Discovered 3 nodes from tarantool: tnt3:3301/replica,tnt2:3301/master,tnt1:3301/replica in 0.247s
2 etcd_master  Tarantool tnt2:3301 [2/20ebffd7-f40e-4c26-8263-a2382f2edafe] vclock:{"1":251630,"2":228108} master  replication: 1/follow:0.0002s,3/follow:0.0010s
3 etcd_replica Tarantool tnt3:3301 [3/ce343d92-3640-4146-8655-abb7d3501be7] vclock:{"1":251630,"2":228108} replica replication: 1/follow:0.0002s,2/follow:0.0032s
1 etcd_replica Tarantool tnt1:3301 [1/1a154d2c-2aad-4785-b7fe-ae5ad41fc4b6] vclock:{"1":251630,"2":228108} replica replication: 2/follow:0.0059s,3/follow:0.0041s
```
Discovery with ETCD allows to connect to every instance in ETCD and check replication status to each neighbour.

### without ETCD
```
$ switchover discovery tnt1:3301

Discovered 3 nodes from tnt1:3301: tnt1:3301/replica,tnt2:3301/master,tnt3:3301/replica in 0.095s
2 Tarantool tnt2:3301 [2/20ebffd7-f40e-4c26-8263-a2382f2edafe] vclock:{"1":251630,"2":248400} master  replication: 1/follow:0.0003s,3/follow:0.0006s
3 Tarantool tnt3:3301 [3/ce343d92-3640-4146-8655-abb7d3501be7] vclock:{"1":251630,"2":248400} replica replication: 1/follow:0.0021s,2/follow:0.0016s
1 Tarantool tnt1:3301 [1/1a154d2c-2aad-4785-b7fe-ae5ad41fc4b6] vclock:{"1":251630,"2":248397} replica replication: 2/follow:0.0031s,3/follow:0.0023s
```

Also, if you don't have ETCD, you may perform discovery using just ip:port of any instance.

<b>Note! switchover performs discovery only through instances in box.cfg.replication.</b> It may lose some instances if replicaset does not use full-mesh topology.

Example:
```
M (master:3301) - (replicates to) -> R1 (replica1:3301)
M (master:3301) - (replicates to) -> R2 (replica2:3301)
```
Then performing `switchover discovery master:3301` will list only master.<br>
But calling `switchover discovery replica1:3301,replica2:3301` will list all 3 instances.

If you don't use ETCD then you better organize replication with full-mesh topology.

### graphviz
Discovery may represent topology using dot:
```bash
$ switchover discovery -g tnt1:3301
digraph G {
	node[shape="circle"]
	tnt1_3301 [label="1/replica: {'1':251630,'2':382743}\ntnt1:3301"]
	tnt3_3301 [label="3/replica: {'1':251630,'2':382748}\ntnt3:3301"]
	tnt2_3301 [label="2/master: {'1':251630,'2':382749}\ntnt2:3301"]
	tnt1_3301 -> tnt2_3301 [style=solid,label="0.000s"]
	tnt1_3301 -> tnt3_3301 [style=solid,label="0.001s"]
	tnt3_3301 -> tnt1_3301 [style=solid,label="0.003s"]
	tnt3_3301 -> tnt2_3301 [style=solid,label="0.001s"]
	tnt2_3301 -> tnt1_3301 [style=solid,label="0.004s"]
	tnt2_3301 -> tnt3_3301 [style=solid,label="0.001s"]
}
```

Or even give you a link to render it in browser:
```
$ switchover discovery -gl tnt1:3301
```

In case of network partitioning discovery may work too long (at least 5 seconds). You can decrease this timeout specifying `--discovery-timeout` option.

## switch
Switch performs consistent switch of RW role in replicaset.
Replicaset must have single, alive master.

Algorithm of the switch:

1. Discovers as many instances of replicaset as possible.
2. Verifies that suggested `candidate` is legitimate leader:
   1. `Candidate` has enough downstreams.
   2. `Candidate` has alive upstream to master.
   3. Replication lag of this path is less than `max_lag` (default: 1 second).
3. Monitors that modifications from the `master` reaches `candidate` in reasonable time (less than `2*max_lag`)
4. Reserves intention in ETCD inside `<etcd_prefix>/<cluster_name>/clusters/<replicaset_name>/switchover` using compare-and-swap with `TTL = 3*max_lag`
5. Performs the switch:
   1. Connects to `master`
      1. switches `master` to `RO` calling `box.cfg{ read_only = true }`
      2. `fiber.yield()` to pass the way for other running fibers to finish their modifications
      3. Starts while-loop waiting until own vclock will match `candidate` vclock using `box.info.replication[candidate.id].downstream.vclock`.
         1. If deadline happens then rollback the switch calling `box.cfg{ read_only = false }` and stopping the switch.
         2. Otherwise, returns updated master vclock via `box.info.vclock`
   2. Connects to `candidate`
      1. Waits until `box.info.vclock` reaches `master` vclock.
         1. If deadline happens then fails the switch and goes to $5.5
         2. Otherwise calling `box.cfg{ read_only = false }` finishes the switch. -> $5.3
      2. If `switchover` catches timeout to `candidate` then it rechecks `box.info.ro` of `canidate` and only if `candidate` is still in RO performs $5.5.
   3. After 5.2.1.2 releases ETCD mutex calling compare-and-delete.
   4. Runs `switchover heal` to actualize leader of replicaset.
   5. (rollback case). Executed only when `master` and `candidate` are in `RO` state and `candidate` will not come leader eventually. It does the following:
      1. Checks that `candidate` is in RO.
      2. Connects to `master` and calls `box.cfg{ read_only = false }` to restore it's RW role.
      3. Releases ETCD mutex calling compare-and-delete
6. May call `package.reload` on `candidate` if switch was successfull (option `--with-reload`).

```bash
$ switchover -e http://etcd0:2379 -p /cloud switch --cluster tarantool tnt1
# Discovery `tarantool` in etcd:/cloud/
Fetching tarantool from ETCD
Discovered 3 nodes from tarantool: tnt1:3301/replica,tnt3:3301/replica,tnt2:3301/master in 0.175s

# Validating that candidate is okey:
Candidate Tarantool tnt1:3301 [1/1a154d2c-2aad-4785-b7fe-ae5ad41fc4b6] vclock:{"1":735437,"2":599840,"3":58968} replica replication: 2/follow:0.0035s,3/follow:0.0013s can be next leader (current: 2/tnt2:3301). Running replication check (safe)

# Performing replication check on candidate (hand made measuring of replication_lag)
wait_clock(599844, 2) on 1 succeed {"1":735437,"2":599844,"3":58968} => 0.0044s
Replication 2/tnt2:3301 -> 1/tnt1:3301 is good. Lag=0.0059s

# Executing the 3-step switch:
Running switch for: 2/20ebffd7-f40e-4c26-8263-a2382f2edafe (tnt2:3301 vclock:{"1":735437,"2":599844,"3":58968}) -> 1/1a154d2c-2aad-4785-b7fe-ae5ad41fc4b6 (tnt1:3301 vclock: {"1":735437,"2":599844,"3":58968})

# Step 1. Setting master to RO (took 14ms)
Master is in RO: Tarantool tnt2:3301 [2/20ebffd7-f40e-4c26-8263-a2382f2edafe] vclock:{"1":735437,"2":599853,"3":58968} replica replication: 1/follow:0.0045s,3/follow:0.0004s took 0.0144s

# Step 2. Setting candidate to RW
Switch 2/tnt2:3301 -> 1/tnt1:3301 was successfully done. Performing discovery

# Step 3. Updating master in ETCD
Changing master in ETCD: tnt2 -> tnt1
ETCD response: {"action":"compareAndSwap","node":{"createdIndex":64,"modifiedIndex":177,"key":"\/cloud\/tarantool\/clusters\/tnt\/master","value":"tnt1"},"prevNode":{"createdIndex":64,"modifiedIndex":174,"key":"\/cloud\/tarantool\/clusters\/tnt\/master","value":"tnt2"}}

# Final discovery:
Discovered 3 nodes from tnt2:3301,tnt3:3301,tnt1:3301: tnt3:3301/replica,tnt2:3301/replica,tnt1:3301/master in 0.343s
1 etcd_master  Tarantool tnt1:3301 [1/1a154d2c-2aad-4785-b7fe-ae5ad41fc4b6] vclock:{"1":735461,"2":599853,"3":58968} master  replication: 2/follow:0.0065s,3/follow:0.0010s
3 etcd_replica Tarantool tnt3:3301 [3/ce343d92-3640-4146-8655-abb7d3501be7] vclock:{"1":735457,"2":599853,"3":58968} replica replication: 1/follow:0.0091s,2/follow:0.0019s
2 etcd_replica Tarantool tnt2:3301 [2/20ebffd7-f40e-4c26-8263-a2382f2edafe] vclock:{"1":735444,"2":599853,"3":58968} replica replication: 1/follow:0.0640s,3/follow:0.0596s
```

## promote
Promote may promote any suitable node to RW state. Promote can be used when all nodes in replicaset are in RO state.

Algorithm of promote:

1. Discovers as many instances of replicaset as possible.
2. Verifies that suggested `candidate` can be promoted to leader:
   1. `Candidate` has enough downstreams.
   2. Replication lag of this path is less than `max_lag` (default: 1 second).
3. Reserves intention in ETCD `<etcd_prefix>/<cluster_name>/clusters/<replicaset_name>/switchover` using compare-and-swap with `TTL = 3*max_lag`
4. Connects to `candidate` and calls `box.cfg{ read_only = false }`
5. Releases ETCD mutex calling compare-and-delete
6. Updates leader of replicaset in ETCD
7. May call `package.reload` on `candidate` if switch was successfull (option `--with-reload`).

```bash
$ switchover -e http://etcd0:2379 -p /cloud promote --cluster tarantool tnt2

# Discovery `tarantool` in etcd:/cloud/
Fetching tarantool from ETCD
Discovered 3 nodes from tarantool: tnt1:3301/replica,tnt3:3301/replica,tnt2:3301/replica in 0.142s

# Validates that noone is master:
No master found in replicaset: 5713e7b4-29d2-4b1c-b6ff-1f2f8bae0d28

# Validates candidate:
Candidate Tarantool tnt2:3301 [2/20ebffd7-f40e-4c26-8263-a2382f2edafe] vclock:{"1":797885,"2":599853,"3":58968} replica replication: 1/follow:0.0003s,3/follow:0.0003s can be next leader

# Promoting candidate to be RW
Candidate 2/tnt2:3301 was promoted. Performing discovery

# Step 3. Updating master in ETCD
Changing master in ETCD: tnt1 -> tnt2
ETCD response: {"action":"compareAndSwap","node":{"createdIndex":64,"modifiedIndex":179,"key":"\/cloud\/tarantool\/clusters\/tnt\/master","value":"tnt2"},"prevNode":{"createdIndex":64,"modifiedIndex":177,"key":"\/cloud\/tarantool\/clusters\/tnt\/master","value":"tnt1"}}

# Final discovery:
Discovered 3 nodes from tnt1:3301,tnt3:3301,tnt2:3301: tnt3:3301/replica,tnt1:3301/replica,tnt2:3301/master in 0.292s
2 etcd_replica Tarantool tnt2:3301 [2/20ebffd7-f40e-4c26-8263-a2382f2edafe] vclock:{"1":797885,"2":599880,"3":58968} master  replication: 1/follow:0.0003s,3/follow:0.0071s
1 etcd_master  Tarantool tnt1:3301 [1/1a154d2c-2aad-4785-b7fe-ae5ad41fc4b6] vclock:{"1":797885,"2":599880,"3":58968} replica replication: 2/follow:0.0037s,3/follow:0.0017s
3 etcd_replica Tarantool tnt3:3301 [3/ce343d92-3640-4146-8655-abb7d3501be7] vclock:{"1":797885,"2":599880,"3":58968} replica replication: 1/follow:0.0085s,2/follow:0.0121s

```

Both `promote` and `switch` can be executed without ETCD mutex but that is strongly discouraged.

## heal
Handy command which actualizes ETCD configuration according to real cluster topology. Updates only `<etcd_prefix>/<cluster_name>/clusters/<replicaset_name>/master`. May refuse update if topology does not reach quorum.

```bash
$ switchover -e http://etcd0:2379 -p /cloud heal tarantool

Fetching tarantool from ETCD
Discovered 3 nodes from tarantool: tnt3:3301/replica,tnt2:3301/replica,tnt1:3301/master in 0.174s

Changing master in ETCD: tnt2 -> tnt1
ETCD response: {"action":"compareAndSwap","node":{"createdIndex":64,"modifiedIndex":181,"key":"\/cloud\/tarantool\/clusters\/tnt\/master","value":"tnt1"},"prevNode":{"createdIndex":64,"modifiedIndex":179,"key":"\/cloud\/tarantool\/clusters\/tnt\/master","value":"tnt2"}}
```

## restart-replication (rr)
Sometimes replication may stop in case of M-M conflicts or missing xlogs or anything else. Some of this cases can be fixed just restarting replication:

```
$ switchover -e http://etcd0:2379 -p /cloud rr --cluster tarantool tnt1
Fetching tarantool from ETCD
Discovered 3 nodes from tarantool: tnt2:3301/replica,tnt1:3301/master,tnt3:3301/replica in 0.217s
Restarting replication on Tarantool tnt1:3301 [1/1a154d2c-2aad-4785-b7fe-ae5ad41fc4b6] vclock:{"1":840140,"2":668592,"3":58968} master  replication: 2/follow:0.0005s,3/follow:0.0011s
Discovered 3 nodes from tnt1:3301: tnt1:3301/master,tnt3:3301/replica,tnt2:3301/replica in 0.530s
1 etcd_master  Tarantool tnt1:3301 [1/1a154d2c-2aad-4785-b7fe-ae5ad41fc4b6] vclock:{"1":840149,"2":668592,"3":58968} master  replication: 2/follow:0.2226s,3/follow:0.2146s
3 etcd_replica Tarantool tnt3:3301 [3/ce343d92-3640-4146-8655-abb7d3501be7] vclock:{"1":840154,"2":668592,"3":58968} replica replication: 1/follow:0.0079s,2/follow:0.0043s
2 etcd_replica Tarantool tnt2:3301 [2/20ebffd7-f40e-4c26-8263-a2382f2edafe] vclock:{"1":840150,"2":668592,"3":58968} replica replication: 1/follow:0.0140s,3/follow:0.0113s
```

Switchover executes following script on given instance:
```lua
repl = box.cfg.replication box.cfg{replication={}} box.cfg{replication = repl}
```

## package-reload (pr)
Executes `package.reload()` on replicaset or given instance. Order of execution is undefined.

# Configuration
Mostly all options of switchover can be configured in file.

| Command line          | Config file        |
|-----------------------|--------------------|
| `--etcd`              | `etcd.endpoints`   |
| `--prefix`            | `etcd.prefix`      |
| `--verbose`           | `verbose`          |
| `--max-lag`           | `max_lag`          |
| `--with-reload`       | `with_reload`      |
| `--discovery-timeout` | `discovery_timeout`|

Example of working configuration:
```yaml
---
etcd:
  prefix: /cloud
  timeout: 3
  endpoints:
    - http://etcd0:2379
    - http://etcd1:2379
    - http://etcd2:2379
max_lag: 3
with_reload: true
discovery_timeout: 5
```

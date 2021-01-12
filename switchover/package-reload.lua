local M = {}

local Replicaset = require "switchover._replicaset"

function M.run(args)
	assert(args.command == "package-reload")

	local tnts, instance = require "switchover.discovery".resolve_and_discovery(
		args.instance or '', args.timeout, args.cluster
	)

	if not args.instance and not args.all then
		error("reload: you must specify instance or --all option", 0)
	end

	if not args.all then
		instance:package_reload()
	else
		local repl = Replicaset(tnts.list)
		for _, inst in ipairs(repl:scored()) do
			inst:package_reload()
		end
	end

	return require 'switchover.discovery'.run {
		command = 'discovery',
		endpoints = { instance.endpoint },
		timeout = args.timeout,
	}
end

return M
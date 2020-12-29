local M = {}

function M.run(args)
	assert(args.command == "restart-replication")

	local _, instance = require "switchover.switch".resolve_and_discovery(
		args.instance, args.timeout
	)

	instance.conn:eval [[
		repl = box.cfg.replication
		box.cfg{ replication = {} }
		box.cfg{ replication = repl }
		repl = nil
	]]

	return require 'switchover.discovery'.run {
		command = 'discovery',
		endpoints = { instance.endpoint },
		timeout = args.timeout,
	}
end

return M
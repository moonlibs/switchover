local M = {}


function M.ack(key, to)
	local fiber = require 'fiber'

	local peer = box.session.peer()
	box.session.storage.peer = peer

	local gkey = '\x00guard_key'

	local g = rawget(_G, gkey)
	if g then
		if fiber.time() < g.deadline then
			return false, ("Guard %s already taken by: %s %s for %.4fs"):format(g.key, g.peer, g.deadline-fiber.time())
		end
		-- stale guard. we may reuse it
		rawset(_G, gkey, nil)
	end

	g = { key = key, peer = peer, at = fiber.time(), deadline = fiber.time()+assert(to) }
	rawset(_G, gkey, g)

	g.fiber = fiber.create(function()
		fiber.sleep(to)
		local g = rawget(_G, gkey)
		if g.fiber == fiber.self() and g.key == key and g.deadline <= fiber.time() then
			require'log'.warn("Autoreleasing lock %s", g.key)
			rawset(_G, gkey, nil)
		end
	end)

	return g
end

function M.release(key)
	local fiber = require 'fiber'
	local gkey = '\x00guard_key'
	local g = rawget(_G, gkey)
	if not g then
		return false, "guard not found"
	end
	if g.key ~= key then
		return false, ("guard is taken by another one: %s %s left %.4fs"):format(g.key, g.peer, g.deadline-fiber.time())
	end
	rawset(_G, gkey, nil)
	g.fiber:cancel()
	return true
end

return M
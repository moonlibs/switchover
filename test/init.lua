local fiber = require 'fiber'
do
	local rpslimiter = setmetatable({
		get = function(self, k, to)
			to = to or 365*86400
			local deadline = fiber.time()+to
			for _ = 1, k do
				local _to = deadline - fiber.time()
				if _to < 0 or not self.chan:get(_to) then
					return false, "timeout"
				end
			end
			return true
		end,
		run = function(o)
			o.chan = fiber.channel(o.n)
			o.fiber = fiber.create(function(self)
				while true do
					self.chan:put(true, 0)
					fiber.sleep(1/self.n)
				end
			end, o)
			return o
		end,
		close = function(self) return self.chan:close() end,
	}, {
		__call = function(self, n)
			return setmetatable({ n = n }, { __index = self }):run()
		end
	})
	rawset(_G, 'rpslimiter', rpslimiter)
end

box.cfg{
	listen = 3301,
	replication = os.getenv('TARANTOOL_REPLICATION'):split(','),
}

box.cfg{ read_only = box.info.id ~= 1 }

if not box.info.ro then
	box.schema.user.grant('guest', 'super', nil, nil, { if_not_exists = true })
	box.schema.space.create('test', {if_not_exists = true}):create_index('pri', { if_not_exists = true })
end
rawset(_G, 'fiber', require 'fiber')

local log = require 'log'

function _G.runload(rps)
	log.info("Running load for %s", rps)
	local limiter = _G.rpslimiter(rps)
	while not box.info.ro and limiter:get(1) do
		box.space.test:insert{
			box.space.test:len(),
			box.info.id,
			box.info.vclock,
		}
	end
end

fiber.create(function()
	fiber.sleep(3)
	while true do
		box.ctl.wait_rw()

		local fs = {}
		for w = 1, 9 do
			fs[w] = fiber.create(_G.runload, 100)
			fs[w]:set_joinable(true)
		end
		for _, f in ipairs(fs) do
			f:join()
		end
	end
end)
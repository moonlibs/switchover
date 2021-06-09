local Mutex = {}
Mutex.__index = Mutex

function Mutex:new(etcd, path)
	return setmetatable({ etcd = etcd, path = assert(path, "mutex: path is requred") }, self)
end

function Mutex:atomic(opts, func, ...)
	local key = assert(opts.key, "Mutex: key is required")
	local ttl = assert(opts.ttl, "Mutex: ttl is required")

	local res = self.etcd:set(self.path, key, { prevExist = false, ttl = ttl }, { leader = true })
	if res.action ~= 'create' then
		-- data is safe, so first arg is true
		return true, ("Mutex wasnt acquired: %s:%s"):format(res.cause, res.message)
	end

	local r = { pcall(func, ...) }
	if table.remove(r, 1) then
		local ok, err = unpack(r)
		if ok then
			self.etcd:rm(self.path, { prevValue = key })
		end
		return ok, err
	else
		return false, r[1]
	end
end

return setmetatable(Mutex, { __call = Mutex.new })
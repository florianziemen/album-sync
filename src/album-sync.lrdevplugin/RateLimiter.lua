--[[
Token bucket for Flickr API calls (limit: 3600/hour per key, shared by all users of the key).
Default: 1 call/second sustained, bursts of up to 10. Shared by all tasks of one publish run.
Dependencies: now() seconds, sleep(seconds).
]]

local M = {}
M.__index = M

function M.new(deps, rate, burst)
	return setmetatable({ deps = deps, rate = rate or 1, burst = burst or 10, tokens = burst or 10 }, M)
end

--- Block (yielding via sleep) until a call may be made. Returns seconds waited.
function M:acquire()
	local waited = 0
	while true do
		local now = self.deps.now()
		if self.last then
			self.tokens = math.min(self.burst, self.tokens + (now - self.last) * self.rate)
		end
		self.last = now
		if self.tokens >= 1 then
			self.tokens = self.tokens - 1
			return waited
		end
		local wait = (1 - self.tokens) / self.rate
		self.deps.sleep(wait)
		waited = waited + wait
	end
end

return M

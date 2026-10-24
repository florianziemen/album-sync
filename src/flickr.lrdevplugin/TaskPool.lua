--[[
Bounded pool of background jobs (parallel uploads). Jobs run in their own tasks; results are
collected by the caller's task, so all Lightroom-side bookkeeping stays on one task.

Dependencies:
  spawn(fn)        start fn in a new task (LrTasks.startAsyncTask)
  sleep(seconds)   yield while waiting
  pcall            LrTasks.pcall in Lightroom
]]

local M = {}
M.__index = M

function M.new(size, deps)
	return setmetatable({ size = math.max(1, size), deps = deps, active = 0, done = {} }, M)
end

--- Start fn(), waiting first while the pool is full. fn's return value is collected later;
--- a raised error is collected as { error = message, context = context }.
function M:submit(context, fn)
	while self.active >= self.size do
		self.deps.sleep(0.05)
	end
	self.active = self.active + 1
	self.deps.spawn(function()
		local ok, result = (self.deps.pcall or pcall)(fn)
		if not ok then
			result = { error = tostring(result), context = context }
		end
		self.done[#self.done + 1] = result
		self.active = self.active - 1
	end)
end

--- Results finished so far (non-blocking).
function M:collect()
	local out = self.done
	self.done = {}
	return out
end

--- Wait for all jobs; returns the remaining results.
function M:drain()
	while self.active > 0 do
		self.deps.sleep(0.05)
	end
	return self:collect()
end

return M

--[[
Just-in-time rendering with a bounded look-ahead (docs/DESIGN.md §5.2(b)).

Items are taken strictly in order. Taking item i makes sure items i..i+ahead have been
started, so at most ahead+1 renders are in flight or waiting on disk at any time.

Dependencies:
  start(item) -> job            begin rendering in the background
  await(job) -> ok, pathOrMsg   block (yielding) until the job is done
]]

local M = {}
M.__index = M

function M.new(items, ahead, start, await)
	return setmetatable({ items = items, ahead = ahead, start = start, await = await, jobs = {}, nextIndex = 1 }, M)
end

function M:_startUpTo(last)
	for j = self.nextIndex, math.min(last, #self.items) do
		if self.jobs[j] == nil then
			self.jobs[j] = self.start(self.items[j])
		end
	end
end

--- Take the next item. Returns item, ok, pathOrMsg; nil when exhausted.
function M:take()
	local i = self.nextIndex
	if i > #self.items then
		return nil
	end
	self:_startUpTo(i + self.ahead)
	local job = self.jobs[i]
	self.jobs[i] = nil
	self.nextIndex = i + 1
	return self.items[i], self.await(job)
end

return M

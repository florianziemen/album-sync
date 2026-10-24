--[[
Shared ticket polling for parallel uploads (docs/DESIGN.md §5a): all workers of a run register
their tickets here, and whichever worker is due polls flickr.photos.upload.checkTickets for all
open tickets at once. Saves API calls (rate limit) compared with one poll per worker.

Dependencies: now(), sleep(seconds). api: FlickrApi (checkTickets).
]]

local M = {}
M.__index = M

M.INTERVAL = 1.5 -- seconds between polls (for all tickets together)
M.STEP = 0.2 -- how often a waiting worker looks at its own ticket

function M.new(api, deps)
	return setmetatable({ api = api, deps = deps, open = {}, results = {}, lastPoll = nil, polling = false }, M)
end

function M:_poll()
	self.polling = true
	local ids = {}
	for ticket in pairs(self.open) do
		ids[#ids + 1] = ticket
	end
	table.sort(ids)
	if #ids > 0 then
		local status, e = self.api:checkTickets(ids)
		for _, ticket in ipairs(ids) do
			local t = status and status[ticket]
			if t then
				self.results[ticket] = t
			elseif e and e.class ~= "transient" then
				self.results[ticket] = { error = e }
			end
		end
	end
	self.lastPoll = self.deps.now()
	self.polling = false
end

--[[
Wait for one ticket. Returns photoId, or nil, err with err.class
  "permanent" (Flickr could not process the file),
  "pending"   (still processing after `timeout` seconds; keep the journal entry),
  "lost"      (ticket unknown to Flickr),
  or the class of a non-transient checkTickets error.
]]
function M:wait(ticket, timeout)
	self.open[ticket] = true
	local started = self.deps.now()
	while true do
		local t = self.results[ticket]
		if t then
			if t.error then
				self.open[ticket], self.results[ticket] = nil, nil
				return nil, t.error
			elseif t.complete == 1 and t.photoId then
				self.open[ticket], self.results[ticket] = nil, nil
				return t.photoId
			elseif t.complete == 2 then
				self.open[ticket], self.results[ticket] = nil, nil
				return nil, { class = "permanent", message = "Flickr could not process the uploaded file" }
			elseif t.invalid then
				self.open[ticket], self.results[ticket] = nil, nil
				return nil, { class = "lost", message = "upload ticket unknown to Flickr" }
			end
		end
		local now = self.deps.now()
		if now - started >= timeout then
			self.open[ticket], self.results[ticket] = nil, nil
			return nil,
				{
					class = "pending",
					message = string.format(
						"Flickr is still processing the upload after %ds (ticket %s)",
						math.floor(now - started),
						ticket
					),
				}
		end
		if not self.polling and (not self.lastPoll or now - self.lastPoll >= M.INTERVAL) then
			self.results[ticket] = nil -- a fresh answer is expected
			self:_poll()
		else
			self.deps.sleep(M.STEP)
		end
	end
end

return M

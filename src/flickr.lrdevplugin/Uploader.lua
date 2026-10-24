--[[
Robust, duplicate-safe photo upload (docs/DESIGN.md §5).

1. Journal entry before sending (title, start time).
2. Async upload -> ticket (stored in the journal) -> poll checkTickets for the photo id.
3. Transient failures are retried with backoff. Before every retry, recent uploads are searched
   for the photo (same title, uploaded since the attempt started): a lost response must not
   produce a duplicate. Several candidates -> stop and leave it to the user.
4. A ticket that is still processing when we give up is NOT re-uploaded: the journal keeps it
   and the next publish links the photo.

Dependencies: now, sleep, log, random01 (as for FlickrApi). api: FlickrApi. journal: Journal.
]]

local Retry = require("Retry")

local M = {}
M.__index = M

M.TICKET_TIMEOUT = 300 -- seconds to wait for Flickr to process an upload
M.RECENT_CHECKS = 3 -- searches for a lost upload (new uploads may take a moment to show up)
M.RECENT_SLACK = 120 -- seconds before the attempt start that still count (clock skew)

function M.new(deps, api, journal)
	-- claimed: photo ids already attributed to some upload of this run (never matched twice,
	-- e.g. virtual copies share a title).
	return setmetatable({ deps = deps, api = api, journal = journal, claimed = {} }, M)
end

function M:_log(level, msg)
	if self.deps.log then
		self.deps.log(level, msg)
	end
end

--[[
Wait for a ticket. Returns photoId, or nil, err where err.class is
  "permanent" (Flickr could not process the file),
  "pending"   (still processing; keep the journal entry, do not re-upload),
  "lost"      (ticket unknown to Flickr; search recent uploads).
]]
function M:waitTicket(ticket)
	local waited, interval = 0, 1
	while true do
		local status, e = self.api:checkTickets({ ticket })
		local t = status and status[ticket]
		if t then
			if t.complete == 1 and t.photoId then
				return t.photoId
			elseif t.complete == 2 then
				return nil, { class = "permanent", message = "Flickr could not process the uploaded file" }
			elseif t.invalid then
				return nil, { class = "lost", message = "upload ticket unknown to Flickr" }
			end
		elseif e and e.class ~= "transient" then
			return nil, e
		end
		if waited >= M.TICKET_TIMEOUT then
			return nil,
				{
					class = "pending",
					message = string.format(
						"Flickr is still processing the upload after %ds (ticket %s)",
						waited,
						ticket
					),
				}
		end
		self.deps.sleep(interval)
		waited = waited + interval
		interval = math.min(interval * 2, 15)
	end
end

--[[
Search own uploads since `since` for `title`. Returns
  photoId        exactly one match
  nil            no match (after M.RECENT_CHECKS searches)
  false, ids     several matches: ambiguous
]]
function M:findRecent(title, since)
	for check = 1, M.RECENT_CHECKS do
		local photos = self.api:recentUploads(since - M.RECENT_SLACK)
		if photos then
			local ids = {}
			for _, p in ipairs(photos) do
				if p.title == title and not self.claimed[p.id] then
					ids[#ids + 1] = p.id
				end
			end
			if #ids == 1 then
				return ids[1]
			elseif #ids > 1 then
				return false, ids
			end
		end
		if check < M.RECENT_CHECKS then
			self.deps.sleep(5 * check)
		end
	end
	return nil
end

--[[
Upload `path` with `fields` for journal key `key`. On success the journal entry gets the photo
id; the caller closes it once the id is stored in the catalog.
opts.fault(stage) (testing only) may return an error to inject at "beforeSend" / "afterSend".
Returns photoId or nil, err.
]]
function M:upload(key, path, fields, opts)
	opts = opts or {}
	local started = self.deps.now()
	self.journal:open(key, { title = fields.title, started = started })

	local function attempt()
		local fault = opts.fault and opts.fault("beforeSend")
		if fault then
			return nil, fault
		end
		local ticket, e = self.api:uploadAsync(path, fields)
		if not ticket then
			return nil, e
		end
		self.journal:update(key, { ticket = ticket })
		fault = opts.fault and opts.fault("afterSend")
		if fault then
			return nil, fault
		end
		local photoId, waitErr = self:waitTicket(ticket)
		if photoId then
			return photoId
		end
		if waitErr.class == "lost" then
			waitErr.class = "transient" -- retry, after the duplicate search below
		end
		return nil, waitErr
	end

	local photoId, e = Retry.run(self.deps, "upload " .. tostring(fields.title), attempt, {
		beforeRetry = function()
			local found, ambiguous = self:findRecent(fields.title, started)
			if found then
				self:_log("info", string.format("upload %s: found on Flickr after lost response: %s", key, found))
				return found
			elseif found == false then
				self:_log(
					"error",
					string.format(
						"upload %s: several candidates on Flickr (%s); not retrying",
						key,
						table.concat(ambiguous, ",")
					)
				)
				return false
			end
			return nil
		end,
	})
	if photoId then
		self.claimed[photoId] = true
		self.journal:update(key, { photoId = photoId })
		return photoId
	end
	if e and e.class ~= "pending" and e.class ~= "transient" then
		-- Definitely not on Flickr (rejected): nothing to reconcile later.
		self.journal:close(key)
	end
	return nil, e
end

--[[
Reconcile entries left open by an earlier run (crash, quit, still processing).
Returns { linked = { [key] = photoId }, pending = { key... }, dropped = { key... },
ambiguous = { [key] = ids } }. Linked and dropped entries are closed by this call except linked
ones, which the caller closes after storing the id.
]]
function M:reconcile()
	local result = { linked = {}, pending = {}, dropped = {}, ambiguous = {} }
	for _, item in ipairs(self.journal:openEntries()) do
		local key, entry = item.key, item.entry
		local photoId = entry.photoId
		local lost = false
		if not photoId and entry.ticket then
			local status = self.api:checkTickets({ entry.ticket })
			local t = status and status[entry.ticket]
			if t and t.complete == 1 then
				photoId = t.photoId
			elseif t and t.complete == 0 then
				result.pending[#result.pending + 1] = key
			elseif t and t.complete == 2 then
				result.dropped[#result.dropped + 1] = key
				self.journal:close(key)
			else
				lost = true
			end
		elseif not photoId then
			lost = true
		end
		if lost then
			local found, ids = self:findRecent(entry.title, entry.started or 0)
			if found then
				photoId = found
			elseif found == false then
				result.ambiguous[key] = ids
			else
				result.dropped[#result.dropped + 1] = key
				self.journal:close(key)
			end
		end
		if photoId then
			self.claimed[photoId] = true
			result.linked[key] = photoId
		end
	end
	return result
end

return M

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

local JpegXmp = require("JpegXmp")
local Retry = require("Retry")
local TicketPoller = require("TicketPoller")

local M = {}
M.__index = M

M.TICKET_TIMEOUT = 300 -- seconds to wait for Flickr to process an upload
M.RECENT_CHECKS = 3 -- searches for a lost upload (new uploads may take a moment to show up)
M.RECENT_SLACK = 120 -- seconds before the attempt start that still count (clock skew)

--- poller (optional): shared TicketPoller for all uploads of a run; one per uploader otherwise.
function M.new(deps, api, journal, poller)
	-- claimed: photo ids already attributed to some upload of this run (never matched twice,
	-- e.g. virtual copies share a title).
	poller = poller or TicketPoller.new(api, deps)
	return setmetatable({ deps = deps, api = api, journal = journal, poller = poller, claimed = {} }, M)
end

function M:_log(level, msg)
	if self.deps.log then
		self.deps.log(level, msg)
	end
end

--[[
Of `ids`, the ones whose upload marker (JpegXmp, read via getExif) belongs to `uuid`.
Photos with another photo's marker or without a marker are not ours. Without a uuid or an
exif-capable api (tests of the title-only logic) all ids are returned.
]]
function M:_ours(ids, uuid)
	if not uuid or not self.api.exif then
		return ids
	end
	local mine = {}
	for _, id in ipairs(ids) do
		local exif = self.api:exif(id)
		local marker = JpegXmp.fromExif(exif)
		if marker.uuid == uuid then
			mine[#mine + 1] = id
		else
			self:_log(
				"info",
				string.format("upload %s: candidate %s is not ours (marker %s)", uuid, id, tostring(marker.uuid))
			)
		end
	end
	return mine
end

--[[
Search own uploads since `since` for `title`, confirmed by the upload marker of photo `uuid`
(a same-titled photo of another Lightroom photo must never be taken: observed 2026-10-24).
Returns
  photoId        exactly one match
  nil            no match (after M.RECENT_CHECKS searches)
  false, ids     several matches: ambiguous
]]
function M:findRecent(title, since, uuid)
	for check = 1, M.RECENT_CHECKS do
		local photos = self.api:recentUploads(since - M.RECENT_SLACK)
		if photos then
			local ids = {}
			for _, p in ipairs(photos) do
				if p.title == title and not self.claimed[p.id] then
					ids[#ids + 1] = p.id
				end
			end
			ids = self:_ours(ids, uuid)
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
		local photoId, waitErr = self.poller:wait(ticket, M.TICKET_TIMEOUT)
		if photoId then
			return photoId
		end
		if waitErr.class == "lost" then
			waitErr.class = "transient" -- retry, after the duplicate search below
		end
		return nil, waitErr
	end

	local photoId, e = Retry.run(self.deps, "upload " .. tostring(fields.title), attempt, {
		beforeRetry = function(err)
			if err and err.notSent then
				-- The request never left this machine: nothing to look for on Flickr.
				self:_log("info", string.format("upload %s: not sent (%s), retrying without search", key, err.message))
				return nil
			end
			local found, ambiguous = self:findRecent(fields.title, started, key)
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
Entries without photo id or usable ticket are matched against ONE listing of own uploads since
the oldest such attempt (no waiting: by now Flickr lists finished uploads), by title, never
matching a photo twice. Several lost entries with the same title and any match are ambiguous:
we cannot tell whose upload it was.
Returns { linked = { [key] = photoId }, pending = { key... }, dropped = { key... },
ambiguous = { [key] = ids } }. Dropped entries are closed here; linked ones are closed by the
caller after storing the id.
]]
function M:reconcile()
	local result = { linked = {}, pending = {}, dropped = {}, ambiguous = {} }
	local lost = {}
	for _, item in ipairs(self.journal:openEntries()) do
		local key, entry = item.key, item.entry
		local photoId = entry.photoId
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
				lost[#lost + 1] = item
			end
		elseif not photoId then
			lost[#lost + 1] = item
		end
		if photoId then
			self.claimed[photoId] = true
			result.linked[key] = photoId
		end
	end

	if #lost > 0 then
		local since
		for _, item in ipairs(lost) do
			local started = item.entry.started or 0
			since = since and math.min(since, started) or started
		end
		local photos = self.api:recentUploads(since - M.RECENT_SLACK)
		local byTitle, order = {}, {}
		for _, item in ipairs(lost) do
			local title = item.entry.title or ""
			if not byTitle[title] then
				byTitle[title] = {}
				order[#order + 1] = title
			end
			table.insert(byTitle[title], item)
		end
		for _, title in ipairs(order) do
			local items = byTitle[title]
			local titled = {}
			for _, p in ipairs(photos or {}) do
				if p.title == title and not self.claimed[p.id] then
					titled[#titled + 1] = p.id
				end
			end
			for _, item in ipairs(items) do
				-- The marker tells whose upload a photo is; without it (tests) several lost entries
				-- of one title cannot be told apart.
				local ids = self:_ours(titled, self.api.exif and item.key or nil)
				local exact = self.api.exif ~= nil
				if not photos then
					result.pending[#result.pending + 1] = item.key -- listing failed: try again next run
				elseif #ids == 0 then
					result.dropped[#result.dropped + 1] = item.key
					self.journal:close(item.key)
				elseif #ids == 1 and (exact or #items == 1) then
					self.claimed[ids[1]] = true
					result.linked[item.key] = ids[1]
				else
					result.ambiguous[item.key] = ids
				end
			end
		end
	end
	table.sort(result.dropped)
	table.sort(result.pending)
	return result
end

return M

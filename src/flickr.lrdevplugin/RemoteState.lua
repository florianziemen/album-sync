--[[
Per-field sync between Lightroom and Flickr (docs/DESIGN.md §3 "Conflicts", "Pull back").

All values are compared in a normalized form: trimmed text, Flickr-normalized tag sets,
privacy value, location key. Stored per photo (plugin field metadataState, JSON):
  { lr = <LR values at the last sync>, sent = <values on Flickr after the last sync> }
sent is nil for photos linked from Flickr (we never saw Flickr's values).
]]

local Privacy = require("Privacy")

local M = {}

M.FIELDS = { "title", "description", "tags", "privacy", "location" }

local function trim(s)
	return ((tostring(s or "")):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Lower-case ASCII and Latin-1 letters (UTF-8 C3 80..9E -> C3 A0..BE, except × at C3 97).
local function lower(s)
	s = s:lower()
	return (
		s:gsub("\195([\128-\158])", function(c)
			local b = c:byte()
			if b == 0x97 then
				return "\195" .. c
			end
			return "\195" .. string.char(b + 32)
		end)
	)
end

--- Flickr's normalized form of one tag: lower case, no spaces or ASCII punctuation.
function M.normTag(tag)
	return (lower(trim(tag)):gsub("[%s%p]", ""))
end

local function tagSet(list)
	local seen, out = {}, {}
	for _, t in ipairs(list) do
		local n = M.normTag(t)
		if n ~= "" and not seen[n] then
			seen[n] = true
			out[#out + 1] = n
		end
	end
	table.sort(out)
	return table.concat(out, " ")
end

--- Split a Flickr tag string ('a "New York" b') into tags.
function M.splitTags(s)
	local out = {}
	s = tostring(s or "")
	for quoted in s:gmatch('"([^"]*)"') do
		out[#out + 1] = quoted
	end
	s = s:gsub('"[^"]*"', " ")
	for plain in s:gmatch("%S+") do
		out[#out + 1] = plain
	end
	return out
end

--- Normalized LR-side values from PhotoFields.metadataFields.
function M.fromFields(fields)
	return {
		title = trim(fields.title),
		description = trim(fields.description),
		tags = tagSet(M.splitTags(fields.tags)),
		privacy = fields.privacy or "private",
		location = fields.location or "",
	}
end

local function content(v)
	if type(v) == "table" then
		return v._content
	end
	return v
end

--- Normalized Flickr values from flickr.photos.getInfo's "photo".
function M.fromInfo(photo)
	local tags = {}
	local list = photo.tags and photo.tags.tag or {}
	if list.id then
		list = { list }
	end
	for _, t in ipairs(list) do
		if tonumber(t.machine_tag) ~= 1 then
			tags[#tags + 1] = content(t) or t.raw
		end
	end
	local v = photo.visibility or {}
	local loc = photo.location or {}
	return {
		title = trim(content(photo.title)),
		description = trim(content(photo.description)),
		tags = tagSet(tags),
		privacy = Privacy.fromFlags(v.ispublic, v.isfriend, v.isfamily),
		location = Privacy.locationKey(loc.latitude, loc.longitude),
	}
end

--- Normalized Flickr values from a photo list entry (extras description,tags,geo).
function M.fromListEntry(p)
	local tags = {}
	for t in tostring(p.tags or ""):gmatch("%S+") do
		tags[#tags + 1] = t
	end
	return {
		title = trim(content(p.title)),
		description = trim(content(p.description)),
		tags = tagSet(tags),
		privacy = Privacy.fromFlags(p.ispublic, p.isfriend, p.isfamily),
		location = Privacy.locationKey(p.latitude, p.longitude),
	}
end

--[[
Decide per field. current: fromFields(LR now). state: stored { lr, sent } or nil.
remote: Flickr now. fields: set of field names to manage (location only when enabled).
Returns { push = set, conflicts = set, flickrOnly = set }:
  push        changed in Lightroom only (or no history at all) -> send
  conflicts   changed in Lightroom and on Flickr since the last sync
  flickrOnly  differs on Flickr while Lightroom did not change -> keep Flickr's value
]]
function M.diff(current, state, remote, fields)
	local r = { push = {}, conflicts = {}, flickrOnly = {} }
	for _, f in ipairs(M.FIELDS) do
		if fields[f] and current[f] ~= remote[f] then
			local lrChanged = not (state and state.lr) or current[f] ~= state.lr[f]
			local flickrChanged = state and state.sent and remote[f] ~= state.sent[f]
			if lrChanged and flickrChanged then
				r.conflicts[f] = true
			elseif lrChanged then
				r.push[f] = true
			else
				r.flickrOnly[f] = true
			end
		end
	end
	return r
end

--- State after a sync: lr = current; sent = what Flickr now has (pushed fields from LR).
function M.after(current, remote, pushed)
	local sent = {}
	for _, f in ipairs(M.FIELDS) do
		if pushed[f] or not remote then
			sent[f] = current[f]
		else
			sent[f] = remote[f]
		end
	end
	return { lr = current, sent = sent }
end

--- Field names in a set, in FIELDS order (for logs and dialogs).
function M.names(set)
	local out = {}
	for _, f in ipairs(M.FIELDS) do
		if set[f] then
			out[#out + 1] = f
		end
	end
	return out
end

return M

--[[
Maps Lightroom photo metadata to Flickr upload/setMeta/setTags fields (docs/DESIGN.md §3).
]]

local Privacy = require("Privacy")

local M = {}

local function blank(s)
	return s == nil or s:match("^%s*$") ~= nil
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Title from LR title, else file name without extension.
function M.title(meta)
	if not blank(meta.title) then
		return meta.title
	end
	return ((meta.fileName or ""):gsub("%.[^.]*$", ""))
end

--[[
Flickr tag string from LR's exportable keywords ("a, b, New York").
Space separated; multi-word tags quoted; duplicates (case-insensitive) dropped; order kept.
]]
function M.tags(keywordList)
	local out, seen = {}, {}
	for raw in (keywordList or ""):gmatch("[^,]+") do
		local tag = trim(raw:gsub('"', ""))
		local key = tag:lower()
		if tag ~= "" and not seen[key] then
			seen[key] = true
			out[#out + 1] = tag:find("%s") and ('"' .. tag .. '"') or tag
		end
	end
	return table.concat(out, " ")
end

--[[
Fields pushed to Flickr for a photo; also the input of the metadata fingerprint.
meta: { title, fileName, caption, keywords, gps = { latitude, longitude }? }
opts: { privacy = resolved Privacy value, location = boolean (send GPS) }
location is "" when disabled or unknown; latitude/longitude are kept for sending.
]]
function M.metadataFields(meta, opts)
	opts = opts or {}
	local gps = opts.location and meta.gps or nil
	return {
		title = M.title(meta),
		description = meta.caption or "",
		tags = M.tags(meta.keywords),
		privacy = opts.privacy or "private",
		location = gps and Privacy.locationKey(gps.latitude, gps.longitude) or "",
		latitude = gps and gps.latitude or nil,
		longitude = gps and gps.longitude or nil,
	}
end

--[[
Upload arguments. fields: from metadataFields. opts.hidden: hide from public searches
(default true). Location is set separately (geo.setLocation) after the upload.
]]
function M.uploadFields(fields, opts)
	opts = opts or {}
	local flags = Privacy.flags(fields.privacy)
	return {
		title = fields.title,
		description = fields.description,
		tags = fields.tags,
		is_public = flags.is_public,
		is_friend = flags.is_friend,
		is_family = flags.is_family,
		hidden = (opts.hidden == false) and "1" or "2",
	}
end

function M.photoUrl(nsid, photoId)
	return string.format("https://www.flickr.com/photos/%s/%s/", nsid, photoId)
end

return M

--[[
Maps Lightroom photo metadata to Flickr upload/setMeta/setTags fields (docs/DESIGN.md §3).
]]

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

--- Fields pushed to Flickr for a photo; also the input of the metadata fingerprint.
--- meta: { title, fileName, caption, keywords }
function M.metadataFields(meta)
	return { title = M.title(meta), description = meta.caption or "", tags = M.tags(meta.keywords) }
end

--[[
fields: from metadataFields
privacy: { isPublic, isFriend, isFamily, hidden }; defaults to fully private and hidden from search.
]]
function M.uploadFields(fields, privacy)
	privacy = privacy or {}
	return {
		title = fields.title,
		description = fields.description,
		tags = fields.tags,
		is_public = privacy.isPublic and "1" or "0",
		is_friend = privacy.isFriend and "1" or "0",
		is_family = privacy.isFamily and "1" or "0",
		hidden = (privacy.hidden == false) and "1" or "2",
	}
end

function M.photoUrl(nsid, photoId)
	return string.format("https://www.flickr.com/photos/%s/%s/", nsid, photoId)
end

return M

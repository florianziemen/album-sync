--[[
Maps Lightroom photo metadata to Flickr upload/setMeta fields (docs/DESIGN.md §3).
]]

local M = {}

local function blank(s)
	return s == nil or s:match("^%s*$") ~= nil
end

--- Title from LR title, else file name without extension.
function M.title(meta)
	if not blank(meta.title) then
		return meta.title
	end
	return ((meta.fileName or ""):gsub("%.[^.]*$", ""))
end

--- Fields pushed to Flickr for a photo; also the input of the metadata fingerprint.
--- meta: { title, fileName, caption }
function M.metadataFields(meta)
	return { title = M.title(meta), description = meta.caption or "" }
end

--[[
meta: { title, fileName, caption }
privacy: { isPublic, isFriend, isFamily, hidden }; defaults to fully private and hidden from search.
]]
function M.uploadFields(meta, privacy)
	privacy = privacy or {}
	local fields = M.metadataFields(meta)
	fields.is_public = privacy.isPublic and "1" or "0"
	fields.is_friend = privacy.isFriend and "1" or "0"
	fields.is_family = privacy.isFamily and "1" or "0"
	fields.hidden = (privacy.hidden == false) and "1" or "2"
	return fields
end

function M.photoUrl(nsid, photoId)
	return string.format("https://www.flickr.com/photos/%s/%s/", nsid, photoId)
end

return M

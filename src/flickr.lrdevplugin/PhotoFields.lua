--[[
Maps Lightroom photo metadata to Flickr upload/setMeta fields (docs/DESIGN.md §3).
]]

local M = {}

M.MACHINE_TAG_NS = "lrflickr"

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

function M.machineTag(uuid)
	return string.format("%s:uuid=%s", M.MACHINE_TAG_NS, uuid)
end

--[[
meta: { title, fileName, caption, uuid }
privacy: { isPublic, isFriend, isFamily, hidden }; defaults to fully private and hidden from search.
]]
function M.uploadFields(meta, privacy)
	privacy = privacy or {}
	return {
		title = M.title(meta),
		description = meta.caption or "",
		tags = M.machineTag(meta.uuid),
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

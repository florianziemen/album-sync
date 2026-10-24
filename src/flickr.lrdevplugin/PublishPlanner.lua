--[[
Decides what to do with each photo of a publish batch (docs/DESIGN.md §5 step 1).

item = {
  publishedId,   -- remote id LR has for this photo in this collection (nil if new here)
  flickrId,      -- plugin field: photo already on Flickr via another collection / earlier
  stored = { image, metadata },    -- fingerprints from the last successful publish
  current = { image, metadata },
}

Actions:
  upload    new photo, render + upload
  relink    already on Flickr: no render, no upload; record id (and update metadata if changed)
  replace   image changed: render + replace file (Pro), then metadata
  metadata  only metadata changed: no render
  adopt     published before fingerprints existed: no render, push metadata, store fingerprints
  noop      nothing changed: no render, just record id again

Without Pro, "replace" is turned (once per batch, by the user) into one of:
  metadataOutdated, leaveModified, reuploadKeep, reuploadDelete
]]

local M = {}

-- Actions that need a rendered file. reupload* replace "replace" when the account has no Pro.
M.RENDERS = { upload = true, replace = true, reuploadKeep = true, reuploadDelete = true }

function M.plan(item)
	local remoteId = item.publishedId or item.flickrId
	if not remoteId then
		return "upload"
	end
	local stored, current = item.stored or {}, item.current or {}
	if not stored.image then
		return item.publishedId and "adopt" or "relink"
	end
	if stored.image ~= current.image then
		return "replace"
	end
	if not item.publishedId then
		return "relink"
	end
	if stored.metadata ~= current.metadata then
		return "metadata"
	end
	return "noop"
end

--- Count actions: { upload = n, replace = n, ... }.
function M.summarize(actions)
	local counts = {}
	for _, a in ipairs(actions) do
		counts[a] = (counts[a] or 0) + 1
	end
	return counts
end

return M

--[[
Reads and writes the per-photo plugin fields (MetadataDefinition.lua) and gathers the
inputs for fingerprints. Must run inside an LrTasks task.
]]

local LrApplication = import("LrApplication")
local LrTasks = import("LrTasks")

local FIELDS = { "flickrId", "flickrState", "imageFingerprint", "metadataFingerprint" }

local M = {}

--- Returns { [photo] = { flickrId, flickrState, imageFingerprint, metadataFingerprint } }.
function M.load(photos)
	local catalog = LrApplication.activeCatalog()
	local raw = catalog:batchGetPropertyForPlugin(photos, _PLUGIN, FIELDS)
	local result = {}
	for _, photo in ipairs(photos) do
		result[photo] = raw[photo] or {}
	end
	return result
end

--- Persist fields for one photo right after a successful Flickr call (crash-safe).
--- values: subset of FIELDS; false clears a field.
function M.save(photo, values)
	local catalog = LrApplication.activeCatalog()
	catalog:withPrivateWriteAccessDo(function()
		for _, f in ipairs(FIELDS) do
			local v = values[f]
			if v == false then
				photo:setPropertyForPlugin(_PLUGIN, f, nil)
			elseif v ~= nil then
				photo:setPropertyForPlugin(_PLUGIN, f, v)
			end
		end
	end, { timeout = 30 })
end

--- Metadata read from LR for Flickr fields.
function M.photoMeta(photo)
	return {
		title = photo:getFormattedMetadata("title"),
		fileName = photo:getFormattedMetadata("fileName"),
		caption = photo:getFormattedMetadata("caption"),
		-- Respects "Include on Export", parents and synonyms.
		keywords = photo:getFormattedMetadata("keywordTagsForExport"),
	}
end

function M.developSettings(photo)
	return photo:getDevelopSettings()
end

--- Remote id (album id) of a published collection by local id, or nil.
function M.collectionRemoteId(localCollectionId)
	if not localCollectionId then
		return nil
	end
	local collection = LrApplication.activeCatalog():getPublishedCollectionByLocalIdentifier(localCollectionId)
	return collection and collection:getRemoteId() or nil
end

--[[
After a re-upload: point every other published collection of this plugin that contains the
photo at the new Flickr id. `except` is the collection being published (LR records it itself).
Returns number of collections updated, or nil, error message.
]]
function M.retarget(photo, oldId, newId, url, except)
	local catalog = LrApplication.activeCatalog()
	local exceptId = except and except.localIdentifier
	local targets = {}
	for _, c in ipairs(photo:getContainedPublishedCollections()) do
		if c.localIdentifier ~= exceptId and c:getService():getPluginId() == _PLUGIN.id then
			targets[#targets + 1] = c
		end
	end
	if #targets == 0 then
		return 0
	end
	local ok, err = LrTasks.pcall(function()
		catalog:withWriteAccessDo("Update Flickr photo id", function()
			for _, c in ipairs(targets) do
				c:addPhotoByRemoteId(photo, newId, url, true)
			end
		end, { timeout = 30 })
	end)
	if not ok then
		return nil, string.format("retarget %s -> %s failed: %s", tostring(oldId), tostring(newId), tostring(err))
	end
	return #targets
end

return M

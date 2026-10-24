--[[
Reads and writes the per-photo plugin fields (MetadataDefinition.lua) and gathers the
inputs for fingerprints. Must run inside an LrTasks task.
]]

local LrApplication = import("LrApplication")

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

return M

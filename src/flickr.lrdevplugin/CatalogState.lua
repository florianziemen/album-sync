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

function M.uuid(photo)
	return photo:getRawMetadata("uuid")
end

function M.photoByUuid(uuid)
	return LrApplication.activeCatalog():findPhotoByUuid(uuid)
end

function M.developSettings(photo)
	return photo:getDevelopSettings()
end

--[[
Flickr ids that LR recorded for `photos` in any published collection of this plugin.
Backfills photos published before the flickrId field existed, so they are relinked instead of
uploaded again. Returns { [photo.localIdentifier] = remoteId }.
]]
function M.remoteIdsFromCollections(photos)
	local result, byCollection = {}, {}
	for _, photo in ipairs(photos) do
		for _, c in ipairs(photo:getContainedPublishedCollections()) do
			if c:getService():getPluginId() == _PLUGIN.id then
				local map = byCollection[c.localIdentifier]
				if not map then
					map = {}
					for _, pp in ipairs(c:getPublishedPhotos()) do
						local rid = pp:getRemoteId()
						if rid then
							map[pp:getPhoto().localIdentifier] = tostring(rid)
						end
					end
					byCollection[c.localIdentifier] = map
				end
				local rid = map[photo.localIdentifier]
				if rid then
					result[photo.localIdentifier] = rid
					break
				end
			end
		end
	end
	return result
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

--- All published collections (not sets) of this plugin's publish services.
function M.pluginCollections()
	local out = {}
	local function walk(container)
		for _, c in ipairs(container:getChildCollections()) do
			out[#out + 1] = c
		end
		for _, set in ipairs(container:getChildCollectionSets()) do
			walk(set)
		end
	end
	for _, service in ipairs(LrApplication.activeCatalog():getPublishServices(_PLUGIN.id)) do
		walk(service)
	end
	return out
end

--- lockedNsid of each publish service of this plugin.
function M.lockedAccounts()
	local out = {}
	for _, service in ipairs(LrApplication.activeCatalog():getPublishServices(_PLUGIN.id)) do
		local settings = service:getPublishSettings() or {}
		if settings.lockedNsid and settings.lockedNsid ~= "" then
			out[#out + 1] = settings.lockedNsid
		end
	end
	return out
end

--[[
Every Flickr id the catalog knows, as links { photo, id, collection } (collection nil for the
plugin field flickrId). One photo can have several links (several collections, stale ids).
]]
function M.knownLinks()
	local links = {}
	for _, c in ipairs(M.pluginCollections()) do
		for _, pp in ipairs(c:getPublishedPhotos()) do
			local rid = pp:getRemoteId()
			if rid then
				links[#links + 1] = { photo = pp:getPhoto(), id = tostring(rid), collection = c }
			end
		end
	end
	local catalog = LrApplication.activeCatalog()
	for _, photo in ipairs(catalog:findPhotosWithProperty(_PLUGIN.id, "flickrId")) do
		local id = photo:getPropertyForPlugin(_PLUGIN, "flickrId", nil, true)
		if id then
			links[#links + 1] = { photo = photo, id = tostring(id) }
		end
	end
	return links
end

--[[
Mark photos whose Flickr copy is gone (see RemoteCheck.classify).
photos: LrPhoto array -> flickrState = "deletedOnFlickr".
unlink = true: also clear their flickrId/fingerprints, and remove `staleLinks`
({ photo, collection }) from their collections, so they can be published again as new photos.
]]
function M.markDeleted(photos, staleLinks, unlink)
	local byCollection = {}
	if unlink then
		for _, link in ipairs(staleLinks) do
			local key = link.collection.localIdentifier
			byCollection[key] = byCollection[key] or { collection = link.collection, photos = {} }
			table.insert(byCollection[key].photos, link.photo)
		end
	end
	LrApplication.activeCatalog():withWriteAccessDo("Flickr: mark photos deleted on Flickr", function()
		for _, photo in ipairs(photos) do
			photo:setPropertyForPlugin(_PLUGIN, "flickrState", "deletedOnFlickr")
			if unlink then
				photo:setPropertyForPlugin(_PLUGIN, "flickrId", nil)
				photo:setPropertyForPlugin(_PLUGIN, "imageFingerprint", nil)
				photo:setPropertyForPlugin(_PLUGIN, "metadataFingerprint", nil)
			end
		end
		for _, item in pairs(byCollection) do
			item.collection:removePhotos(item.photos)
		end
	end, { timeout = 60 })
end

return M

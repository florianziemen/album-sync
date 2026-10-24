--[[
Links catalog photos to existing Flickr photos without uploading (import and review):
into the album collections that exist for the photo's albums, else into "Photostream".
Fingerprints of the current LR state are stored, so nothing is pushed until the photo
changes in Lightroom.
]]

local AlbumSync = require("AlbumSync")
local CatalogState = require("CatalogState")
local Fingerprint = require("Fingerprint")
local PhotoFields = require("PhotoFields")
local PhotoRenderer = require("PhotoRenderer")

local M = {}

function M.renderSettings(service)
	return PhotoRenderer.copySettings(service:getPublishSettings()) or {}
end

--- Link records for CatalogState.linkPublished. matches: array of { id, photo }.
function M.links(nsid, matches, renderSettings)
	local out = {}
	for _, m in ipairs(matches) do
		out[#out + 1] = {
			photo = m.photo,
			id = m.id,
			url = PhotoFields.photoUrl(nsid, m.id),
			fingerprints = {
				image = Fingerprint.image(CatalogState.developSettings(m.photo), renderSettings),
				metadata = Fingerprint.metadata(PhotoFields.metadataFields(CatalogState.photoMeta(m.photo))),
			},
		}
	end
	return out
end

--[[
Link one photo found in review: into the existing collections of `albumIds`, or into
Photostream when the photo is in no album. Returns a short description of where.
]]
function M.linkOne(service, nsid, photo, flickrId, albumIds)
	local links = M.links(nsid, { { id = flickrId, photo = photo } }, M.renderSettings(service))
	local byRemote = CatalogState.collectionsByRemoteId()
	local where = {}
	for _, albumId in ipairs(albumIds or {}) do
		local c = byRemote[albumId]
		if c then
			CatalogState.linkPublished(c, links, { id = albumId, url = AlbumSync.url(nsid, albumId) })
			where[#where + 1] = c:getName()
		end
	end
	if #where == 0 then
		local c = CatalogState.defaultCollection(service)
		if c then
			CatalogState.linkPublished(c, links)
			where[#where + 1] = c:getName()
		end
	end
	return table.concat(where, ", ")
end

return M

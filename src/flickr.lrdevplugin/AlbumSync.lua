--[[
Flickr album (photoset) operations with idempotent semantics (docs/DESIGN.md §7).

"Already in album" / "not in album" count as success, so retries and re-publishes are safe.
An album deleted on Flickr is recreated on the next add.
All functions take a FlickrApi instance.
]]

local M = {}

-- Flickr error codes (photosets.* docs, checked 2026-10-24).
local SET_NOT_FOUND = 1
local ALREADY_IN_SET = 3
local NOT_IN_SET = 3
local PHOTO_NOT_FOUND = 2 -- removePhoto: photo deleted on Flickr

function M.url(nsid, albumId)
	return string.format("https://www.flickr.com/photos/%s/albums/%s", nsid, albumId)
end

--- Create an album; the primary photo becomes its first member. Returns album id or nil, err.
function M.create(api, title, primaryPhotoId)
	local data, e = api:call(
		"flickr.photosets.create",
		{
			title = title,
			primary_photo_id = primaryPhotoId,
		},
		"POST",
		function(d)
			if type(d.photoset) ~= "table" or not d.photoset.id then
				return "photosets.create: missing photoset.id"
			end
		end
	)
	if not data then
		return nil, e
	end
	return tostring(data.photoset.id)
end

--[[
Add a photo to the album in `album` = { id, title }, creating the album when it has no id yet
or no longer exists on Flickr. Updates album.id and sets album.created = true when created.
Returns true or nil, err.
]]
function M.add(api, album, photoId)
	if album.id then
		local _, e = api:call("flickr.photosets.addPhoto", { photoset_id = album.id, photo_id = photoId }, "POST")
		if not e or e.code == ALREADY_IN_SET then
			return true
		end
		if e.code ~= SET_NOT_FOUND then
			return nil, e
		end
		album.recreatedFrom = album.id
	end
	local id, e = M.create(api, album.title, photoId)
	if not id then
		return nil, e
	end
	album.id, album.created = id, true
	return true
end

--- Remove a photo from an album. Missing album, missing photo or photo-not-in-album count as success.
function M.remove(api, albumId, photoId)
	local _, e = api:call("flickr.photosets.removePhoto", { photoset_id = albumId, photo_id = photoId }, "POST")
	if not e or e.code == SET_NOT_FOUND or e.code == NOT_IN_SET or e.code == PHOTO_NOT_FOUND then
		return true
	end
	return nil, e
end

--- Rename an album, keeping its description (editMeta may clear an omitted description).
function M.rename(api, albumId, title)
	local info, e = api:call("flickr.photosets.getInfo", { photoset_id = albumId }, nil, function(d)
		if type(d.photoset) ~= "table" then
			return "photosets.getInfo: missing photoset"
		end
	end)
	if not info then
		return nil, e
	end
	local description = info.photoset.description
	if type(description) == "table" then
		description = description._content
	end
	local _, editErr = api:call(
		"flickr.photosets.editMeta",
		{ photoset_id = albumId, title = title, description = description or "" },
		"POST"
	)
	if editErr then
		return nil, editErr
	end
	return true
end

--- Push the order of photo ids (photos not listed keep their relative order).
function M.reorder(api, albumId, photoIds)
	if #photoIds == 0 then
		return true
	end
	local _, e = api:call(
		"flickr.photosets.reorderPhotos",
		{ photoset_id = albumId, photo_ids = table.concat(photoIds, ",") },
		"POST"
	)
	if e then
		return nil, e
	end
	return true
end

--- Album ids a photo belongs to. Returns array or nil, err.
function M.albumsOf(api, photoId)
	local data, e = api:call("flickr.photos.getAllContexts", { photo_id = photoId })
	if not data then
		return nil, e
	end
	local ids = {}
	local sets = data.set
	if type(sets) == "table" then
		if sets.id then -- single object instead of array
			sets = { sets }
		end
		for _, s in ipairs(sets) do
			ids[#ids + 1] = tostring(s.id)
		end
	end
	return ids
end

--[[
After a re-upload: put the new photo into every album of the old one; with keepOld, also take
the old photo out of those albums (it stays online). Returns array of album ids, or nil, err.
]]
function M.moveToNewPhoto(api, oldId, newId, keepOld)
	local albums, e = M.albumsOf(api, oldId)
	if not albums then
		return nil, e
	end
	for _, albumId in ipairs(albums) do
		local ok, addErr = M.add(api, { id = albumId }, newId)
		if not ok then
			return nil, addErr
		end
		if keepOld then
			local removed, rmErr = M.remove(api, albumId, oldId)
			if not removed then
				return nil, rmErr
			end
		end
	end
	return albums
end

return M

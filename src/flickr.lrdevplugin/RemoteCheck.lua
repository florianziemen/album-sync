--[[
Finds photos that LR believes are on Flickr but were deleted there (docs/DESIGN.md §3).

A photo counts as deleted only if it is missing from the full listing of own photos AND a
direct lookup (photos.getInfo) says "Photo not found". An incomplete listing therefore can
never cause a false "deleted".
]]

local M = {}

--[[
remoteIds: array of Flickr photo ids known to the catalog.
Returns { missing = {id...}, checked = n, listed = count, total = total, unconfirmed = {id...} }
or nil, err. unconfirmed: lookups that failed with an error other than "not found".
]]
function M.findMissing(api, remoteIds, progress)
	local listed, count, total = api:listOwnPhotoIds()
	if not listed then
		return nil, count
	end
	local result = { missing = {}, unconfirmed = {}, checked = #remoteIds, listed = count, total = total }
	local candidates = {}
	for _, id in ipairs(remoteIds) do
		if not listed[tostring(id)] then
			candidates[#candidates + 1] = tostring(id)
		end
	end
	for i, id in ipairs(candidates) do
		if progress then
			progress(i, #candidates)
		end
		local exists = api:photoExists(id)
		if exists == false then
			result.missing[#result.missing + 1] = id
		elseif exists == nil then
			result.unconfirmed[#result.unconfirmed + 1] = id
		end
	end
	return result
end

--[[
Decide what to mark. links: array of { photoKey, id, collectionKey } (collectionKey nil = the
plugin field flickrId, i.e. the photo's current id). missing: set { [id] = true }.
A photo is deleted when its current id is missing, or - without a current id - when all its
collection ids are missing. Returns { photos = { [photoKey] = true }, staleLinks = {link...} }
where staleLinks are collection links whose id is missing (to remove when unlinking).
]]
function M.classify(links, missing)
	local byPhoto = {}
	for _, link in ipairs(links) do
		local p = byPhoto[link.photoKey] or { collections = {}, anyPresent = false }
		byPhoto[link.photoKey] = p
		if link.collectionKey == nil then
			p.current = link.id
		else
			p.collections[#p.collections + 1] = link
			if not missing[link.id] then
				p.anyPresent = true
			end
		end
	end
	local result = { photos = {}, staleLinks = {} }
	for key, p in pairs(byPhoto) do
		local deleted
		if p.current then
			deleted = missing[p.current] == true
		else
			deleted = #p.collections > 0 and not p.anyPresent
		end
		if deleted then
			result.photos[key] = true
		end
		for _, link in ipairs(p.collections) do
			if missing[link.id] then
				result.staleLinks[#result.staleLinks + 1] = link
			end
		end
	end
	return result
end

return M

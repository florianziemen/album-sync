--[[
Plans linking existing Flickr albums/photos to a catalog (docs/DESIGN.md §7).

Inputs:
  albums      FlickrIndex.albums result (with photos)
  photostream photos taken in the catalog's range (FlickrIndex.photosTaken)
  catalog     Matcher catalog records (key = photo uuid)
  range       { min, max } wall-clock taken strings of the catalog
  linked      { [key] = flickrId } photos already linked (plugin field)
Matching runs once over all Flickr photos in range, so duplicates are found across albums.

Result: {
  albums = array of { album, inRange, matches = { {id, key, how} }, review = {...} },  -- in-range albums only
  photostream = { matches, review },  -- matched photos in no album
  review = all review items { id, candidates, reason, album? },
  stats = { albumsTotal, albumsInRange, flickrInRange, matched, review, notInCatalog }
}
]]

local FlickrIndex = require("FlickrIndex")
local Matcher = require("Matcher")

local M = {}

function M.build(albums, photostream, catalog, range, linked)
	linked = linked or {}
	local inRangeAlbums, all, seen, albumOf = {}, {}, {}, {}
	local function add(p)
		if not seen[p.id] then
			seen[p.id] = true
			all[#all + 1] = p
		end
	end
	for _, album in ipairs(albums) do
		local photos = FlickrIndex.inRange(album, range.min, range.max)
		if #photos > 0 then
			inRangeAlbums[#inRangeAlbums + 1] = { album = album, photos = photos }
			for _, p in ipairs(photos) do
				add(p)
				albumOf[p.id] = albumOf[p.id] or {}
				table.insert(albumOf[p.id], album)
			end
		end
	end
	for _, p in ipairs(photostream or {}) do
		add(p)
	end

	-- Pairs linked earlier (this catalog) are settled: leave both sides out of matching, so
	-- re-running the import neither re-queues them nor offers them as candidates.
	local linkedIds = {}
	for _, id in pairs(linked) do
		linkedIds[tostring(id)] = true
	end
	local open, alreadyLinked = {}, 0
	for _, p in ipairs(all) do
		if linkedIds[p.id] then
			alreadyLinked = alreadyLinked + 1
		else
			open[#open + 1] = p
		end
	end
	local present = {}
	for _, p in ipairs(all) do
		present[p.id] = true
	end
	local candidates = {}
	for _, c in ipairs(catalog) do
		local id = linked[c.key]
		if not (id and present[tostring(id)]) then
			candidates[#candidates + 1] = c
		end
	end

	local r = Matcher.match(candidates, open)

	-- A photo already linked to a different Flickr id is a conflict, not a match.
	local review = {}
	for _, item in ipairs(r.review) do
		review[#review + 1] = item
	end
	local matches = {}
	for id, m in pairs(r.matches) do
		local existing = linked[m.key]
		if existing and existing ~= id then
			review[#review + 1] = {
				id = id,
				candidates = { m.key },
				reason = "catalog photo is already linked to Flickr photo " .. existing,
			}
		else
			matches[id] = m
		end
	end
	table.sort(review, function(a, b)
		return a.id < b.id
	end)
	local photoById = {}
	for _, p in ipairs(all) do
		photoById[p.id] = p
	end
	local reviewById = {}
	for _, item in ipairs(review) do
		local p = photoById[item.id]
		item.title = p and p.title
		item.taken = p and p.taken
		local albumsOfPhoto = albumOf[item.id]
		item.album = albumsOfPhoto and albumsOfPhoto[1].title or nil
		item.albumIds = {}
		for _, a in ipairs(albumsOfPhoto or {}) do
			item.albumIds[#item.albumIds + 1] = a.id
		end
		reviewById[item.id] = item
	end

	local result = { albums = {}, photostream = { matches = {}, review = {} }, review = review }
	local matched = 0
	for _, entry in ipairs(inRangeAlbums) do
		local plan = { album = entry.album, inRange = #entry.photos, matches = {}, review = {} }
		for _, p in ipairs(entry.photos) do
			local m = matches[p.id]
			if m then
				plan.matches[#plan.matches + 1] = { id = p.id, key = m.key, how = m.how }
			elseif reviewById[p.id] then
				plan.review[#plan.review + 1] = reviewById[p.id]
			end
		end
		result.albums[#result.albums + 1] = plan
	end
	for _, p in ipairs(photostream or {}) do
		if not albumOf[p.id] then
			local m = matches[p.id]
			if m then
				table.insert(result.photostream.matches, { id = p.id, key = m.key, how = m.how })
			elseif reviewById[p.id] then
				table.insert(result.photostream.review, reviewById[p.id])
			end
		end
	end
	for _ in pairs(matches) do
		matched = matched + 1
	end
	result.albumOf = albumOf
	result.stats = {
		albumsTotal = #albums,
		albumsInRange = #inRangeAlbums,
		flickrInRange = #all,
		matched = matched,
		alreadyLinked = alreadyLinked,
		review = #review,
		notInCatalog = #r.notInCatalog,
	}
	return result
end

--[[
Move a review item into the matches (after an EXIF tie-break or a user decision): into every
in-range album containing the photo, or into the photostream when it is in no album.
]]
function M.promote(plan, flickrId, key, how)
	local function drop(list)
		for i = #list, 1, -1 do
			if list[i].id == flickrId then
				table.remove(list, i)
			end
		end
	end
	local inAlbum = {}
	for _, album in ipairs(plan.albumOf[flickrId] or {}) do
		inAlbum[album.id] = true
	end
	local match = { id = flickrId, key = key, how = how }
	drop(plan.review)
	drop(plan.photostream.review)
	for _, a in ipairs(plan.albums) do
		drop(a.review)
		if inAlbum[a.album.id] then
			a.matches[#a.matches + 1] = match
		end
	end
	if next(inAlbum) == nil then
		plan.photostream.matches[#plan.photostream.matches + 1] = match
	end
	plan.stats.matched = plan.stats.matched + 1
	plan.stats.review = plan.stats.review - 1
end

--- Catalog range from Matcher records: { min, max } or nil when no dated photos.
function M.range(catalog)
	local lo, hi
	for _, c in ipairs(catalog) do
		if c.taken then
			lo = (not lo or c.taken < lo) and c.taken or lo
			hi = (not hi or c.taken > hi) and c.taken or hi
		end
	end
	if not lo then
		return nil
	end
	return { min = lo, max = hi }
end

--- LR "dateTimeOriginalISO8601" (e.g. 2019-05-01T10:00:00.12+02:00) -> wall clock seconds.
function M.wallClock(iso)
	if type(iso) ~= "string" then
		return nil
	end
	local d, t = iso:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d:%d%d)")
	return d and (d .. " " .. t) or nil
end

return M

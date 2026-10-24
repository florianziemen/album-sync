--[[
File > Plug-in Extras > "Album Sync: Link existing Flickr albums…"

Read-only on Flickr. Lists the account's albums (cached), keeps those with photos in this
catalog's date range, matches their photos (and photostream photos in no album) to catalog
photos, shows the albums grouped by the year of their newest photo, and links the chosen ones:
one published collection per album under a collection set per year, photos marked as already
published (no upload). Unclear matches go to the review queue.
]]

local LrBinding = import("LrBinding")
local LrDialogs = import("LrDialogs")
local LrFunctionContext = import("LrFunctionContext")
local LrLogger = import("LrLogger")
local LrProgressScope = import("LrProgressScope")
local LrView = import("LrView")
local LrApplication = import("LrApplication")

local AccountGuard = require("AccountGuard")
local AlbumSync = require("AlbumSync")
local AppDeps = require("AppDeps")
local CatalogState = require("CatalogState")
local CredentialStore = require("CredentialStore")
local FlickrApi = require("FlickrApi")
local FlickrIndex = require("FlickrIndex")
local FlickrResponse = require("FlickrResponse")
local ImportPlan = require("ImportPlan")
local JsonFile = require("JsonFile")
local Linker = require("Linker")
local Matcher = require("Matcher")
local RateLimiter = require("RateLimiter")
local ReviewQueue = require("ReviewQueue")
local UiText = require("UiText")

local log = LrLogger("album-sync")
log:enable("logfile")

local function fatal(message)
	log:error("import: " .. message)
	LrDialogs.message("Album Sync: link existing albums", message, "critical")
end

local function albumLine(plan)
	local a = plan.album
	return string.format(
		"%s — %d in range: %d matched, %d to review",
		a.title ~= "" and a.title or ("(untitled " .. a.id .. ")"),
		plan.inRange,
		#plan.matches,
		#plan.review
	)
end

-- Selection dialog: albums grouped by year, all checked by default. Returns selected set or nil.
local function choose(context, plan)
	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(context)
	local groups = FlickrIndex.byYear((function()
		local list = {}
		for _, p in ipairs(plan.albums) do
			p.album.plan = p
			list[#list + 1] = p.album
		end
		return list
	end)())
	local rows = {}
	for _, g in ipairs(groups) do
		rows[#rows + 1] =
			f:static_text({ title = g.year and tostring(g.year) or "Unknown year", font = "<system/bold>" })
		for _, album in ipairs(g.albums) do
			local key = "album_" .. album.id
			props[key] = #album.plan.matches > 0
			rows[#rows + 1] = f:checkbox({ title = albumLine(album.plan), value = LrView.bind(key) })
		end
	end
	props.photostream = #plan.photostream.matches > 0
	local s = plan.stats
	local result = LrDialogs.presentModalDialog({
		title = "Album Sync: link existing albums",
		actionVerb = "Link",
		contents = f:column({
			bind_to_object = props,
			spacing = f:control_spacing(),
			UiText.wrapped(
				f,
				string.format(
					"%d of %d albums have photos in this catalog's date range. %d Flickr photos in range: "
						.. "%d matched, %d to review, %d not in this catalog.",
					s.albumsInRange,
					s.albumsTotal,
					s.flickrInRange,
					s.matched,
					s.review,
					s.notInCatalog
				),
				90
			),
			f:scrolled_view({ width = 640, height = 360, f:column(rows) }),
			f:checkbox({
				title = string.format(
					"Photostream: link %d matched photo(s) that are in no album",
					#plan.photostream.matches
				),
				value = LrView.bind("photostream"),
			}),
			UiText.wrapped(
				f,
				"Nothing is changed on Flickr. Unclear matches are kept for review "
					.. "(File > Plug-in Extras > Album Sync: Review unclear matches…).",
				90
			),
		}),
	})
	if result ~= "ok" then
		return nil
	end
	local selected = { photostream = props.photostream }
	for _, p in ipairs(plan.albums) do
		selected[p.album.id] = props["album_" .. p.album.id] == true
	end
	return selected
end

-- Unique collection name within a year set: Flickr album titles can repeat.
local function collectionName(album, used)
	local name = album.title ~= "" and album.title or ("Album " .. album.id)
	if used[name] then
		name = string.format("%s (%s)", name, album.id)
	end
	used[name] = true
	return name
end

LrFunctionContext.postAsyncTaskWithContext("Album Sync: link existing albums", function(context)
	LrDialogs.attachErrorDialogToFunctionContext(context)
	local catalog = LrApplication.activeCatalog()
	local deps = AppDeps()
	deps.limiter = RateLimiter.new(deps)

	local nsid, e = AccountGuard.catalogAccount(CatalogState.lockedAccounts())
	if not nsid then
		return fatal(e.message .. " Create a Flickr publish service and lock it to the account first.")
	end
	local service = CatalogState.publishService()
	local creds = CredentialStore.account(nsid)
	local user
	user, e = AccountGuard.verify(deps, creds, nsid, "read")
	if not user then
		return fatal(FlickrResponse.describe(e))
	end
	local api = FlickrApi.new(deps, creds, { token = creds.token, tokenSecret = creds.tokenSecret })
	log:info(string.format("import: account %s (%s), perms=%s", user.username, user.id, tostring(creds.perms)))

	local progress = LrProgressScope({ title = "Album Sync: reading catalog and albums", functionContext = context })
	progress:setCaption("Reading catalog…")
	for _, ch in ipairs(CatalogState.repairFlickrIds()) do
		log:info(
			string.format(
				"import: repaired Flickr ID of %s: %s -> %s",
				tostring(ch.photo:getRawMetadata("uuid")),
				tostring(ch.from),
				ch.to
			)
		)
	end
	local records, photoByKey, linked, linkedIds = CatalogState.matcherRecords()
	local range = ImportPlan.range(records)
	if not range then
		progress:done()
		return fatal("No photos with a capture date in this catalog.")
	end
	log:info(string.format("import: %d catalog photos, range %s .. %s", #records, range.min, range.max))

	local cache = FlickrIndex.Cache.new(JsonFile.storage("albums-" .. nsid:gsub("[^%w]", "_") .. ".json"))
	-- Albums untouched since before the catalog's first photo cannot contain its photos.
	-- 2 days of slack for time zones (taken dates are wall clock) and camera clocks.
	local updatedSince = FlickrIndex.toSeconds(range.min) - 2 * 86400
	local albums
	albums, e = FlickrIndex.albums(api, cache, function(i, n, album)
		progress:setCaption(string.format("Reading album %d of %d: %s", i, n, album.title))
		progress:setPortionComplete(i, n)
	end, updatedSince)
	if not albums then
		progress:done()
		return fatal(FlickrResponse.describe(e))
	end
	local skipped, cached = 0, 0
	for _, a in ipairs(albums) do
		skipped = skipped + (a.skipped and 1 or 0)
		cached = cached + (a.fromCache and 1 or 0)
	end
	log:info(
		string.format("import: %d albums, %d from cache, %d skipped (unchanged before range)", #albums, cached, skipped)
	)
	progress:setPortionComplete(0, 1) -- new phase: the album bar was full
	progress:setCaption("Reading photos taken in this catalog's range…")
	local photostream
	photostream, e = FlickrIndex.photosTaken(api, range.min, range.max, function(n)
		progress:setCaption(string.format("Reading photos taken in this catalog's range… %d", n))
	end)
	progress:done()
	if not photostream then
		return fatal(FlickrResponse.describe(e))
	end

	local plan = ImportPlan.build(albums, photostream, records, range, linked, linkedIds)

	-- Tier 3: EXIF tie-break for "same time" cases (one getExif call each).
	local recordByKey = {}
	for _, r in ipairs(records) do
		recordByKey[r.key] = r
	end
	local exifCandidates = {}
	for _, item in ipairs(plan.review) do
		if item.reason:find("^same time") then
			exifCandidates[#exifCandidates + 1] = item
		end
	end
	if #exifCandidates > 0 then
		local tie =
			LrProgressScope({ title = "Album Sync: comparing EXIF of unclear matches", functionContext = context })
		for i, item in ipairs(exifCandidates) do
			tie:setPortionComplete(i - 1, #exifCandidates)
			local exif = api:exif(item.id)
			if exif then
				local cands = {}
				for _, key in ipairs(item.candidates) do
					cands[#cands + 1] = recordByKey[key]
				end
				local key, how = Matcher.resolveByExif(exif, cands)
				log:info(
					string.format(
						"import: exif flickr=%s PreservedFileName=%s SubSec=%s Serial=%s -> %s (%s)",
						item.id,
						tostring(exif.PreservedFileName),
						tostring(exif.SubSecTimeOriginal),
						tostring(exif.SerialNumber),
						tostring(key),
						tostring(how)
					)
				)
				for _, c in ipairs(cands) do
					log:info(
						string.format(
							"import: candidate %s names=%s subsec=%s serial=%s iso=%s",
							c.key,
							table.concat(c.names, "|"),
							tostring(c.subsec),
							tostring(c.serial),
							tostring(c.iso)
						)
					)
				end
				if key then
					ImportPlan.promote(plan, item.id, key, how)
				end
			end
		end
		tie:done()
	end
	local s = plan.stats
	log:info(
		string.format(
			"import: albums=%d inRange=%d flickrInRange=%d matched=%d review=%d notInCatalog=%d photostreamOnly=%d",
			s.albumsTotal,
			s.albumsInRange,
			s.flickrInRange,
			s.matched,
			s.review,
			s.notInCatalog,
			#plan.photostream.matches
		)
	)

	local selected = choose(context, plan)
	if not selected then
		return
	end

	-- Fingerprints of the current LR state: linked photos are only pushed after a change in LR.
	local renderSettings = Linker.renderSettings(service)
	local function linksFor(matches)
		local list = {}
		for i, m in ipairs(matches) do
			list[i] = { id = m.id, photo = photoByKey[m.key] }
		end
		return Linker.links(nsid, list, renderSettings, service:getPublishSettings())
	end

	local apply = LrProgressScope({ title = "Album Sync: linking albums", functionContext = context })
	local existing = CatalogState.collectionsByRemoteId()
	local linkedAlbums, linkedPhotos = 0, 0

	-- Phase 1: create year sets and collections (new objects are usable after the gate).
	local targets = {}
	catalog:withWriteAccessDo("Album Sync: create album collections", function()
		local sets, used = {}, {}
		for _, p in ipairs(plan.albums) do
			if selected[p.album.id] and #p.matches > 0 then
				local collection = existing[p.album.id]
				if not collection then
					local yearName = p.album.year and tostring(p.album.year) or "Unknown year"
					sets[yearName] = sets[yearName] or service:createPublishedCollectionSet(yearName, nil, true)
					used[yearName] = used[yearName] or {}
					collection =
						service:createPublishedCollection(collectionName(p.album, used[yearName]), sets[yearName], true)
				end
				targets[#targets + 1] = { plan = p, collection = collection }
			end
		end
	end, { timeout = 60 })

	-- Phase 2: link photos per album.
	for i, t in ipairs(targets) do
		apply:setCaption(string.format("Linking album %d of %d: %s", i, #targets, t.plan.album.title))
		apply:setPortionComplete(i - 1, #targets)
		local remoteId = t.collection:getRemoteId()
		if remoteId and tostring(remoteId) ~= t.plan.album.id then
			log:error(
				string.format(
					"import: collection %s already belongs to album %s, skipping album %s",
					t.collection:getName(),
					tostring(remoteId),
					t.plan.album.id
				)
			)
		else
			local links = linksFor(t.plan.matches)
			local n, conflicts = CatalogState.linkPublished(
				t.collection,
				links,
				{ id = t.plan.album.id, url = AlbumSync.url(nsid, t.plan.album.id) }
			)
			linkedAlbums = linkedAlbums + 1
			linkedPhotos = linkedPhotos + n
			log:info(string.format("import: album %s (%s): linked %d", t.plan.album.title, t.plan.album.id, n))
			for _, sk in ipairs(conflicts) do
				log:error(
					string.format(
						"import: flickr=%s already belongs to %s in album %s; skipped",
						sk.link.id,
						tostring(sk.holder:getRawMetadata("uuid")),
						t.plan.album.title
					)
				)
			end
		end
	end

	if selected.photostream and #plan.photostream.matches > 0 then
		local photostreamCollection = CatalogState.defaultCollection(service)
		if photostreamCollection then
			apply:setCaption("Linking photostream photos…")
			local links = linksFor(plan.photostream.matches)
			local n, conflicts = CatalogState.linkPublished(photostreamCollection, links)
			linkedPhotos = linkedPhotos + n
			log:info(string.format("import: photostream: linked %d, skipped %d", n, #conflicts))
		else
			log:error("import: no default (Photostream) collection found")
		end
	end
	apply:done()

	local queue = ReviewQueue.new(JsonFile.storage("review-" .. JsonFile.catalogKey() .. ".json"))
	-- Photos linked now are no longer unclear (they may be queued from an earlier run).
	local resolvedNow = 0
	local function dequeue(matches)
		for _, m in ipairs(matches) do
			if queue:remove(m.id) then
				resolvedNow = resolvedNow + 1
			end
		end
	end
	for _, t in ipairs(targets) do
		dequeue(t.plan.matches)
	end
	if selected.photostream then
		dequeue(plan.photostream.matches)
	end
	if resolvedNow > 0 then
		log:info(string.format("import: %d queued item(s) resolved by this run", resolvedNow))
	end
	local added = queue:add(plan.review)
	for _, item in ipairs(plan.review) do
		log:info(
			string.format(
				"import: review flickr=%s album=%s candidates=%s reason=%s",
				item.id,
				tostring(item.album),
				table.concat(item.candidates, ","),
				item.reason
			)
		)
	end

	LrDialogs.message(
		"Album Sync: albums linked",
		string.format(
			"Linked %d album(s) and %d photo(s) as already published.\n%d unclear match(es) added to the review queue "
				.. "(%d in total).",
			linkedAlbums,
			linkedPhotos,
			added,
			#queue:items()
		),
		"info"
	)
end)

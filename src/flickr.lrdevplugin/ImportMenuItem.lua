--[[
File > Plug-in Extras > "Flickr: Link existing Flickr albums…"

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
local Fingerprint = require("Fingerprint")
local FlickrApi = require("FlickrApi")
local FlickrIndex = require("FlickrIndex")
local FlickrResponse = require("FlickrResponse")
local ImportPlan = require("ImportPlan")
local JsonFile = require("JsonFile")
local PhotoFields = require("PhotoFields")
local PhotoRenderer = require("PhotoRenderer")
local RateLimiter = require("RateLimiter")
local ReviewQueue = require("ReviewQueue")

local log = LrLogger("lrflickr")
log:enable("logfile")

local function fatal(message)
	log:error("import: " .. message)
	LrDialogs.message("Flickr: link existing albums", message, "critical")
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
		title = "Flickr: link existing albums",
		actionVerb = "Link",
		contents = f:column({
			bind_to_object = props,
			spacing = f:control_spacing(),
			f:static_text({
				title = string.format(
					"%d of %d albums have photos in this catalog's date range. %d Flickr photos in range: "
						.. "%d matched, %d to review, %d not in this catalog.",
					s.albumsInRange,
					s.albumsTotal,
					s.flickrInRange,
					s.matched,
					s.review,
					s.notInCatalog
				),
			}),
			f:scrolled_view({ width = 640, height = 360, f:column(rows) }),
			f:checkbox({
				title = string.format(
					"Photostream: link %d matched photo(s) that are in no album",
					#plan.photostream.matches
				),
				value = LrView.bind("photostream"),
			}),
			f:static_text({
				title = "Nothing is changed on Flickr. Unclear matches are kept for review "
					.. "(File > Plug-in Extras > Flickr: Review unclear matches…).",
			}),
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

LrFunctionContext.postAsyncTaskWithContext("Flickr: link existing albums", function(context)
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

	local progress = LrProgressScope({ title = "Flickr: reading catalog and albums", functionContext = context })
	progress:setCaption("Reading catalog…")
	local records, photoByKey, linked = CatalogState.matcherRecords()
	local range = ImportPlan.range(records)
	if not range then
		progress:done()
		return fatal("No photos with a capture date in this catalog.")
	end
	log:info(string.format("import: %d catalog photos, range %s .. %s", #records, range.min, range.max))

	local cache = FlickrIndex.Cache.new(JsonFile.storage("albums-" .. nsid:gsub("[^%w]", "_") .. ".json"))
	local albums
	albums, e = FlickrIndex.albums(api, cache, function(i, n, album)
		progress:setCaption(string.format("Reading album %d of %d: %s", i, n, album.title))
		progress:setPortionComplete(i, n)
	end)
	if not albums then
		progress:done()
		return fatal(FlickrResponse.describe(e))
	end
	progress:setCaption("Reading photos taken in this catalog's range…")
	local photostream
	photostream, e = FlickrIndex.photosTaken(api, range.min, range.max, function(n)
		progress:setCaption(string.format("Reading photos taken in this catalog's range… %d", n))
	end)
	progress:done()
	if not photostream then
		return fatal(FlickrResponse.describe(e))
	end

	local plan = ImportPlan.build(albums, photostream, records, range, linked)
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
	local renderSettings = PhotoRenderer.copySettings(service:getPublishSettings()) or {}
	local function linksFor(matches)
		local out = {}
		for _, m in ipairs(matches) do
			local photo = photoByKey[m.key]
			out[#out + 1] = {
				photo = photo,
				id = m.id,
				url = PhotoFields.photoUrl(nsid, m.id),
				fingerprints = {
					image = Fingerprint.image(CatalogState.developSettings(photo), renderSettings),
					metadata = Fingerprint.metadata(PhotoFields.metadataFields(CatalogState.photoMeta(photo))),
				},
			}
		end
		return out
	end

	local apply = LrProgressScope({ title = "Flickr: linking albums", functionContext = context })
	local existing = CatalogState.collectionsByRemoteId()
	local linkedAlbums, linkedPhotos = 0, 0

	-- Phase 1: create year sets and collections (new objects are usable after the gate).
	local targets = {}
	catalog:withWriteAccessDo("Flickr: create album collections", function()
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
			CatalogState.linkPublished(
				t.collection,
				links,
				{ id = t.plan.album.id, url = AlbumSync.url(nsid, t.plan.album.id) }
			)
			linkedAlbums = linkedAlbums + 1
			linkedPhotos = linkedPhotos + #links
			log:info(string.format("import: album %s (%s): linked %d", t.plan.album.title, t.plan.album.id, #links))
		end
	end

	if selected.photostream and #plan.photostream.matches > 0 then
		local photostreamCollection = CatalogState.defaultCollection(service)
		if photostreamCollection then
			apply:setCaption("Linking photostream photos…")
			local links = linksFor(plan.photostream.matches)
			CatalogState.linkPublished(photostreamCollection, links)
			linkedPhotos = linkedPhotos + #links
			log:info(string.format("import: photostream: linked %d", #links))
		else
			log:error("import: no default (Photostream) collection found")
		end
	end
	apply:done()

	local queue = ReviewQueue.new(JsonFile.storage("review-" .. JsonFile.catalogKey() .. ".json"))
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
		"Flickr: albums linked",
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

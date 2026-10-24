--[[
File > Plug-in Extras > "Album Sync: Review unclear matches…"

Works through the review queue of this catalog (read-only on Flickr). Each item first gets
an EXIF tie-break; otherwise a dialog shows the Flickr photo next to the candidate catalog
photos (with notes on virtual copies and identical files): link one, mark "not in this
catalog" (removed from the queue), decide later, or stop and put the candidates of all queued
items into the collection "Album Sync: review candidates" (this item's are selected).
Linked photos go into the collections of the photo's albums, else into "Photostream".
]]

local LrApplication = import("LrApplication")
local LrBinding = import("LrBinding")
local LrDialogs = import("LrDialogs")
local LrFileUtils = import("LrFileUtils")
local LrFunctionContext = import("LrFunctionContext")
local LrHttp = import("LrHttp")
local LrLogger = import("LrLogger")
local LrPathUtils = import("LrPathUtils")
local LrProgressScope = import("LrProgressScope")
local LrShell = import("LrShell")
local LrTasks = import("LrTasks")
local LrView = import("LrView")

local AccountGuard = require("AccountGuard")
local AlbumSync = require("AlbumSync")
local AppDeps = require("AppDeps")
local CatalogState = require("CatalogState")
local CredentialStore = require("CredentialStore")
local FlickrApi = require("FlickrApi")
local FlickrResponse = require("FlickrResponse")
local JsonFile = require("JsonFile")
local DuplicateCheck = require("DuplicateCheck")
local Linker = require("Linker")
local Matcher = require("Matcher")
local PhotoFields = require("PhotoFields")
local RateLimiter = require("RateLimiter")
local ReviewQueue = require("ReviewQueue")
local UiText = require("UiText")

local log = LrLogger("album-sync")
log:enable("logfile")

local function fatal(message)
	log:error("review: " .. message)
	LrDialogs.message("Album Sync: review unclear matches", message, "critical")
end

-- Notes on how the candidates relate (virtual copies, shared or identical original files).
local function candidateNotes(candidates)
	local infos = {}
	for i, c in ipairs(candidates) do
		infos[i] = {
			path = c.photo:getRawMetadata("path"),
			size = c.photo:getRawMetadata("fileSize"),
			virtual = c.photo:getRawMetadata("isVirtualCopy"),
			copyName = c.photo:getFormattedMetadata("copyName"),
		}
		c.path = infos[i].path
	end
	local cache = {}
	return DuplicateCheck.describe(infos, function(i, j)
		local key = math.min(i, j) .. "-" .. math.max(i, j)
		if cache[key] == nil then
			local a, b = io.open(infos[i].path, "rb"), io.open(infos[j].path, "rb")
			cache[key] = a and b and DuplicateCheck.sameContent(a, b) or false
			if a then
				a:close()
			end
			if b then
				b:close()
			end
		end
		return cache[key]
	end)
end

-- Download a small preview of the Flickr photo into `dir`; returns the file path or nil.
local function preview(api, flickrId, dir)
	local url = api:previewUrl(flickrId)
	if not url then
		return nil
	end
	local body, headers = LrHttp.get(url, nil, 30)
	if not body or not headers or headers.status ~= 200 then
		log:error("review: preview download failed for " .. flickrId)
		return nil
	end
	local path = LrPathUtils.child(dir, flickrId .. ".jpg")
	local f = io.open(path, "wb")
	if not f then
		return nil
	end
	f:write(body)
	f:close()
	return path
end

local function ask(context, item, index, total, candidates, previewPath, nsid)
	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(context)
	props.choice = "later"
	-- Keyboard: type a candidate's number (or l, x, s) into the focused field, then Return.
	local keys = { l = "later", x = "dismiss", s = "show" }
	for n, c in ipairs(candidates) do
		if not c.linkedTo then
			keys[tostring(n)] = c.key
		end
	end
	props:addObserver("typed", function(_, _, value)
		local choice = keys[string.lower(string.match(value or "", "(%S)%s*$") or "")]
		if choice then
			props.choice = choice
		end
	end)
	local flickrUrl = PhotoFields.photoUrl(nsid, item.id)

	local left = {
		spacing = f:control_spacing(),
		previewPath and f:picture({ value = previewPath, width = 320, height = 320 })
			or f:static_text({ title = "(no preview)" }),
		f:static_text({ title = "On Flickr: " .. tostring(item.title or item.id) }),
		f:static_text({ title = "Taken: " .. tostring(item.taken or "?") }),
		f:static_text({ title = "Album: " .. tostring(item.album or "(none)") }),
		UiText.wrapped(f, "Why unclear: " .. tostring(item.reason), 45),
		f:push_button({
			title = "Open on Flickr",
			action = function()
				LrHttp.openUrlInBrowser(flickrUrl)
			end,
		}),
	}
	local right = {
		spacing = f:control_spacing(),
		f:row({
			f:static_text({ title = "Key:" }),
			f:edit_field({ value = LrView.bind("typed"), immediate = true, width_in_chars = 3 }),
			f:static_text({ title = "number, l = later, x = not in catalog, s = show; then Return" }),
		}),
	}
	for n, c in ipairs(candidates) do
		local label = n .. ". " .. c.name
		local choose = c.linkedTo
				and UiText.wrapped(f, label .. " (already linked to Flickr photo " .. c.linkedTo .. ")", 40)
			or f:radio_button({ title = label, value = LrView.bind("choice"), checked_value = c.key })
		local info = { choose, f:static_text({ title = "Taken: " .. tostring(c.taken) }) }
		if c.note ~= "" then
			info[#info + 1] = UiText.wrapped(f, c.note, 40)
		end
		if c.path then
			info[#info + 1] = UiText.wrapped(f, c.path, 40)
			info[#info + 1] = f:push_button({
				title = "Show in Finder",
				action = function()
					LrShell.revealInShell(c.path)
				end,
			})
		end
		right[#right + 1] = f:row({ f:catalog_photo({ photo = c.photo, width = 160, height = 160 }), f:column(info) })
	end
	right[#right + 1] = f:radio_button({
		title = "Not in this catalog (remove from the list) [x]",
		value = LrView.bind("choice"),
		checked_value = "dismiss",
	})
	right[#right + 1] =
		f:radio_button({ title = "Decide later [l]", value = LrView.bind("choice"), checked_value = "later" })
	right[#right + 1] = f:radio_button({
		title = "Stop; collect all candidates in the Library, select these [s]",
		value = LrView.bind("choice"),
		checked_value = "show",
	})

	local result = LrDialogs.presentModalDialog({
		title = string.format("Album Sync: unclear match %d of %d", index, total),
		actionVerb = "Apply",
		cancelVerb = "Stop reviewing",
		contents = f:row({ bind_to_object = props, spacing = f:dialog_spacing(), f:column(left), f:column(right) }),
	})
	if result ~= "ok" then
		return nil
	end
	return props.choice
end

LrFunctionContext.postAsyncTaskWithContext("Album Sync: review unclear matches", function(context)
	LrDialogs.attachErrorDialogToFunctionContext(context)
	local deps = AppDeps()
	deps.limiter = RateLimiter.new(deps)

	local nsid, e = AccountGuard.catalogAccount(CatalogState.lockedAccounts())
	if not nsid then
		return fatal(e.message)
	end
	local creds = CredentialStore.account(nsid)
	local user
	user, e = AccountGuard.verify(deps, creds, nsid, "read")
	if not user then
		return fatal(FlickrResponse.describe(e))
	end
	local api = FlickrApi.new(deps, creds, { token = creds.token, tokenSecret = creds.tokenSecret })
	local service = CatalogState.publishService()

	-- Repair stale Flickr ID fields first, also when there is nothing to review.
	local reading = LrProgressScope({ title = "Album Sync: reading catalog…", functionContext = context })
	local publishedLinks = CatalogState.publishedLinks()
	local okOthers, others = LrTasks.pcall(CatalogState.foreignPublished)
	if not okOthers then
		log:error("review: reading other publish services failed: " .. tostring(others))
		others = {}
	end
	for _, other in ipairs(others) do
		local sample = other.links[1]
		log:info(
			string.format(
				"review: other publish service %q (%s): %d collections, %d photos, %d with remote id%s",
				other.name,
				tostring(other.pluginId),
				other.collections,
				other.photos,
				#other.links,
				sample and string.format(", e.g. %s -> %s", sample.id, tostring(sample.url)) or ""
			)
		)
	end
	for _, ch in ipairs(CatalogState.repairFlickrIds(publishedLinks)) do
		log:info(
			string.format(
				"review: repaired Flickr ID of %s: %s -> %s",
				tostring(ch.photo:getRawMetadata("uuid")),
				tostring(ch.from),
				ch.to
			)
		)
	end
	local queue = ReviewQueue.new(JsonFile.storage("review-" .. JsonFile.catalogKey() .. ".json"))
	local items = {}
	for i, item in ipairs(queue:items()) do
		items[i] = item
	end
	if #items == 0 then
		reading:done()
		LrDialogs.message("Album Sync: nothing to review", "There are no unclear matches for this catalog.", "info")
		return
	end

	local records, photoByKey, linked, linkedIds = CatalogState.matcherRecords(publishedLinks)
	reading:done()
	local recordByKey = {}
	for _, r in ipairs(records) do
		recordByKey[r.key] = r
	end
	local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"), "album-sync-review")
	LrFileUtils.createAllDirectories(dir)

	local linkedCount, dismissed, auto, settled, duplicates = 0, 0, 0, 0, {}
	local linkedFlickr = linkedIds -- every Flickr id linked anywhere in this catalog
	local function link(item, key, how)
		local albums = AlbumSync.albumsOf(api, item.id) or {}
		local where, conflicts = Linker.linkOne(service, nsid, photoByKey[key], item.id, albums)
		for _, c in ipairs(conflicts) do
			local holderName = c.holder:getFormattedMetadata("fileName")
			local msg = string.format(
				"Flickr photo %s is already linked to %s (%s) in “%s”; not linked again.",
				item.id,
				tostring(holderName),
				tostring(c.holder:getRawMetadata("uuid")),
				c.collection:getName()
			)
			log:error("review: " .. msg)
			LrDialogs.message("Album Sync: already linked", msg, "warning")
		end
		if where == "" then
			return false
		end
		linked[key] = item.id -- never offer this photo again in this session
		linkedFlickr[tostring(item.id)] = true
		queue:remove(item.id)
		linkedCount = linkedCount + 1
		log:info(string.format("review: linked flickr=%s to %s (%s) in %s", item.id, key, how, where))
		return true
	end

	-- Pre-pass: Flickr photos another publish service (Lightroom's own Flickr service) recorded
	-- as uploaded from a specific catalog photo. Flickr ids are global, so this is exact.
	local recorded = {}
	for _, other in ipairs(others) do
		for _, l in ipairs(other.links) do
			if tostring(l.url or ""):find("flickr.com", 1, true) then
				recorded[l.id] = recorded[l.id] or l
			end
		end
	end
	-- Consistency check of earlier links against that record (log only).
	local agree, disagree = 0, 0
	for _, pl in ipairs(publishedLinks) do
		local l = recorded[pl.id]
		if l and l.key == pl.key then
			agree = agree + 1
		elseif l then
			disagree = disagree + 1
			log:info(
				string.format(
					"review: flickr=%s is linked to %s but was published from %s (%s)",
					pl.id,
					pl.key,
					l.key,
					tostring(l.photo:getFormattedMetadata("fileName"))
				)
			)
		end
	end
	log:info(string.format("review: links vs. publish service record: %d agree, %d differ", agree, disagree))
	local byService = 0
	for _, item in ipairs(items) do
		local l = recorded[tostring(item.id)]
		if l and not linkedFlickr[tostring(item.id)] then
			if linked[l.key] then
				-- Published twice from the same photo (e.g. into two collections): a duplicate
				-- upload when the files match in size, else a different version (stays queued).
				local keep = tostring(linked[l.key])
				local a, b = api:originalSize(keep), api:originalSize(item.id)
				local same = a and b and DuplicateCheck.sameImage(a, b)
				log:info(
					string.format(
						"review: flickr=%s was published from %s, which is linked to flickr=%s already (%s vs %s bytes%s)",
						item.id,
						l.key,
						keep,
						tostring(a),
						tostring(b),
						same and ": duplicate upload" or ""
					)
				)
				if same then
					queue:remove(item.id)
					duplicates[#duplicates + 1] = { keep = keep, duplicate = tostring(item.id), bytes = b }
				end
			else
				photoByKey[l.key] = photoByKey[l.key] or l.photo
				if link(item, l.key, "recorded by publish service") then
					byService = byService + 1
				end
			end
		end
	end
	auto = auto + byService
	items = {}
	for i, item in ipairs(queue:items()) do
		items[i] = item
	end

	-- Pre-pass: several Flickr copies of one catalog photo with identical file sizes are the same
	-- file uploaded more than once. Keep the oldest copy (or the one linked already), list the rest.
	local groups = DuplicateCheck.groups(items, linked)
	if #groups > 0 then
		local scope = LrProgressScope({
			title = string.format("Album Sync: comparing file sizes of %d duplicate group(s)", #groups),
			functionContext = context,
		})
		for gi, g in ipairs(groups) do
			scope:setPortionComplete(gi - 1, #groups)
			if scope:isCanceled() then
				break
			end
			local sizes = {}
			for _, id in ipairs(g.ids) do
				sizes[id] = api:originalSize(id)
			end
			local decision, why = DuplicateCheck.decide(g.ids, sizes)
			if decision and g.linkedId then
				-- keep the copy the import linked; every other copy is a duplicate of it
				decision.duplicates = {}
				for _, id in ipairs(g.ids) do
					if id ~= g.linkedId then
						decision.duplicates[#decision.duplicates + 1] = id
					end
				end
				decision.primary = g.linkedId
			end
			if decision then
				local ok = true
				if not g.linkedId then
					local albums = AlbumSync.albumsOf(api, decision.primary) or {}
					local where = Linker.linkOne(service, nsid, photoByKey[g.key], decision.primary, albums)
					ok = where ~= ""
					if ok then
						linked[g.key] = decision.primary
						linkedFlickr[decision.primary] = true
						linkedCount = linkedCount + 1
					end
				end
				if ok then
					for _, id in ipairs(g.queued) do
						queue:remove(id)
					end
					for _, id in ipairs(decision.duplicates) do
						duplicates[#duplicates + 1] =
							{ keep = decision.primary, duplicate = id, bytes = decision.bytes }
					end
					log:info(
						string.format(
							"review: identical copies (%d bytes) of %s: kept %s, duplicates %s",
							decision.bytes,
							g.key,
							decision.primary,
							table.concat(decision.duplicates, ",")
						)
					)
				end
			else
				log:info(string.format("review: copies of %s stay for review: %s", g.key, tostring(why)))
			end
		end
		scope:done()
		items = {}
		for i, item in ipairs(queue:items()) do
			items[i] = item
		end
	end

	for i, item in ipairs(items) do
		local candidates = {}
		for _, key in ipairs(item.candidates or {}) do
			local r, photo = recordByKey[key], photoByKey[key]
			if r and photo then
				candidates[#candidates + 1] = {
					key = key,
					photo = photo,
					record = r,
					name = r.names[1] or key,
					taken = r.taken,
					linkedTo = linked[key],
				}
			end
		end
		local states = {}
		for _, c in ipairs(candidates) do
			states[#states + 1] = c.key .. "=" .. tostring(c.linkedTo)
		end
		log:info(
			string.format(
				"review: item flickr=%s linkedSomewhere=%s candidates %s",
				item.id,
				tostring(linkedFlickr[tostring(item.id)] == true),
				table.concat(states, " ")
			)
		)
		if linkedFlickr[tostring(item.id)] then
			queue:remove(item.id) -- linked meanwhile (earlier review, import or publish)
			settled = settled + 1
			log:info("review: flickr=" .. item.id .. " is already linked; removed from the queue")
		elseif #candidates == 0 then
			queue:remove(item.id) -- candidates no longer in the catalog
			log:info("review: dropped flickr=" .. item.id .. " (no candidates left)")
		else
			local resolved, how
			local exif = api:exif(item.id)
			if exif then
				local recs = {}
				for _, c in ipairs(candidates) do
					if not c.linkedTo then
						recs[#recs + 1] = c.record
					end
				end
				if #recs > 0 then
					resolved, how = Matcher.resolveByExif(exif, recs)
				end
			end
			if resolved then
				if link(item, resolved, how) then
					auto = auto + 1
				end
			else
				for n, note in ipairs(candidateNotes(candidates)) do
					candidates[n].note = note
				end
				local choice = ask(context, item, i, #items, candidates, preview(api, item.id, dir), nsid)
				if choice == nil then
					break
				elseif choice == "show" then
					local catalog = LrApplication.activeCatalog()
					local photos = {}
					for n, c in ipairs(candidates) do
						photos[n] = c.photo
					end
					-- Candidates of every queued item; this item's stay selected.
					local all, seen = {}, {}
					for _, queued in ipairs(queue:items()) do
						for _, key in ipairs(queued.candidates or {}) do
							local photo = photoByKey[key]
							if photo and not seen[key] then
								seen[key] = true
								all[#all + 1] = photo
							end
						end
					end
					-- A collection of its own: visible whatever source or filter was active.
					local collection
					catalog:withWriteAccessDo("Album Sync: review candidates", function()
						collection = catalog:createCollection("Album Sync: review candidates", nil, true)
						collection:removeAllPhotos()
						collection:addPhotos(all)
						collection:addPhotos(photos)
					end)
					catalog:setActiveSources({ collection })
					LrTasks.sleep(0.5) -- the grid switches asynchronously; select after it has
					catalog:setSelectedPhotos(photos[1], photos)
					log:info(
						string.format(
							"review: %d candidates in collection %q, selected the %d of flickr=%s",
							#collection:getPhotos(),
							collection:getName(),
							#photos,
							item.id,
							collection:getName()
						)
					)
					break
				elseif choice == "dismiss" then
					queue:remove(item.id)
					dismissed = dismissed + 1
					log:info("review: dismissed flickr=" .. item.id)
				elseif choice ~= "later" then
					link(item, choice, "user")
				end
			end
		end
	end
	LrFileUtils.delete(dir)

	-- Duplicate uploads found by size: a list to clean up on Flickr (nothing is deleted here).
	local listNote = ""
	if #duplicates > 0 then
		local lines =
			{ "Duplicate uploads on Flickr (identical file to the kept photo). Delete them on Flickr if you like:" }
		for _, d in ipairs(duplicates) do
			lines[#lines + 1] = string.format(
				"duplicate %s   (keep %s, %d bytes)",
				PhotoFields.photoUrl(nsid, d.duplicate),
				PhotoFields.photoUrl(nsid, d.keep),
				d.bytes
			)
		end
		local path = JsonFile.path("duplicates-" .. JsonFile.catalogKey() .. ".txt")
		local f = io.open(path, "w")
		if f then
			f:write(table.concat(lines, "\n"), "\n")
			f:close()
			listNote = string.format("\n\n%d duplicate upload(s) on Flickr are listed in:\n%s", #duplicates, path)
		end
	end

	LrDialogs.message(
		"Album Sync: review",
		string.format(
			"Linked %d photo(s) (%d automatically), removed %d, %d were already linked. %d left for later.%s",
			linkedCount,
			auto,
			dismissed,
			settled,
			#queue:items(),
			listNote
		),
		"info"
	)
end)

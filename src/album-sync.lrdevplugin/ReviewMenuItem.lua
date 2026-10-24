--[[
File > Plug-in Extras > "Album Sync: Review unclear matches…"

Works through the review queue of this catalog (read-only on Flickr). Each item first gets
an EXIF tie-break; otherwise a dialog shows the Flickr photo next to the candidate catalog
photos: link one, mark "not in this catalog" (removed from the queue), or decide later.
Linked photos go into the collections of the photo's albums, else into "Photostream".
]]

local LrBinding = import("LrBinding")
local LrDialogs = import("LrDialogs")
local LrFileUtils = import("LrFileUtils")
local LrFunctionContext = import("LrFunctionContext")
local LrHttp = import("LrHttp")
local LrLogger = import("LrLogger")
local LrPathUtils = import("LrPathUtils")
local LrView = import("LrView")

local AccountGuard = require("AccountGuard")
local AlbumSync = require("AlbumSync")
local AppDeps = require("AppDeps")
local CatalogState = require("CatalogState")
local CredentialStore = require("CredentialStore")
local FlickrApi = require("FlickrApi")
local FlickrResponse = require("FlickrResponse")
local JsonFile = require("JsonFile")
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
	local right = { spacing = f:control_spacing() }
	for _, c in ipairs(candidates) do
		local choose = c.linkedTo
				and UiText.wrapped(f, c.name .. " (already linked to Flickr photo " .. c.linkedTo .. ")", 40)
			or f:radio_button({ title = "This one: " .. c.name, value = LrView.bind("choice"), checked_value = c.key })
		right[#right + 1] = f:row({
			f:catalog_photo({ photo = c.photo, width = 160, height = 160 }),
			f:column({ choose, f:static_text({ title = "Taken: " .. tostring(c.taken) }) }),
		})
	end
	right[#right + 1] = f:radio_button({
		title = "Not in this catalog (remove from the list)",
		value = LrView.bind("choice"),
		checked_value = "dismiss",
	})
	right[#right + 1] =
		f:radio_button({ title = "Decide later", value = LrView.bind("choice"), checked_value = "later" })

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
	for _, ch in ipairs(CatalogState.repairFlickrIds()) do
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
		LrDialogs.message("Album Sync: nothing to review", "There are no unclear matches for this catalog.", "info")
		return
	end

	local records, photoByKey, linked, linkedIds = CatalogState.matcherRecords()
	local recordByKey = {}
	for _, r in ipairs(records) do
		recordByKey[r.key] = r
	end
	local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"), "album-sync-review")
	LrFileUtils.createAllDirectories(dir)

	local linkedCount, dismissed, auto, settled = 0, 0, 0, 0
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
				local choice = ask(context, item, i, #items, candidates, preview(api, item.id, dir), nsid)
				if choice == nil then
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

	LrDialogs.message(
		"Album Sync: review",
		string.format(
			"Linked %d photo(s) (%d automatically by EXIF), removed %d, %d were already linked. %d left for later.",
			linkedCount,
			auto,
			dismissed,
			settled,
			#queue:items()
		),
		"info"
	)
end)

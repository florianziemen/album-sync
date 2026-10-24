--[[
File > Plug-in Extras > "Flickr: Review unclear matches…"

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

local log = LrLogger("lrflickr")
log:enable("logfile")

local function fatal(message)
	log:error("review: " .. message)
	LrDialogs.message("Flickr: review unclear matches", message, "critical")
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
		f:static_text({ title = "Flickr: " .. tostring(item.title or item.id) }),
		f:static_text({ title = "Taken: " .. tostring(item.taken or "?") }),
		f:static_text({ title = "Album: " .. tostring(item.album or "(none)") }),
		f:static_text({ title = "Why unclear: " .. tostring(item.reason) }),
		f:push_button({
			title = "Open on Flickr",
			action = function()
				LrHttp.openUrlInBrowser(flickrUrl)
			end,
		}),
	}
	local right = { spacing = f:control_spacing() }
	for _, c in ipairs(candidates) do
		right[#right + 1] = f:row({
			f:catalog_photo({ photo = c.photo, width = 160, height = 160 }),
			f:column({
				f:radio_button({ title = "This one: " .. c.name, value = LrView.bind("choice"), checked_value = c.key }),
				f:static_text({ title = "Taken: " .. tostring(c.taken) }),
			}),
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
		title = string.format("Flickr: unclear match %d of %d", index, total),
		actionVerb = "Apply",
		cancelVerb = "Stop reviewing",
		contents = f:row({ bind_to_object = props, spacing = f:dialog_spacing(), f:column(left), f:column(right) }),
	})
	if result ~= "ok" then
		return nil
	end
	return props.choice
end

LrFunctionContext.postAsyncTaskWithContext("Flickr: review unclear matches", function(context)
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

	local queue = ReviewQueue.new(JsonFile.storage("review-" .. JsonFile.catalogKey() .. ".json"))
	local items = {}
	for i, item in ipairs(queue:items()) do
		items[i] = item
	end
	if #items == 0 then
		LrDialogs.message("Flickr: nothing to review", "There are no unclear matches for this catalog.", "info")
		return
	end

	local records, photoByKey = CatalogState.matcherRecords()
	local recordByKey = {}
	for _, r in ipairs(records) do
		recordByKey[r.key] = r
	end
	local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"), "lrflickr-review")
	LrFileUtils.createAllDirectories(dir)

	local linked, dismissed, auto = 0, 0, 0
	local function link(item, key, how)
		local albums = AlbumSync.albumsOf(api, item.id) or {}
		local where = Linker.linkOne(service, nsid, photoByKey[key], item.id, albums)
		queue:remove(item.id)
		linked = linked + 1
		log:info(string.format("review: linked flickr=%s to %s (%s) in %s", item.id, key, how, where))
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
				}
			end
		end
		if #candidates == 0 then
			queue:remove(item.id) -- candidates no longer in the catalog
			log:info("review: dropped flickr=" .. item.id .. " (no candidates left)")
		else
			local resolved, how
			local exif = api:exif(item.id)
			if exif then
				local recs = {}
				for j, c in ipairs(candidates) do
					recs[j] = c.record
				end
				resolved, how = Matcher.resolveByExif(exif, recs)
			end
			if resolved then
				auto = auto + 1
				link(item, resolved, how)
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
		"Flickr: review",
		string.format(
			"Linked %d photo(s) (%d automatically by EXIF), removed %d. %d left for later.",
			linked,
			auto,
			dismissed,
			#queue:items()
		),
		"info"
	)
end)

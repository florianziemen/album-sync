--[[
Flickr publish service.

- Account lock: publishing is refused unless the stored token belongs to the locked account.
- Per photo, PublishPlanner decides: upload / relink / replace / metadata / adopt / noop.
  Lightroom renders nothing; photos that need pixels are rendered just in time (RenderQueue).
- Flickr ID and fingerprints are stored in plugin fields right after each successful call.
- Each published collection (except the default "Photostream") is a Flickr album, created
  lazily with the first photo as cover. Collection sets are a Lightroom-only grouping.
- New photos are uploaded private and hidden from search. Nothing is deleted on Flickr except
  on the explicit "Re-upload, delete the old photo" choice; deleting a collection keeps the album.
]]

local LrBinding = import("LrBinding")
local LrDate = import("LrDate")
local LrDialogs = import("LrDialogs")
local LrErrors = import("LrErrors")
local LrFileUtils = import("LrFileUtils")
local LrLogger = import("LrLogger")
local LrProgressScope = import("LrProgressScope")
local LrTasks = import("LrTasks")
local LrView = import("LrView")

local AccountGuard = require("AccountGuard")
local AlbumSync = require("AlbumSync")
local AppDeps = require("AppDeps")
local CatalogState = require("CatalogState")
local CredentialStore = require("CredentialStore")
local FlickrApi = require("FlickrApi")
local FlickrResponse = require("FlickrResponse")
local Journal = require("Journal")
local JsonFile = require("JsonFile")
local Fingerprint = require("Fingerprint")
local PhotoFields = require("PhotoFields")
local PhotoRenderer = require("PhotoRenderer")
local Privacy = require("Privacy")
local RemoteState = require("RemoteState")
local json = require("json")
local JpegXmp = require("JpegXmp")
local PublishPlanner = require("PublishPlanner")
local RateLimiter = require("RateLimiter")
local RenderQueue = require("RenderQueue")
local TaskPool = require("TaskPool")
local TicketPoller = require("TicketPoller")
local Uploader = require("Uploader")

local RENDER_AHEAD = 2

local log = LrLogger("flockr")
log:enable("logfile")

-- One structured log line per event: "PUBLISH t=... ev=... k=v ...".
local function event(name, fields)
	local parts = { string.format("PUBLISH t=%.3f ev=%s", LrDate.currentTime(), name) }
	local keys = {}
	for k in pairs(fields or {}) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		parts[#parts + 1] = k .. "=" .. tostring(fields[k])
	end
	log:info(table.concat(parts, " "))
end

local provider = {
	supportsIncrementalPublish = "only",
	canExportVideo = false,
	hideSections = { "exportLocation", "video" },
	allowFileFormats = { "JPEG" },
	allowColorSpaces = { "sRGB" },
	supportsCustomSortOrder = true,
	titleForPublishedCollection = "Album",
	titleForPublishedCollectionSet = "Album Set",
	exportPresetFields = {
		{ key = "lockedNsid", default = "" },
		{ key = "lockedUsername", default = "" },
		{ key = "dryRun", default = false },
		{ key = "parallelUploads", default = 3 },
		{ key = "privacy", default = "private" },
		{ key = "hideFromSearch", default = true },
		{ key = "sendLocation", default = false },
		{ key = "faultMode", default = "none" },
	},
}

function provider.getCollectionBehaviorInfo()
	return {
		defaultCollectionName = "Photostream",
		defaultCollectionCanBeDeleted = false,
		canAddCollection = true,
	}
end

function provider.metadataThatTriggersRepublish()
	return {
		default = false,
		title = true,
		caption = true,
		keywords = true,
		gps = true,
		dateCreated = true,
		[_PLUGIN.id .. ".flickrPrivacy"] = true,
	}
end

local function privacyItems(withDefault)
	local items = {}
	if withDefault then
		items[1] = { title = "Service default", value = "default" }
	end
	for _, v in ipairs(Privacy.VALUES) do
		items[#items + 1] = { title = Privacy.TITLES[v], value = v }
	end
	return items
end

-- Per album: privacy and location override the service defaults (photo field wins over both).
function provider.viewForCollectionSettings(f, _, info)
	local settings = info.collectionSettings
	if settings.privacy == nil then
		settings.privacy = "default"
	end
	if settings.location == nil then
		settings.location = "default"
	end
	return f:group_box({
		title = "Flickr album settings",
		bind_to_object = settings,
		f:row({
			f:static_text({ title = "Privacy:", width = 90 }),
			f:popup_menu({ value = LrView.bind("privacy"), items = privacyItems(true) }),
		}),
		f:row({
			f:static_text({ title = "Location:", width = 90 }),
			f:popup_menu({
				value = LrView.bind("location"),
				items = {
					{ title = "Service default", value = "default" },
					{ title = "Send location", value = "on" },
					{ title = "Do not send location", value = "off" },
				},
			}),
		}),
		f:static_text({ title = "A photo's “Flickr privacy” field (Metadata panel) overrides these." }),
	})
end

-- Verified account + API client for the service's locked account. `need`: "read"|"write"|"delete".
-- Also enforces one Flickr account per catalog. Throws on failure.
local function connect(publishSettings, need, deps)
	deps = deps or AppDeps()
	local _, mixed = AccountGuard.catalogAccount(CatalogState.lockedAccounts())
	if mixed and mixed.reason == "several" then
		LrErrors.throwUserError("Flickr: " .. mixed.message)
	end
	local creds = CredentialStore.account(publishSettings.lockedNsid)
	local user, e = AccountGuard.verify(deps, creds, publishSettings.lockedNsid, need)
	if not user then
		LrErrors.throwUserError("Flickr: " .. FlickrResponse.describe(e))
	end
	return user, FlickrApi.new(deps, creds, { token = creds.token, tokenSecret = creds.tokenSecret }), creds
end

-- Removing photos from a collection removes them from its album only; they stay on Flickr.
-- The plugin field flickrId stays, so re-adding a photo relinks instead of uploading again.
function provider.deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback, localId)
	local albumId = CatalogState.collectionRemoteId(localId)
	if not albumId then
		for _, id in ipairs(arrayOfPhotoIds) do
			event("removeFromCollectionOnly", { id = id })
			deletedCallback(id)
		end
		return
	end
	local _, api = connect(publishSettings, "write")
	for _, id in ipairs(arrayOfPhotoIds) do
		local ok, e = AlbumSync.remove(api, albumId, id)
		event("removeFromAlbum", { album = albumId, id = id, err = e and e.message })
		if ok then
			deletedCallback(id)
		end
	end
end

function provider.validatePublishedCollectionName(name)
	if not name or name:match("^%s*$") then
		return false, "Album names cannot be empty."
	end
	return true
end

function provider.renamePublishedCollection(publishSettings, info)
	if info.isDefaultCollection or not info.remoteId or info.publishedCollection:type() ~= "LrPublishedCollection" then
		return
	end
	local _, api = connect(publishSettings, "write")
	local ok, e = AlbumSync.rename(api, info.remoteId, info.name)
	event("renameAlbum", { album = info.remoteId, err = e and e.message })
	if not ok then
		LrErrors.throwUserError("Flickr: could not rename the album: " .. FlickrResponse.describe(e))
	end
end

-- Deleting a collection (or set) never deletes albums or photos on Flickr. Our own question
-- replaces Lightroom's default one ("delete the photos from the service?"), which would be
-- misleading here. Returning "delete" proceeds without Lightroom's prompt.
function provider.shouldDeletePublishedCollection(_, info)
	if not info.hasItemsOnService then
		return nil
	end
	local names = {}
	for _, c in ipairs(info.collections or {}) do
		names[#names + 1] = "“" .. tostring(c:getName()) .. "”"
	end
	local answer = LrDialogs.confirm(
		string.format("Remove %s from Lightroom only?", table.concat(names, ", ")),
		"The Flickr album(s) and all their photos stay online. Delete them on the Flickr website "
			.. "if you no longer want them.",
		"Remove from Lightroom only",
		"Cancel"
	)
	event("shouldDeleteCollection", { names = table.concat(names, ","), answer = answer })
	return answer == "ok" and "delete" or "cancel"
end

function provider.deletePublishedCollection(_, info)
	event("deleteCollectionKeepAlbum", { album = info.remoteId, name = info.name })
end

function provider.imposeSortOrderOnPublishedCollection(publishSettings, info, remoteIdSequence)
	if info.isDefaultCollection or not info.remoteCollectionId then
		return
	end
	local _, api = connect(publishSettings, "write")
	local _, e = AlbumSync.reorder(api, info.remoteCollectionId, remoteIdSequence)
	event("reorderAlbum", { album = info.remoteCollectionId, n = #remoteIdSequence, err = e and e.message })
end

-- Pop-up items for the account lock: every logged-in account, plus the current lock even if
-- it is not (yet) in the list. Must not touch the keychain: dialogs are not tasks.
local function accountItems(current)
	local items = { { title = "(choose an account)", value = "" } }
	local ok, accounts = pcall(CredentialStore.accounts)
	if not ok then
		log:error("account list for dialog failed: " .. tostring(accounts))
		accounts = {}
	end
	local seen = false
	for _, a in ipairs(accounts) do
		seen = seen or a.nsid == current
		items[#items + 1] = { title = string.format("%s (%s, %s)", a.username, a.nsid, a.perms), value = a.nsid }
	end
	if current and current ~= "" and not seen then
		items[#items + 1] = { title = current, value = current }
	end
	return items
end

function provider.sectionsForTopOfDialog(f, propertyTable)
	local bind = LrView.bind
	propertyTable:addObserver("lockedNsid", function(props, _, nsid)
		local ok, accounts = pcall(CredentialStore.accounts)
		for _, a in ipairs(ok and accounts or {}) do
			if a.nsid == nsid then
				props.lockedUsername = a.username
			end
		end
	end)
	return {
		{
			title = "Flickr account",
			synopsis = bind({
				key = "lockedUsername",
				transform = function(v)
					return (v and v ~= "") and ("Locked to " .. v) or "Not locked"
				end,
			}),
			f:row({
				f:static_text({ title = "Locked to:", width = 90 }),
				f:popup_menu({
					value = bind("lockedNsid"),
					items = accountItems(propertyTable.lockedNsid),
					width_in_chars = 40,
				}),
			}),
			f:static_text({
				title = "Accounts are added with File > Plug-in Extras > Flickr: Log in. "
					.. "Use one Flickr account per catalog.",
			}),
		},
		{
			title = "Visibility",
			f:row({
				f:static_text({ title = "Default privacy:", width = 110 }),
				f:popup_menu({ value = bind("privacy"), items = privacyItems(false) }),
				f:checkbox({ title = "Hide from public searches", value = bind("hideFromSearch") }),
			}),
			f:row({
				f:checkbox({ title = "Send location (GPS) by default", value = bind("sendLocation") }),
			}),
			f:static_text({
				title = "Albums can override privacy and location (collection settings); "
					.. "photos can override privacy (Metadata panel, “Flickr privacy”).",
			}),
		},
		{
			title = "Upload",
			f:row({
				f:static_text({ title = "Parallel uploads:", width = 110 }),
				f:popup_menu({
					value = bind("parallelUploads"),
					items = {
						{ title = "1", value = 1 },
						{ title = "2", value = 2 },
						{ title = "3", value = 3 },
						{ title = "4", value = 4 },
					},
				}),
			}),
		},
		{
			title = "Development",
			f:row({
				f:checkbox({
					title = "Dry run: plan and render, but make no changes on Flickr or in the catalog",
					value = bind("dryRun"),
				}),
			}),
			f:row({
				f:static_text({ title = "Inject fault:", width = 110 }),
				f:popup_menu({
					value = bind("faultMode"),
					items = {
						{ title = "None", value = "none" },
						{ title = "Network error before sending (once)", value = "beforeSend" },
						{ title = "Response lost after upload (once)", value = "afterSend" },
						{ title = "Crash after upload, before saving (once)", value = "crashAfterUpload" },
					},
				}),
			}),
		},
	}
end

-- Pre-pass (does not start rendering): plan every rendition and skip all Lightroom renders.
local function planBatch(session, renderSettings, settings, collectionSettings)
	local entries = {}
	local ok, err = LrTasks.pcall(function()
		for _, r in session:renditions() do
			r:skipRender()
			entries[#entries + 1] = {
				photo = r.photo,
				publishedId = r.publishedPhotoId,
				uuid = CatalogState.uuid(r.photo),
			}
		end
		local photos = {}
		for i, entry in ipairs(entries) do
			photos[i] = entry.photo
		end
		local state = CatalogState.load(photos)
		local unknown = {}
		for _, entry in ipairs(entries) do
			if not state[entry.photo].flickrId and not entry.publishedId then
				unknown[#unknown + 1] = entry.photo
			end
		end
		local backfill = #unknown > 0 and CatalogState.remoteIdsFromCollections(unknown) or {}
		for _, entry in ipairs(entries) do
			local fields = state[entry.photo]
			if fields.copiedFrom then
				event("copiedFields", { photo = entry.photo.localIdentifier, masterFlickrId = fields.copiedFrom })
			end
			local backfilled = backfill[entry.photo.localIdentifier]
			if backfilled then
				fields.flickrId = backfilled
				event("backfill", { photo = entry.photo.localIdentifier, id = backfilled })
			end
			entry.copyName = CatalogState.photoMeta(entry.photo).copyName
			entry.locationOn = Privacy.locationEnabled(collectionSettings.location, settings.sendLocation == true)
			entry.fields = PhotoFields.metadataFields(CatalogState.photoMeta(entry.photo), {
				privacy = Privacy.resolve(fields.flickrPrivacy, collectionSettings.privacy, settings.privacy),
				location = entry.locationOn,
			})
			entry.norm = RemoteState.fromFields(entry.fields)
			if fields.metadataState then
				local okState, decoded = pcall(json.decode, fields.metadataState)
				entry.state = okState and decoded or nil
			end
			entry.current = {
				image = Fingerprint.image(CatalogState.developSettings(entry.photo), renderSettings),
				metadata = Fingerprint.metadata(entry.fields),
			}
			entry.flickrId = fields.flickrId
			entry.storedMetadata = fields.metadataFingerprint
			entry.action = PublishPlanner.plan({
				publishedId = entry.publishedId,
				flickrId = fields.flickrId,
				stored = { image = fields.imageFingerprint, metadata = fields.metadataFingerprint },
				current = entry.current,
			})
		end
	end)
	if not ok then
		log:error("planning failed: " .. tostring(err))
		LrErrors.throwUserError("Flickr: planning failed: " .. tostring(err))
	end
	return entries
end

-- Choices offered when images changed but the account cannot replace (no Pro).
local NON_PRO_CHOICES = {
	{
		value = "metadataOutdated",
		title = "Update metadata only",
		detail = "The old image stays on Flickr; the photos are marked as outdated.",
	},
	{
		value = "leaveModified",
		title = "Leave as modified",
		detail = "Nothing is sent; the photos stay in “Modified Photos to Re-Publish”.",
	},
	{
		value = "reuploadKeep",
		title = "Re-upload, keep the old photo",
		detail = "Uploads a new photo; the old one stays online so links keep working.",
	},
	{
		value = "reuploadDelete",
		title = "Re-upload, delete the old photo",
		detail = "Uploads a new photo, then deletes the old one (comments, faves and links are lost).",
	},
}

local function askNonPro(functionContext, count, allowDelete)
	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(functionContext)
	props.choice = NON_PRO_CHOICES[1].value
	local rows = {
		f:static_text({
			title = string.format("%d photo(s) have image changes, but replacing images needs Flickr Pro.", count),
		}),
	}
	for _, c in ipairs(NON_PRO_CHOICES) do
		if c.value == "reuploadDelete" and not allowDelete then
			rows[#rows + 1] =
				f:static_text({ title = "(Deleting the old photo needs a login with “delete” permission.)" })
			break
		end
		rows[#rows + 1] = f:radio_button({ title = c.title, value = LrView.bind("choice"), checked_value = c.value })
		rows[#rows + 1] = f:static_text({ title = "      " .. c.detail })
	end
	rows.bind_to_object = props
	rows.spacing = f:control_spacing()
	local result = LrDialogs.presentModalDialog({
		title = "Flickr: image changes without Pro",
		contents = f:column(rows),
		actionVerb = "Continue",
	})
	return result == "ok" and props.choice or "leaveModified"
end

-- Replace needs Pro. Without it, ask once for the whole batch.
local function resolveReplaces(functionContext, api, user, entries, counts, allowDelete)
	if not counts.replace then
		return
	end
	local pro, e = api:isPro(user.id)
	if pro == nil then
		LrErrors.throwUserError("Flickr: could not check Pro status: " .. FlickrResponse.describe(e))
	end
	event("proCheck", { pro = pro, replace = counts.replace })
	if pro then
		return
	end
	local choice = askNonPro(functionContext, counts.replace, allowDelete)
	event("nonProChoice", { choice = choice, n = counts.replace })
	for _, entry in ipairs(entries) do
		if entry.action == "replace" then
			entry.action = choice
		end
	end
end

local function renderQueue(entries, renderSettings, ahead)
	local toRender = {}
	for _, entry in ipairs(entries) do
		if PublishPlanner.RENDERS[entry.action] then
			toRender[#toRender + 1] = { photo = entry.photo, stripGps = not entry.locationOn }
		end
	end
	local folder = PhotoRenderer.makeFolder()
	local start, await = PhotoRenderer.renderer(renderSettings, folder)
	return RenderQueue.new(toRender, ahead or RENDER_AHEAD, start, await), folder
end

local GONE_MESSAGE = "This photo no longer exists on Flickr. Use File > Plug-in Extras > "
	.. "“Flickr: Check for photos deleted on Flickr…” to mark or unlink such photos."

-- Faults for testing recovery (Development section). Each fires once per run.
local function faultInjector(mode)
	if not mode or mode == "none" then
		return nil
	end
	local fired = false
	local function once()
		if fired then
			return false
		end
		fired = true
		return true
	end
	return {
		upload = function(stage)
			if mode == stage and once() then
				event("faultInjected", { mode = mode })
				local where = stage == "beforeSend" and "network error before sending" or "response lost after upload"
				return { class = "transient", message = "injected fault: " .. where, notSent = stage == "beforeSend" }
			end
		end,
		crash = function()
			if mode == "crashAfterUpload" and once() then
				event("faultInjected", { mode = mode })
				return true
			end
			return false
		end,
	}
end

-- Flickr side of one planned action. Uploads run in worker tasks; everything that touches the
-- catalog or the rendition happens later in finish(). Returns remoteId or nil, message.
-- For re-uploads, entry.oldId is set and album membership moves to the new photo.
local function execute(ctx, entry, path)
	local api = ctx.api
	local action = entry.action
	local remoteId = entry.publishedId or entry.flickrId
	local e

	if action == "upload" or action == "reuploadKeep" or action == "reuploadDelete" then
		local marked, markErr = PhotoRenderer.mark(path, { uuid = entry.uuid, copy = entry.copyName or "" })
		if not marked then
			log:error("marker not written for " .. tostring(entry.uuid) .. ": " .. tostring(markErr))
		end
		local oldId = remoteId
		remoteId, e = ctx.uploader:upload(
			entry.uuid,
			path,
			PhotoFields.uploadFields(entry.fields, { hidden = ctx.hideFromSearch }),
			{ fault = ctx.faults and ctx.faults.upload }
		)
		if remoteId and not ctx.markerChecked then
			-- Once per run: does Flickr return our XMP marker? (Needed for exact matching.)
			ctx.markerChecked = true
			local exif = api:exif(remoteId)
			local found = JpegXmp.fromExif(exif)
			local spaces, seen = {}, {}
			for key in pairs(exif or {}) do
				local space = key:match("^([^:]+):")
				if space and not seen[space] then
					seen[space] = true
					spaces[#spaces + 1] = space
				end
			end
			table.sort(spaces)
			event("markerCheck", {
				id = remoteId,
				uuid = found.uuid,
				copy = found.copy,
				ok = found.uuid == entry.uuid,
				namespaces = table.concat(spaces, ","),
			})
		end
		if remoteId and entry.fields.latitude then
			local _, geoErr = api:setLocation(remoteId, entry.fields.latitude, entry.fields.longitude)
			event("location", { id = remoteId, err = geoErr and geoErr.message })
		end
		if remoteId and oldId then
			entry.oldId = oldId
			local keep = action == "reuploadKeep"
			local albums, moveErr = AlbumSync.moveToNewPhoto(api, oldId, remoteId, keep)
			event("moveAlbums", {
				old = oldId,
				new = remoteId,
				albums = albums and table.concat(albums, ",") or nil,
				err = moveErr and moveErr.message,
			})
			if not keep then
				-- Only after the new upload succeeded. A failed delete leaves a duplicate, not a loss.
				local _, delErr = api:deletePhoto(oldId)
				event("deleteOld", { old = oldId, new = remoteId, err = delErr and delErr.message })
			end
		end
	elseif action == "replace" then
		local _, replaceErr = api:replace(path, remoteId)
		e = replaceErr
	end
	if e then
		if e.class == "pending" then
			return nil, e.message .. " It will be linked on the next publish."
		end
		return nil, FlickrResponse.describe(e)
	end

	-- Only the fields decided by syncMetadata (changed in Lightroom, or conflicts resolved for it).
	if entry.push and next(entry.push) then
		local _, metaErr = api:pushMetadata(remoteId, entry.fields, entry.push)
		if metaErr then
			if metaErr.code == 1 then -- setMeta/setTags: Photo not found
				entry.goneOnFlickr = true
				return nil, GONE_MESSAGE
			end
			return nil, FlickrResponse.describe(metaErr)
		end
	end
	return remoteId
end

-- Actions whose metadata must be compared with Flickr before pushing.
local SYNC_ACTIONS = { metadata = true, adopt = true, metadataOutdated = true }

local function needsSync(entry)
	if SYNC_ACTIONS[entry.action] then
		return true
	end
	return (entry.action == "relink" or entry.action == "replace") and entry.storedMetadata ~= entry.current.metadata
end

local CONFLICT_CHOICES = {
	{ value = "skip", title = "Skip these photos", detail = "Nothing is sent; they stay in “Modified”." },
	{ value = "lr", title = "Use Lightroom's values", detail = "Overwrites the changes made on Flickr." },
	{ value = "flickr", title = "Keep Flickr's values", detail = "Sends only the fields without conflict." },
}

local function askConflicts(functionContext, conflicted)
	local perField = {}
	for _, e in ipairs(conflicted) do
		for _, f in ipairs(RemoteState.names(e.conflicts)) do
			perField[f] = (perField[f] or 0) + 1
		end
	end
	local summary = {}
	for _, f in ipairs(RemoteState.FIELDS) do
		if perField[f] then
			summary[#summary + 1] = string.format("%s (%d)", f, perField[f])
		end
	end
	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(functionContext)
	props.choice = "skip"
	local rows = {
		f:static_text({
			title = string.format(
				"%d photo(s) were changed both in Lightroom and on Flickr since the last publish: %s.",
				#conflicted,
				table.concat(summary, ", ")
			),
		}),
	}
	for _, c in ipairs(CONFLICT_CHOICES) do
		rows[#rows + 1] = f:radio_button({ title = c.title, value = LrView.bind("choice"), checked_value = c.value })
		rows[#rows + 1] = f:static_text({ title = "      " .. c.detail })
	end
	rows[#rows + 1] = f:static_text({ title = "Details per photo are in the log (flockr.log)." })
	rows.bind_to_object = props
	rows.spacing = f:control_spacing()
	local result = LrDialogs.presentModalDialog({
		title = "Flickr: conflicting changes",
		contents = f:column(rows),
		actionVerb = "Continue",
	})
	return result == "ok" and props.choice or "skip"
end

--[[
Compare Lightroom and Flickr per field for every photo whose metadata changed (docs/DESIGN.md
§3 "Conflicts"). Reads Flickr's current values (album listing: 500 per call; else getInfo),
then sets entry.push (fields to send), entry.remote and entry.flickrOnly; asks once for all
conflicts. Returns the number of photos with Flickr-only changes (kept).
]]
local function syncMetadata(functionContext, api, entries, album)
	local todo = {}
	for _, entry in ipairs(entries) do
		if needsSync(entry) then
			todo[#todo + 1] = entry
		end
	end
	if #todo == 0 then
		return 0
	end
	local listed = {}
	if album and album.id and #todo >= 3 then
		listed = api:albumPhotoStates(album.id) or {}
	end
	local conflicted, flickrOnly = {}, 0
	for _, entry in ipairs(todo) do
		local id = tostring(entry.publishedId or entry.flickrId)
		local remote
		if listed[id] then
			remote = RemoteState.fromListEntry(listed[id])
		else
			local info, err = api:photoInfo(id)
			if info then
				remote = RemoteState.fromInfo(info)
			elseif err and err.code == 1 then
				entry.goneOnFlickr = true
				entry.action = "gone"
			else
				entry.action = "syncFailed"
				entry.syncError = "could not read the photo's current values on Flickr: "
					.. FlickrResponse.describe(err)
			end
		end
		if remote then
			entry.remote = remote
			local managed =
				{ title = true, description = true, tags = true, privacy = true, location = entry.locationOn }
			local d = RemoteState.diff(entry.norm, entry.state, remote, managed)
			entry.push, entry.flickrOnly = d.push, d.flickrOnly
			if next(d.conflicts) then
				entry.conflicts = d.conflicts
				conflicted[#conflicted + 1] = entry
			end
			for _, f in ipairs(RemoteState.names(d.flickrOnly)) do
				log:info(
					string.format(
						"sync %s: %s changed on Flickr, kept (Flickr %q, Lightroom %q)",
						id,
						f,
						tostring(remote[f]),
						tostring(entry.norm[f])
					)
				)
			end
			if next(d.flickrOnly) then
				flickrOnly = flickrOnly + 1
			end
			event("sync", {
				id = id,
				push = table.concat(RemoteState.names(d.push), ","),
				conflicts = table.concat(RemoteState.names(d.conflicts), ","),
				flickrOnly = table.concat(RemoteState.names(d.flickrOnly), ","),
			})
		end
	end
	if #conflicted > 0 then
		for _, entry in ipairs(conflicted) do
			for _, f in ipairs(RemoteState.names(entry.conflicts)) do
				log:info(
					string.format(
						"conflict %s: %s Flickr %q, Lightroom %q",
						tostring(entry.publishedId or entry.flickrId),
						f,
						tostring(entry.remote[f]),
						tostring(entry.norm[f])
					)
				)
			end
		end
		local choice = askConflicts(functionContext, conflicted)
		event("conflictChoice", { choice = choice, n = #conflicted })
		for _, entry in ipairs(conflicted) do
			if choice == "lr" then
				for f in pairs(entry.conflicts) do
					entry.push[f] = true
				end
			elseif choice == "skip" then
				entry.action = "conflictSkipped"
			end
		end
	end
	return flickrOnly
end

-- Make sure a photo new to this collection is in its album. Re-uploads already took over the
-- old photo's albums. Returns true or nil, message.
local function ensureInAlbum(api, user, session, album, entry, remoteId)
	if not album or entry.publishedId then
		return true
	end
	local ok, e = AlbumSync.add(api, album, remoteId)
	if not ok then
		if e.code == 2 then -- addPhoto: Photo not found
			entry.goneOnFlickr = true
			return nil, GONE_MESSAGE
		end
		return nil, "could not add to album: " .. FlickrResponse.describe(e)
	end
	if album.created then
		session:recordRemoteCollectionId(album.id)
		session:recordRemoteCollectionUrl(AlbumSync.url(user.id, album.id))
		event("albumCreated", { album = album.id, title = album.title, recreatedFrom = album.recreatedFrom })
		album.created = nil
	end
	return true
end

-- Identifies a photo in log lines (no paths).
local function photoLabel(photo)
	local ok, name = LrTasks.pcall(function()
		return photo:getFormattedMetadata("fileName")
	end)
	return string.format("%s (localId=%s)", ok and tostring(name) or "?", tostring(photo.localIdentifier))
end

local function fail(rendition, entry, message)
	log:error(
		string.format(
			"photo failed: %s action=%s remoteId=%s: %s",
			photoLabel(rendition.photo),
			tostring(entry and entry.action),
			tostring(entry and (entry.publishedId or entry.flickrId)),
			tostring(message)
		)
	)
	if entry and entry.goneOnFlickr then
		CatalogState.save(rendition.photo, { flickrState = "deletedOnFlickr" })
	end
	rendition:uploadFailed(tostring(message))
end

-- Link photos whose upload finished (or was lost) in an earlier, interrupted run.
-- Returns sets of uuids that must not be uploaded again in this run: pending, ambiguous.
local function reconcileJournal(uploader, journal)
	local blocked = { pending = {}, ambiguous = {} }
	if #journal:openEntries() == 0 then
		return blocked
	end
	local r = uploader:reconcile()
	local linked = 0
	for uuid, photoId in pairs(r.linked) do
		local photo = CatalogState.photoByUuid(uuid)
		if photo then
			CatalogState.save(photo, { flickrId = photoId, flickrState = "published" })
		end
		journal:close(uuid)
		linked = linked + 1
		event("reconcileLinked", { uuid = uuid, id = photoId, inCatalog = photo ~= nil })
	end
	for _, uuid in ipairs(r.pending) do
		blocked.pending[uuid] = true
	end
	local ambiguous = 0
	for uuid, ids in pairs(r.ambiguous) do
		blocked.ambiguous[uuid] = ids
		ambiguous = ambiguous + 1
		log:error(
			string.format("journal: upload of %s is ambiguous, candidates on Flickr: %s", uuid, table.concat(ids, ","))
		)
	end
	event("reconcile", { linked = linked, pending = #r.pending, dropped = #r.dropped, ambiguous = ambiguous })
	return blocked
end

local function clampParallel(v)
	return math.max(1, math.min(4, math.floor(tonumber(v) or 3)))
end

function provider.processRenderedPhotos(functionContext, exportContext)
	functionContext:addFailureHandler(function(_, message)
		log:error("publish run aborted: " .. tostring(message))
	end)
	local settings = exportContext.propertyTable
	local session = exportContext.exportSession
	local deps = AppDeps()
	deps.limiter = RateLimiter.new(deps)
	local dryRun = settings.dryRun == true
	local user, api, creds = connect(settings, dryRun and "read" or "write", deps)

	local journal = Journal.new(JsonFile.storage("journal-" .. JsonFile.catalogKey() .. ".json"))
	if journal.corrupt then
		log:error("journal was unreadable and has been reset; contents: " .. tostring(journal.corrupt))
	end
	-- One ticket poll for all parallel uploads (saves API calls).
	local uploader = Uploader.new(deps, api, journal, TicketPoller.new(api, deps))
	local blocked = { pending = {}, ambiguous = {} }
	if not dryRun and #journal:openEntries() > 0 then
		local scope = LrProgressScope({
			title = string.format("Flickr: checking %d interrupted upload(s)…", #journal:openEntries()),
			functionContext = functionContext,
		})
		blocked = reconcileJournal(uploader, journal)
		scope:done()
	end

	local renderSettings = PhotoRenderer.copySettings(settings)
	if not renderSettings then
		LrErrors.throwUserError("Flickr: could not read export settings for rendering.")
	end

	local collectionSettings = {}
	local okInfo, summary = LrTasks.pcall(function()
		return exportContext.publishedCollection:getCollectionInfoSummary()
	end)
	if okInfo and type(summary) == "table" and type(summary.collectionSettings) == "table" then
		collectionSettings = summary.collectionSettings
	end

	local entries = planBatch(session, renderSettings, settings, collectionSettings)
	local actions, byPhoto = {}, {}
	for i, entry in ipairs(entries) do
		if entry.action == "upload" and blocked.pending[entry.uuid] then
			entry.action = "waitPending"
		elseif entry.action == "upload" and blocked.ambiguous[entry.uuid] then
			entry.action = "ambiguous"
			entry.candidates = blocked.ambiguous[entry.uuid]
		end
		actions[i] = entry.action
		byPhoto[entry.photo] = entry
	end
	local counts = PublishPlanner.summarize(actions)
	local parallel = clampParallel(settings.parallelUploads)
	event("plan", {
		n = #entries,
		dryRun = dryRun,
		parallel = parallel,
		fault = settings.faultMode,
		upload = counts.upload,
		relink = counts.relink,
		replace = counts.replace,
		metadata = counts.metadata,
		adopt = counts.adopt,
		noop = counts.noop,
		waitPending = counts.waitPending,
		ambiguous = counts.ambiguous,
	})
	resolveReplaces(functionContext, api, user, entries, counts, AccountGuard.permsAllow(creds.perms, "delete"))

	-- The album of this collection (nil for the default "Photostream" collection).
	local info = exportContext.publishedCollectionInfo or {}
	local album = (not info.isDefaultCollection) and { id = info.remoteId, title = info.name } or nil
	event("collection", { name = info.name, album = album and album.id, default = info.isDefaultCollection })

	local ctx = {
		api = api,
		uploader = uploader,
		journal = journal,
		user = user,
		session = session,
		album = album,
		faults = (not dryRun) and faultInjector(settings.faultMode) or nil,
		publishedCollection = exportContext.publishedCollection,
		hideFromSearch = settings.hideFromSearch ~= false,
	}
	local flickrOnly = syncMetadata(functionContext, api, entries, album)

	-- Lightroom side of a finished action; always on this (the publish) task.
	local function finish(rendition, entry, remoteId, err)
		if not remoteId then
			fail(rendition, entry, err)
			return
		end
		if entry.action == "upload" and ctx.faults and ctx.faults.crash() then
			error("injected fault: crash after upload, before saving (photo " .. tostring(remoteId) .. ")")
		end
		-- Persist first: if anything below fails, the next publish relinks instead of re-uploading.
		-- What Flickr has now, per field, for the next conflict check.
		local newState
		if entry.action == "upload" or entry.action == "reuploadKeep" or entry.action == "reuploadDelete" then
			newState = RemoteState.after(entry.norm, nil, {})
		elseif entry.remote then
			newState = RemoteState.after(entry.norm, entry.remote, entry.push or {})
		end
		CatalogState.save(rendition.photo, {
			flickrId = remoteId,
			flickrState = entry.action == "metadataOutdated" and "imageOutdated" or "published",
			imageFingerprint = entry.current.image,
			metadataFingerprint = entry.current.metadata,
			metadataState = newState and json.encode(newState) or nil,
		})
		journal:close(entry.uuid)
		local url = PhotoFields.photoUrl(user.id, remoteId)
		if entry.oldId then
			local n, retargetErr =
				CatalogState.retarget(rendition.photo, entry.oldId, remoteId, url, ctx.publishedCollection)
			event("retarget", { old = entry.oldId, new = remoteId, collections = n, err = retargetErr })
		end
		local inAlbum, albumErr = ensureInAlbum(api, user, session, album, entry, remoteId)
		if inAlbum then
			rendition:recordPublishedPhotoId(remoteId)
			rendition:recordPublishedPhotoUrl(url)
		else
			fail(rendition, entry, albumErr)
		end
	end

	local function removeFile(path)
		if path and LrFileUtils.exists(path) then
			LrFileUtils.delete(path)
		end
	end

	local pool = TaskPool.new(parallel, {
		spawn = function(fn)
			LrTasks.startAsyncTask(fn, "flockr upload")
		end,
		sleep = LrTasks.sleep,
		pcall = LrTasks.pcall,
	})
	local function finishResults(results)
		for _, r in ipairs(results) do
			if r.error then
				fail(r.context.rendition, r.context.entry, "upload task failed: " .. r.error)
				removeFile(r.context.path)
			else
				event(r.entry.action, { id = r.remoteId, err = r.err })
				finish(r.rendition, r.entry, r.remoteId, r.err)
				removeFile(r.path)
			end
		end
	end

	-- Render look-ahead covers all workers plus the next photo.
	local queue, folder = renderQueue(entries, renderSettings, parallel)
	exportContext:configureProgress({ title = string.format("Publishing %d photo(s) to Flickr", #entries) })

	for _, rendition in exportContext:renditions({ stopIfCanceled = true }) do
		rendition:waitForRender() -- returns immediately: all renditions were skipped
		local entry = byPhoto[rendition.photo]
		local path, ok, msg = nil, true, nil

		if PublishPlanner.RENDERS[entry.action] then
			local item
			item, ok, msg = queue:take()
			if not item or item.photo ~= rendition.photo then
				ok, msg = false, "render order mismatch"
			end
			path = ok and msg or nil
		end

		if not ok then
			fail(rendition, entry, "render failed: " .. tostring(msg))
		elseif entry.action == "leaveModified" then
			fail(rendition, entry, "Image changed; replacing needs Flickr Pro.")
		elseif entry.action == "gone" then
			fail(rendition, entry, GONE_MESSAGE)
		elseif entry.action == "syncFailed" then
			fail(rendition, entry, entry.syncError)
		elseif entry.action == "conflictSkipped" then
			fail(rendition, entry, "Changed both in Lightroom and on Flickr; skipped (see the log).")
		elseif entry.action == "waitPending" then
			fail(
				rendition,
				entry,
				"An earlier upload of this photo is still being processed by Flickr; publish again later."
			)
		elseif entry.action == "ambiguous" then
			fail(
				rendition,
				entry,
				"An earlier upload may have reached Flickr more than once (candidates: "
					.. table.concat(entry.candidates, ", ")
					.. "). Check on Flickr; see the log."
			)
		elseif dryRun then
			event("dryRun", { action = entry.action, id = entry.publishedId or entry.flickrId })
			removeFile(path)
		elseif PublishPlanner.RENDERS[entry.action] then
			local context = { rendition = rendition, entry = entry, path = path }
			pool:submit(context, function()
				local remoteId, err = execute(ctx, entry, path)
				return { rendition = rendition, entry = entry, path = path, remoteId = remoteId, err = err }
			end)
		else
			local remoteId, err = execute(ctx, entry, nil)
			event(entry.action, { id = remoteId, err = err })
			finish(rendition, entry, remoteId, err)
		end
		finishResults(pool:collect())
	end
	finishResults(pool:drain())
	LrFileUtils.delete(folder)
	event("end", { n = #entries, flickrOnly = flickrOnly })
	if flickrOnly > 0 then
		LrDialogs.message(
			"Flickr: changes made on Flickr were kept",
			string.format(
				"%d photo(s) have changes made on Flickr (title, description, tags, privacy or location) that "
					.. "Lightroom does not have. They were not overwritten. Details are in flockr.log.",
				flickrOnly
			),
			"info"
		)
	end
end

return provider

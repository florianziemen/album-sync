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
local LrTasks = import("LrTasks")
local LrView = import("LrView")

local AccountGuard = require("AccountGuard")
local AlbumSync = require("AlbumSync")
local AppDeps = require("AppDeps")
local CatalogState = require("CatalogState")
local CredentialStore = require("CredentialStore")
local FlickrApi = require("FlickrApi")
local FlickrAuth = require("FlickrAuth")
local FlickrResponse = require("FlickrResponse")
local Journal = require("Journal")
local JournalFile = require("JournalFile")
local Fingerprint = require("Fingerprint")
local PhotoFields = require("PhotoFields")
local PhotoRenderer = require("PhotoRenderer")
local PublishPlanner = require("PublishPlanner")
local RateLimiter = require("RateLimiter")
local RenderQueue = require("RenderQueue")
local TaskPool = require("TaskPool")
local Uploader = require("Uploader")

local RENDER_AHEAD = 2

local log = LrLogger("lrflickr")
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
	return { default = false, title = true, caption = true, keywords = true, gps = true, dateCreated = true }
end

-- Verified account + API client for hooks outside processRenderedPhotos. Throws on failure.
local function connect(publishSettings)
	local deps = AppDeps()
	local creds = CredentialStore.load()
	local user, e = AccountGuard.verify(deps, creds, publishSettings.lockedNsid)
	if not user then
		LrErrors.throwUserError("Flickr: " .. FlickrResponse.describe(e))
	end
	return user, FlickrApi.new(deps, creds, { token = creds.token, tokenSecret = creds.tokenSecret })
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
	local _, api = connect(publishSettings)
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
	local _, api = connect(publishSettings)
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
	local _, api = connect(publishSettings)
	local _, e = AlbumSync.reorder(api, info.remoteCollectionId, remoteIdSequence)
	event("reorderAlbum", { album = info.remoteCollectionId, n = #remoteIdSequence, err = e and e.message })
end

local function lockToCurrentLogin(propertyTable)
	LrTasks.startAsyncTask(function()
		local creds = CredentialStore.load()
		if not creds.token then
			propertyTable.lockStatus = "Not logged in. Use File > Plug-in Extras > Flickr: Log in."
			return
		end
		local user, e = FlickrAuth.new(AppDeps(), creds)
			:testLogin({ token = creds.token, tokenSecret = creds.tokenSecret })
		if not user then
			propertyTable.lockStatus = FlickrResponse.describe(e)
			return
		end
		propertyTable.lockedNsid = user.id
		propertyTable.lockedUsername = user.username
		propertyTable.lockStatus = "Locked."
	end)
end

function provider.sectionsForTopOfDialog(f, propertyTable)
	local bind = LrView.bind
	propertyTable.lockStatus = ""
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
				f:static_text({ title = bind("lockedUsername"), width_in_chars = 20 }),
				f:static_text({ title = bind("lockedNsid"), width_in_chars = 16 }),
			}),
			f:row({
				f:push_button({
					title = "Lock to logged-in account",
					action = function()
						lockToCurrentLogin(propertyTable)
					end,
				}),
				f:static_text({ title = bind("lockStatus"), fill_horizontal = 1 }),
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
local function planBatch(session, renderSettings)
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
			local backfilled = backfill[entry.photo.localIdentifier]
			if backfilled then
				fields.flickrId = backfilled
				event("backfill", { photo = entry.photo.localIdentifier, id = backfilled })
			end
			entry.fields = PhotoFields.metadataFields(CatalogState.photoMeta(entry.photo))
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

local function askNonPro(functionContext, count)
	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(functionContext)
	props.choice = NON_PRO_CHOICES[1].value
	local rows = {
		f:static_text({
			title = string.format("%d photo(s) have image changes, but replacing images needs Flickr Pro.", count),
		}),
	}
	for _, c in ipairs(NON_PRO_CHOICES) do
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
local function resolveReplaces(functionContext, api, user, entries, counts)
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
	local choice = askNonPro(functionContext, counts.replace)
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
			toRender[#toRender + 1] = entry.photo
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
				return { class = "transient", message = "injected fault: " .. where }
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
		local oldId = remoteId
		remoteId, e = ctx.uploader:upload(
			entry.uuid,
			path,
			PhotoFields.uploadFields(entry.fields),
			{ fault = ctx.faults and ctx.faults.upload }
		)
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

	local needsMeta = action == "metadata"
		or action == "adopt"
		or action == "metadataOutdated"
		or ((action == "replace" or action == "relink") and entry.storedMetadata ~= entry.current.metadata)
	if needsMeta then
		local _, metaErr = api:setMetadata(remoteId, entry.fields)
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
	local creds = CredentialStore.load()
	local dryRun = settings.dryRun == true

	local user, e = AccountGuard.verify(deps, creds, settings.lockedNsid)
	if not user then
		LrErrors.throwUserError("Flickr: " .. FlickrResponse.describe(e))
	end
	local api = FlickrApi.new(deps, creds, { token = creds.token, tokenSecret = creds.tokenSecret })

	local journal = Journal.new(JournalFile.storage())
	if journal.corrupt then
		log:error("journal was unreadable and has been reset; contents: " .. tostring(journal.corrupt))
	end
	local uploader = Uploader.new(deps, api, journal)
	local blocked = dryRun and { pending = {}, ambiguous = {} } or reconcileJournal(uploader, journal)

	local renderSettings = PhotoRenderer.copySettings(settings)
	if not renderSettings then
		LrErrors.throwUserError("Flickr: could not read export settings for rendering.")
	end

	local entries = planBatch(session, renderSettings)
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
	resolveReplaces(functionContext, api, user, entries, counts)

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
	}

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
		CatalogState.save(rendition.photo, {
			flickrId = remoteId,
			flickrState = entry.action == "metadataOutdated" and "imageOutdated" or "published",
			imageFingerprint = entry.current.image,
			metadataFingerprint = entry.current.metadata,
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
			LrTasks.startAsyncTask(fn, "lrflickr upload")
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
			local photo
			photo, ok, msg = queue:take()
			if photo ~= rendition.photo then
				ok, msg = false, "render order mismatch"
			end
			path = ok and msg or nil
		end

		if not ok then
			fail(rendition, entry, "render failed: " .. tostring(msg))
		elseif entry.action == "leaveModified" then
			fail(rendition, entry, "Image changed; replacing needs Flickr Pro.")
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
	event("end", { n = #entries })
end

return provider

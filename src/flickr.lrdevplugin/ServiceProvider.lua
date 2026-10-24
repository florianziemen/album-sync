--[[
Flickr publish service.

- Account lock: publishing is refused unless the stored token belongs to the locked account.
- Per photo, PublishPlanner decides: upload / relink / replace / metadata / adopt / noop.
  Lightroom renders nothing; photos that need pixels are rendered just in time (RenderQueue).
- Flickr ID and fingerprints are stored in plugin fields right after each successful call.
- New photos are uploaded private and hidden from search. Nothing is ever deleted on Flickr.
]]

local LrDate = import("LrDate")
local LrDialogs = import("LrDialogs")
local LrErrors = import("LrErrors")
local LrFileUtils = import("LrFileUtils")
local LrLogger = import("LrLogger")
local LrTasks = import("LrTasks")
local LrView = import("LrView")

local AccountGuard = require("AccountGuard")
local AppDeps = require("AppDeps")
local CatalogState = require("CatalogState")
local CredentialStore = require("CredentialStore")
local FlickrApi = require("FlickrApi")
local FlickrAuth = require("FlickrAuth")
local FlickrResponse = require("FlickrResponse")
local Fingerprint = require("Fingerprint")
local PhotoFields = require("PhotoFields")
local PhotoRenderer = require("PhotoRenderer")
local PublishPlanner = require("PublishPlanner")
local RenderQueue = require("RenderQueue")

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
	exportPresetFields = {
		{ key = "lockedNsid", default = "" },
		{ key = "lockedUsername", default = "" },
		{ key = "dryRun", default = false },
	},
}

function provider.getCollectionBehaviorInfo()
	return {
		defaultCollectionName = "Photostream",
		defaultCollectionCanBeDeleted = false,
		canAddCollection = false,
		maxCollectionSetDepth = 0,
	}
end

function provider.metadataThatTriggersRepublish()
	return { default = false, title = true, caption = true, keywords = true, gps = true, dateCreated = true }
end

-- Never delete on Flickr: only drop the photo from the published collection. The plugin
-- field flickrId stays, so re-adding the photo relinks instead of uploading a duplicate.
function provider.deletePhotosFromPublishedCollection(_, arrayOfPhotoIds, deletedCallback)
	for _, id in ipairs(arrayOfPhotoIds) do
		event("removeFromCollectionOnly", { id = id })
		deletedCallback(id)
	end
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
			title = "Development",
			f:row({
				f:checkbox({
					title = "Dry run: plan and render, but make no changes on Flickr or in the catalog",
					value = bind("dryRun"),
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
			entries[#entries + 1] = { photo = r.photo, publishedId = r.publishedPhotoId }
		end
		local photos = {}
		for i, entry in ipairs(entries) do
			photos[i] = entry.photo
		end
		local state = CatalogState.load(photos)
		for _, entry in ipairs(entries) do
			local fields = state[entry.photo]
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

-- Replace needs Pro. Without it, ask once for the whole batch.
local function resolveReplaces(api, user, entries, counts)
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
	local answer = LrDialogs.confirm(
		string.format("%d photo(s) have image changes, but replacing images needs Flickr Pro.", counts.replace),
		"Update metadata only: the old image stays on Flickr and the photos are marked as outdated.\n"
			.. "Leave as modified: nothing is sent for these photos; they stay in “Modified Photos to Re-Publish”.",
		"Update metadata only",
		"Leave as modified"
	)
	for _, entry in ipairs(entries) do
		if entry.action == "replace" then
			entry.action = (answer == "ok") and "metadataOutdated" or "leaveModified"
		end
	end
end

local function renderQueue(entries, renderSettings)
	local toRender = {}
	for _, entry in ipairs(entries) do
		if PublishPlanner.RENDERS[entry.action] then
			toRender[#toRender + 1] = entry.photo
		end
	end
	local folder = PhotoRenderer.makeFolder()
	local start, await = PhotoRenderer.renderer(renderSettings, folder)
	return RenderQueue.new(toRender, RENDER_AHEAD, start, await), folder
end

-- Executes one planned action. Returns remoteId on success, or nil, message.
local function execute(api, entry, path)
	local action = entry.action
	local remoteId = entry.publishedId or entry.flickrId
	local e

	if action == "upload" then
		remoteId, e = api:upload(path, PhotoFields.uploadFields(entry.fields))
	elseif action == "replace" then
		local _, replaceErr = api:replace(path, remoteId)
		e = replaceErr
	end
	if e then
		return nil, FlickrResponse.describe(e)
	end

	local needsMeta = action == "metadata"
		or action == "adopt"
		or action == "metadataOutdated"
		or ((action == "replace" or action == "relink") and entry.storedMetadata ~= entry.current.metadata)
	if needsMeta then
		local _, metaErr = api:call(
			"flickr.photos.setMeta",
			{ photo_id = remoteId, title = entry.fields.title, description = entry.fields.description },
			"POST"
		)
		if metaErr then
			return nil, FlickrResponse.describe(metaErr)
		end
	end
	return remoteId
end

-- Identifies a photo in log lines (no paths).
local function photoLabel(photo)
	local ok, name = pcall(function()
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
	rendition:uploadFailed(tostring(message))
end

function provider.processRenderedPhotos(functionContext, exportContext)
	functionContext:addFailureHandler(function(_, message)
		log:error("publish run aborted: " .. tostring(message))
	end)
	local settings = exportContext.propertyTable
	local session = exportContext.exportSession
	local deps = AppDeps()
	local creds = CredentialStore.load()
	local dryRun = settings.dryRun == true

	local user, e = AccountGuard.verify(deps, creds, settings.lockedNsid)
	if not user then
		LrErrors.throwUserError("Flickr: " .. FlickrResponse.describe(e))
	end
	local api = FlickrApi.new(deps, creds, { token = creds.token, tokenSecret = creds.tokenSecret })

	local renderSettings = PhotoRenderer.copySettings(settings)
	if not renderSettings then
		LrErrors.throwUserError("Flickr: could not read export settings for rendering.")
	end

	local entries = planBatch(session, renderSettings)
	local actions, byPhoto = {}, {}
	for i, entry in ipairs(entries) do
		actions[i] = entry.action
		byPhoto[entry.photo] = entry
	end
	local counts = PublishPlanner.summarize(actions)
	event("plan", {
		n = #entries,
		dryRun = dryRun,
		upload = counts.upload,
		relink = counts.relink,
		replace = counts.replace,
		metadata = counts.metadata,
		adopt = counts.adopt,
		noop = counts.noop,
	})
	resolveReplaces(api, user, entries, counts)

	local queue, folder = renderQueue(entries, renderSettings)
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
		elseif dryRun then
			event("dryRun", { action = entry.action, id = entry.publishedId or entry.flickrId })
		else
			local remoteId, err = execute(api, entry, path)
			event(entry.action, { id = remoteId, err = err })
			if remoteId then
				rendition:recordPublishedPhotoId(remoteId)
				rendition:recordPublishedPhotoUrl(PhotoFields.photoUrl(user.id, remoteId))
				CatalogState.save(rendition.photo, {
					flickrId = remoteId,
					flickrState = entry.action == "metadataOutdated" and "imageOutdated" or "published",
					imageFingerprint = entry.current.image,
					metadataFingerprint = entry.current.metadata,
				})
			else
				fail(rendition, entry, err)
			end
		end

		if path and LrFileUtils.exists(path) then
			LrFileUtils.delete(path)
		end
	end
	LrFileUtils.delete(folder)
	event("end", { n = #entries })
end

return provider

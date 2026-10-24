--[[
Publish service (development spike).

- Account lock: publishing is refused unless the stored token belongs to the locked account.
- Rendering spike: logs how far Lightroom renders ahead of the upload loop ("SPIKE" lines
  in lrflickr.log), and tests skipRender() for already-published photos.
- New photos are uploaded private and hidden from search; already-published photos only get
  their title/description updated. Nothing is ever deleted on Flickr.
]]

local LrDate = import("LrDate")
local LrErrors = import("LrErrors")
local LrFileUtils = import("LrFileUtils")
local LrLogger = import("LrLogger")
local LrPathUtils = import("LrPathUtils")
local LrTasks = import("LrTasks")
local LrView = import("LrView")

local AccountGuard = require("AccountGuard")
local CredentialStore = require("CredentialStore")
local FlickrApi = require("FlickrApi")
local FlickrAuth = require("FlickrAuth")
local FlickrResponse = require("FlickrResponse")
local LrDeps = require("LrDeps")
local LrRender = require("LrRender")
local PhotoFields = require("PhotoFields")
local RenderQueue = require("RenderQueue")

local log = LrLogger("lrflickr")
log:enable("logfile")

local function spike(event, fields)
	local parts = { string.format("SPIKE t=%.3f ev=%s", LrDate.currentTime(), event) }
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

local function dirStats(dir)
	local count, bytes = 0, 0
	if dir and LrFileUtils.exists(dir) then
		for path in LrFileUtils.files(dir) do
			count = count + 1
			bytes = bytes + (LrFileUtils.fileAttributes(path).fileSize or 0)
		end
	end
	return count, bytes
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
		{ key = "spikeUploadMode", default = "dryRun" },
		{ key = "spikeSkipStrategy", default = "none" },
		{ key = "spikeDelay", default = 3 },
		{ key = "spikeDeleteAfterUpload", default = true },
		{ key = "spikeRenderMode", default = "lightroom" },
		{ key = "spikeAhead", default = 2 },
	},
}

function provider.getCollectionBehaviorInfo()
	return {
		defaultCollectionName = "Photostream (dev)",
		defaultCollectionCanBeDeleted = false,
		canAddCollection = false,
		maxCollectionSetDepth = 0,
	}
end

function provider.metadataThatTriggersRepublish()
	return { default = false, title = true, caption = true, keywords = true, gps = true, dateCreated = true }
end

-- Never delete on Flickr: only drop the photo from the published collection.
function provider.deletePhotosFromPublishedCollection(_, arrayOfPhotoIds, deletedCallback)
	for _, id in ipairs(arrayOfPhotoIds) do
		spike("removeFromCollectionOnly", { id = id })
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
		local user, e = FlickrAuth.new(LrDeps(), creds)
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
			title = "Development spike",
			f:row({
				f:static_text({ title = "Upload:", width = 90 }),
				f:popup_menu({
					value = bind("spikeUploadMode"),
					items = {
						{ title = "Dry run (sleep, no Flickr)", value = "dryRun" },
						{ title = "Upload to Flickr (private)", value = "flickr" },
					},
				}),
				f:static_text({ title = "Dry-run seconds:" }),
				f:edit_field({ value = bind("spikeDelay"), width_in_chars = 4, min = 0, max = 60, precision = 1 }),
			}),
			f:row({
				f:static_text({ title = "Skip render:", width = 90 }),
				f:popup_menu({
					value = bind("spikeSkipStrategy"),
					items = {
						{ title = "Never", value = "none" },
						{ title = "Already published (pre-pass)", value = "skipFirstPass" },
					},
				}),
				f:checkbox({ title = "Delete rendered file after upload", value = bind("spikeDeleteAfterUpload") }),
			}),
			f:row({
				f:static_text({ title = "Render:", width = 90 }),
				f:popup_menu({
					value = bind("spikeRenderMode"),
					items = {
						{ title = "Lightroom (whole batch)", value = "lightroom" },
						{ title = "Own, just in time", value = "own" },
					},
				}),
				f:static_text({ title = "Files ahead:" }),
				f:edit_field({ value = bind("spikeAhead"), width_in_chars = 3, min = 0, max = 20, precision = 0 }),
			}),
		},
	}
end

local function photoMeta(photo)
	return {
		title = photo:getFormattedMetadata("title"),
		fileName = photo:getFormattedMetadata("fileName"),
		caption = photo:getFormattedMetadata("caption"),
		uuid = photo:getRawMetadata("uuid"),
	}
end

local function updateMetadata(api, rendition, meta)
	local _, e = api:call("flickr.photos.setMeta", {
		photo_id = rendition.publishedPhotoId,
		title = PhotoFields.title(meta),
		description = meta.caption or "",
	}, "POST")
	return e
end

local function fmt(seconds)
	return string.format("%.3f", seconds)
end

-- Pre-pass over the renditions (does not start rendering). Skips the photos we do not let
-- Lightroom render and returns the photos that still need uploading, in publish order.
local function prePass(session, renderMode, skipStrategy)
	local toRender = {}
	local t0 = LrDate.currentTime()
	local ok, err = LrTasks.pcall(function()
		for _, r in session:renditions() do
			local published = r.publishedPhotoId ~= nil
			if renderMode == "own" or (skipStrategy == "skipFirstPass" and published) then
				r:skipRender()
				spike("skipRender", { id = r.publishedPhotoId })
			end
			if renderMode == "own" and not published then
				toRender[#toRender + 1] = r.photo
			end
		end
	end)
	spike("skipPassDone", { ok = ok, err = err, seconds = fmt(LrDate.currentTime() - t0), toRender = #toRender })
	if not ok then
		LrErrors.throwUserError("Flickr: pre-pass failed: " .. tostring(err))
	end
	return toRender
end

local function ownRenderQueue(settings, toRender)
	local base, method, count = LrRender.copySettings(settings)
	spike("copySettings", { method = method, count = count })
	if not base then
		LrErrors.throwUserError("Flickr: could not read export settings for rendering.")
	end
	local folder = LrRender.makeFolder()
	local start, await = LrRender.renderer(base, folder)
	local ahead = math.max(0, math.floor(tonumber(settings.spikeAhead) or 2))
	return RenderQueue.new(toRender, ahead, start, await), folder
end

local function uploadOne(api, user, rendition, path, meta, i)
	local tu = LrDate.currentTime()
	local photoId, err = api:upload(path, PhotoFields.uploadFields(meta))
	spike("uploaded", { i = i, id = photoId, seconds = fmt(LrDate.currentTime() - tu), err = err and err.message })
	if photoId then
		rendition:recordPublishedPhotoId(photoId)
		rendition:recordPublishedPhotoUrl(PhotoFields.photoUrl(user.id, photoId))
	else
		log:error("upload failed: " .. FlickrResponse.describe(err))
		rendition:uploadFailed(FlickrResponse.describe(err))
	end
end

function provider.processRenderedPhotos(_, exportContext)
	local settings = exportContext.propertyTable
	local session = exportContext.exportSession
	local deps = LrDeps()
	local creds = CredentialStore.load()

	local user, e = AccountGuard.verify(deps, creds, settings.lockedNsid)
	if not user then
		LrErrors.throwUserError("Flickr: " .. FlickrResponse.describe(e))
	end
	local api = FlickrApi.new(deps, creds, { token = creds.token, tokenSecret = creds.tokenSecret })

	local n = session:countRenditions()
	local own = settings.spikeRenderMode == "own"
	spike("start", {
		n = n,
		mode = settings.spikeUploadMode,
		skip = settings.spikeSkipStrategy,
		render = settings.spikeRenderMode,
		ahead = settings.spikeAhead,
		delay = settings.spikeDelay,
		deleteAfter = settings.spikeDeleteAfterUpload,
	})

	local toRender = prePass(session, settings.spikeRenderMode, settings.spikeSkipStrategy)
	local queue, folder
	if own then
		queue, folder = ownRenderQueue(settings, toRender)
	end

	exportContext:configureProgress({ title = string.format("Publishing %d photo(s) to Flickr", n) })

	local i = 0
	for _, rendition in exportContext:renditions({ stopIfCanceled = true }) do
		i = i + 1
		local t0 = LrDate.currentTime()
		local ok, pathOrMsg = rendition:waitForRender()
		local path = rendition.destinationPath

		if own and not rendition.publishedPhotoId then
			local photo
			photo, ok, pathOrMsg = queue:take()
			path = ok and pathOrMsg or nil
			if photo ~= rendition.photo then
				spike("orderMismatch", { i = i })
				ok, pathOrMsg, path = false, "render order mismatch", nil
			end
		end

		local count, bytes = dirStats(own and folder or (path and LrPathUtils.parent(path)))
		spike("rendered", {
			i = i,
			waited = fmt(LrDate.currentTime() - t0),
			ok = ok,
			skipped = rendition.wasSkipped,
			exists = path and LrFileUtils.exists(path) or false,
			filesInDir = count,
			bytesInDir = bytes,
			inFlight = queue and queue:inFlight(),
			published = rendition.publishedPhotoId,
		})

		local meta = photoMeta(rendition.photo)
		if not ok then
			rendition:uploadFailed(tostring(pathOrMsg))
		elseif rendition.publishedPhotoId then
			local err = updateMetadata(api, rendition, meta)
			if err then
				rendition:uploadFailed(FlickrResponse.describe(err))
			else
				rendition:recordPublishedPhotoId(rendition.publishedPhotoId)
			end
			spike("metadataOnly", { i = i, id = rendition.publishedPhotoId, err = err and err.message })
		elseif settings.spikeUploadMode == "flickr" then
			uploadOne(api, user, rendition, path, meta, i)
		else
			LrTasks.sleep(tonumber(settings.spikeDelay) or 0)
		end

		if (own or settings.spikeDeleteAfterUpload) and path and LrFileUtils.exists(path) then
			LrFileUtils.delete(path)
		end
	end
	if folder then
		LrFileUtils.delete(folder)
	end
	spike("end", { i = i })
end

return provider

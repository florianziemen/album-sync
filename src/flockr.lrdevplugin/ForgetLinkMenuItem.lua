--[[
File > Plug-in Extras > "Flickr: Forget Flickr link for selected photos"

Clears the plugin fields (Flickr ID, state, fingerprints, sync state) of the selected photos.
Catalog only: nothing changes on Flickr, published collections are not touched. Useful after a
wrong manual link, or to re-run matching (e.g. after "Import from Another Catalog", which
copies plugin fields).
]]

local LrApplication = import("LrApplication")
local LrDialogs = import("LrDialogs")
local LrFunctionContext = import("LrFunctionContext")
local LrLogger = import("LrLogger")

local log = LrLogger("flockr")
log:enable("logfile")

local FIELDS = { "flickrId", "flickrState", "imageFingerprint", "metadataFingerprint", "metadataState" }

LrFunctionContext.postAsyncTaskWithContext("Flickr: forget link", function(context)
	LrDialogs.attachErrorDialogToFunctionContext(context)
	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos()
	if #photos == 0 then
		LrDialogs.message("Flickr: forget link", "Select the photos first.", "info")
		return
	end
	local answer = LrDialogs.confirm(
		string.format("Forget the Flickr link of %d selected photo(s)?", #photos),
		"Only the catalog is changed: their Flickr ID and sync state are cleared. Nothing is deleted on "
			.. "Flickr, and published collections are not changed. Publishing them again uploads new photos, "
			.. "unless they are linked again (Link existing Flickr albums / review).",
		"Forget link",
		"Cancel"
	)
	if answer ~= "ok" then
		return
	end
	catalog:withPrivateWriteAccessDo(function()
		for _, photo in ipairs(photos) do
			for _, f in ipairs(FIELDS) do
				photo:setPropertyForPlugin(_PLUGIN, f, nil)
			end
		end
	end, { timeout = 60 })
	log:info(string.format("forget link: cleared %d photo(s)", #photos))
end)

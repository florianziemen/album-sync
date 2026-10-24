--[[
Disclaimer that must be accepted once before the plugin does anything (menu items, publishing).
Acceptance is stored in the plugin preferences; raising VERSION asks again.
]]

local LrDialogs = import("LrDialogs")
local LrErrors = import("LrErrors")
local LrFunctionContext = import("LrFunctionContext")
local LrPrefs = import("LrPrefs")
local LrView = import("LrView")

local UiText = require("UiText")

local M = {}

M.VERSION = 1

M.TEXT = 'Album Sync is free software, provided "as is" without warranty of any kind (MIT License). '
	.. "It uploads photos to Flickr, changes their titles, descriptions, tags, privacy, location and albums, "
	.. "and writes to your Lightroom catalog. Bugs, changes of the Flickr API or wrong settings can lead to "
	.. "lost, duplicated, mislabelled or unintentionally public photos and other problems. There is no "
	.. "guarantee for your photos or data: "
	.. "Keep backups of your catalog and originals. You use it at your own risk.\n\n"
	.. "Album Sync is an independent project. It is not affiliated with, endorsed or supported by Adobe Inc. "
	.. "or SmugMug, Inc. (Flickr). This product uses the Flickr API but is not endorsed or certified by "
	.. "SmugMug, Inc. Adobe and Lightroom are trademarks of Adobe Inc.; Flickr is a trademark of SmugMug, Inc."

function M.accepted()
	return LrPrefs.prefsForPlugin().disclaimerAccepted == M.VERSION
end

--- True when accepted (now or earlier). Shows the disclaimer if needed; must run in a task.
function M.accept()
	if M.accepted() then
		return true
	end
	local result
	LrFunctionContext.callWithContext("Album Sync: disclaimer", function()
		local f = LrView.osFactory()
		result = LrDialogs.presentModalDialog({
			title = "Album Sync: please read before use",
			contents = f:column({ UiText.wrapped(f, M.TEXT, 80) }),
			actionVerb = "I accept",
			cancelVerb = "Cancel",
		})
	end)
	if result == "ok" then
		LrPrefs.prefsForPlugin().disclaimerAccepted = M.VERSION
		return true
	end
	return false
end

--- Like accept(), but raises a user error when declined (publishing hooks).
function M.require()
	if not M.accept() then
		LrErrors.throwUserError("Album Sync: the disclaimer was not accepted, so nothing was done.")
	end
end

return M

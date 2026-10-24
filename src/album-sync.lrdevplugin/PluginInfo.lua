--[[
Plug-in Manager section: what the plugin is, where to start, and the notices required by
the Flickr API terms (Section 3) and for the trademarks used descriptively.
]]

local LrHttp = import("LrHttp")

local UiText = require("UiText")

local REPO = "https://github.com/florianziemen/album-sync"

return {
	sectionsForTopOfDialog = function(f)
		return {
			{
				title = "Album Sync",
				UiText.wrapped(f, "Publish and sync Flickr albums from Adobe Lightroom Classic."),
				UiText.wrapped(
					f,
					"Start with File > Plug-in Extras > Album Sync: Log in to Flickr, "
						.. "then set up the “Album Sync” publish service."
				),
				f:push_button({
					title = "Documentation and source code",
					action = function()
						LrHttp.openUrlInBrowser(REPO)
					end,
				}),
				UiText.wrapped(f, "This product uses the Flickr API but is not endorsed or certified by SmugMug, Inc."),
				UiText.wrapped(
					f,
					"Adobe and Lightroom are trademarks of Adobe Inc.; Flickr is a trademark of SmugMug, Inc.\n"
						.. "This project is not affiliated with either."
				),
				UiText.wrapped(f, "MIT License. Log file: album-sync.log in Lightroom's logs folder."),
			},
		}
	end,
}

--[[
Plug-in Manager section: what the plugin is, where to start, and the notices required by
the Flickr API terms (Section 3) and for the trademarks used descriptively.
]]

local LrHttp = import("LrHttp")

local REPO = "https://github.com/florianziemen/album-sync"

return {
	sectionsForTopOfDialog = function(f)
		return {
			{
				title = "Album Sync",
				f:static_text({
					title = "Publish and sync Flickr albums from Adobe Lightroom Classic.",
					fill_horizontal = 1,
				}),
				f:static_text({
					title = "Start with File > Plug-in Extras > Album Sync: Log in to Flickr, then set up the “Album Sync” publish service.",
					fill_horizontal = 1,
				}),
				f:push_button({
					title = "Documentation and source code",
					action = function()
						LrHttp.openUrlInBrowser(REPO)
					end,
				}),
				f:static_text({
					title = "This product uses the Flickr API but is not endorsed or certified by SmugMug, Inc.",
					fill_horizontal = 1,
				}),
				f:static_text({
					title = "Adobe and Lightroom are trademarks of Adobe Inc.; Flickr is a trademark of SmugMug, Inc. "
						.. "This project is not affiliated with either.",
					fill_horizontal = 1,
				}),
				f:static_text({
					title = "MIT License. Log file: album-sync.log in Lightroom's logs folder.",
					fill_horizontal = 1,
				}),
			},
		}
	end,
}

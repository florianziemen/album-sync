return {
	LrSdkVersion = 13.0,
	LrSdkMinimumVersion = 13.0,
	LrToolkitIdentifier = "io.github.lightroom-flickr",
	LrPluginName = "Flickr Publish (open source)",

	LrExportServiceProvider = {
		title = "Flickr (dev)",
		file = "ServiceProvider.lua",
	},

	LrExportMenuItems = {
		{ title = "Flickr: Log in", file = "LoginMenuItem.lua" },
	},

	VERSION = { major = 0, minor = 0, revision = 2 },
}

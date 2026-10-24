return {
	LrSdkVersion = 13.0,
	LrSdkMinimumVersion = 13.0,
	LrToolkitIdentifier = "io.github.lightroom-flickr",
	LrPluginName = "Flickr Publish (open source)",

	LrExportServiceProvider = {
		title = "Flickr (dev)",
		file = "ServiceProvider.lua",
	},

	LrMetadataProvider = "MetadataDefinition.lua",

	LrExportMenuItems = {
		{ title = "Flickr: Log in", file = "LoginMenuItem.lua" },
		{ title = "Flickr: Check for photos deleted on Flickr…", file = "CheckDeletedMenuItem.lua" },
	},

	VERSION = { major = 0, minor = 1, revision = 0 },
}

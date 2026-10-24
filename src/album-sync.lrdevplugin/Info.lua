return {
	LrSdkVersion = 13.0,
	LrSdkMinimumVersion = 13.0,
	LrToolkitIdentifier = "io.github.florianziemen.album-sync",
	LrPluginName = "Album Sync",

	LrExportServiceProvider = {
		title = "Album Sync",
		file = "ServiceProvider.lua",
	},

	LrMetadataProvider = "MetadataDefinition.lua",
	LrPluginInfoProvider = "PluginInfo.lua",
	LrPluginInfoUrl = "https://github.com/florianziemen/album-sync",

	LrExportMenuItems = {
		{ title = "Album Sync: Log in to Flickr", file = "LoginMenuItem.lua" },
		{ title = "Album Sync: Check for photos deleted on Flickr…", file = "CheckDeletedMenuItem.lua" },
		{ title = "Album Sync: Link existing Flickr albums…", file = "ImportMenuItem.lua" },
		{ title = "Album Sync: Review unclear matches…", file = "ReviewMenuItem.lua" },
		{ title = "Album Sync: Forget Flickr link for selected photos", file = "ForgetLinkMenuItem.lua" },
	},

	VERSION = { major = 0, minor = 1, revision = 0 },
}

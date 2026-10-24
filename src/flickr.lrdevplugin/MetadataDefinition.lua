--[[
Per-photo plugin fields (docs/DESIGN.md §3, §6). Shown read-only in the Metadata panel
(Flickr ID is searchable for smart collections); the rest is internal.
]]

return {
	metadataFieldsForPhotos = {
		{
			id = "flickrId",
			title = "Flickr ID",
			dataType = "string",
			searchable = true,
			browsable = true,
			readOnly = true,
		},
		{
			id = "flickrState",
			title = "Flickr state",
			dataType = "string",
			searchable = true,
			browsable = true,
			readOnly = true,
		},
		{ id = "imageFingerprint", dataType = "string" },
		{ id = "metadataFingerprint", dataType = "string" },
	},
	schemaVersion = 1,
}

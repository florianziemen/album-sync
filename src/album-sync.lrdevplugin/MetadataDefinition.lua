--[[
Per-photo plugin fields (docs/DESIGN.md §3, §6). Shown in the Metadata panel:
Flickr ID and state (read-only, searchable), Flickr privacy (editable override).
The rest is internal.
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
		{
			id = "flickrPrivacy",
			title = "Flickr privacy",
			dataType = "enum",
			searchable = true,
			browsable = true,
			values = {
				{ value = "default", title = "Album / service default" },
				{ value = "public", title = "Public" },
				{ value = "friendsFamily", title = "Friends and family" },
				{ value = "friends", title = "Friends" },
				{ value = "family", title = "Family" },
				{ value = "private", title = "Private" },
			},
		},
		{ id = "imageFingerprint", dataType = "string" },
		{ id = "metadataFingerprint", dataType = "string" },
		-- JSON { lr, sent }: values at the last sync, for per-field conflict detection.
		{ id = "metadataState", dataType = "string" },
	},
	schemaVersion = 2,
}

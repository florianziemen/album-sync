--[[
File > Plug-in Extras > "Flickr: Check for photos deleted on Flickr…"

Compares every Flickr id the catalog knows with the account's photos, confirms each missing one
with a direct lookup, then asks once: mark only (default rule: never remove or republish
automatically), or mark and unlink so the photos can be published again.
]]

local LrDialogs = import("LrDialogs")
local LrFunctionContext = import("LrFunctionContext")
local LrLogger = import("LrLogger")
local LrProgressScope = import("LrProgressScope")

local AccountGuard = require("AccountGuard")
local AppDeps = require("AppDeps")
local CatalogState = require("CatalogState")
local CredentialStore = require("CredentialStore")
local FlickrApi = require("FlickrApi")
local FlickrResponse = require("FlickrResponse")
local RateLimiter = require("RateLimiter")
local RemoteCheck = require("RemoteCheck")

local log = LrLogger("album-sync")
log:enable("logfile")

local function fatal(message)
	log:error("check deleted: " .. message)
	LrDialogs.message("Flickr: check for deleted photos", message, "critical")
end

LrFunctionContext.postAsyncTaskWithContext("Flickr: check for deleted photos", function(context)
	LrDialogs.attachErrorDialogToFunctionContext(context)
	local deps = AppDeps()
	deps.limiter = RateLimiter.new(deps)
	local nsid, e = AccountGuard.catalogAccount(CatalogState.lockedAccounts())
	if not nsid then
		return fatal(e.message)
	end
	local creds = CredentialStore.account(nsid)
	local user
	user, e = AccountGuard.verify(deps, creds, nsid, "read")
	if not user then
		return fatal(FlickrResponse.describe(e))
	end
	log:info(string.format("check deleted: account %s (%s)", tostring(user.username), user.id))

	local progress = LrProgressScope({ title = "Checking Flickr for deleted photos", functionContext = context })
	local links = CatalogState.knownLinks()
	local ids, seen = {}, {}
	local abstract = {}
	for i, link in ipairs(links) do
		if not seen[link.id] then
			seen[link.id] = true
			ids[#ids + 1] = link.id
		end
		abstract[i] = {
			photoKey = link.photo.localIdentifier,
			id = link.id,
			collectionKey = link.collection and link.collection.localIdentifier,
			index = i,
		}
	end
	progress:setCaption(string.format("Listing your photos on Flickr (%d known in this catalog)…", #ids))

	local api = FlickrApi.new(deps, creds, { token = creds.token, tokenSecret = creds.tokenSecret })
	local result, err = RemoteCheck.findMissing(api, ids, function(i, n)
		progress:setCaption(string.format("Confirming missing photo %d of %d…", i, n))
		progress:setPortionComplete(i, n)
	end)
	progress:done()
	if not result then
		return fatal(FlickrResponse.describe(err))
	end

	local missing = {}
	for _, id in ipairs(result.missing) do
		missing[id] = true
	end
	local decision = RemoteCheck.classify(abstract, missing)
	local photos, byKey = {}, {}
	for _, link in ipairs(links) do
		local key = link.photo.localIdentifier
		if decision.photos[key] and not byKey[key] then
			byKey[key] = true
			photos[#photos + 1] = link.photo
		end
	end
	local stale = {}
	for _, a in ipairs(decision.staleLinks) do
		stale[#stale + 1] = links[a.index]
	end

	log:info(
		string.format(
			"check deleted: known=%d listed=%d total=%d missing=%d unconfirmed=%d photos=%d staleLinks=%d",
			#ids,
			result.listed,
			result.total,
			#result.missing,
			#result.unconfirmed,
			#photos,
			#stale
		)
	)
	if #result.missing > 0 then
		log:info("check deleted: missing ids " .. table.concat(result.missing, ","))
	end
	local unconfirmedNote = #result.unconfirmed > 0
			and string.format(
				"\n\n%d photo(s) could not be checked because of errors; see the log. They are left unchanged.",
				#result.unconfirmed
			)
		or ""

	if #photos == 0 and #stale == 0 then
		LrDialogs.message(
			"Flickr: no deleted photos found",
			string.format("All %d Flickr photo(s) known to this catalog still exist.%s", #ids, unconfirmedNote),
			"info"
		)
		return
	end

	local answer = LrDialogs.confirm(
		string.format("%d photo(s) in this catalog no longer exist on Flickr.", #photos),
		"Mark only: set “Flickr state” to deletedOnFlickr; nothing else changes.\n"
			.. "Mark and unlink: also clear their Flickr ID and remove them from the Flickr collections, "
			.. "so they can be published again as new photos."
			.. unconfirmedNote,
		"Mark only",
		"Cancel",
		"Mark and unlink"
	)
	if answer == "cancel" then
		return
	end
	local unlink = answer == "other"
	CatalogState.markDeleted(photos, stale, unlink)
	log:info(string.format("check deleted: marked %d photo(s), unlink=%s", #photos, tostring(unlink)))
end)

--[[
File > Plug-in Extras > "Flickr: Log in".

Asks for API key/secret and the permission to grant (read / write / delete), runs the OAuth
oob flow, verifies with flickr.test.login, and stores the token for that account in the
keychain. Several accounts can be logged in; each publish service is locked to one.
]]

local LrBinding = import("LrBinding")
local LrDialogs = import("LrDialogs")
local LrFunctionContext = import("LrFunctionContext")
local LrHttp = import("LrHttp")
local LrLogger = import("LrLogger")
local LrView = import("LrView")

local CredentialStore = require("CredentialStore")
local FlickrAuth = require("FlickrAuth")
local FlickrResponse = require("FlickrResponse")
local AppDeps = require("AppDeps")

local log = LrLogger("flockr")
log:enable("logfile")

local deps = AppDeps
local describe = FlickrResponse.describe

local function askCredentials(context, stored)
	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(context)
	props.consumerKey = stored.consumerKey or ""
	props.consumerSecret = stored.consumerSecret or ""
	props.perms = "read"
	local result = LrDialogs.presentModalDialog({
		title = "Flickr API key",
		contents = f:column({
			bind_to_object = props,
			spacing = f:control_spacing(),
			f:static_text({ title = "Create a key at flickr.com/services/apps/create (requires Flickr Pro)." }),
			f:row({
				f:static_text({ title = "Key:", width = 60 }),
				f:edit_field({ value = LrView.bind("consumerKey"), width_in_chars = 36 }),
			}),
			f:row({
				f:static_text({ title = "Secret:", width = 60 }),
				f:password_field({ value = LrView.bind("consumerSecret"), width_in_chars = 36 }),
			}),
			f:row({
				f:static_text({ title = "Allow:", width = 60 }),
				f:popup_menu({
					value = LrView.bind("perms"),
					items = {
						{ title = "Read only (import, matching; can never change anything)", value = "read" },
						{ title = "Read and write (publish)", value = "write" },
						{ title = "Read, write and delete (publish, re-upload with delete)", value = "delete" },
					},
				}),
			}),
			f:static_text({ title = "Log in to the account you want in the browser (use a private window if needed)." }),
		}),
	})
	local key = (props.consumerKey or ""):gsub("%s", "")
	local secret = (props.consumerSecret or ""):gsub("%s", "")
	if result ~= "ok" or key == "" or secret == "" then
		return nil
	end
	return { consumerKey = key, consumerSecret = secret, perms = props.perms }
end

local function askVerifier(context)
	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(context)
	props.verifier = ""
	local result = LrDialogs.presentModalDialog({
		title = "Flickr authorization",
		contents = f:column({
			bind_to_object = props,
			spacing = f:control_spacing(),
			f:static_text({ title = "Authorize in the browser, then paste the code Flickr shows:" }),
			f:edit_field({ value = LrView.bind("verifier"), width_in_chars = 20 }),
		}),
	})
	if result ~= "ok" or props.verifier == "" then
		return nil
	end
	return (props.verifier:gsub("%s", ""))
end

LrFunctionContext.postAsyncTaskWithContext("Flickr login", function(context)
	LrDialogs.attachErrorDialogToFunctionContext(context)

	local creds = askCredentials(context, CredentialStore.app())
	if not creds then
		return
	end
	CredentialStore.saveApp(creds.consumerKey, creds.consumerSecret)
	local auth = FlickrAuth.new(deps(), creds)

	local reqToken, e = auth:requestToken()
	if not reqToken then
		log:error("request_token failed: " .. describe(e))
		LrDialogs.message("Flickr login failed (request token)", describe(e), "critical")
		return
	end

	LrHttp.openUrlInBrowser(FlickrAuth.authorizeUrl(reqToken, creds.perms))
	local verifier = askVerifier(context)
	if not verifier then
		return
	end

	local access
	access, e = auth:accessToken(reqToken, verifier)
	if not access then
		log:error("access_token failed: " .. describe(e))
		LrDialogs.message("Flickr login failed (access token)", describe(e), "critical")
		return
	end

	local user
	user, e = auth:testLogin(access)
	if not user then
		log:error("test.login failed: " .. describe(e))
		LrDialogs.message("Flickr login failed (test.login)", describe(e), "critical")
		return
	end

	CredentialStore.saveAccount(user.id, user.username, creds.perms, access.token, access.tokenSecret)
	log:info(string.format("login ok for %s (%s), perms=%s", tostring(user.username), tostring(user.id), creds.perms))
	LrDialogs.message(
		"Logged in to Flickr as " .. tostring(user.username),
		string.format("NSID: %s\nPermission: %s", tostring(user.id), creds.perms)
	)
end)

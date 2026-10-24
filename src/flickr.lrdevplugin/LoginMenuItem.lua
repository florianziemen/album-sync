--[[
Prototype: File > Plug-in Extras > "Flickr: Log in".

Asks for API key/secret, runs the OAuth oob flow, verifies with flickr.test.login,
stores tokens in the keychain, and reports whether LrDigest supports HMAC-SHA1.
]]

local LrBinding = import("LrBinding")
local LrDialogs = import("LrDialogs")
local LrDigest = import("LrDigest")
local LrFunctionContext = import("LrFunctionContext")
local LrHttp = import("LrHttp")
local LrLogger = import("LrLogger")
local LrView = import("LrView")

local CredentialStore = require("CredentialStore")
local FlickrAuth = require("FlickrAuth")
local FlickrResponse = require("FlickrResponse")
local AppDeps = require("AppDeps")
local Sha1 = require("Sha1")

local log = LrLogger("lrflickr")
log:enable("logfile")

local deps = AppDeps
local describe = FlickrResponse.describe

-- Spike: does the built-in LrDigest offer HMAC-SHA1? Never fails, only reports.
local function probeLrDigestHmacSha1()
	local key, msg = "key", "The quick brown fox jumps over the lazy dog"
	local expected = Sha1.hmacHex(key, msg)
	local ok, result = pcall(function()
		local h = LrDigest.HMAC.init("SHA1", key)
		h:update(msg)
		return h:digest()
	end)
	if not ok then
		return "LrDigest.HMAC SHA1: unavailable (" .. tostring(result) .. ")"
	end
	local hex = type(result) == "string" and result:lower() or tostring(result)
	return string.format("LrDigest.HMAC SHA1: returned %s; matches pure Lua: %s", hex, tostring(hex == expected))
end

local function askCredentials(context, stored)
	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(context)
	props.consumerKey = stored.consumerKey or ""
	props.consumerSecret = stored.consumerSecret or ""
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
		}),
	})
	local key = (props.consumerKey or ""):gsub("%s", "")
	local secret = (props.consumerSecret or ""):gsub("%s", "")
	if result ~= "ok" or key == "" or secret == "" then
		return nil
	end
	return { consumerKey = key, consumerSecret = secret }
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

	local stored = CredentialStore.load()
	local creds = askCredentials(context, stored)
	if not creds then
		return
	end
	CredentialStore.save(creds)
	local auth = FlickrAuth.new(deps(), creds)

	local reqToken, e = auth:requestToken()
	if not reqToken then
		log:error("request_token failed: " .. describe(e))
		LrDialogs.message("Flickr login failed (request token)", describe(e), "critical")
		return
	end

	LrHttp.openUrlInBrowser(FlickrAuth.authorizeUrl(reqToken, "delete"))
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

	CredentialStore.save({
		token = access.token,
		tokenSecret = access.tokenSecret,
		userNsid = user.id,
		username = user.username,
	})
	local probe = probeLrDigestHmacSha1()
	log:info("login ok for " .. tostring(user.id) .. "; " .. probe)
	LrDialogs.message(
		"Logged in to Flickr as " .. tostring(user.username),
		"NSID: " .. tostring(user.id) .. "\n\n" .. probe
	)
end)

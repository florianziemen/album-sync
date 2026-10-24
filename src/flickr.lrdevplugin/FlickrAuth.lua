--[[
Flickr OAuth 1.0a login flow with out-of-band (oob) verifier.

Dependencies as for FlickrApi (transport, now, random).
]]

local OAuth = require("OAuth")
local FlickrApi = require("FlickrApi")
local FlickrResponse = require("FlickrResponse")

local OAUTH_BASE = "https://www.flickr.com/services/oauth/"

local M = {}
M.__index = M

--- deps: { transport, now, random }; creds: { consumerKey, consumerSecret }
function M.new(deps, creds)
	return setmetatable({ deps = deps, creds = creds, api = FlickrApi.new(deps, creds) }, M)
end

--- Step 1. Returns { token, tokenSecret } or nil, err.
function M:requestToken()
	local resp = self.api:signedRequest("GET", OAUTH_BASE .. "request_token", { oauth_callback = "oob" })
	local form, e = FlickrResponse.parseOAuth(resp)
	if not form then
		return nil, e
	end
	if form.oauth_callback_confirmed ~= "true" then
		return nil, { class = "auth", message = "callback not confirmed" }
	end
	return { token = form.oauth_token, tokenSecret = form.oauth_token_secret }
end

--- Step 2. URL the user opens in a browser.
function M.authorizeUrl(requestToken, perms)
	return OAUTH_BASE
		.. "authorize?oauth_token="
		.. OAuth.encode(requestToken.token)
		.. "&perms="
		.. OAuth.encode(perms or "delete")
end

--- Step 3. Returns { token, tokenSecret, userNsid, username, fullname } or nil, err.
function M:accessToken(requestToken, verifier)
	local resp = self.api:signedRequest(
		"GET",
		OAUTH_BASE .. "access_token",
		{ oauth_verifier = verifier },
		requestToken.token,
		requestToken.tokenSecret
	)
	local form, e = FlickrResponse.parseOAuth(resp)
	if not form then
		return nil, e
	end
	return {
		token = form.oauth_token,
		tokenSecret = form.oauth_token_secret,
		userNsid = form.user_nsid,
		username = form.username,
		fullname = form.fullname,
	}
end

--- Verify tokens. Returns { id, username } or nil, err.
function M:testLogin(access)
	local data, e = FlickrApi.new(self.deps, self.creds, access):call("flickr.test.login")
	if not data then
		return nil, e
	end
	return { id = data.user.id, username = data.user.username._content }
end

return M

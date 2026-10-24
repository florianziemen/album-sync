--[[
Signed Flickr API client: REST calls and photo upload.

Dependencies are injected:
  transport(req) -> resp            req = { method, url, params }
  postMultipart(req) -> resp        req = { url, params, filePath, fileField }
  now() -> unix seconds
  random(n) -> integer in [1, n]
creds = { consumerKey, consumerSecret }; access = { token, tokenSecret } or nil.
]]

local OAuth = require("OAuth")
local FlickrResponse = require("FlickrResponse")

local REST_URL = "https://api.flickr.com/services/rest/"
local UPLOAD_URL = "https://up.flickr.com/services/upload/"
local REPLACE_URL = "https://up.flickr.com/services/replace/"

local M = {}
M.__index = M

function M.new(deps, creds, access)
	return setmetatable({ deps = deps, creds = creds, access = access or {} }, M)
end

--- Copy of `params` with all oauth_* fields and signature added.
function M:sign(method, url, params, token, tokenSecret)
	return OAuth.sign({
		method = method,
		url = url,
		params = params,
		consumerKey = self.creds.consumerKey,
		consumerSecret = self.creds.consumerSecret,
		token = token,
		tokenSecret = tokenSecret,
		nonce = OAuth.nonce(self.deps.random),
		timestamp = math.floor(self.deps.now()),
	})
end

--- Signed request with explicit token (used by the login flow before access is known).
function M:signedRequest(method, url, params, token, tokenSecret)
	return self.deps.transport({
		method = method,
		url = url,
		params = self:sign(method, url, params, token, tokenSecret),
	})
end

--[[
REST call. httpMethod defaults to GET; Flickr requires POST for setters.
Returns decoded JSON or nil, err.
]]
function M:call(method, params, httpMethod)
	local all = { method = method, format = "json", nojsoncallback = "1" }
	for k, v in pairs(params or {}) do
		all[k] = v
	end
	local resp = self:signedRequest(httpMethod or "GET", REST_URL, all, self.access.token, self.access.tokenSecret)
	return FlickrResponse.parseRest(resp)
end

function M:_postFile(url, filePath, fields)
	local signed = self:sign("POST", url, fields or {}, self.access.token, self.access.tokenSecret)
	local resp = self.deps.postMultipart({
		url = url,
		params = signed,
		filePath = filePath,
		fileField = "photo",
	})
	return FlickrResponse.parseUpload(resp)
end

--- Upload a file. `fields` are Flickr upload arguments (title, tags, is_public, ...).
--- Returns the photo id or nil, err.
function M:upload(filePath, fields)
	return self:_postFile(UPLOAD_URL, filePath, fields)
end

--- Replace the image of an existing photo (Flickr Pro only). Returns the photo id or nil, err;
--- a non-Pro account yields class "replace_not_pro".
function M:replace(filePath, photoId)
	local id, e = self:_postFile(REPLACE_URL, filePath, { photo_id = photoId })
	if e and e.code == 1 then
		e.class = "replace_not_pro"
	end
	return id, e
end

--- Returns true/false for Pro status of `nsid`, or nil, err.
function M:isPro(nsid)
	local data, e = self:call("flickr.people.getInfo", { user_id = nsid })
	if not data then
		return nil, e
	end
	return tonumber(data.person and data.person.ispro) == 1
end

return M

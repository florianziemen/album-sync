--[[
Signed Flickr API client: REST calls and photo upload.

Dependencies are injected:
  transport(req) -> resp            req = { method, url, params }
  postMultipart(req) -> resp        req = { url, params, filePath, fileField }
  now() -> unix seconds
  random(n) -> integer in [1, n]
  log(level, message)               optional; level "info" | "error"
  fileSize(path) -> bytes           optional, for diagnostics
  pcall                             optional; LrTasks.pcall in Lightroom (calls yield)
creds = { consumerKey, consumerSecret }; access = { token, tokenSecret } or nil.

Every exchange is logged as one summary line; failures additionally get a full,
redacted dump of request and response (Diagnostics).
]]

local OAuth = require("OAuth")
local Diagnostics = require("Diagnostics")
local FlickrResponse = require("FlickrResponse")

local REST_URL = "https://api.flickr.com/services/rest/"
local UPLOAD_URL = "https://up.flickr.com/services/upload/"
local REPLACE_URL = "https://up.flickr.com/services/replace/"

local M = {}
M.__index = M

function M.new(deps, creds, access)
	return setmetatable({ deps = deps, creds = creds, access = access or {} }, M)
end

function M:_log(level, message)
	if self.deps.log then
		self.deps.log(level, message)
	end
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

--[[
Send `req` with `send`, parse with `parse`, log. `check(result)` may reject a successful
parse whose shape is unexpected; it returns an error message or nil.
Returns result or nil, err.
]]
function M:exchange(label, send, req, parse, check)
	local t0 = self.deps.now()
	local ok, resp = (self.deps.pcall or pcall)(send, req)
	if not ok then
		resp = { message = "transport raised: " .. tostring(resp) }
	end
	local elapsed = self.deps.now() - t0
	local result, err = parse(resp)
	if result ~= nil and check then
		local problem = check(result)
		if problem then
			result, err = nil, { class = "unexpected", message = problem }
		end
	end
	self:_log(err and "error" or "info", Diagnostics.summary(label, req, resp, elapsed, err))
	if err then
		self:_log("error", Diagnostics.exchange(label, req, resp, elapsed, err))
		return nil, err
	end
	return result
end

--- Signed GET/POST with an explicit token, parsed with `parse` (used by the login flow).
function M:signedExchange(label, method, url, params, token, tokenSecret, parse, check)
	local req = { method = method, url = url, params = self:sign(method, url, params, token, tokenSecret) }
	return self:exchange(label, self.deps.transport, req, parse, check)
end

--[[
REST call. httpMethod defaults to GET; Flickr requires POST for setters.
Returns decoded JSON or nil, err.
]]
function M:call(method, params, httpMethod, check)
	local all = { method = method, format = "json", nojsoncallback = "1" }
	for k, v in pairs(params or {}) do
		all[k] = v
	end
	return self:signedExchange(
		method,
		httpMethod or "GET",
		REST_URL,
		all,
		self.access.token,
		self.access.tokenSecret,
		FlickrResponse.parseRest,
		check
	)
end

function M:_postFile(label, url, filePath, fields)
	local req = {
		method = "POST",
		url = url,
		params = self:sign("POST", url, fields or {}, self.access.token, self.access.tokenSecret),
		filePath = filePath,
		fileField = "photo",
		fileSize = self.deps.fileSize and self.deps.fileSize(filePath),
	}
	return self:exchange(label, self.deps.postMultipart, req, FlickrResponse.parseUpload)
end

--- Upload a file. `fields` are Flickr upload arguments (title, tags, is_public, ...).
--- Returns the photo id or nil, err.
function M:upload(filePath, fields)
	return self:_postFile("upload", UPLOAD_URL, filePath, fields)
end

--- Replace the image of an existing photo (Flickr Pro only). Returns the photo id or nil, err;
--- a non-Pro account yields class "replace_not_pro".
function M:replace(filePath, photoId)
	local id, e = self:_postFile("replace", REPLACE_URL, filePath, { photo_id = photoId })
	if e and e.code == 1 then
		e.class = "replace_not_pro"
	end
	return id, e
end

--- Push title, description and tags (fields from PhotoFields.metadataFields).
--- setTags replaces all tags on the photo. Returns true or nil, err.
function M:setMetadata(photoId, fields)
	local _, e = self:call(
		"flickr.photos.setMeta",
		{ photo_id = photoId, title = fields.title, description = fields.description },
		"POST"
	)
	if e then
		return nil, e
	end
	_, e = self:call("flickr.photos.setTags", { photo_id = photoId, tags = fields.tags or "" }, "POST")
	if e then
		return nil, e
	end
	return true
end

--- Returns true/false for Pro status of `nsid`, or nil, err.
function M:isPro(nsid)
	local data, e = self:call("flickr.people.getInfo", { user_id = nsid }, nil, function(d)
		if type(d.person) ~= "table" or d.person.ispro == nil then
			return "people.getInfo: missing person.ispro"
		end
	end)
	if not data then
		return nil, e
	end
	return tonumber(data.person.ispro) == 1
end

return M

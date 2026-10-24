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
  sleep(seconds)                    optional; enables retries of idempotent REST calls
  random01() -> [0, 1)              optional; jitter for retries
  limiter                           optional RateLimiter shared by all calls of a run
creds = { consumerKey, consumerSecret }; access = { token, tokenSecret } or nil.

Every exchange is logged as one summary line; failures additionally get a full,
redacted dump of request and response (Diagnostics).
]]

local OAuth = require("OAuth")
local Diagnostics = require("Diagnostics")
local Retry = require("Retry")
local FlickrResponse = require("FlickrResponse")

local REST_URL = "https://api.flickr.com/services/rest/"
local UPLOAD_URL = "https://up.flickr.com/services/upload/"
local REPLACE_URL = "https://up.flickr.com/services/replace/"

-- REST methods that must not be retried blindly: a lost response may hide a success.
local NOT_IDEMPOTENT = { ["flickr.photosets.create"] = true }

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
parse whose shape is unexpected; it returns an error message or nil. `expected` is a set of
Flickr error codes the caller handles as normal outcomes (logged as info, no dump).
Returns result or nil, err.
]]
function M:exchange(label, send, req, parse, check, expected)
	if self.deps.limiter then
		local waited = self.deps.limiter:acquire()
		if waited > 0 then
			self:_log("info", string.format("rate limit: waited %.1fs before %s", waited, label))
		end
	end
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
	if err and expected and err.code and expected[err.code] then
		self:_log("info", Diagnostics.summary(label, req, resp, elapsed, err) .. " (expected)")
		return nil, err
	end
	self:_log(err and "error" or "info", Diagnostics.summary(label, req, resp, elapsed, err))
	if err then
		self:_log("error", Diagnostics.exchange(label, req, resp, elapsed, err))
		return nil, err
	end
	return result
end

--- Signed GET/POST with an explicit token, parsed with `parse` (used by the login flow).
function M:signedExchange(label, method, url, params, token, tokenSecret, parse, check, expected)
	local req = { method = method, url = url, params = self:sign(method, url, params, token, tokenSecret) }
	return self:exchange(label, self.deps.transport, req, parse, check, expected)
end

--[[
REST call. httpMethod defaults to GET; Flickr requires POST for setters.
expected: optional set of error codes that are normal outcomes for the caller (see exchange).
Returns decoded JSON or nil, err.
]]
function M:call(method, params, httpMethod, check, expected)
	local all = { method = method, format = "json", nojsoncallback = "1" }
	for k, v in pairs(params or {}) do
		all[k] = v
	end
	local function once()
		-- Re-signed per attempt: fresh nonce and timestamp.
		return self:signedExchange(
			method,
			httpMethod or "GET",
			REST_URL,
			all,
			self.access.token,
			self.access.tokenSecret,
			FlickrResponse.parseRest,
			check,
			expected
		)
	end
	if not self.deps.sleep or NOT_IDEMPOTENT[method] then
		return once()
	end
	return Retry.run(self.deps, method, once)
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

--- Async upload: returns a ticket id (poll with checkTickets) or nil, err.
function M:uploadAsync(filePath, fields)
	local all = { async = "1" }
	for k, v in pairs(fields or {}) do
		all[k] = v
	end
	local req = {
		method = "POST",
		url = UPLOAD_URL,
		params = self:sign("POST", UPLOAD_URL, all, self.access.token, self.access.tokenSecret),
		filePath = filePath,
		fileField = "photo",
		fileSize = self.deps.fileSize and self.deps.fileSize(filePath),
	}
	return self:exchange("upload(async)", self.deps.postMultipart, req, FlickrResponse.parseUploadTicket)
end

--[[
Ticket status. Returns { [ticketId] = { complete = 0|1|2, photoId = string|nil, invalid = bool } }
or nil, err. complete: 0 pending, 1 done (photoId set), 2 failed (file could not be processed).
]]
function M:checkTickets(ticketIds)
	local data, e = self:call(
		"flickr.photos.upload.checkTickets",
		{ tickets = table.concat(ticketIds, ",") },
		nil,
		function(d)
			if type(d.uploader) ~= "table" then
				return "checkTickets: missing uploader"
			end
		end
	)
	if not data then
		return nil, e
	end
	local tickets = data.uploader.ticket or {}
	if tickets.id then
		tickets = { tickets }
	end
	local out = {}
	for _, t in ipairs(tickets) do
		out[tostring(t.id)] = {
			complete = tonumber(t.complete) or 0,
			photoId = t.photoid and tostring(t.photoid) or nil,
			invalid = tonumber(t.invalid) == 1,
		}
	end
	return out
end

--[[
Own photos uploaded at or after `sinceUnix` (most recent first, up to 500).
Returns array of { id, title, uploaded (unix), taken } or nil, err.
]]
function M:recentUploads(sinceUnix)
	local data, e = self:call(
		"flickr.people.getPhotos",
		{
			user_id = "me",
			min_upload_date = tostring(math.floor(sinceUnix)),
			extras = "date_upload,date_taken",
			per_page = "500",
		},
		nil,
		function(d)
			if type(d.photos) ~= "table" then
				return "people.getPhotos: missing photos"
			end
		end
	)
	if not data then
		return nil, e
	end
	local out = {}
	for _, p in ipairs(data.photos.photo or {}) do
		out[#out + 1] = {
			id = tostring(p.id),
			title = p.title,
			uploaded = tonumber(p.dateupload),
			taken = p.datetaken,
		}
	end
	return out
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

--- true if the photo exists for the caller, false if Flickr says "Photo not found", or nil, err.
function M:photoExists(photoId)
	local data, e = self:call("flickr.photos.getInfo", { photo_id = photoId }, nil, nil, { [1] = true })
	if data then
		return true
	end
	if e and e.code == 1 then
		return false
	end
	return nil, e
end

--[[
All own photo ids (paged, 500 per call). Returns set { [id] = true }, count, total or nil, err.
count < total means the listing was incomplete; callers must not treat absence as deletion
without confirming (photoExists).
]]
function M:listOwnPhotoIds()
	local ids, count, page, total = {}, 0, 1, 0
	local pages
	repeat
		local data, e = self:call(
			"flickr.people.getPhotos",
			{
				user_id = "me",
				per_page = "500",
				page = tostring(page),
			},
			nil,
			function(d)
				if type(d.photos) ~= "table" then
					return "people.getPhotos: missing photos"
				end
			end
		)
		if not data then
			return nil, e
		end
		pages = tonumber(data.photos.pages) or 1
		total = tonumber(data.photos.total) or total
		for _, p in ipairs(data.photos.photo or {}) do
			local id = tostring(p.id)
			if not ids[id] then
				ids[id] = true
				count = count + 1
			end
		end
		page = page + 1
	until page > pages
	return ids, count, total
end

local function content(v)
	if type(v) == "table" then
		return v._content
	end
	return v
end

-- Compact photo record from a photo list entry (extras date_taken, o_dims).
local function photoRecord(p)
	return {
		id = tostring(p.id),
		title = content(p.title) or "",
		taken = p.datetaken,
		takenUnknown = tonumber(p.datetakenunknown) == 1,
		w = tonumber(p.o_width),
		h = tonumber(p.o_height),
	}
end
M.photoRecord = photoRecord

M.PHOTO_EXTRAS = "date_taken,o_dims"

--- All own albums: array of { id, title, count, updated, created } or nil, err.
function M:albums()
	local out, page = {}, 1
	local pages
	repeat
		local data, e = self:call(
			"flickr.photosets.getList",
			{ per_page = "500", page = tostring(page) },
			nil,
			function(d)
				if type(d.photosets) ~= "table" then
					return "photosets.getList: missing photosets"
				end
			end
		)
		if not data then
			return nil, e
		end
		pages = tonumber(data.photosets.pages) or 1
		for _, set in ipairs(data.photosets.photoset or {}) do
			out[#out + 1] = {
				id = tostring(set.id),
				title = content(set.title) or "",
				count = (tonumber(set.photos) or 0) + (tonumber(set.videos) or 0),
				updated = tonumber(set.date_update),
				created = tonumber(set.date_create),
			}
		end
		page = page + 1
	until page > pages
	return out
end

--- Photos of one album (photoRecord array, album order) or nil, err.
function M:albumPhotos(albumId)
	local out, page = {}, 1
	local pages
	repeat
		local data, e = self:call(
			"flickr.photosets.getPhotos",
			{
				photoset_id = albumId,
				extras = M.PHOTO_EXTRAS,
				per_page = "500",
				page = tostring(page),
			},
			nil,
			function(d)
				if type(d.photoset) ~= "table" then
					return "photosets.getPhotos: missing photoset"
				end
			end
		)
		if not data then
			return nil, e
		end
		pages = tonumber(data.photoset.pages) or 1
		for _, p in ipairs(data.photoset.photo or {}) do
			out[#out + 1] = photoRecord(p)
		end
		page = page + 1
	until page > pages
	return out
end

--[[
One page of own photos taken in [minTaken, maxTaken] ("YYYY-MM-DD HH:MM:SS").
Returns { photos = photoRecord array, page, pages, total } or nil, err.
]]
function M:photosTakenPage(minTaken, maxTaken, page)
	local data, e = self:call(
		"flickr.people.getPhotos",
		{
			user_id = "me",
			min_taken_date = minTaken,
			max_taken_date = maxTaken,
			extras = M.PHOTO_EXTRAS,
			per_page = "500",
			page = tostring(page or 1),
		},
		nil,
		function(d)
			if type(d.photos) ~= "table" then
				return "people.getPhotos: missing photos"
			end
		end
	)
	if not data then
		return nil, e
	end
	local photos = {}
	for _, p in ipairs(data.photos.photo or {}) do
		photos[#photos + 1] = photoRecord(p)
	end
	return {
		photos = photos,
		page = tonumber(data.photos.page) or 1,
		pages = tonumber(data.photos.pages) or 1,
		total = tonumber(data.photos.total) or #photos,
	}
end

--[[
EXIF of the stored original (owner only). Returns { [tag] = raw value } (e.g.
PreservedFileName, SubSecTimeOriginal, DateTimeOriginal, SerialNumber) or nil, err.
]]
function M:exif(photoId)
	local data, e = self:call("flickr.photos.getExif", { photo_id = photoId }, nil, function(d)
		if type(d.photo) ~= "table" then
			return "photos.getExif: missing photo"
		end
	end)
	if not data then
		return nil, e
	end
	local out = {}
	for _, entry in ipairs(data.photo.exif or {}) do
		local raw = entry.raw
		if type(raw) == "table" then
			raw = raw._content
		end
		if entry.tag and raw ~= nil and out[entry.tag] == nil then
			out[entry.tag] = tostring(raw)
		end
	end
	return out
end

--- URL of a small rendition (Large Square 150 or Small 320) for previews, or nil, err.
function M:previewUrl(photoId)
	local data, e = self:call("flickr.photos.getSizes", { photo_id = photoId }, nil, function(d)
		if type(d.sizes) ~= "table" then
			return "photos.getSizes: missing sizes"
		end
	end)
	if not data then
		return nil, e
	end
	local best
	for _, size in ipairs(data.sizes.size or {}) do
		if size.label == "Small 320" then
			return size.source
		elseif size.label == "Large Square" or size.label == "Small" then
			best = best or size.source
		end
	end
	return best
end

--- Delete a photo on Flickr (needs perms=delete). Only on explicit user choice.
function M:deletePhoto(photoId)
	local _, e = self:call("flickr.photos.delete", { photo_id = photoId }, "POST")
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

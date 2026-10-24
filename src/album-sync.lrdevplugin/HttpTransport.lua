--[[
Transport adapter: maps Flickr requests onto LrHttp. Must run inside an LrTasks task.
]]

local LrHttp = import("LrHttp")
local LrPathUtils = import("LrPathUtils")
local OAuth = require("OAuth")

local TIMEOUT = 30
local UPLOAD_TIMEOUT = 300

local M = {}

local function headerTable(raw)
	local h = {}
	for _, entry in ipairs(raw or {}) do
		if type(entry) == "table" and entry.field then
			h[entry.field:lower()] = entry.value
		end
	end
	return h
end

local function toResponse(body, raw)
	raw = raw or {}
	local message
	if raw.error then
		message = string.format("%s (%s)", tostring(raw.error.name), tostring(raw.error.errorCode))
	end
	return {
		status = raw.status,
		body = body,
		headers = headerTable(raw),
		message = message,
		networkError = raw.error,
	}
end

--- req: { method = "GET"|"POST", url, params }. Returns { status, body, headers, message }.
function M.request(req)
	local query = OAuth.normalize(req.params or {})
	if req.method == "POST" then
		return toResponse(
			LrHttp.post(
				req.url,
				query,
				{ { field = "Content-Type", value = "application/x-www-form-urlencoded" } },
				"POST",
				TIMEOUT
			)
		)
	end
	return toResponse(LrHttp.get(req.url .. "?" .. query, nil, TIMEOUT))
end

--[[
Byte size of a remote file without downloading it. First a HEAD request (Content-Length),
then a GET for the first byte only (Content-Range "bytes 0-0/12345"). Flickr's image servers
support both; whether LrHttp passes them through is checked at runtime (the method used is
returned for the log). Returns bytes, method or nil, message.
]]
function M.remoteSize(url)
	local _, head = LrHttp.post(url, "", nil, "HEAD", TIMEOUT)
	head = head or {}
	if head.status == 200 then
		local length = tonumber(headerTable(head)["content-length"])
		if length and length > 0 then
			return length, "HEAD"
		end
	end
	local body, raw = LrHttp.get(url, { { field = "Range", value = "bytes=0-0" } }, TIMEOUT)
	raw = raw or {}
	if raw.status == 206 then
		local total = tonumber((headerTable(raw)["content-range"] or ""):match("/(%d+)%s*$"))
		if total then
			return total, "range"
		end
	elseif raw.status == 200 and body then
		return #body, "full download" -- range ignored
	end
	return nil, string.format("size of %s: HEAD %s, GET %s", url, tostring(head.status), tostring(raw.status))
end

--- req: { url, params, filePath, fileField }. Returns { status, body, headers, message }.
function M.postMultipart(req)
	local content = {}
	for k, v in pairs(req.params or {}) do
		content[#content + 1] = { name = k, value = v }
	end
	content[#content + 1] = {
		name = req.fileField,
		fileName = LrPathUtils.leafName(req.filePath),
		filePath = req.filePath,
		contentType = "image/jpeg",
	}
	return toResponse(LrHttp.postMultipart(req.url, content, nil, UPLOAD_TIMEOUT))
end

return M

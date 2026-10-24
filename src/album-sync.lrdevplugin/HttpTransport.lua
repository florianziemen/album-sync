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

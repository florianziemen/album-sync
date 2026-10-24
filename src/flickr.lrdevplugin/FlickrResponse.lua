--[[
Parse Flickr responses and classify failures (docs/DESIGN.md §8).

A response is { status = number|nil, body = string|nil, headers = table|nil }.
Errors are { class, code, message, requestId } with class one of:
  transient, throttle, auth, permanent, account, replace_not_pro
]]

local json = require("json")
local OAuth = require("OAuth")

local M = {}

local REST_CLASSES = {
	[14] = "throttle",
	[96] = "auth",
	[97] = "auth",
	[98] = "auth",
	[99] = "auth",
	[100] = "auth",
	[105] = "transient",
	[106] = "transient",
	[2] = "permanent",
	[4] = "permanent",
	[5] = "permanent",
	[8] = "permanent",
	[15] = "permanent",
	[6] = "account",
	[7] = "account",
}

local function requestId(resp)
	local h = resp and resp.headers
	return h and (h["x-flickr-api-request"] or h["X-Flickr-Api-Request"])
end

local function err(class, code, message, resp)
	return { class = class, code = code, message = message, requestId = requestId(resp) }
end

local function httpFailure(resp)
	if not resp or not resp.status then
		return err("transient", nil, resp and resp.message or "network error", resp)
	end
	if resp.status == 429 or resp.status >= 500 then
		return err("transient", resp.status, "HTTP " .. resp.status, resp)
	end
	return nil
end

--- OAuth token endpoints: form-encoded body. Returns table or nil, err.
function M.parseOAuth(resp)
	local failure = httpFailure(resp)
	if failure then
		return nil, failure
	end
	local form = OAuth.parseForm(resp.body)
	if form.oauth_problem then
		return nil, err("auth", form.oauth_problem, "OAuth problem: " .. form.oauth_problem, resp)
	end
	if resp.status ~= 200 or not form.oauth_token then
		return nil, err("transient", resp.status, "unexpected OAuth response", resp)
	end
	return form
end

--- REST with format=json&nojsoncallback=1. Returns decoded table or nil, err.
function M.parseRest(resp)
	local failure = httpFailure(resp)
	if failure then
		return nil, failure
	end
	local ok, data = pcall(json.decode, resp.body or "")
	if not ok or type(data) ~= "table" then
		-- Flickr answers some errors (e.g. unknown path) in XML even when JSON was requested.
		local code, msg = (resp.body or ""):match('<err code="(%d+)" msg="([^"]*)"')
		if code then
			code = tonumber(code)
			return nil, err(REST_CLASSES[code] or "permanent", code, msg, resp)
		end
		return nil, err("transient", resp.status, "unparseable response", resp)
	end
	if data.stat == "ok" then
		return data
	end
	local code = tonumber(data.code)
	return nil, err(REST_CLASSES[code] or "permanent", code, data.message or "unknown error", resp)
end

--- Human-readable one-line description of an error (no secrets).
function M.describe(e)
	local s = string.format("[%s] %s", tostring(e.class), tostring(e.message))
	if e.code then
		s = s .. " (code " .. tostring(e.code) .. ")"
	end
	if e.requestId then
		s = s .. "\nRequest ID: " .. e.requestId
	end
	return s
end

--- Upload/replace endpoints: always XML. Returns photo id (string) or nil, err.
function M.parseUpload(resp)
	local failure = httpFailure(resp)
	if failure then
		return nil, failure
	end
	local body = resp.body or ""
	local photoId = body:match('<rsp stat="ok">.-<photoid[^>]*>(%d+)</photoid>')
	if photoId then
		return photoId
	end
	local code, msg = body:match('<err code="(%d+)" msg="([^"]*)"')
	if not code then
		return nil, err("transient", resp.status, "unparseable upload response", resp)
	end
	code = tonumber(code)
	local e = err(REST_CLASSES[code] or "permanent", code, msg, resp)
	-- Code 14 may carry the number of seconds to wait before retrying.
	e.waitSeconds = tonumber(body:match("non_pro_desktop_upload_wait_time%D*(%d+)"))
	return nil, e
end

return M

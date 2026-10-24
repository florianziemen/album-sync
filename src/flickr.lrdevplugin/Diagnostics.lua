--[[
Formats HTTP exchanges for the log, with secrets redacted (AGENTS.md: never log tokens,
secrets or signatures). Used for full dumps whenever a Flickr call fails or surprises us.
]]

local M = {}

M.MAX_BODY = 65536

local SECRET_PARAMS = {
	oauth_signature = true,
	oauth_token = true,
	oauth_token_secret = true,
	oauth_verifier = true,
}

local function sortedKeys(t)
	local keys = {}
	for k in pairs(t or {}) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function mask(value)
	value = tostring(value)
	if #value <= 4 then
		return "<redacted>"
	end
	return value:sub(1, 4) .. "…<redacted>"
end

--- Copy of params with secrets removed and the consumer key shortened.
function M.redactParams(params)
	local out = {}
	for k, v in pairs(params or {}) do
		if SECRET_PARAMS[k] then
			out[k] = "<redacted>"
		elseif k == "oauth_consumer_key" then
			out[k] = mask(v)
		else
			out[k] = v
		end
	end
	return out
end

--- Remove token values from form-encoded OAuth bodies and similar text.
function M.redactBody(body)
	if type(body) ~= "string" then
		return tostring(body)
	end
	body = body:gsub('(oauth_token_secret=)[^&%s"]*', "%1<redacted>")
	body = body:gsub('(oauth_token=)[^&%s"]*', "%1<redacted>")
	return body
end

local function truncate(body)
	if #body > M.MAX_BODY then
		return body:sub(1, M.MAX_BODY) .. string.format("\n…[truncated, %d bytes total]", #body)
	end
	return body
end

--[[
Multi-line dump of one exchange.
req:  { method, url, params, filePath?, fileSize? }
resp: { status, headers, body, message, networkError }
err:  classified error from FlickrResponse (optional)
]]
function M.exchange(label, req, resp, elapsed, err)
	local lines = {}
	local function add(fmt, ...)
		lines[#lines + 1] = string.format(fmt, ...)
	end
	add("===== Flickr exchange failed: %s =====", tostring(label))
	if err then
		add("error: class=%s code=%s message=%s", tostring(err.class), tostring(err.code), tostring(err.message))
	end
	add("elapsed: %.3f s", elapsed or -1)
	add("request: %s %s", tostring(req.method), tostring(req.url))
	local params = M.redactParams(req.params)
	for _, k in ipairs(sortedKeys(params)) do
		add("  param %s=%s", tostring(k), tostring(params[k]))
	end
	if req.filePath then
		add("  file %s (%s bytes)", tostring(req.filePath), tostring(req.fileSize))
	end
	if not resp then
		add("response: none (transport returned nil)")
	else
		add("response: status=%s", tostring(resp.status))
		if resp.message then
			add("  transport error: %s", tostring(resp.message))
		end
		local ne = resp.networkError
		if type(ne) == "table" then
			for _, k in ipairs(sortedKeys(ne)) do
				add("  networkError.%s=%s", tostring(k), tostring(ne[k]))
			end
		end
		local headers = resp.headers or {}
		for _, k in ipairs(sortedKeys(headers)) do
			add("  header %s: %s", tostring(k), tostring(headers[k]))
		end
		local body = M.redactBody(resp.body or "")
		add("  body (%d bytes):", #(resp.body or ""))
		lines[#lines + 1] = truncate(body)
	end
	add("===== end =====")
	return table.concat(lines, "\n")
end

--- One-line summary for every call.
function M.summary(label, req, resp, elapsed, err)
	local headers = resp and resp.headers or {}
	return string.format(
		"flickr %s %s status=%s %.3fs bytes=%d rid=%s%s",
		tostring(req.method),
		tostring(label),
		tostring(resp and resp.status),
		elapsed or -1,
		#(resp and resp.body or ""),
		tostring(headers["x-flickr-api-request"]),
		err and (" FAIL " .. tostring(err.class) .. "/" .. tostring(err.code)) or ""
	)
end

return M

--[[
OAuth 1.0a request signing with HMAC-SHA1 (RFC 5849).

Pure Lua; nonce and timestamp are passed in by the caller.
]]

local Sha1 = require("Sha1")
local Base64 = require("Base64")

local M = {}

--- RFC 3986 percent-encoding: everything except unreserved characters.
function M.encode(s)
	return (tostring(s):gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function decode(s)
	s = s:gsub("+", " ")
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

--- Parse an application/x-www-form-urlencoded body into a table.
function M.parseForm(body)
	local t = {}
	for pair in (body or ""):gmatch("[^&]+") do
		local k, v = pair:match("^([^=]*)=?(.*)$")
		t[decode(k)] = decode(v)
	end
	return t
end

--- Encoded, sorted "k=v&k=v" string of a flat params table.
function M.normalize(params)
	local pairsList = {}
	for k, v in pairs(params) do
		pairsList[#pairsList + 1] = { M.encode(k), M.encode(v) }
	end
	table.sort(pairsList, function(a, b)
		if a[1] == b[1] then
			return a[2] < b[2]
		end
		return a[1] < b[1]
	end)
	local out = {}
	for i, p in ipairs(pairsList) do
		out[i] = p[1] .. "=" .. p[2]
	end
	return table.concat(out, "&")
end

--- Signature base string. `url` must not contain a query string.
function M.baseString(method, url, params)
	local scheme, host, path = url:match("^(%a+)://([^/]+)(.*)$")
	assert(scheme, "invalid url")
	local baseUrl = scheme:lower() .. "://" .. host:lower() .. (path ~= "" and path or "/")
	return method:upper() .. "&" .. M.encode(baseUrl) .. "&" .. M.encode(M.normalize(params))
end

--[[
Returns a new params table: `args.params` plus all oauth_* fields including oauth_signature.

args: method, url, params, consumerKey, consumerSecret, token, tokenSecret, nonce, timestamp
]]
function M.sign(args)
	local all = {}
	for k, v in pairs(args.params or {}) do
		all[k] = v
	end
	all.oauth_consumer_key = args.consumerKey
	all.oauth_nonce = args.nonce
	all.oauth_timestamp = tostring(args.timestamp)
	all.oauth_signature_method = "HMAC-SHA1"
	all.oauth_version = "1.0"
	if args.token then
		all.oauth_token = args.token
	end
	local key = M.encode(args.consumerSecret) .. "&" .. M.encode(args.tokenSecret or "")
	local base = M.baseString(args.method, args.url, all)
	all.oauth_signature = Base64.encode(Sha1.hmacBinary(key, base))
	return all
end

--- Random alphanumeric nonce; `random(n)` must return an integer in [1, n].
function M.nonce(random)
	local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	local out = {}
	for i = 1, 32 do
		local r = random(#chars)
		out[i] = chars:sub(r, r)
	end
	return table.concat(out)
end

return M

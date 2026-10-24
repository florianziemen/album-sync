--[[
Check OAuth signing against live Flickr without Lightroom.

  FLICKR_KEY=... FLICKR_SECRET=... luajit tools/request_token.lua

Requests a token (step 1 of the login flow) and prints the authorize URL.
Uses curl; secrets are read from the environment and never printed.
]]

package.path = "src/flockr.lrdevplugin/?.lua;" .. package.path

local FlickrAuth = require("FlickrAuth")
local OAuth = require("OAuth")

local key, secret = os.getenv("FLICKR_KEY"), os.getenv("FLICKR_SECRET")
if not key or not secret then
	io.stderr:write("set FLICKR_KEY and FLICKR_SECRET\n")
	os.exit(2)
end

local function shellQuote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function transport(req)
	local url = req.url .. "?" .. OAuth.normalize(req.params)
	local pipe = io.popen("curl -sS -m 30 -w '\\n%{http_code}' " .. shellQuote(url))
	local out = pipe:read("*a")
	pipe:close()
	local body, status = out:match("^(.*)\n(%d+)$")
	return { status = tonumber(status), body = body, message = body == nil and out or nil }
end

math.randomseed(os.time())
local auth = FlickrAuth.new({ transport = transport, now = os.time, random = math.random }, {
	consumerKey = key,
	consumerSecret = secret,
})

local rt, e = auth:requestToken()
if not rt then
	print(string.format("FAILED [%s] %s (code %s)", tostring(e.class), tostring(e.message), tostring(e.code)))
	os.exit(1)
end
print("OK: signing accepted by Flickr. Authorize URL (not needed for this check):")
print(FlickrAuth.authorizeUrl(rt, "delete"))

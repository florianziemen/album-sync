--[[
Builds the dependency table that core modules expect, backed by Lightroom APIs.
]]

local LrDate = import("LrDate")
local HttpTransport = require("HttpTransport")

-- LrDate counts from 2001-01-01 UTC.
local UNIX_OFFSET = 978307200

local seeded = false

return function()
	if not seeded then
		math.randomseed(math.floor((LrDate.currentTime() * 1000) % 2147483647))
		seeded = true
	end
	return {
		transport = HttpTransport.request,
		postMultipart = HttpTransport.postMultipart,
		now = function()
			return LrDate.currentTime() + UNIX_OFFSET
		end,
		random = function(n)
			return math.random(n)
		end,
	}
end

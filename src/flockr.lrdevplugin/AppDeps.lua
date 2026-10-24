--[[
Builds the dependency table that core modules expect, backed by Lightroom APIs.
]]

local LrDate = import("LrDate")
local LrFileUtils = import("LrFileUtils")
local LrLogger = import("LrLogger")
local LrTasks = import("LrTasks")
local HttpTransport = require("HttpTransport")

-- LrDate counts from 2001-01-01 UTC.
local UNIX_OFFSET = 978307200

local logger = LrLogger("flockr")
logger:enable("logfile")

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
		log = function(level, message)
			if level == "error" then
				logger:error(message)
			else
				logger:info(message)
			end
		end,
		fileSize = function(path)
			local attrs = path and LrFileUtils.fileAttributes(path)
			return attrs and attrs.fileSize
		end,
		pcall = LrTasks.pcall,
		sleep = LrTasks.sleep,
		random01 = math.random,
	}
end

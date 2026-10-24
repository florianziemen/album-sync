--[[
File storage for Journal: one journal per catalog in Lightroom's application-support folder,
written via a temp file and rename so a crash never leaves a half-written journal.
]]

local LrApplication = import("LrApplication")
local LrFileUtils = import("LrFileUtils")
local LrPathUtils = import("LrPathUtils")

local Sha1 = require("Sha1")

local M = {}

function M.path()
	local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath("appData"), "lrflickr")
	LrFileUtils.createAllDirectories(dir)
	local catalogKey = Sha1.hex(LrApplication.activeCatalog():getPath()):sub(1, 12)
	return LrPathUtils.child(dir, "journal-" .. catalogKey .. ".json")
end

--- Storage table for Journal.new.
function M.storage()
	local path = M.path()
	return {
		path = path,
		load = function()
			if LrFileUtils.exists(path) then
				return LrFileUtils.readFile(path)
			end
			return nil
		end,
		save = function(text)
			local tmp = path .. ".tmp"
			local f = assert(io.open(tmp, "wb"))
			f:write(text)
			f:close()
			-- os.rename replaces the target atomically on the same volume.
			local ok, err = os.rename(tmp, path)
			if not ok then
				error("could not write journal: " .. tostring(err))
			end
		end,
	}
end

return M

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

--[[
Storage table for Journal.new. Lightroom's Lua has no os.rename, so a save writes a temp file,
deletes the old journal and moves the temp file into place; load falls back to the temp file
if a crash happened between delete and move.
]]
function M.storage()
	local path = M.path()
	local tmp = path .. ".tmp"
	return {
		path = path,
		load = function()
			if LrFileUtils.exists(path) then
				return LrFileUtils.readFile(path)
			elseif LrFileUtils.exists(tmp) then
				return LrFileUtils.readFile(tmp)
			end
			return nil
		end,
		save = function(text)
			local f = assert(io.open(tmp, "wb"))
			f:write(text)
			f:close()
			if LrFileUtils.exists(path) then
				LrFileUtils.delete(path)
			end
			LrFileUtils.move(tmp, path)
			if not LrFileUtils.exists(path) then
				error("could not write journal " .. path)
			end
		end,
	}
end

return M

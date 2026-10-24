--[[
JSON file storage ({ load, save }) in Lightroom's application-support folder (lrflickr/),
written via a temp file so a crash never leaves a half-written file. Used for the upload
journal (per catalog) and the album cache (per account).
]]

local LrApplication = import("LrApplication")
local LrFileUtils = import("LrFileUtils")
local LrPathUtils = import("LrPathUtils")

local Sha1 = require("Sha1")

local M = {}

--- Short stable key for the active catalog (hash of its path).
function M.catalogKey()
	return Sha1.hex(LrApplication.activeCatalog():getPath()):sub(1, 12)
end

function M.path(fileName)
	local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath("appData"), "lrflickr")
	LrFileUtils.createAllDirectories(dir)
	return LrPathUtils.child(dir, fileName)
end

--[[
Storage table for Journal.new / FlickrIndex.Cache.new. Lightroom's Lua has no os.rename, so a save writes a temp file,
deletes the old journal and moves the temp file into place; load falls back to the temp file
if a crash happened between delete and move.
]]
function M.storage(fileName)
	local path = M.path(fileName)
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
				error("could not write " .. path)
			end
		end,
	}
end

return M

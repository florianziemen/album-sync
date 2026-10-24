--[[
Persistent queue of unclear matches (docs/DESIGN.md §7), one per catalog.
Item: { id = flickrId, candidates = { photo uuid... }, reason, album? }.
Storage is injected: { load() -> string|nil, save(string) }.
]]

local json = require("json")

local M = {}
M.__index = M

function M.new(storage)
	local self = setmetatable({ storage = storage, data = { version = 1, items = {} } }, M)
	local raw = storage.load()
	if raw and raw ~= "" then
		local ok, decoded = pcall(json.decode, raw)
		if ok and type(decoded) == "table" and type(decoded.items) == "table" then
			self.data = decoded
		end
	end
	return self
end

function M:items()
	return self.data.items
end

--- Add items not yet queued (by Flickr id). Returns the number added.
function M:add(items)
	local known = {}
	for _, q in ipairs(self.data.items) do
		known[q.id] = true
	end
	local added = 0
	for _, item in ipairs(items) do
		if not known[item.id] then
			known[item.id] = true
			self.data.items[#self.data.items + 1] = item
			added = added + 1
		end
	end
	if added > 0 then
		self.storage.save(json.encode(self.data))
	end
	return added
end

--- Remove an item (resolved or dismissed).
function M:remove(flickrId)
	for i, q in ipairs(self.data.items) do
		if q.id == flickrId then
			table.remove(self.data.items, i)
			self.storage.save(json.encode(self.data))
			return true
		end
	end
	return false
end

return M

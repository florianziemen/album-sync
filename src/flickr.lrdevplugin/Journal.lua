--[[
Persistent upload journal (docs/DESIGN.md §5 "Resume").

An entry is opened *before* an upload is sent and closed only after the Flickr id is stored in
the catalog. Whatever is left open after a crash or quit is reconciled on the next publish.
Keyed by LR photo uuid. Storage is injected: { load() -> string|nil, save(string) }.
]]

local json = require("json")

local M = {}
M.__index = M

function M.new(storage)
	local self = setmetatable({ storage = storage, data = { version = 1, entries = {} } }, M)
	local raw = storage.load()
	if raw and raw ~= "" then
		local ok, decoded = pcall(json.decode, raw)
		if ok and type(decoded) == "table" and type(decoded.entries) == "table" then
			self.data = decoded
		else
			self.corrupt = raw
		end
	end
	return self
end

function M:_save()
	self.storage.save(json.encode(self.data))
end

--- Start an entry (overwrites a stale one for the same key).
function M:open(key, fields)
	local entry = {}
	for k, v in pairs(fields or {}) do
		entry[k] = v
	end
	self.data.entries[key] = entry
	self:_save()
	return entry
end

function M:update(key, fields)
	local entry = self.data.entries[key]
	if not entry then
		return nil
	end
	for k, v in pairs(fields) do
		entry[k] = v
	end
	self:_save()
	return entry
end

function M:close(key)
	if self.data.entries[key] then
		self.data.entries[key] = nil
		self:_save()
	end
end

function M:get(key)
	return self.data.entries[key]
end

--- Open entries as array of { key, entry }, sorted by key.
function M:openEntries()
	local out = {}
	for key, entry in pairs(self.data.entries) do
		out[#out + 1] = { key = key, entry = entry }
	end
	table.sort(out, function(a, b)
		return a.key < b.key
	end)
	return out
end

return M

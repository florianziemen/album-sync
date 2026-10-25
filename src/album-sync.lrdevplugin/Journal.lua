--[[
Persistent upload journal (docs/DESIGN.md §5 "Resume").

An entry is opened *before* an upload is sent and closed only after the Flickr id is stored in
the catalog. Whatever is left open after a crash or quit is reconciled on the next publish.
Keyed by LR photo uuid. Storage is injected: { load() -> string|nil, save(string) }.

Parallel upload tasks share one journal and storage.save yields in Lightroom, so saves are
serialized: a save waits for the one in progress, then writes the latest state (or returns if
that write already covered it).

Dependencies (only needed when saves can overlap):
  sleep(seconds)   yield while another save is in progress
  pcall            LrTasks.pcall in Lightroom
]]

local json = require("json")

local M = {}
M.__index = M

function M.new(storage, deps)
	local self = setmetatable({
		storage = storage,
		deps = deps or {},
		data = { version = 1, entries = {} },
		requested = 0,
		written = 0,
	}, M)
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
	self.requested = self.requested + 1
	local mine = self.requested
	while self.saving do
		self.deps.sleep(0.02)
	end
	if self.written >= mine then
		return
	end
	self.saving = true
	local covers = self.requested
	local ok, err = (self.deps.pcall or pcall)(self.storage.save, json.encode(self.data))
	self.saving = false
	if not ok then
		error(err, 0)
	end
	self.written = covers
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

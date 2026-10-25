--[[
Persistent upload journal (docs/DESIGN.md §5 "Resume").

An entry is opened *before* an upload is sent and closed only after the Flickr id is stored in
the catalog. Whatever is left open after a crash or quit is reconciled on the next publish.
Keyed by LR photo uuid. Storage is injected: { load() -> string|nil, save(string) }.

Parallel upload tasks share one journal and storage.save yields in Lightroom, so saves are
serialized: a save waits for the one in progress, then writes the latest state (or returns if
that write already covered it).

Concurrent publish runs share one journal per catalog, each through its own lease (M:lease()).
A lease marks the entries it opened or claimed for reconciliation as live; other leases neither
reconcile nor reopen them.

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
		live = {}, -- key -> lease currently uploading or reconciling it
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
	self.live[key] = nil
	if self.data.entries[key] then
		self.data.entries[key] = nil
		self:_save()
	end
end

function M:get(key)
	return self.data.entries[key]
end

local function sortedEntries(entries, keep)
	local out = {}
	for key, entry in pairs(entries) do
		if keep(key) then
			out[#out + 1] = { key = key, entry = entry }
		end
	end
	table.sort(out, function(a, b)
		return a.key < b.key
	end)
	return out
end

--- Open entries as array of { key, entry }, sorted by key.
function M:openEntries()
	return sortedEntries(self.data.entries, function()
		return true
	end)
end

--- Without leases every open entry is left over from an earlier run.
function M:claimStale()
	return self:openEntries()
end

local Lease = {}
Lease.__index = Lease

--- A view of the journal for one publish run (same interface as the journal).
function M:lease()
	return setmetatable({ journal = self }, Lease)
end

--- Returns nil if another lease is uploading `key`.
function Lease:open(key, fields)
	local owner = self.journal.live[key]
	if owner and owner ~= self then
		return nil
	end
	self.journal.live[key] = self
	return self.journal:open(key, fields)
end

function Lease:update(key, fields)
	return self.journal:update(key, fields)
end

function Lease:close(key)
	self.journal:close(key)
end

function Lease:get(key)
	return self.journal:get(key)
end

--- Open entries no lease is working on (left over from an interrupted run).
function Lease:staleEntries()
	local live = self.journal.live
	return sortedEntries(self.journal.data.entries, function(key)
		return live[key] == nil
	end)
end

--- staleEntries(), claimed by this lease so that other runs leave them alone.
function Lease:claimStale()
	local out = self:staleEntries()
	for _, item in ipairs(out) do
		self.journal.live[item.key] = self
	end
	return out
end

--- Keys another lease is uploading or reconciling (set).
function Lease:busyKeys()
	local out = {}
	for key, owner in pairs(self.journal.live) do
		if owner ~= self then
			out[key] = true
		end
	end
	return out
end

--- Hand back everything this lease holds; entries still open become stale.
function Lease:release()
	for key, owner in pairs(self.journal.live) do
		if owner == self then
			self.journal.live[key] = nil
		end
	end
end

return M

--[[
Decides about several Flickr copies of one catalog photo by the byte size of their originals
(docs/DESIGN.md §7). Two exports of the same image are never byte-identical: Lightroom writes
export time, document ids and current metadata into each file. Observed differences: 8 to
about 1000 bytes on ~10 MB files. A real edit changes the compressed image data by far more.
So sizes within TOLERANCE count as the same image.
]]

local M = {}

M.TOLERANCE_RATIO = 0.0005 -- 0.05 % of the file size
M.TOLERANCE_MIN = 4096 -- bytes

function M.sameImage(a, b)
	local tolerance = math.max(M.TOLERANCE_MIN, M.TOLERANCE_RATIO * math.max(a, b))
	return math.abs(a - b) <= tolerance
end

--[[
ids: Flickr ids of the copies (at least 2). sizes: { [id] = bytes } (missing = unknown).
Returns { primary, duplicates = {id...} } when all sizes are known and equal (primary = the
oldest copy, i.e. the lowest id), or nil, reason.
]]
function M.decide(ids, sizes)
	if #ids < 2 then
		return nil, "single copy"
	end
	local size
	for _, id in ipairs(ids) do
		local s = sizes[id]
		if not s then
			return nil, "size unknown for " .. tostring(id)
		end
		if size and not M.sameImage(s, size) then
			return nil, string.format("different sizes (%d vs %d bytes: different versions)", size, s)
		end
		size = size or s
	end
	local primary
	for _, id in ipairs(ids) do
		if not primary or tonumber(id) < tonumber(primary) then
			primary = id
		end
	end
	local duplicates = {}
	for _, id in ipairs(ids) do
		if id ~= primary then
			duplicates[#duplicates + 1] = id
		end
	end
	table.sort(duplicates)
	return { primary = primary, duplicates = duplicates, bytes = size }
end

--[[
Groups queued review items by their single candidate (one catalog photo, several Flickr
copies). items: review queue items. linked: { [catalogKey] = flickrId } (copies linked
earlier count as members of the group). Returns array of { key, ids, queued = {id...} }.
]]
function M.groups(items, linked)
	local byKey, order = {}, {}
	for _, item in ipairs(items) do
		if item.reason == "duplicate on Flickr" and item.candidates and #item.candidates == 1 then
			local key = item.candidates[1]
			if not byKey[key] then
				byKey[key] = { key = key, ids = {}, queued = {}, seen = {} }
				order[#order + 1] = key
			end
			local g = byKey[key]
			if not g.seen[item.id] then
				g.seen[item.id] = true
				g.ids[#g.ids + 1] = item.id
				g.queued[#g.queued + 1] = item.id
			end
		end
	end
	local out = {}
	for _, key in ipairs(order) do
		local g = byKey[key]
		local already = linked and linked[key]
		if already and not g.seen[tostring(already)] then
			table.insert(g.ids, 1, tostring(already))
			g.linkedId = tostring(already)
		end
		g.seen = nil
		out[#out + 1] = g
	end
	return out
end

-- True when two open files (anything with :read(n)) have the same content.
function M.sameContent(a, b)
	while true do
		local x, y = a:read(1048576), b:read(1048576)
		if x ~= y then
			return false
		elseif x == nil then
			return true
		end
	end
end

--[[
Explains how candidate catalog photos relate, so the review can tell copies apart.
infos: array of { path, size, virtual (bool), copyName }. sameFile(i, j): compares the contents
of infos[i] and infos[j] (only asked for different paths of equal size). Returns an array of
notes (strings, "" when nothing to say), one per candidate; candidates are numbered from 1.
]]
function M.describe(infos, sameFile)
	local notes = {}
	for i, info in ipairs(infos) do
		local parts = {}
		if info.virtual then
			parts[#parts + 1] = "virtual copy" .. (info.copyName and (' "' .. info.copyName .. '"') or "")
		end
		for j, other in ipairs(infos) do
			if j ~= i and info.path and info.path == other.path then
				parts[#parts + 1] = "same original file as " .. j
			elseif j ~= i and info.path and other.path and info.size and info.size == other.size then
				if sameFile(i, j) then
					parts[#parts + 1] = "identical file to " .. j .. " (imported twice)"
				end
			end
		end
		notes[i] = table.concat(parts, "; ")
	end
	return notes
end

return M

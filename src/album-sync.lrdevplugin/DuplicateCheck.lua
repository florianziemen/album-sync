--[[
Decides about several Flickr copies of one catalog photo by the byte size of their originals
(docs/DESIGN.md §7): identical size means the same file was uploaded more than once.
]]

local M = {}

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
		if size and s ~= size then
			return nil, "different sizes (different versions)"
		end
		size = s
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

return M

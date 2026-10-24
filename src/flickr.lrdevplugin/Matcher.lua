--[[
Matches Flickr photos to catalog photos (docs/DESIGN.md §7, tiers 2 and 3a).

catalog: array of { key, taken, names, aspect }
  taken   wall-clock "YYYY-MM-DD HH:MM:SS" (LR capture time, local, seconds)
  names   array of file names (current and original/preserved), any case, with extension
  aspect  width/height of the cropped photo (optional)
flickr: array of { id, title, taken, takenUnknown, w, h } (FlickrApi.photoRecord)

Rules: candidates = catalog photos taken in the same second.
  exactly one candidate whose name equals the title (case-insensitive, extension ignored)
    -> match "time+title"; several (virtual copies) -> the one with the same aspect ratio
    -> match "time+title+aspect"
  otherwise exactly one candidate with the same aspect ratio (1%, either orientation)
    -> match "time+aspect"
  candidates but no unique decision -> review
  no candidates -> notInCatalog (ignored)
A catalog photo matched by several Flickr photos (duplicates on Flickr) -> all to review.
]]

local M = {}

M.ASPECT_TOLERANCE = 0.01

local function base(name)
	return ((name or ""):lower():gsub("%.[^.]*$", ""))
end

local function aspectMatches(p, c)
	if not (p.w and p.h and p.h > 0 and c.aspect and c.aspect > 0) then
		return nil -- unknown
	end
	local r = p.w / p.h
	local tol = M.ASPECT_TOLERANCE
	return math.abs(r - c.aspect) / c.aspect <= tol or math.abs(1 / r - c.aspect) / c.aspect <= tol
end

--[[
Returns {
  matches = { [flickrId] = { key, how } },
  review = array of { id, candidates = {key...}, reason },
  notInCatalog = array of flickr ids,
}
]]
function M.match(catalog, flickr)
	local byTaken = {}
	for _, c in ipairs(catalog) do
		if c.taken then
			byTaken[c.taken] = byTaken[c.taken] or {}
			table.insert(byTaken[c.taken], c)
		end
	end

	local result = { matches = {}, review = {}, notInCatalog = {} }
	local claimedBy = {} -- catalog key -> array of flickr ids
	local function keys(list)
		local out = {}
		for i, c in ipairs(list) do
			out[i] = c.key
		end
		return out
	end
	local function review(p, cands, reason)
		result.review[#result.review + 1] = { id = p.id, candidates = keys(cands), reason = reason }
	end
	local function match(p, c, how)
		result.matches[p.id] = { key = c.key, how = how }
		claimedBy[c.key] = claimedBy[c.key] or {}
		table.insert(claimedBy[c.key], p.id)
	end

	for _, p in ipairs(flickr) do
		local cands = (not p.takenUnknown and p.taken) and byTaken[p.taken] or nil
		if not cands then
			result.notInCatalog[#result.notInCatalog + 1] = p.id
		else
			local title = base(p.title)
			local byTitle = {}
			for _, c in ipairs(cands) do
				for _, n in ipairs(c.names or {}) do
					if title ~= "" and base(n) == title then
						byTitle[#byTitle + 1] = c
						break
					end
				end
			end
			if #byTitle == 1 then
				match(p, byTitle[1], "time+title")
			elseif #byTitle > 1 then
				-- Virtual copies share time and name; a different crop can still tell them apart.
				local byBoth = {}
				for _, c in ipairs(byTitle) do
					if aspectMatches(p, c) then
						byBoth[#byBoth + 1] = c
					end
				end
				if #byBoth == 1 then
					match(p, byBoth[1], "time+title+aspect")
				else
					review(p, #byBoth > 1 and byBoth or byTitle, "same time and title (virtual copies?)")
				end
			else
				local byAspect, unknown = {}, false
				for _, c in ipairs(cands) do
					local m = aspectMatches(p, c)
					if m == nil then
						unknown = true
					elseif m then
						byAspect[#byAspect + 1] = c
					end
				end
				if #byAspect == 1 and not unknown then
					match(p, byAspect[1], "time+aspect")
				elseif #byAspect == 0 and not unknown then
					review(p, cands, "same time, different crop or format")
				else
					review(p, #byAspect > 0 and byAspect or cands, "same time, title differs")
				end
			end
		end
	end

	-- Duplicates on Flickr: one catalog photo, several Flickr photos -> review all of them.
	for key, ids in pairs(claimedBy) do
		if #ids > 1 then
			for _, id in ipairs(ids) do
				result.matches[id] = nil
				result.review[#result.review + 1] = { id = id, candidates = { key }, reason = "duplicate on Flickr" }
			end
		end
	end
	table.sort(result.review, function(a, b)
		return a.id < b.id
	end)
	return result
end

--- Fraction of a second from an EXIF SubSecTime string ("69" -> 0.69, "690" -> 0.69).
function M.subsecFraction(subsec)
	local digits = tostring(subsec or ""):match("^%s*(%d+)")
	if not digits then
		return nil
	end
	return tonumber(digits) / 10 ^ #digits
end

--[[
Tie-break with the EXIF of the Flickr original (tier 3). exif: FlickrApi:exif result.
candidates: Matcher catalog records, optionally with subsec (fraction) and serial.
Returns key, how or nil.
Order: camera serial narrows the set; then preserved/original file name; then sub-second.
]]
function M.resolveByExif(exif, candidates)
	local pool = candidates
	local serial = exif.SerialNumber
	if serial and serial ~= "" then
		local same = {}
		for _, c in ipairs(candidates) do
			if c.serial and tostring(c.serial) == serial then
				same[#same + 1] = c
			end
		end
		if #same > 0 then
			pool = same
		end
	end
	if #pool == 1 and pool ~= candidates then
		return pool[1].key, "exif:serial"
	end
	local preserved = exif.PreservedFileName or exif.RawFileName
	if preserved and preserved ~= "" then
		local hits = {}
		for _, c in ipairs(pool) do
			for _, n in ipairs(c.names or {}) do
				if base(n) == base(preserved) then
					hits[#hits + 1] = c
					break
				end
			end
		end
		if #hits == 1 then
			return hits[1].key, "exif:filename"
		end
	end
	local frac = M.subsecFraction(exif.SubSecTimeOriginal)
	if frac then
		local hits = {}
		for _, c in ipairs(pool) do
			if c.subsec and math.abs(c.subsec - frac) < 0.006 then
				hits[#hits + 1] = c
			end
		end
		if #hits == 1 then
			return hits[1].key, "exif:subsec"
		end
	end
	return nil
end

return M

--[[
What is on Flickr: albums with their photos (cached), and photos by date taken
(docs/DESIGN.md §7). Dates are Flickr's wall-clock "YYYY-MM-DD HH:MM:SS" strings, which
compare correctly as strings.
]]

local json = require("json")

local M = {}

-- Flickr returns at most ~4000 results per search; split windows above this.
M.WINDOW_LIMIT = 3500

-- Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
local function daysFromCivil(y, m, d)
	if m <= 2 then
		y = y - 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = math.floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function civilFromDays(z)
	z = z + 719468
	local era = math.floor(z / 146097)
	local doe = z - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = mp < 10 and mp + 3 or mp - 9
	if m <= 2 then
		y = y + 1
	end
	return y, m, d
end

--- "YYYY-MM-DD HH:MM:SS" -> seconds (wall clock, no time zone).
function M.toSeconds(s)
	local y, mo, d, h, mi, se = s:match("^(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
	assert(y, "bad date: " .. tostring(s))
	return daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400 + h * 3600 + mi * 60 + se
end

function M.fromSeconds(n)
	local days = math.floor(n / 86400)
	local rest = n - days * 86400
	local y, m, d = civilFromDays(days)
	return string.format(
		"%04d-%02d-%02d %02d:%02d:%02d",
		y,
		m,
		d,
		math.floor(rest / 3600),
		math.floor(rest % 3600 / 60),
		rest % 60
	)
end

--[[
All own photos taken in [minTaken, maxTaken], splitting the window while a query would exceed
WINDOW_LIMIT. Returns array (deduplicated by id) or nil, err.
]]
function M.photosTaken(api, minTaken, maxTaken, progress)
	local out, seen = {}, {}
	local function add(photos)
		for _, p in ipairs(photos) do
			if not seen[p.id] then
				seen[p.id] = true
				out[#out + 1] = p
			end
		end
	end
	local function window(lo, hi)
		local first, e = api:photosTakenPage(lo, hi, 1)
		if not first then
			return nil, e
		end
		local loS, hiS = M.toSeconds(lo), M.toSeconds(hi)
		if first.total > M.WINDOW_LIMIT and hiS > loS then
			local mid = loS + math.floor((hiS - loS) / 2)
			local ok, err = window(lo, M.fromSeconds(mid))
			if not ok then
				return nil, err
			end
			return window(M.fromSeconds(mid + 1), hi)
		end
		add(first.photos)
		for page = 2, first.pages do
			local r, pe = api:photosTakenPage(lo, hi, page)
			if not r then
				return nil, pe
			end
			add(r.photos)
		end
		if progress then
			progress(#out)
		end
		return true
	end
	local ok, e = window(minTaken, maxTaken)
	if not ok then
		return nil, e
	end
	return out
end

--- Album cache: { [albumId] = { updated, photos } } in injected storage { load, save }.
local Cache = {}
Cache.__index = Cache
M.Cache = Cache

function Cache.new(storage)
	local self = setmetatable({ storage = storage, data = { version = 1, albums = {} } }, Cache)
	local raw = storage.load()
	if raw and raw ~= "" then
		local ok, decoded = pcall(json.decode, raw)
		if ok and type(decoded) == "table" and type(decoded.albums) == "table" then
			self.data = decoded
		end
	end
	return self
end

function Cache:get(albumId, updated)
	local entry = self.data.albums[albumId]
	if entry and updated and entry.updated == updated then
		return entry.photos
	end
	return nil
end

function Cache:put(albumId, updated, photos)
	self.data.albums[albumId] = { updated = updated, photos = photos }
end

--- Drop albums that no longer exist; then write.
function Cache:save(existingIds)
	if existingIds then
		for id in pairs(self.data.albums) do
			if not existingIds[id] then
				self.data.albums[id] = nil
			end
		end
	end
	self.storage.save(json.encode(self.data))
end

--[[
All albums with photos, using the cache for albums whose date_update did not change.
Returns array of { id, title, count, updated, photos, newest, year, fromCache } or nil, err.
progress(i, n, album) is called per album.
]]
function M.albums(api, cache, progress)
	local list, e = api:albums()
	if not list then
		return nil, e
	end
	local existing = {}
	for i, album in ipairs(list) do
		existing[album.id] = true
		if progress then
			progress(i, #list, album)
		end
		local photos = cache:get(album.id, album.updated)
		album.fromCache = photos ~= nil
		if not photos then
			local fetchErr
			photos, fetchErr = api:albumPhotos(album.id)
			if not photos then
				return nil, fetchErr
			end
			cache:put(album.id, album.updated, photos)
		end
		album.photos = photos
		local newest
		for _, p in ipairs(photos) do
			if p.taken and not p.takenUnknown and (not newest or p.taken > newest) then
				newest = p.taken
			end
		end
		album.newest = newest
		album.year = newest and tonumber(newest:sub(1, 4)) or nil
	end
	cache:save(existing)
	return list
end

--- Photos of `album` taken in [minTaken, maxTaken].
function M.inRange(album, minTaken, maxTaken)
	local out = {}
	for _, p in ipairs(album.photos or {}) do
		if p.taken and not p.takenUnknown and p.taken >= minTaken and p.taken <= maxTaken then
			out[#out + 1] = p
		end
	end
	return out
end

--- Albums grouped by year (newest year first): array of { year, albums } (year nil = unknown).
function M.byYear(albums)
	local groups, order = {}, {}
	for _, a in ipairs(albums) do
		local key = a.year or "unknown"
		if not groups[key] then
			groups[key] = { year = a.year, albums = {} }
			order[#order + 1] = key
		end
		table.insert(groups[key].albums, a)
	end
	table.sort(order, function(x, y)
		if x == "unknown" then
			return false
		elseif y == "unknown" then
			return true
		end
		return x > y
	end)
	local out = {}
	for i, key in ipairs(order) do
		table.sort(groups[key].albums, function(a, b)
			return (a.newest or "") > (b.newest or "")
		end)
		out[i] = groups[key]
	end
	return out
end

return M

local FlickrApi = require("FlickrApi")
local FlickrIndex = require("FlickrIndex")
local h = require("tests.helpers")

local ACCESS = { token = "AT", tokenSecret = "AS" }

local function memoryStorage()
	local store = {}
	return {
		store = store,
		load = function()
			return store.value
		end,
		save = function(s)
			store.value = s
		end,
	}
end

describe("FlickrIndex dates", function()
	it("round-trips wall-clock timestamps", function()
		for _, s in ipairs({
			"1970-01-01 00:00:00",
			"2000-02-29 12:34:56",
			"2026-10-24 14:26:21",
			"1999-12-31 23:59:59",
		}) do
			assert.equal(s, FlickrIndex.fromSeconds(FlickrIndex.toSeconds(s)))
		end
		assert.equal(86400, FlickrIndex.toSeconds("1970-01-02 00:00:00"))
	end)
end)

describe("FlickrApi album listing", function()
	it("parses albums and album photos", function()
		local deps = h.fakeDeps({
			{
				status = 200,
				body = '{"photosets":{"page":1,"pages":1,"photoset":[{"id":"7","photos":"3","videos":0,'
					.. '"title":{"_content":"Trip"},"date_update":"1700000000","date_create":"1600000000"}]},"stat":"ok"}',
			},
			{
				status = 200,
				body = '{"photoset":{"id":"7","page":1,"pages":1,"photo":[{"id":"1","title":"IMG_1",'
					.. '"datetaken":"2019-05-01 10:00:00","datetakenunknown":"0","o_width":"6000","o_height":"4000"}]},'
					.. '"stat":"ok"}',
			},
		})
		local api = FlickrApi.new(deps, h.CREDS, ACCESS)
		assert.same(
			{ { id = "7", title = "Trip", count = 3, updated = 1700000000, created = 1600000000 } },
			api:albums()
		)
		assert.same({
			{ id = "1", title = "IMG_1", taken = "2019-05-01 10:00:00", takenUnknown = false, w = 6000, h = 4000 },
		}, api:albumPhotos("7"))
		assert.equal("date_taken,o_dims,url_l", deps.calls[2].params.extras)
	end)
end)

describe("FlickrIndex.photosTaken", function()
	it("splits windows above the limit and deduplicates", function()
		local old = FlickrIndex.WINDOW_LIMIT
		FlickrIndex.WINDOW_LIMIT = 2
		local calls = {}
		local all = {
			{ id = "a", taken = "2019-01-01 00:00:00" },
			{ id = "b", taken = "2019-06-01 00:00:00" },
			{ id = "c", taken = "2019-12-31 00:00:00" },
		}
		local api = {
			photosTakenPage = function(_, lo, hi, page)
				calls[#calls + 1] = lo .. "|" .. hi .. "|" .. page
				local hits = {}
				for _, p in ipairs(all) do
					if p.taken >= lo and p.taken <= hi then
						hits[#hits + 1] = p
					end
				end
				return { photos = hits, page = 1, pages = 1, total = #hits }
			end,
		}
		local photos = FlickrIndex.photosTaken(api, "2019-01-01 00:00:00", "2019-12-31 23:59:59")
		FlickrIndex.WINDOW_LIMIT = old
		assert.equal(3, #photos)
		assert.is_true(#calls > 1)
	end)
end)

describe("FlickrIndex.albums", function()
	local function fakeApi(albums, photosById)
		local fetched = {}
		return {
			fetched = fetched,
			albums = function()
				return albums
			end,
			albumPhotos = function(_, id)
				fetched[#fetched + 1] = id
				return photosById[id]
			end,
		}
	end

	it("computes newest photo and year, uses the cache for unchanged albums", function()
		local storage = memoryStorage()
		local photos = {
			A = {
				{ id = "1", taken = "2018-03-01 10:00:00" },
				{ id = "2", taken = "2019-07-01 10:00:00" },
				{ id = "3", taken = "2030-01-01 00:00:00", takenUnknown = true },
			},
			B = { { id = "4", taken = "2017-01-01 00:00:00" } },
		}
		local api = fakeApi({ { id = "A", updated = 1 }, { id = "B", updated = 1 } }, photos)
		local albums = FlickrIndex.albums(api, FlickrIndex.Cache.new(storage))
		assert.equal("2019-07-01 10:00:00", albums[1].newest)
		assert.equal(2019, albums[1].year)
		assert.same({ "A", "B" }, api.fetched)

		-- second run: A unchanged, B updated, C deleted from the list
		local api2 = fakeApi({ { id = "A", updated = 1 }, { id = "B", updated = 2 } }, photos)
		local again = FlickrIndex.albums(api2, FlickrIndex.Cache.new(storage))
		assert.same({ "B" }, api2.fetched)
		assert.is_true(again[1].fromCache)
		assert.is_false(again[2].fromCache)
	end)

	it("skips albums unchanged since before the range", function()
		local api = fakeApi(
			{ { id = "Old", updated = 100 }, { id = "New", updated = 300 } },
			{ New = { { id = "1", taken = "2019-01-01 00:00:00" } } }
		)
		local albums = FlickrIndex.albums(api, FlickrIndex.Cache.new(memoryStorage()), nil, 200)
		assert.same({ "New" }, api.fetched)
		assert.is_true(albums[1].skipped)
		assert.same({}, albums[1].photos)
		assert.is_nil(albums[2].skipped)
	end)

	it("filters by date range and groups by year", function()
		local a = {
			id = "A",
			year = 2019,
			newest = "2019-07-01 10:00:00",
			photos = {
				{ id = "1", taken = "2018-12-31 23:59:59" },
				{ id = "2", taken = "2019-07-01 10:00:00" },
			},
		}
		local b = { id = "B", year = 2019, newest = "2019-08-01 00:00:00", photos = {} }
		local c = { id = "C", year = 2018, newest = "2018-01-01 00:00:00", photos = {} }
		local d = { id = "D", photos = {} }
		assert.same(
			{ "2" },
			(function()
				local ids = {}
				for i, p in ipairs(FlickrIndex.inRange(a, "2019-01-01 00:00:00", "2019-12-31 23:59:59")) do
					ids[i] = p.id
				end
				return ids
			end)()
		)
		local groups = FlickrIndex.byYear({ c, a, d, b })
		assert.equal(2019, groups[1].year)
		assert.same({ "B", "A" }, { groups[1].albums[1].id, groups[1].albums[2].id })
		assert.equal(2018, groups[2].year)
		assert.is_nil(groups[3].year)
	end)
end)

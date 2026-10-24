local Matcher = require("Matcher")

local T = "2019-05-01 10:00:00"

local function photo(id, title, taken, w, h)
	return { id = id, title = title, taken = taken or T, w = w or 6000, h = h or 4000 }
end

describe("Matcher", function()
	it("matches by time and title, also via the original file name", function()
		local catalog = {
			{ key = "A", taken = T, names = { "20190501-FLO_5240.CR3", "FLO_5240.CR3" }, aspect = 1.5 },
			{ key = "B", taken = T, names = { "20190501-FLO_5241.CR3", "FLO_5241.CR3" }, aspect = 1.5 },
		}
		local r = Matcher.match(catalog, { photo("1", "FLO_5240"), photo("2", "20190501-flo_5241") })
		assert.same({ key = "A", how = "time+title" }, r.matches["1"])
		assert.same({ key = "B", how = "time+title" }, r.matches["2"])
		assert.same({}, r.review)
	end)

	it("falls back to a unique aspect ratio when the title differs (renamed, either orientation)", function()
		local catalog = {
			{ key = "A", taken = T, names = { "x.CR3" }, aspect = 1.5 },
			{ key = "B", taken = T, names = { "y.CR3" }, aspect = 1.0 },
		}
		local r = Matcher.match(catalog, { photo("1", "Sunset", T, 4000, 6000) })
		assert.same({ key = "A", how = "time+aspect" }, r.matches["1"])
	end)

	it("sends ties and weak evidence to review", function()
		local catalog = {
			{ key = "A", taken = T, names = { "IMG_1.CR3" }, aspect = 1.5 },
			{ key = "A2", taken = T, names = { "IMG_1.CR3" }, aspect = 1.5 }, -- virtual copy
			{ key = "B", taken = "2019-05-01 11:00:00", names = { "IMG_2.CR3" } }, -- no aspect known
		}
		local r = Matcher.match(catalog, {
			photo("1", "IMG_1"),
			photo("2", "renamed", "2019-05-01 11:00:00"),
		})
		assert.same({}, r.matches)
		assert.equal(2, #r.review)
		assert.same({ "A", "A2" }, r.review[1].candidates)
		assert.truthy(r.review[1].reason:find("virtual", 1, true))
		assert.same({ "B" }, r.review[2].candidates)
	end)

	it("tells virtual copies apart by crop", function()
		local catalog = {
			{ key = "M", taken = T, names = { "IMG_1.CR3" }, aspect = 1.5 },
			{ key = "V", taken = T, names = { "IMG_1.CR3" }, aspect = 1.0 }, -- square crop
		}
		local r = Matcher.match(catalog, { photo("1", "IMG_1", T, 6000, 4000), photo("2", "IMG_1", T, 4000, 4000) })
		assert.same({ key = "M", how = "time+title+aspect" }, r.matches["1"])
		assert.same({ key = "V", how = "time+title+aspect" }, r.matches["2"])
	end)

	it("reviews a single candidate with a different crop instead of guessing", function()
		local catalog = { { key = "A", taken = T, names = { "x.CR3" }, aspect = 1.0 } }
		local r = Matcher.match(catalog, { photo("1", "other", T, 6000, 4000) })
		assert.same({}, r.matches)
		assert.equal("same time, different crop or format", r.review[1].reason)
	end)

	it("ignores Flickr photos without a catalog candidate or without a date", function()
		local catalog = { { key = "A", taken = T, names = { "IMG_1.CR3" } } }
		local r = Matcher.match(catalog, {
			photo("1", "IMG_1", "2001-01-01 00:00:00"),
			{ id = "2", title = "IMG_1", taken = T, takenUnknown = true },
		})
		assert.same({ "1", "2" }, r.notInCatalog)
	end)

	it("reviews all Flickr duplicates of one catalog photo", function()
		local catalog = { { key = "A", taken = T, names = { "IMG_1.CR3" }, aspect = 1.5 } }
		local r = Matcher.match(catalog, { photo("1", "IMG_1"), photo("2", "IMG_1") })
		assert.same({}, r.matches)
		assert.equal(2, #r.review)
		assert.equal("duplicate on Flickr", r.review[1].reason)
	end)
end)

describe("Matcher.resolveByExif", function()
	local cands = {
		{ key = "A", names = { "20260911-FLO_100.CR3", "FLO_100.CR3" }, subsec = 0.12, serial = "111" },
		{ key = "B", names = { "20260911-FLO_101.CR3", "FLO_101.CR3" }, subsec = 0.69, serial = "111" },
		{ key = "C", names = { "IMG_5.HEIC" }, subsec = 0.69, serial = "999" },
	}

	it("uses the preserved file name", function()
		assert.equal("B", (Matcher.resolveByExif({ PreservedFileName = "FLO_101.CR3" }, cands)))
	end)

	it("uses sub-seconds within the camera's serial", function()
		local key, how = Matcher.resolveByExif({ SubSecTimeOriginal = "69", SerialNumber = "111" }, cands)
		assert.equal("B", key)
		assert.equal("exif:subsec", how)
	end)

	it("uses a unique camera serial", function()
		assert.equal("C", (Matcher.resolveByExif({ SerialNumber = "999" }, cands)))
	end)

	it("gives up when nothing is unique", function()
		assert.is_nil(Matcher.resolveByExif({ SubSecTimeOriginal = "69" }, cands))
		assert.is_nil(Matcher.resolveByExif({}, cands))
	end)

	it("parses sub-second strings", function()
		assert.equal(0.69, Matcher.subsecFraction("69"))
		assert.equal(0.69, Matcher.subsecFraction("690"))
		assert.equal(0.05, Matcher.subsecFraction("05"))
		assert.is_nil(Matcher.subsecFraction(nil))
	end)
end)

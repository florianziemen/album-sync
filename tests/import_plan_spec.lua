local ImportPlan = require("ImportPlan")

local function p(id, title, taken)
	return { id = id, title = title, taken = taken, w = 6000, h = 4000 }
end

local RANGE = { min = "2019-01-01 00:00:00", max = "2019-12-31 23:59:59" }

describe("ImportPlan", function()
	local catalog = {
		{ key = "u1", taken = "2019-03-01 10:00:00", names = { "IMG_1.CR3" }, aspect = 1.5 },
		{ key = "u2", taken = "2019-03-01 11:00:00", names = { "IMG_2.CR3" }, aspect = 1.5 },
		{ key = "u3", taken = "2019-03-01 12:00:00", names = { "IMG_3.CR3" }, aspect = 1.5 },
		{ key = "u4", taken = "2019-03-01 13:00:00", names = { "IMG_4.CR3" }, aspect = 1.5 },
	}
	local albums = {
		{
			id = "A",
			title = "Spring",
			photos = { p("1", "IMG_1", "2019-03-01 10:00:00"), p("9", "x", "2018-05-01 00:00:00") },
		},
		{ id = "B", title = "Old", photos = { p("8", "IMG_8", "2017-01-01 00:00:00") } },
		{
			id = "C",
			title = "Both",
			photos = { p("2", "IMG_2", "2019-03-01 11:00:00"), p("1", "IMG_1", "2019-03-01 10:00:00") },
		},
	}
	local photostream = {
		p("1", "IMG_1", "2019-03-01 10:00:00"),
		p("2", "IMG_2", "2019-03-01 11:00:00"),
		p("3", "IMG_3", "2019-03-01 12:00:00"), -- in no album
		p("4", "IMG_4", "2019-03-01 13:00:00"), -- conflicts with an existing link
		p("5", "unknown", "2019-07-07 07:07:07"), -- not in catalog
	}

	it("keeps in-range albums, matches across albums and the photostream", function()
		local r = ImportPlan.build(albums, photostream, catalog, RANGE, { u4 = "777" })
		assert.equal(2, #r.albums)
		assert.equal("A", r.albums[1].album.id)
		assert.equal(1, r.albums[1].inRange)
		assert.same({ { id = "1", key = "u1", how = "time+title" } }, r.albums[1].matches)
		assert.equal(2, #r.albums[2].matches)
		assert.same({ { id = "3", key = "u3", how = "time+title" } }, r.photostream.matches)
		assert.equal(1, #r.review)
		assert.truthy(r.review[1].reason:find("already linked to Flickr photo 777", 1, true))
		assert.same(
			{ albumsTotal = 3, albumsInRange = 2, flickrInRange = 5, matched = 3, review = 1, notInCatalog = 1 },
			r.stats
		)
	end)

	it("derives the catalog range and wall-clock times", function()
		assert.same({ min = "2019-03-01 10:00:00", max = "2019-03-01 13:00:00" }, ImportPlan.range(catalog))
		assert.equal("2019-05-01 10:00:00", ImportPlan.wallClock("2019-05-01T10:00:00.12+02:00"))
		assert.equal("2019-05-01 10:00:00", ImportPlan.wallClock("2019-05-01T10:00:00"))
		assert.is_nil(ImportPlan.wallClock("2019-05-01"))
		assert.is_nil(ImportPlan.wallClock(nil))
	end)
end)

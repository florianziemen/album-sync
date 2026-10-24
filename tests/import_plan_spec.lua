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
		assert.equal("IMG_4", r.review[1].title)
		assert.equal("2019-03-01 13:00:00", r.review[1].taken)
		assert.same({
			albumsTotal = 3,
			albumsInRange = 2,
			flickrInRange = 5,
			matched = 3,
			alreadyLinked = 0,
			review = 1,
			notInCatalog = 1,
		}, r.stats)
	end)

	it("leaves pairs linked earlier out of matching", function()
		local r = ImportPlan.build(albums, photostream, catalog, RANGE, { u1 = "1", u4 = "4" })
		assert.equal(2, r.stats.alreadyLinked)
		assert.equal(0, r.stats.review) -- u4 <-> 4 is settled, not a conflict any more
		for _, a in ipairs(r.albums) do
			for _, m in ipairs(a.matches) do
				assert.are_not.equal("1", m.id)
			end
		end
	end)

	it("treats Flickr ids linked only in collections as settled", function()
		local r = ImportPlan.build(albums, photostream, catalog, RANGE, {}, { ["3"] = true })
		assert.equal(1, r.stats.alreadyLinked)
		-- photo 3 is settled, not matched again; photo 4 (no link here) still matches
		assert.same({ { id = "4", key = "u4", how = "time+title" } }, r.photostream.matches)
	end)

	it("derives the catalog range and wall-clock times", function()
		assert.same({ min = "2019-03-01 10:00:00", max = "2019-03-01 13:00:00" }, ImportPlan.range(catalog))
		assert.equal("2019-05-01 10:00:00", ImportPlan.wallClock("2019-05-01T10:00:00.12+02:00"))
		assert.equal("2019-05-01 10:00:00", ImportPlan.wallClock("2019-05-01T10:00:00"))
		assert.is_nil(ImportPlan.wallClock("2019-05-01"))
		assert.is_nil(ImportPlan.wallClock(nil))
	end)
end)

describe("ImportPlan.promote", function()
	it("moves a resolved review item into its albums or the photostream", function()
		local catalog = {
			{ key = "u1", taken = "2019-03-01 10:00:00", names = { "a.CR3" }, aspect = 1.5 },
			{ key = "u2", taken = "2019-03-01 10:00:00", names = { "b.CR3" }, aspect = 1.5 },
		}
		local function ph(id)
			return { id = id, title = "renamed", taken = "2019-03-01 10:00:00", w = 6000, h = 4000 }
		end
		local albums = { { id = "A", title = "Album", photos = { ph("1") } } }
		local plan = ImportPlan.build(albums, { ph("1"), ph("2") }, catalog, RANGE, {})
		assert.equal(2, #plan.review)
		ImportPlan.promote(plan, "1", "u1", "exif:filename")
		ImportPlan.promote(plan, "2", "u2", "user")
		assert.same({ { id = "1", key = "u1", how = "exif:filename" } }, plan.albums[1].matches)
		assert.same({}, plan.albums[1].review)
		assert.same({ { id = "2", key = "u2", how = "user" } }, plan.photostream.matches)
		assert.same({}, plan.review)
		assert.equal(2, plan.stats.matched)
		assert.equal(0, plan.stats.review)
	end)
end)

describe("ImportPlan duplicates", function()
	local catalog = { { key = "u1", taken = "2019-03-01 10:00:00", names = { "IMG_1.CR3" }, aspect = 1.5 } }
	local function ph(id)
		return { id = id, title = "IMG_1", taken = "2019-03-01 10:00:00", w = 6000, h = 4000 }
	end

	it("links one upload per album to the same catalog photo", function()
		local albums = {
			{ id = "A", title = "A", photos = { ph("200") } },
			{ id = "B", title = "B", photos = { ph("100") } },
		}
		local r = ImportPlan.build(albums, { ph("100"), ph("200") }, catalog, RANGE, {})
		assert.same({}, r.review)
		assert.same({ { id = "200", key = "u1", how = "copy per album", primary = "100" } }, r.albums[1].matches)
		assert.same({ { id = "100", key = "u1", how = "copy per album", primary = "100" } }, r.albums[2].matches)
	end)

	it("keeps real duplicates (same album, or no album) in review", function()
		local sameAlbum = { { id = "A", title = "A", photos = { ph("100"), ph("200") } } }
		local r = ImportPlan.build(sameAlbum, {}, catalog, RANGE, {})
		assert.equal(2, #r.review)
		local oneAlbumless = { { id = "A", title = "A", photos = { ph("100") } } }
		r = ImportPlan.build(oneAlbumless, { ph("100"), ph("300") }, catalog, RANGE, {})
		assert.equal(2, #r.review)
	end)
end)

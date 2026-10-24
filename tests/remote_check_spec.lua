local FlickrApi = require("FlickrApi")
local RemoteCheck = require("RemoteCheck")
local AlbumSync = require("AlbumSync")
local h = require("tests.helpers")

local ACCESS = { token = "AT", tokenSecret = "AS" }

local function page(n, pages, total, ids)
	local photos = {}
	for i, id in ipairs(ids) do
		photos[i] = string.format('{"id":"%s"}', id)
	end
	return {
		status = 200,
		body = string.format(
			'{"photos":{"page":%d,"pages":%d,"total":%d,"photo":[%s]},"stat":"ok"}',
			n,
			pages,
			total,
			table.concat(photos, ",")
		),
	}
end

local NOT_FOUND = { status = 200, body = '{"stat":"fail","code":1,"message":"Photo not found"}' }
local FOUND = { status = 200, body = '{"photo":{"id":"x"},"stat":"ok"}' }

describe("FlickrApi listing", function()
	it("pages through all own photos", function()
		local deps = h.fakeDeps({ page(1, 2, 3, { "1", "2" }), page(2, 2, 3, { "3" }) })
		local ids, count, total = FlickrApi.new(deps, h.CREDS, ACCESS):listOwnPhotoIds()
		assert.same({ ["1"] = true, ["2"] = true, ["3"] = true }, ids)
		assert.equal(3, count)
		assert.equal(3, total)
		assert.equal("2", deps.calls[2].params.page)
	end)

	it("distinguishes not found from errors", function()
		local deps =
			h.fakeDeps({ FOUND, NOT_FOUND, { status = 200, body = '{"stat":"fail","code":100,"message":"x"}' } })
		local api = FlickrApi.new(deps, h.CREDS, ACCESS)
		assert.is_true(api:photoExists("1"))
		assert.is_false(api:photoExists("2"))
		local exists, e = api:photoExists("3")
		assert.is_nil(exists)
		assert.equal(100, e.code)
	end)
end)

describe("RemoteCheck.findMissing", function()
	it("confirms every candidate before calling it missing", function()
		-- listing is incomplete: "2" is absent from it but still exists
		local deps = h.fakeDeps({ page(1, 1, 3, { "1" }), FOUND, NOT_FOUND })
		local r = RemoteCheck.findMissing(FlickrApi.new(deps, h.CREDS, ACCESS), { "1", "2", "3" })
		assert.same({ "3" }, r.missing)
		assert.same({}, r.unconfirmed)
		assert.equal(1, r.listed)
		assert.equal(3, r.total)
	end)

	it("reports lookups that failed for other reasons as unconfirmed", function()
		local deps =
			h.fakeDeps({ page(1, 1, 0, {}), { status = 200, body = '{"stat":"fail","code":100,"message":"x"}' } })
		local r = RemoteCheck.findMissing(FlickrApi.new(deps, h.CREDS, ACCESS), { "9" })
		assert.same({}, r.missing)
		assert.same({ "9" }, r.unconfirmed)
	end)
end)

describe("RemoteCheck.classify", function()
	it("uses the current id when there is one", function()
		local links = {
			{ photoKey = "A", id = "new" }, -- field: current id, exists
			{ photoKey = "A", id = "old", collectionKey = "c1" }, -- stale after re-upload
			{ photoKey = "B", id = "b1" }, -- field, deleted
			{ photoKey = "B", id = "b1", collectionKey = "c1" },
		}
		local r = RemoteCheck.classify(links, { old = true, b1 = true })
		assert.same({ B = true }, r.photos)
		assert.equal(2, #r.staleLinks) -- A's old link and B's collection link
	end)

	it("without a current id, needs all collection ids missing", function()
		local links = {
			{ photoKey = "C", id = "c1", collectionKey = "x" },
			{ photoKey = "C", id = "c2", collectionKey = "y" },
			{ photoKey = "D", id = "d1", collectionKey = "x" },
		}
		local r = RemoteCheck.classify(links, { c1 = true, d1 = true })
		assert.same({ D = true }, r.photos)
		assert.equal(2, #r.staleLinks)
	end)
end)

describe("AlbumSync.remove with deleted photos", function()
	it("treats a photo deleted on Flickr as removed", function()
		local deps = h.fakeDeps({ { status = 200, body = '{"stat":"fail","code":2,"message":"Photo not found"}' } })
		assert.is_true(AlbumSync.remove(FlickrApi.new(deps, h.CREDS, ACCESS), "1", "p"))
	end)
end)

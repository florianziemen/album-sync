local AlbumSync = require("AlbumSync")
local FlickrApi = require("FlickrApi")
local h = require("tests.helpers")

local ACCESS = { token = "AT", tokenSecret = "AS" }
local OK = { status = 200, body = '{"stat":"ok"}' }

local function fail(code, msg)
	return { status = 200, body = string.format('{"stat":"fail","code":%d,"message":"%s"}', code, msg or "x") }
end

local function api(replies)
	local deps = h.fakeDeps(replies)
	return FlickrApi.new(deps, h.CREDS, ACCESS), deps
end

local function methods(deps)
	local out = {}
	for i, c in ipairs(deps.calls) do
		out[i] = c.params.method
	end
	return out
end

describe("AlbumSync", function()
	it("creates the album with the first photo as primary", function()
		local a, deps = api({ { status = 200, body = '{"photoset":{"id":"72177","url":"u"},"stat":"ok"}' } })
		local album = { title = "Trip" }
		assert.is_true(AlbumSync.add(a, album, "p1"))
		assert.equal("72177", album.id)
		assert.is_true(album.created)
		assert.equal("Trip", deps.calls[1].params.title)
		assert.equal("p1", deps.calls[1].params.primary_photo_id)
		assert.equal("POST", deps.calls[1].method)
	end)

	it("adds to an existing album; 'already in set' is success", function()
		local a, deps = api({ OK, fail(3, "Photo already in set") })
		local album = { id = "72177", title = "Trip" }
		assert.is_true(AlbumSync.add(a, album, "p2"))
		assert.is_true(AlbumSync.add(a, album, "p2"))
		assert.same({ "flickr.photosets.addPhoto", "flickr.photosets.addPhoto" }, methods(deps))
		assert.is_nil(album.created)
	end)

	it("recreates an album deleted on Flickr", function()
		local a, deps = api({
			fail(1, "Photoset not found"),
			{ status = 200, body = '{"photoset":{"id":"999"},"stat":"ok"}' },
		})
		local album = { id = "72177", title = "Trip" }
		assert.is_true(AlbumSync.add(a, album, "p3"))
		assert.equal("999", album.id)
		assert.equal("72177", album.recreatedFrom)
		assert.same({ "flickr.photosets.addPhoto", "flickr.photosets.create" }, methods(deps))
	end)

	it("propagates other add errors", function()
		local a = api({ fail(10, "Maximum number of photos in set") })
		local ok, e = AlbumSync.add(a, { id = "1", title = "T" }, "p")
		assert.is_nil(ok)
		assert.equal(10, e.code)
	end)

	it("treats missing album / photo not in album as removed", function()
		local a = api({ OK, fail(1), fail(3), fail(2, "Photo not found") })
		assert.is_true(AlbumSync.remove(a, "1", "p"))
		assert.is_true(AlbumSync.remove(a, "1", "p"))
		assert.is_true(AlbumSync.remove(a, "1", "p"))
		local ok, e = AlbumSync.remove(a, "1", "p")
		assert.is_nil(ok)
		assert.equal(2, e.code)
	end)

	it("renames keeping the description", function()
		local a, deps = api({
			{ status = 200, body = '{"photoset":{"id":"1","description":{"_content":"keep me"}},"stat":"ok"}' },
			OK,
		})
		assert.is_true(AlbumSync.rename(a, "1", "New"))
		assert.equal("flickr.photosets.editMeta", deps.calls[2].params.method)
		assert.equal("New", deps.calls[2].params.title)
		assert.equal("keep me", deps.calls[2].params.description)
	end)

	it("reorders with a comma list and skips empty lists", function()
		local a, deps = api({ OK })
		assert.is_true(AlbumSync.reorder(a, "1", {}))
		assert.equal(0, #deps.calls)
		assert.is_true(AlbumSync.reorder(a, "1", { "3", "1", "2" }))
		assert.equal("3,1,2", deps.calls[1].params.photo_ids)
	end)

	it("moves album membership to a re-uploaded photo", function()
		local a, deps = api({
			{ status = 200, body = '{"set":[{"id":"10","title":"A"},{"id":"20","title":"B"}],"stat":"ok"}' },
			OK, -- add new to 10
			OK, -- remove old from 10
			OK, -- add new to 20
			OK, -- remove old from 20
		})
		assert.same({ "10", "20" }, AlbumSync.moveToNewPhoto(a, "old", "new", true))
		assert.same({
			"flickr.photos.getAllContexts",
			"flickr.photosets.addPhoto",
			"flickr.photosets.removePhoto",
			"flickr.photosets.addPhoto",
			"flickr.photosets.removePhoto",
		}, methods(deps))
		assert.equal("new", deps.calls[2].params.photo_id)
		assert.equal("old", deps.calls[3].params.photo_id)
	end)

	it("does not remove the old photo when it is deleted anyway", function()
		local a, deps = api({ { status = 200, body = '{"set":[{"id":"10"}],"stat":"ok"}' }, OK })
		assert.same({ "10" }, AlbumSync.moveToNewPhoto(a, "old", "new", false))
		assert.equal(2, #deps.calls)
	end)

	it("handles photos in no album", function()
		local a = api({ { status = 200, body = '{"stat":"ok"}' } })
		assert.same({}, AlbumSync.albumsOf(a, "p"))
	end)
end)

local Privacy = require("Privacy")
local FlickrApi = require("FlickrApi")
local h = require("tests.helpers")

describe("Privacy", function()
	it("resolves photo > collection > service, ignoring 'default'", function()
		assert.equal("public", Privacy.resolve("public", "friends", "private"))
		assert.equal("friends", Privacy.resolve("default", "friends", "private"))
		assert.equal("family", Privacy.resolve(nil, nil, "family"))
		assert.equal("private", Privacy.resolve(nil, "default", nil))
	end)

	it("round-trips Flickr flags", function()
		for _, v in ipairs(Privacy.VALUES) do
			local f = Privacy.flags(v)
			assert.equal(v, Privacy.fromFlags(f.is_public, f.is_friend, f.is_family))
		end
		assert.equal("public", Privacy.fromFlags(1, 1, 1))
	end)

	it("decides the location switch and key", function()
		assert.is_true(Privacy.locationEnabled("on", false))
		assert.is_false(Privacy.locationEnabled("off", true))
		assert.is_true(Privacy.locationEnabled("default", true))
		assert.equal("53.5500,9.9900", Privacy.locationKey(53.55, 9.99))
		assert.equal("", Privacy.locationKey(0, 0))
		assert.equal("", Privacy.locationKey(nil, 1))
	end)
end)

describe("FlickrApi.pushMetadata", function()
	local OK = { status = 200, body = '{"stat":"ok"}' }
	local FIELDS = {
		title = "T",
		description = "D",
		tags = "a",
		privacy = "friends",
		location = "1.0000,2.0000",
		latitude = 1,
		longitude = 2,
	}

	local function methods(deps)
		local out = {}
		for i, c in ipairs(deps.calls) do
			out[i] = c.params.method
		end
		return out
	end

	it("pushes only the selected fields", function()
		local deps = h.fakeDeps({ OK, OK })
		assert(FlickrApi.new(deps, h.CREDS, {}):pushMetadata("1", FIELDS, { tags = true, privacy = true }))
		assert.same({ "flickr.photos.setTags", "flickr.photos.setPerms" }, methods(deps))
		assert.equal("1", deps.calls[2].params.is_friend)
		assert.equal("0", deps.calls[2].params.is_public)
	end)

	it("sets and removes the location", function()
		local deps = h.fakeDeps({
			OK,
			{ status = 200, body = '{"stat":"fail","code":2,"message":"Photo has no location information"}' },
		})
		local api = FlickrApi.new(deps, h.CREDS, {})
		assert(api:pushMetadata("1", FIELDS, { location = true }))
		assert.equal("flickr.photos.geo.setLocation", deps.calls[1].params.method)
		assert.equal("1.000000", deps.calls[1].params.lat)
		assert(api:pushMetadata("1", { location = "" }, { location = true }))
		assert.equal("flickr.photos.geo.removeLocation", deps.calls[2].params.method)
	end)
end)

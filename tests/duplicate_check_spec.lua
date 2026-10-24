local DuplicateCheck = require("DuplicateCheck")

describe("DuplicateCheck.decide", function()
	it("keeps the oldest of identical copies", function()
		local r = DuplicateCheck.decide({ "300", "100", "200" }, { ["100"] = 5, ["200"] = 5, ["300"] = 5 })
		assert.same({ primary = "100", duplicates = { "200", "300" }, bytes = 5 }, r)
	end)

	it("compares ids numerically", function()
		assert.equal("99", DuplicateCheck.decide({ "100", "99" }, { ["99"] = 1, ["100"] = 1 }).primary)
	end)

	it("treats re-exports of the same image as identical (metadata differs by a few bytes)", function()
		local r = DuplicateCheck.decide({ "1", "2" }, { ["1"] = 9348633, ["2"] = 9348641 })
		assert.equal("1", r.primary)
		assert.is_truthy(DuplicateCheck.decide({ "1", "2" }, { ["1"] = 10463505, ["2"] = 10462462 }))
	end)

	it("does not decide on different or unknown sizes", function()
		local r, why = DuplicateCheck.decide({ "1", "2" }, { ["1"] = 9000000, ["2"] = 9100000 })
		assert.is_nil(r)
		assert.truthy(why:find("different", 1, true))
		r, why = DuplicateCheck.decide({ "1", "2" }, { ["1"] = 9000000 })
		assert.is_nil(r)
		assert.truthy(why:find("unknown", 1, true))
	end)
end)

describe("DuplicateCheck.groups", function()
	it("groups duplicate items by catalog photo and adds the linked copy", function()
		local items = {
			{ id = "1", candidates = { "u1" }, reason = "duplicate on Flickr" },
			{ id = "2", candidates = { "u1" }, reason = "duplicate on Flickr" },
			{ id = "3", candidates = { "u2" }, reason = "duplicate on Flickr" },
			{ id = "4", candidates = { "u3", "u4" }, reason = "same time and title (virtual copies?)" },
		}
		local g = DuplicateCheck.groups(items, { u2 = "9" })
		assert.equal(2, #g)
		assert.same({ "1", "2" }, g[1].ids)
		assert.same({ "9", "3" }, g[2].ids) -- copy linked by the import counts too
		assert.equal("9", g[2].linkedId)
		assert.same({ "3" }, g[2].queued)
	end)
end)

describe("FlickrApi.originalSize", function()
	local FlickrApi = require("FlickrApi")
	local h = require("tests.helpers")

	it("finds the original's URL and asks for its size", function()
		local deps = h.fakeDeps({
			{
				status = 200,
				body = '{"sizes":{"size":[{"label":"Large","source":"https://x/b.jpg"},'
					.. '{"label":"Original","source":"https://x/o.jpg"}]},"stat":"ok"}',
			},
			{ status = 200, body = '{"sizes":{"size":[{"label":"Large","source":"https://x/b.jpg"}]},"stat":"ok"}' },
		})
		local asked
		deps.remoteSize = function(url)
			asked = url
			return 12345, "HEAD"
		end
		local api = FlickrApi.new(deps, h.CREDS, {})
		assert.equal(12345, api:originalSize("1"))
		assert.equal("https://x/o.jpg", asked)
		local bytes, e = api:originalSize("2")
		assert.is_nil(bytes)
		assert.truthy(e.message:find("no original", 1, true))
	end)
end)

describe("DuplicateCheck.sameContent", function()
	local function file(s)
		local pos = 1
		return {
			read = function(_, n)
				if pos > #s then
					return nil
				end
				local chunk = s:sub(pos, pos + n - 1)
				pos = pos + n
				return chunk
			end,
		}
	end

	it("compares contents", function()
		assert.is_true(DuplicateCheck.sameContent(file("abc"), file("abc")))
		assert.is_false(DuplicateCheck.sameContent(file("abc"), file("abd")))
		assert.is_false(DuplicateCheck.sameContent(file("abc"), file("ab")))
	end)
end)

describe("DuplicateCheck.describe", function()
	it("names virtual copies, shared originals and duplicate imports", function()
		local infos = {
			{ path = "/a.nef", size = 10 },
			{ path = "/a.nef", size = 10, virtual = true, copyName = "Copy 1" },
			{ path = "/b.nef", size = 10 },
			{ path = "/c.nef", size = 11 },
		}
		local asked = {}
		local notes = DuplicateCheck.describe(infos, function(i, j)
			asked[#asked + 1] = i .. "-" .. j
			return true
		end)
		assert.equal("same original file as 2; identical file to 3 (imported twice)", notes[1])
		assert.equal('virtual copy "Copy 1"; same original file as 1; identical file to 3 (imported twice)', notes[2])
		assert.equal("", notes[4])
		assert.same({ "1-3", "2-3", "3-1", "3-2" }, asked)
	end)
end)

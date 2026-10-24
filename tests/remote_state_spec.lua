local RemoteState = require("RemoteState")

local ALL = { title = true, description = true, tags = true, privacy = true, location = true }

local function state(t)
	local base = { title = "T", description = "D", tags = "a b", privacy = "private", location = "" }
	for k, v in pairs(t or {}) do
		base[k] = v
	end
	return base
end

describe("RemoteState normalization", function()
	it("normalizes tags like Flickr", function()
		assert.equal("newyork", RemoteState.normTag(" New York "))
		assert.equal("überfoo", RemoteState.normTag("Über-Foo"))
		assert.same({ "New York", "cat", "dog" }, RemoteState.splitTags('"New York" cat dog'))
		local f = RemoteState.fromFields({
			title = " T ",
			description = "D",
			tags = 'cat "New York" Cat',
			privacy = "public",
		})
		assert.same({ title = "T", description = "D", tags = "cat newyork", privacy = "public", location = "" }, f)
	end)

	it("reads getInfo and list entries the same way", function()
		local info = RemoteState.fromInfo({
			title = { _content = "T" },
			description = { _content = "D" },
			tags = {
				tag = {
					{ raw = "New York", _content = "newyork" },
					{ raw = "x:y=z", _content = "xyz", machine_tag = 1 },
				},
			},
			visibility = { ispublic = 0, isfriend = 1, isfamily = 1 },
			location = { latitude = "53.55", longitude = "9.99" },
		})
		local entry = RemoteState.fromListEntry({
			title = "T",
			description = { _content = "D" },
			tags = "newyork",
			ispublic = 0,
			isfriend = 1,
			isfamily = 1,
			latitude = 53.55,
			longitude = 9.99,
		})
		assert.same(info, entry)
		assert.same(
			{ title = "T", description = "D", tags = "newyork", privacy = "friendsFamily", location = "53.5500,9.9900" },
			info
		)
	end)
end)

describe("RemoteState.diff", function()
	it("pushes fields changed only in Lightroom", function()
		local r = RemoteState.diff(state({ title = "T2" }), { lr = state(), sent = state() }, state(), ALL)
		assert.same({ "title" }, RemoteState.names(r.push))
		assert.same({}, RemoteState.names(r.conflicts))
	end)

	it("keeps fields changed only on Flickr", function()
		local r = RemoteState.diff(state(), { lr = state(), sent = state() }, state({ tags = "a b c" }), ALL)
		assert.same({ "tags" }, RemoteState.names(r.flickrOnly))
		assert.same({}, RemoteState.names(r.push))
	end)

	it("reports conflicts when both sides changed", function()
		local r = RemoteState.diff(
			state({ title = "LR" }),
			{ lr = state(), sent = state() },
			state({ title = "Flickr", privacy = "public" }),
			ALL
		)
		assert.same({ "title" }, RemoteState.names(r.conflicts))
		assert.same({ "privacy" }, RemoteState.names(r.flickrOnly))
	end)

	it("treats equal values as in sync even if both changed", function()
		local r =
			RemoteState.diff(state({ title = "X" }), { lr = state(), sent = state() }, state({ title = "X" }), ALL)
		assert.same({}, RemoteState.names(r.push))
		assert.same({}, RemoteState.names(r.conflicts))
	end)

	it("for linked photos (no sent state) only pushes what changed in Lightroom", function()
		local linked = { lr = state({ title = "IMG_1" }) }
		local remote = state({ title = "Sunset on the beach", tags = "beach" })
		local r = RemoteState.diff(state({ title = "IMG_1", tags = "a b new" }), linked, remote, ALL)
		assert.same({ "tags" }, RemoteState.names(r.push)) -- keyword added in LR
		assert.same({ "title" }, RemoteState.names(r.flickrOnly)) -- Flickr title survives
	end)

	it("without any history pushes everything that differs", function()
		local r = RemoteState.diff(state({ title = "New" }), nil, state(), ALL)
		assert.same({ "title" }, RemoteState.names(r.push))
	end)

	it("ignores unmanaged fields (location off)", function()
		local fields = { title = true, description = true, tags = true, privacy = true }
		local r =
			RemoteState.diff(state(), { lr = state(), sent = state() }, state({ location = "1.0000,2.0000" }), fields)
		assert.same({}, RemoteState.names(r.flickrOnly))
	end)

	it("records what Flickr has after a sync", function()
		local after = RemoteState.after(state({ title = "LR" }), state({ tags = "x" }), { title = true })
		assert.equal("LR", after.sent.title)
		assert.equal("x", after.sent.tags)
		assert.equal("a b", after.lr.tags)
	end)
end)

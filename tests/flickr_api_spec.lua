local FlickrApi = require("FlickrApi")
local OAuth = require("OAuth")
local h = require("tests.helpers")

local ACCESS = { token = "AT", tokenSecret = "AS" }

local function verifySignature(method, url, signed)
	local params = {}
	for k, v in pairs(signed) do
		if k:sub(1, 6) ~= "oauth_" then
			params[k] = v
		end
	end
	local expected = OAuth.sign({
		method = method,
		url = url,
		params = params,
		consumerKey = "ckey",
		consumerSecret = "csecret",
		token = "AT",
		tokenSecret = "AS",
		nonce = signed.oauth_nonce,
		timestamp = signed.oauth_timestamp,
	})
	assert.equal(expected.oauth_signature, signed.oauth_signature)
end

describe("FlickrApi", function()
	it("sends setters as signed POST with json format", function()
		local deps = h.fakeDeps({ { status = 200, body = '{"stat":"ok"}' } })
		assert(FlickrApi.new(deps, h.CREDS, ACCESS):call("flickr.photos.setMeta", { photo_id = "1" }, "POST"))
		local req = deps.calls[1]
		assert.equal("POST", req.method)
		assert.equal("flickr.photos.setMeta", req.params.method)
		assert.equal("json", req.params.format)
		verifySignature("POST", req.url, req.params)
	end)

	it("uploads with signed fields and the file outside the signature", function()
		local deps = h.fakeDeps(
			{},
			{ { status = 200, body = '<?xml version="1.0"?>\n<rsp stat="ok">\n<photoid>12345</photoid>\n</rsp>' } }
		)
		local id = FlickrApi.new(deps, h.CREDS, ACCESS):upload("/tmp/x.jpg", { title = "t", tags = "a:b=c" })
		assert.equal("12345", id)
		local up = deps.uploads[1]
		assert.equal("https://up.flickr.com/services/upload/", up.url)
		assert.equal("/tmp/x.jpg", up.filePath)
		assert.equal("photo", up.fileField)
		assert.is_nil(up.params.photo)
		verifySignature("POST", up.url, up.params)
	end)

	it("replaces via the replace endpoint and flags non-Pro accounts", function()
		local deps = h.fakeDeps({}, {
			{ status = 200, body = '<rsp stat="ok"><photoid secret="s" originalsecret="o">42</photoid></rsp>' },
			{ status = 200, body = '<rsp stat="fail"><err code="1" msg="Not a pro account" /></rsp>' },
		})
		local api = FlickrApi.new(deps, h.CREDS, ACCESS)
		assert.equal("42", api:replace("/tmp/x.jpg", "42"))
		local up = deps.uploads[1]
		assert.equal("https://up.flickr.com/services/replace/", up.url)
		assert.equal("42", up.params.photo_id)
		verifySignature("POST", up.url, up.params)
		local _, e = api:replace("/tmp/x.jpg", "42")
		assert.equal("replace_not_pro", e.class)
	end)

	it("pushes metadata with setMeta then setTags", function()
		local deps = h.fakeDeps({ { status = 200, body = '{"stat":"ok"}' }, { status = 200, body = '{"stat":"ok"}' } })
		local ok = FlickrApi.new(deps, h.CREDS, ACCESS)
			:setMetadata("42", { title = "T", description = "D", tags = '"New York" cat' })
		assert.is_true(ok)
		assert.equal("flickr.photos.setMeta", deps.calls[1].params.method)
		assert.equal("T", deps.calls[1].params.title)
		assert.equal("flickr.photos.setTags", deps.calls[2].params.method)
		assert.equal('"New York" cat', deps.calls[2].params.tags)
		assert.equal("POST", deps.calls[2].method)
	end)

	it("stops after a failing setMeta", function()
		local deps = h.fakeDeps({ { status = 200, body = '{"stat":"fail","code":1,"message":"Photo not found"}' } })
		local ok, e = FlickrApi.new(deps, h.CREDS, ACCESS)
			:setMetadata("42", { title = "T", description = "", tags = "" })
		assert.is_nil(ok)
		assert.equal(1, e.code)
		assert.equal(1, #deps.calls)
	end)

	it("uploads async and returns the ticket", function()
		local deps = h.fakeDeps({}, {
			{ status = 200, body = '<?xml version="1.0"?>\n<rsp stat="ok">\n<ticketid>1234-5678</ticketid>\n</rsp>' },
		})
		assert.equal("1234-5678", FlickrApi.new(deps, h.CREDS, ACCESS):uploadAsync("/tmp/x.jpg", { title = "t" }))
		assert.equal("1", deps.uploads[1].params.async)
		verifySignature("POST", deps.uploads[1].url, deps.uploads[1].params)
	end)

	it("parses ticket status (array and single object)", function()
		local deps = h.fakeDeps({
			{
				status = 200,
				body = '{"uploader":{"ticket":[{"id":"1","complete":1,"photoid":"99"},'
					.. '{"id":"2","complete":0},{"id":"3","invalid":1}]},"stat":"ok"}',
			},
			{ status = 200, body = '{"uploader":{"ticket":{"id":"4","complete":"2"}},"stat":"ok"}' },
		})
		local api = FlickrApi.new(deps, h.CREDS, ACCESS)
		local t = api:checkTickets({ "1", "2", "3" })
		assert.same({ complete = 1, photoId = "99", invalid = false }, t["1"])
		assert.equal(0, t["2"].complete)
		assert.is_true(t["3"].invalid)
		assert.equal("1,2,3", deps.calls[1].params.tickets)
		assert.equal(2, api:checkTickets({ "4" })["4"].complete)
	end)

	it("lists recent uploads", function()
		local deps = h.fakeDeps({
			{
				status = 200,
				body = '{"photos":{"page":1,"photo":[{"id":"7","title":"IMG_1","dateupload":"1700000000",'
					.. '"datetaken":"2026-10-24 14:26:21"}]},"stat":"ok"}',
			},
		})
		local list = FlickrApi.new(deps, h.CREDS, ACCESS):recentUploads(1699999999.7)
		assert.same({ { id = "7", title = "IMG_1", uploaded = 1700000000, taken = "2026-10-24 14:26:21" } }, list)
		assert.equal("1699999999", deps.calls[1].params.min_upload_date)
		assert.equal("me", deps.calls[1].params.user_id)
	end)

	it("deletes photos via POST", function()
		local deps = h.fakeDeps({ { status = 200, body = '{"stat":"ok"}' } })
		assert.is_true(FlickrApi.new(deps, h.CREDS, ACCESS):deletePhoto("42"))
		assert.equal("flickr.photos.delete", deps.calls[1].params.method)
		assert.equal("42", deps.calls[1].params.photo_id)
		assert.equal("POST", deps.calls[1].method)
	end)

	it("reads Pro status", function()
		local deps = h.fakeDeps({
			{ status = 200, body = '{"person":{"id":"1@N07","ispro":0},"stat":"ok"}' },
			{ status = 200, body = '{"person":{"id":"1@N07","ispro":1},"stat":"ok"}' },
		})
		local api = FlickrApi.new(deps, h.CREDS, ACCESS)
		assert.is_false(api:isPro("1@N07"))
		assert.is_true(api:isPro("1@N07"))
		assert.equal("flickr.people.getInfo", deps.calls[1].params.method)
	end)

	it("classifies upload errors and wait hints", function()
		local deps = h.fakeDeps({}, {
			{
				status = 200,
				body = '<rsp stat="fail"><err code="14" msg="Server at capacity" '
					.. 'non_pro_desktop_upload_wait_time="120" /></rsp>',
			},
			{ status = 200, body = '<rsp stat="fail"><err code="6" msg="Upload limit reached" /></rsp>' },
			{ status = 502, body = "" },
		})
		local api = FlickrApi.new(deps, h.CREDS, ACCESS)
		local _, e = api:upload("/tmp/x.jpg", {})
		assert.equal("throttle", e.class)
		assert.equal(120, e.waitSeconds)
		_, e = api:upload("/tmp/x.jpg", {})
		assert.equal("account", e.class)
		_, e = api:upload("/tmp/x.jpg", {})
		assert.equal("transient", e.class)
	end)
end)

describe("FlickrApi missing files", function()
	local FlickrApi2 = require("FlickrApi")
	local helpers = require("tests.helpers")

	it("fails permanently without sending when the rendered file is missing", function()
		local deps = helpers.fakeDeps({}, {})
		deps.fileSize = function()
			return nil
		end
		local _, e = FlickrApi2.new(deps, helpers.CREDS, {}):uploadAsync("/tmp/gone.jpg", {})
		assert.equal("permanent", e.class)
		assert.equal(0, #deps.uploads)
	end)
end)

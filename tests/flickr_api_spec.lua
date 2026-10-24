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

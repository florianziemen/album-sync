local FlickrResponse = require("FlickrResponse")

-- Bodies captured from live probes on 2026-10-24 (docs/DESIGN.md §8).
local XML_BAD_KEY = '<?xml version="1.0" encoding="utf-8" ?>\n<rsp stat="fail">\n\t'
	.. '<err code="100" msg="Invalid API Key (Key not found)" />\n</rsp>\n'
local XML_NO_METHOD = '<?xml version="1.0" encoding="utf-8" ?>\n<rsp stat="fail">\n\t'
	.. '<err code="212" msg="Method not found" />\n</rsp>'

describe("FlickrResponse.parseRest", function()
	it("returns data on stat=ok", function()
		local data = FlickrResponse.parseRest({ status = 200, body = '{"user":{"id":"1@N0"},"stat":"ok"}' })
		assert.equal("1@N0", data.user.id)
	end)

	it("classifies JSON code 100 as auth, with request id", function()
		local data, e = FlickrResponse.parseRest({
			status = 200,
			body = '{"stat":"fail","code":100,"message":"Invalid API Key (Key not found)"}',
			headers = { ["x-flickr-api-request"] = "Root=1-abc" },
		})
		assert.is_nil(data)
		assert.same(
			{ class = "auth", code = 100, message = "Invalid API Key (Key not found)", requestId = "Root=1-abc" },
			e
		)
	end)

	it("handles XML errors returned despite format=json", function()
		local _, e = FlickrResponse.parseRest({ status = 200, body = XML_BAD_KEY })
		assert.equal("auth", e.class)
		assert.equal(100, e.code)
		_, e = FlickrResponse.parseRest({ status = 200, body = XML_NO_METHOD })
		assert.equal("permanent", e.class)
		assert.equal(212, e.code)
	end)

	it("treats CDN HTML, 5xx, 429 and network errors as transient", function()
		local html = "<html><head><title>301 Moved Permanently</title></head></html>"
		assert.equal("transient", select(2, FlickrResponse.parseRest({ status = 301, body = html })).class)
		assert.equal("transient", select(2, FlickrResponse.parseRest({ status = 503, body = "" })).class)
		assert.equal("transient", select(2, FlickrResponse.parseRest({ status = 429, body = "" })).class)
		local _, e = FlickrResponse.parseRest({ message = "timedOut (-1001)" })
		assert.equal("transient", e.class)
		assert.equal("timedOut (-1001)", e.message)
	end)

	it("classifies upload throttling and account limits", function()
		assert.equal(
			"throttle",
			select(2, FlickrResponse.parseRest({ status = 200, body = '{"stat":"fail","code":14,"message":"x"}' })).class
		)
		assert.equal(
			"account",
			select(2, FlickrResponse.parseRest({ status = 200, body = '{"stat":"fail","code":6,"message":"x"}' })).class
		)
	end)
end)

describe("FlickrResponse.parseOAuth", function()
	it("returns the token form on success", function()
		local form = FlickrResponse.parseOAuth({
			status = 200,
			body = "oauth_callback_confirmed=true&oauth_token=T&oauth_token_secret=S",
		})
		assert.equal("T", form.oauth_token)
	end)

	it("classifies oauth_problem as auth (400 and 401 cases)", function()
		local _, e = FlickrResponse.parseOAuth({
			status = 400,
			body = "oauth_problem=parameter_absent&oauth_parameters_absent=oauth_consumer_key%26oauth_signature",
		})
		assert.equal("auth", e.class)
		assert.equal("parameter_absent", e.code)
		_, e = FlickrResponse.parseOAuth({ status = 401, body = "oauth_problem=consumer_key_unknown" })
		assert.equal("consumer_key_unknown", e.code)
	end)

	it("treats unexpected bodies as transient", function()
		local _, e = FlickrResponse.parseOAuth({ status = 200, body = "<html>" })
		assert.equal("transient", e.class)
	end)
end)

local Diagnostics = require("Diagnostics")
local FlickrApi = require("FlickrApi")
local h = require("tests.helpers")

local ACCESS = { token = "ACCESSTOKEN", tokenSecret = "TOKENSECRET" }

local function capture(deps)
	local lines = {}
	deps.log = function(level, message)
		lines[#lines + 1] = { level = level, message = message }
	end
	return lines
end

local function joined(lines, level)
	local out = {}
	for _, l in ipairs(lines) do
		if not level or l.level == level then
			out[#out + 1] = l.message
		end
	end
	return table.concat(out, "\n")
end

describe("Diagnostics", function()
	it("redacts secrets in params and bodies", function()
		local p = Diagnostics.redactParams({
			oauth_signature = "sig",
			oauth_token = "tok",
			oauth_verifier = "123-456",
			oauth_consumer_key = "0123456789abcdef",
			title = "keep",
		})
		assert.equal("<redacted>", p.oauth_signature)
		assert.equal("<redacted>", p.oauth_token)
		assert.equal("<redacted>", p.oauth_verifier)
		assert.equal("0123…<redacted>", p.oauth_consumer_key)
		assert.equal("keep", p.title)
		assert.equal(
			"fullname=X&oauth_token=<redacted>&oauth_token_secret=<redacted>&user_nsid=1",
			Diagnostics.redactBody("fullname=X&oauth_token=AAA&oauth_token_secret=BBB&user_nsid=1")
		)
	end)

	it("truncates huge bodies", function()
		local dump = Diagnostics.exchange("x", { method = "GET", url = "u" }, {
			status = 200,
			body = string.rep("a", Diagnostics.MAX_BODY + 10),
		}, 0.1)
		assert.truthy(dump:find("truncated, " .. (Diagnostics.MAX_BODY + 10) .. " bytes total", 1, true))
	end)
end)

describe("FlickrApi logging", function()
	it("logs one summary line for a successful call, no dump", function()
		local deps = h.fakeDeps({
			{ status = 200, body = '{"stat":"ok"}', headers = { ["x-flickr-api-request"] = "Root=1-ok" } },
		})
		local lines = capture(deps)
		assert(FlickrApi.new(deps, h.CREDS, ACCESS):call("flickr.test.echo"))
		assert.equal(1, #lines)
		assert.equal("info", lines[1].level)
		assert.truthy(lines[1].message:find("flickr.test.echo status=200", 1, true))
		assert.truthy(lines[1].message:find("rid=Root=1-ok", 1, true))
	end)

	it("dumps the full exchange on stat=fail, without secrets", function()
		local deps = h.fakeDeps({
			{
				status = 200,
				body = '{"stat":"fail","code":98,"message":"Invalid auth token"}',
				headers = { ["x-flickr-api-request"] = "Root=1-bad", ["content-type"] = "application/json" },
			},
		})
		local lines = capture(deps)
		local _, e = FlickrApi.new(deps, h.CREDS, ACCESS):call("flickr.photos.setMeta", { photo_id = "42" }, "POST")
		assert.equal(98, e.code)
		local dump = joined(lines, "error")
		assert.truthy(dump:find("Flickr exchange failed: flickr.photos.setMeta", 1, true))
		assert.truthy(dump:find("request: POST https://api.flickr.com/services/rest/", 1, true))
		assert.truthy(dump:find("param photo_id=42", 1, true))
		assert.truthy(dump:find("header content-type: application/json", 1, true))
		assert.truthy(dump:find("Invalid auth token", 1, true))
		assert.truthy(dump:find("rid=Root=1-bad", 1, true))
		assert.is_nil(dump:find("ACCESSTOKEN", 1, true))
		assert.is_nil(dump:find("TOKENSECRET", 1, true))
		assert.is_nil(dump:find("csecret", 1, true))
	end)

	it("dumps network errors and transport exceptions", function()
		local deps = h.fakeDeps({
			{ message = "timedOut (-1001)", networkError = { errorCode = -1001, name = "timedOut" } },
		})
		deps.postMultipart = function()
			error("boom")
		end
		local lines = capture(deps)
		local api = FlickrApi.new(deps, h.CREDS, ACCESS)
		local _, e = api:call("flickr.test.echo")
		assert.equal("transient", e.class)
		local dump = joined(lines, "error")
		assert.truthy(dump:find("networkError.errorCode=-1001", 1, true))
		assert.truthy(dump:find("transport error: timedOut", 1, true))

		_, e = api:upload("/tmp/x.jpg", {})
		assert.equal("transient", e.class)
		assert.truthy(joined(lines, "error"):find("transport raised:", 1, true))
		assert.truthy(joined(lines, "error"):find("file /tmp/x.jpg", 1, true))
	end)

	it("logs expected error codes as info without a dump", function()
		local deps = h.fakeDeps({ { status = 200, body = '{"stat":"fail","code":1,"message":"Photoset not found"}' } })
		local lines = capture(deps)
		local _, e = FlickrApi.new(deps, h.CREDS, ACCESS):call(
			"flickr.photosets.removePhoto",
			{ photoset_id = "1", photo_id = "2" },
			"POST",
			nil,
			{ [1] = true }
		)
		assert.equal(1, e.code)
		assert.equal(1, #lines)
		assert.equal("info", lines[1].level)
		assert.truthy(lines[1].message:find("(expected)", 1, true))
	end)

	it("flags successful responses with an unexpected shape", function()
		local deps = h.fakeDeps({ { status = 200, body = '{"stat":"ok","person":{}}' } })
		local lines = capture(deps)
		local pro, e = FlickrApi.new(deps, h.CREDS, ACCESS):isPro("1@N07")
		assert.is_nil(pro)
		assert.equal("unexpected", e.class)
		assert.truthy(joined(lines, "error"):find('"person":{}', 1, true))
	end)
end)

local FlickrAuth = require("FlickrAuth")
local OAuth = require("OAuth")

local CREDS = { consumerKey = "ckey", consumerSecret = "csecret" }

-- Fake transport: records requests and replies from a queue.
local function fakeDeps(replies)
	local calls = {}
	return {
		calls = calls,
		now = function()
			return 1700000000
		end,
		random = function()
			return 1
		end,
		transport = function(req)
			calls[#calls + 1] = req
			return table.remove(replies, 1)
		end,
	}
end

describe("FlickrAuth", function()
	it("runs the full oob flow", function()
		local deps = fakeDeps({
			{ status = 200, body = "oauth_callback_confirmed=true&oauth_token=RT&oauth_token_secret=RS" },
			{
				status = 200,
				body = "fullname=Jane%20Doe&oauth_token=AT&oauth_token_secret=AS&user_nsid=1%40N0&username=jane",
			},
			{ status = 200, body = '{"user":{"id":"1@N0","username":{"_content":"jane"}},"stat":"ok"}' },
		})
		local auth = FlickrAuth.new(deps, CREDS)

		local rt = assert(auth:requestToken())
		assert.same({ token = "RT", tokenSecret = "RS" }, rt)
		local p = deps.calls[1].params
		assert.equal("oob", p.oauth_callback)
		assert.equal("ckey", p.oauth_consumer_key)
		assert.is_nil(p.oauth_token)
		assert.equal("1700000000", p.oauth_timestamp)

		assert.equal(
			"https://www.flickr.com/services/oauth/authorize?oauth_token=RT&perms=delete",
			FlickrAuth.authorizeUrl(rt, "delete")
		)

		local at = assert(auth:accessToken(rt, "123-456-789"))
		assert.equal("AT", at.token)
		assert.equal("1@N0", at.userNsid)
		assert.equal("Jane Doe", at.fullname)
		p = deps.calls[2].params
		assert.equal("RT", p.oauth_token)
		assert.equal("123-456-789", p.oauth_verifier)

		local user = assert(auth:testLogin(at))
		assert.same({ id = "1@N0", username = "jane" }, user)
		assert.equal("flickr.test.login", deps.calls[3].params.method)
		assert.equal("AT", deps.calls[3].params.oauth_token)
	end)

	it("signs requests verifiably with consumer and token secret", function()
		local deps =
			fakeDeps({ { status = 200, body = '{"stat":"ok","user":{"id":"x","username":{"_content":"y"}}}' } })
		local auth = FlickrAuth.new(deps, CREDS)
		auth:testLogin({ token = "AT", tokenSecret = "AS" })
		local req = deps.calls[1]
		local params = {}
		for k, v in pairs(req.params) do
			if k:sub(1, 6) ~= "oauth_" then
				params[k] = v
			end
		end
		local expected = OAuth.sign({
			method = req.method,
			url = req.url,
			params = params,
			consumerKey = "ckey",
			consumerSecret = "csecret",
			token = "AT",
			tokenSecret = "AS",
			nonce = req.params.oauth_nonce,
			timestamp = req.params.oauth_timestamp,
		})
		assert.equal(expected.oauth_signature, req.params.oauth_signature)
	end)

	it("propagates oauth problems", function()
		local deps = fakeDeps({ { status = 401, body = "oauth_problem=consumer_key_unknown" } })
		local rt, e = FlickrAuth.new(deps, CREDS):requestToken()
		assert.is_nil(rt)
		assert.equal("auth", e.class)
		assert.equal("consumer_key_unknown", e.code)
	end)

	it("rejects an unconfirmed callback", function()
		local deps = fakeDeps({ { status = 200, body = "oauth_token=RT&oauth_token_secret=RS" } })
		local rt, e = FlickrAuth.new(deps, CREDS):requestToken()
		assert.is_nil(rt)
		assert.equal("unexpected", e.class)
		assert.equal("callback not confirmed", e.message)
	end)
end)

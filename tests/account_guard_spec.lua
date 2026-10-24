local AccountGuard = require("AccountGuard")
local h = require("tests.helpers")

local LOGGED_IN = { consumerKey = "ckey", consumerSecret = "csecret", token = "AT", tokenSecret = "AS" }

describe("AccountGuard", function()
	it("accepts the locked account", function()
		local deps = h.fakeDeps({ h.loginReply("1@N07", "dummy") })
		local user = assert(AccountGuard.verify(deps, LOGGED_IN, "1@N07"))
		assert.equal("dummy", user.username)
		assert.equal("AT", deps.calls[1].params.oauth_token)
	end)

	it("refuses a different account", function()
		local deps = h.fakeDeps({ h.loginReply("2@N01", "main") })
		local user, e = AccountGuard.verify(deps, LOGGED_IN, "1@N07")
		assert.is_nil(user)
		assert.equal("auth", e.class)
		assert.truthy(e.message:find("locked to 1@N07", 1, true))
	end)

	it("refuses when not locked, without calling Flickr", function()
		local deps = h.fakeDeps({})
		for _, locked in ipairs({ "", false }) do
			local user, e = AccountGuard.verify(deps, LOGGED_IN, locked or nil)
			assert.is_nil(user)
			assert.truthy(e.message:find("not locked", 1, true))
		end
		assert.equal(0, #deps.calls)
	end)

	it("refuses when not logged in", function()
		local _, e = AccountGuard.verify(h.fakeDeps({}), h.CREDS, "1@N07")
		assert.truthy(e.message:find("Not logged in", 1, true))
	end)

	it("propagates Flickr errors", function()
		local deps = h.fakeDeps({ { status = 200, body = '{"stat":"fail","code":98,"message":"Invalid auth token"}' } })
		local _, e = AccountGuard.verify(deps, LOGGED_IN, "1@N07")
		assert.equal(98, e.code)
	end)
end)

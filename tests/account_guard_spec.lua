local AccountGuard = require("AccountGuard")
local h = require("tests.helpers")

local function account(perms)
	return {
		consumerKey = "ckey",
		consumerSecret = "csecret",
		token = "AT",
		tokenSecret = "AS",
		username = "dummy",
		perms = perms or "delete",
	}
end

describe("AccountGuard", function()
	it("accepts the locked account with enough permission", function()
		local deps = h.fakeDeps({ h.loginReply("1@N07", "dummy") })
		local user = assert(AccountGuard.verify(deps, account("write"), "1@N07", "write"))
		assert.equal("dummy", user.username)
		assert.equal("AT", deps.calls[1].params.oauth_token)
	end)

	it("refuses a token for a different account", function()
		local deps = h.fakeDeps({ h.loginReply("2@N01", "main") })
		local user, e = AccountGuard.verify(deps, account(), "1@N07", "write")
		assert.is_nil(user)
		assert.equal("auth", e.class)
		assert.truthy(e.message:find("locked to 1@N07", 1, true))
	end)

	it("refuses read-only logins for writes, without calling Flickr", function()
		local deps = h.fakeDeps({})
		local user, e = AccountGuard.verify(deps, account("read"), "1@N07", "write")
		assert.is_nil(user)
		assert.truthy(e.message:find("only allows “read”", 1, true))
		assert.equal(0, #deps.calls)
	end)

	it("refuses when not locked or not logged in", function()
		local deps = h.fakeDeps({})
		local _, e = AccountGuard.verify(deps, account(), "", "read")
		assert.truthy(e.message:find("not locked", 1, true))
		_, e = AccountGuard.verify(deps, nil, "1@N07", "read")
		assert.truthy(e.message:find("No Flickr login", 1, true))
		assert.equal(0, #deps.calls)
	end)

	it("propagates Flickr errors", function()
		local deps = h.fakeDeps({ { status = 200, body = '{"stat":"fail","code":98,"message":"Invalid auth token"}' } })
		local _, e = AccountGuard.verify(deps, account(), "1@N07", "read")
		assert.equal(98, e.code)
	end)

	it("ranks permissions", function()
		assert.is_true(AccountGuard.permsAllow("delete", "write"))
		assert.is_true(AccountGuard.permsAllow("write", "read"))
		assert.is_false(AccountGuard.permsAllow("read", "write"))
		assert.is_false(AccountGuard.permsAllow(nil, "read"))
	end)

	it("allows exactly one account per catalog", function()
		assert.equal("1@N07", AccountGuard.catalogAccount({ "1@N07", "", "1@N07" }))
		local _, e = AccountGuard.catalogAccount({ "" })
		assert.equal("none", e.reason)
		_, e = AccountGuard.catalogAccount({ "1@N07", "2@N01" })
		assert.equal("several", e.reason)
	end)
end)

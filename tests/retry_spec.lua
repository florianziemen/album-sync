local Retry = require("Retry")
local RateLimiter = require("RateLimiter")
local FlickrApi = require("FlickrApi")
local h = require("tests.helpers")

local function sleeper()
	local slept = {}
	return slept, function(s)
		slept[#slept + 1] = s
	end
end

describe("Retry", function()
	it("retries transient errors with growing backoff, then succeeds", function()
		local slept, sleep = sleeper()
		local n = 0
		local result = Retry.run({ sleep = sleep }, "x", function()
			n = n + 1
			if n < 3 then
				return nil, { class = "transient" }
			end
			return "done"
		end)
		assert.equal("done", result)
		assert.same({ 1.5, 3 }, slept) -- 2*0.75, 4*0.75 with jitter 0.5
	end)

	it("does not retry permanent or auth errors", function()
		local _, sleep = sleeper()
		local n = 0
		local _, e = Retry.run({ sleep = sleep }, "x", function()
			n = n + 1
			return nil, { class = "auth" }
		end)
		assert.equal(1, n)
		assert.equal(1, e.attempts)
	end)

	it("gives up after the configured attempts", function()
		local slept, sleep = sleeper()
		local _, e = Retry.run({ sleep = sleep }, "x", function()
			return nil, { class = "transient" }
		end, { policy = { attempts = 3, base = 1, factor = 2, cap = 60 } })
		assert.equal(3, e.attempts)
		assert.equal(2, #slept)
	end)

	it("honours Flickr's wait hint for throttling", function()
		assert.equal(120, Retry.delay({ class = "throttle", waitSeconds = 120 }, 1))
		assert.equal(
			60,
			Retry.delay({ class = "transient" }, 10, Retry.DEFAULTS, function()
				return 1
			end)
		)
	end)

	it("lets beforeRetry find an already-successful result or abort", function()
		local _, sleep = sleeper()
		local calls = 0
		local result = Retry.run({ sleep = sleep }, "upload", function()
			calls = calls + 1
			return nil, { class = "transient" }
		end, {
			beforeRetry = function()
				return "found-on-flickr"
			end,
		})
		assert.equal("found-on-flickr", result)
		assert.equal(1, calls)

		local _, e = Retry.run({ sleep = sleep }, "upload", function()
			return nil, { class = "transient", message = "lost" }
		end, {
			beforeRetry = function()
				return false
			end,
		})
		assert.equal("lost", e.message)
	end)
end)

describe("RateLimiter", function()
	it("allows a burst, then paces to the rate", function()
		local t = 0
		local slept = {}
		local limiter = RateLimiter.new({
			now = function()
				return t
			end,
			sleep = function(s)
				slept[#slept + 1] = s
				t = t + s
			end,
		}, 1, 3)
		for _ = 1, 3 do
			assert.equal(0, limiter:acquire())
		end
		assert.equal(1, limiter:acquire())
		t = t + 10 -- idle refills up to the burst size only
		for _ = 1, 3 do
			assert.equal(0, limiter:acquire())
		end
		assert.is_true(limiter:acquire() > 0)
	end)
end)

describe("FlickrApi retries", function()
	local ACCESS = { token = "AT", tokenSecret = "AS" }

	it("retries idempotent calls with a fresh signature", function()
		local deps = h.fakeDeps({ { status = 503, body = "" }, { status = 200, body = '{"stat":"ok"}' } })
		local _, sleep = sleeper()
		deps.sleep = sleep
		local n = 0
		deps.random = function(k)
			n = n + 1
			return (n % k) + 1
		end
		assert(
			FlickrApi.new(deps, h.CREDS, ACCESS):call("flickr.photos.setTags", { photo_id = "1", tags = "" }, "POST")
		)
		assert.equal(2, #deps.calls)
		assert.are_not.equal(deps.calls[1].params.oauth_nonce, deps.calls[2].params.oauth_nonce)
	end)

	it("never retries album creation", function()
		local deps = h.fakeDeps({ { status = 503, body = "" }, { status = 200, body = '{"stat":"ok"}' } })
		deps.sleep = function() end
		local _, e = FlickrApi.new(deps, h.CREDS, ACCESS):call("flickr.photosets.create", { title = "t" }, "POST")
		assert.equal("transient", e.class)
		assert.equal(1, #deps.calls)
	end)

	it("goes through the shared rate limiter", function()
		local deps = h.fakeDeps({ { status = 200, body = '{"stat":"ok"}' } })
		local acquired = 0
		deps.limiter = {
			acquire = function()
				acquired = acquired + 1
				return 0
			end,
		}
		FlickrApi.new(deps, h.CREDS, ACCESS):call("flickr.test.echo")
		assert.equal(1, acquired)
	end)
end)

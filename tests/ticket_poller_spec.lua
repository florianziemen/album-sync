local TicketPoller = require("TicketPoller")
local Uploader = require("Uploader")
local FlickrResponse = require("FlickrResponse")

-- Cooperative scheduler: each waiter is a coroutine; sleep() yields and advances time.
local function world()
	local w = { t = 0, polls = {} }
	w.deps = {
		now = function()
			return w.t
		end,
		sleep = function(s)
			w.t = w.t + s
			coroutine.yield()
		end,
	}
	return w
end

describe("TicketPoller", function()
	it("polls all open tickets together", function()
		local w = world()
		local done = { T1 = 3, T2 = 3, T3 = 6 } -- time at which each ticket completes
		local api = {
			checkTickets = function(_, ids)
				w.polls[#w.polls + 1] = table.concat(ids, ",")
				local out = {}
				for _, id in ipairs(ids) do
					out[id] = w.t >= done[id] and { complete = 1, photoId = "P" .. id } or { complete = 0 }
				end
				return out
			end,
		}
		local poller = TicketPoller.new(api, w.deps)
		local results, cos = {}, {}
		for _, ticket in ipairs({ "T1", "T2", "T3" }) do
			cos[#cos + 1] = coroutine.create(function()
				results[ticket] = poller:wait(ticket, 60)
			end)
		end
		for _ = 1, 500 do
			for _, co in ipairs(cos) do
				if coroutine.status(co) ~= "dead" then
					assert(coroutine.resume(co))
				end
			end
		end
		assert.same({ T1 = "PT1", T2 = "PT2", T3 = "PT3" }, results)
		-- the first worker polls right away; once all are waiting, one call covers all three
		local combined = false
		for _, p in ipairs(w.polls) do
			combined = combined or p == "T1,T2,T3"
		end
		assert.is_true(combined)
		assert.is_true(#w.polls <= 6) -- per-worker polling at 1 s would need ~12
	end)

	it("reports failed, lost and still-processing tickets", function()
		local w = world()
		local api = {
			checkTickets = function()
				return { A = { complete = 2 }, B = { invalid = true, complete = 0 }, C = { complete = 0 } }
			end,
		}
		local poller = TicketPoller.new(api, w.deps)
		local errs = {}
		local cos = {}
		for _, ticket in ipairs({ "A", "B", "C" }) do
			cos[#cos + 1] = coroutine.create(function()
				local _, e = poller:wait(ticket, 10)
				errs[ticket] = e.class
			end)
		end
		for _ = 1, 500 do
			for _, co in ipairs(cos) do
				if coroutine.status(co) ~= "dead" then
					assert(coroutine.resume(co))
				end
			end
		end
		assert.same({ A = "permanent", B = "lost", C = "pending" }, errs)
	end)
end)

describe("not-sent errors", function()
	it("are recognized from macOS network error codes", function()
		local _, e = FlickrResponse.parseUpload({ networkError = { errorCode = -1004, name = "cannotConnectToHost" } })
		assert.is_true(e.notSent)
		_, e = FlickrResponse.parseUpload({ networkError = { errorCode = -1001, name = "timedOut" } })
		assert.is_false(e.notSent)
		_, e = FlickrResponse.parseUpload({ status = 503, body = "" })
		assert.is_nil(e.notSent)
	end)

	it("skip the duplicate search before retrying", function()
		local searched = false
		local api = {
			uploadAsync = (function()
				local n = 0
				return function()
					n = n + 1
					if n == 1 then
						return nil, { class = "transient", notSent = true, message = "cannot connect" }
					end
					return "T1"
				end
			end)(),
			checkTickets = function()
				return { T1 = { complete = 1, photoId = "P1" } }
			end,
			recentUploads = function()
				searched = true
				return {}
			end,
		}
		local journal = {
			open = function()
				return {}
			end,
			update = function() end,
			close = function() end,
		}
		local t = 0
		local deps = {
			now = function()
				return t
			end,
			sleep = function(s)
				t = t + s
			end,
		}
		assert.equal("P1", Uploader.new(deps, api, journal):upload("u", "/x.jpg", { title = "x" }))
		assert.is_false(searched)
	end)
end)

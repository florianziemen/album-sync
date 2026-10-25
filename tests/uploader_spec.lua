local Journal = require("Journal")
local Uploader = require("Uploader")
local json = require("json")

local function memoryStorage(initial)
	local store = { value = initial }
	return {
		store = store,
		load = function()
			return store.value
		end,
		save = function(s)
			store.value = s
		end,
	}
end

-- Scripted fake of the FlickrApi methods used by Uploader.
local function fakeApi(script)
	local api = { calls = {} }
	local function nextOf(name, ...)
		api.calls[#api.calls + 1] = name
		local queue = script[name] or {}
		local r = table.remove(queue, 1)
		if type(r) == "function" then
			return r(...)
		end
		if r == nil then
			error("unexpected call: " .. name)
		end
		return r[1], r[2]
	end
	function api.uploadAsync(_, ...)
		return nextOf("uploadAsync", ...)
	end
	function api.checkTickets(_, ...)
		return nextOf("checkTickets", ...)
	end
	function api.recentUploads(_, ...)
		return nextOf("recentUploads", ...)
	end
	return api
end

local function deps()
	local t = 1000
	return {
		now = function()
			return t
		end,
		sleep = function(s)
			t = t + s
		end,
	}
end

local function count(list, name)
	local n = 0
	for _, c in ipairs(list) do
		if c == name then
			n = n + 1
		end
	end
	return n
end

describe("Journal", function()
	it("persists entries across instances", function()
		local storage = memoryStorage()
		local j = Journal.new(storage)
		j:open("u1", { title = "a", started = 1 })
		j:update("u1", { ticket = "T1" })
		local j2 = Journal.new(storage)
		assert.same({ title = "a", started = 1, ticket = "T1" }, j2:get("u1"))
		j2:close("u1")
		assert.same({}, Journal.new(storage):openEntries())
	end)

	it("survives a corrupt file", function()
		local j = Journal.new(memoryStorage("{not json"))
		assert.equal("{not json", j.corrupt)
		assert.same({}, j:openEntries())
	end)

	it("serializes overlapping saves and writes the latest state last", function()
		local store, active, peak = {}, 0, 0
		local storage = {
			load = function() end,
			save = function(s)
				active = active + 1
				peak = math.max(peak, active)
				coroutine.yield() -- LrFileUtils yields mid-save
				store.value = s
				active = active - 1
			end,
		}
		-- Plain pcall cannot span a yield in Lua 5.1 (Lightroom injects LrTasks.pcall).
		local function yieldSafePcall(fn, ...)
			return true, fn(...)
		end
		local j = Journal.new(storage, { sleep = coroutine.yield, pcall = yieldSafePcall })
		local tasks = {}
		for i = 1, 3 do
			tasks[i] = coroutine.create(function()
				j:open("u" .. i, { n = i })
			end)
		end
		local alive = true
		while alive do
			alive = false
			for _, co in ipairs(tasks) do
				if coroutine.status(co) ~= "dead" then
					assert(coroutine.resume(co))
					alive = true
				end
			end
		end
		assert.equal(1, peak)
		assert.equal(3, #Journal.new({
			load = function()
				return store.value
			end,
		}):openEntries())
	end)

	it("releases the save lock when storage fails", function()
		local fail = true
		local j = Journal.new({
			load = function() end,
			save = function()
				if fail then
					error("disk full", 0)
				end
			end,
		})
		assert.has_error(function()
			j:open("u1", {})
		end, "disk full")
		fail = false
		j:open("u2", {})
		assert.is_falsy(j.saving)
	end)
end)

describe("Journal leases", function()
	local function keys(items)
		local out = {}
		for _, item in ipairs(items) do
			out[#out + 1] = item.key
		end
		return out
	end

	it("share one file and keep each other's entries", function()
		local storage = memoryStorage()
		local j = Journal.new(storage)
		local a, b = j:lease(), j:lease()
		a:open("u1", { n = 1 })
		b:open("u2", { n = 2 })
		assert.same({ "u1", "u2" }, keys(Journal.new(storage):openEntries()))
	end)

	it("do not reconcile or reopen what another run is uploading", function()
		local j = Journal.new(memoryStorage())
		local a, b = j:lease(), j:lease()
		assert.truthy(a:open("u1", {}))
		assert.same({}, b:claimStale())
		assert.same({ u1 = true }, b:busyKeys())
		assert.same({}, a:busyKeys())
		assert.is_nil(b:open("u1", {}))
		assert.truthy(a:open("u1", {})) -- same run may reopen
	end)

	it("let one run claim stale entries and hand them back on release", function()
		local j = Journal.new(memoryStorage('{"version":1,"entries":{"old":{"title":"x"}}}'))
		local a, b = j:lease(), j:lease()
		assert.same({ "old" }, keys(a:claimStale()))
		assert.same({}, b:claimStale())
		a:release()
		assert.same({ "old" }, keys(b:claimStale()))
	end)

	it("free a key when its entry is closed", function()
		local j = Journal.new(memoryStorage())
		local a, b = j:lease(), j:lease()
		a:open("u1", {})
		a:close("u1")
		assert.same({}, b:busyKeys())
		assert.truthy(b:open("u1", {}))
	end)
end)

describe("Uploader", function()
	local FIELDS = { title = "IMG_1" }

	it("uploads async, waits for the ticket, records the photo id", function()
		local storage = memoryStorage()
		local journal = Journal.new(storage)
		local api = fakeApi({
			uploadAsync = { { "T1" } },
			checkTickets = { { { T1 = { complete = 0 } } }, { { T1 = { complete = 1, photoId = "P1" } } } },
		})
		local up = Uploader.new(deps(), api, journal)
		assert.equal("P1", up:upload("u1", "/x.jpg", FIELDS))
		assert.same({ title = "IMG_1", started = 1000, ticket = "T1", photoId = "P1" }, journal:get("u1"))
		assert.equal("P1", json.decode(storage.store.value).entries.u1.photoId)
	end)

	it("finds an upload whose response was lost instead of uploading twice", function()
		local journal = Journal.new(memoryStorage())
		local api = fakeApi({
			uploadAsync = { { nil, { class = "transient", message = "timedOut" } } },
			recentUploads = { { { { id = "P9", title = "other" }, { id = "P1", title = "IMG_1" } } } },
		})
		local up = Uploader.new(deps(), api, journal)
		assert.equal("P1", up:upload("u1", "/x.jpg", FIELDS))
		assert.equal(1, count(api.calls, "uploadAsync"))
	end)

	it("retries when the photo did not arrive", function()
		local journal = Journal.new(memoryStorage())
		local api = fakeApi({
			uploadAsync = { { nil, { class = "transient" } }, { "T2" } },
			recentUploads = { { {} }, { {} }, { {} } },
			checkTickets = { { { T2 = { complete = 1, photoId = "P2" } } } },
		})
		local up = Uploader.new(deps(), api, journal)
		assert.equal("P2", up:upload("u1", "/x.jpg", FIELDS))
		assert.equal(2, count(api.calls, "uploadAsync"))
		assert.equal(Uploader.RECENT_CHECKS, count(api.calls, "recentUploads"))
	end)

	it("does not upload a photo another run is uploading", function()
		local journal = Journal.new(memoryStorage())
		local other = journal:lease()
		other:open("u1", { title = "IMG_1" })
		local api = fakeApi({})
		local id, e = Uploader.new(deps(), api, journal:lease()):upload("u1", "/x.jpg", FIELDS)
		assert.is_nil(id)
		assert.equal("busy", e.class)
		assert.same({}, api.calls)
		assert.is_not_nil(journal:get("u1"))
	end)

	it("stops on ambiguous candidates and keeps the journal entry", function()
		local journal = Journal.new(memoryStorage())
		local api = fakeApi({
			uploadAsync = { { nil, { class = "transient", message = "lost" } } },
			recentUploads = { { { { id = "P1", title = "IMG_1" }, { id = "P2", title = "IMG_1" } } } },
		})
		local up = Uploader.new(deps(), api, journal)
		local id, e = up:upload("u1", "/x.jpg", FIELDS)
		assert.is_nil(id)
		assert.equal("lost", e.message)
		assert.is_not_nil(journal:get("u1"))
	end)

	it("never matches a photo already claimed in this run (virtual copies)", function()
		local journal = Journal.new(memoryStorage())
		local api = fakeApi({
			uploadAsync = { { "T1" }, { nil, { class = "transient" } }, { "T2" } },
			checkTickets = {
				{ { T1 = { complete = 1, photoId = "P1" } } },
				{ { T2 = { complete = 1, photoId = "P2" } } },
			},
			recentUploads = {
				{ { { id = "P1", title = "IMG_1" } } },
				{ { { id = "P1", title = "IMG_1" } } },
				{ { { id = "P1", title = "IMG_1" } } },
			},
		})
		local up = Uploader.new(deps(), api, journal)
		assert.equal("P1", up:upload("u1", "/x.jpg", FIELDS))
		assert.equal("P2", up:upload("u2", "/x-copy.jpg", FIELDS))
	end)

	it("does not re-upload while Flickr is still processing", function()
		local journal = Journal.new(memoryStorage())
		local api = fakeApi({ uploadAsync = { { "T1" } } })
		api.checkTickets = function() -- still processing, however often it is asked
			return { T1 = { complete = 0 } }
		end
		local up = Uploader.new(deps(), api, journal)
		local id, e = up:upload("u1", "/x.jpg", FIELDS)
		assert.is_nil(id)
		assert.equal("pending", e.class)
		assert.equal(1, count(api.calls, "uploadAsync"))
		assert.equal("T1", journal:get("u1").ticket)
	end)

	it("drops the journal entry when Flickr rejects the file", function()
		local journal = Journal.new(memoryStorage())
		local api = fakeApi({ uploadAsync = { { nil, { class = "permanent", code = 5, message = "bad filetype" } } } })
		local _, e = Uploader.new(deps(), api, journal):upload("u1", "/x.jpg", FIELDS)
		assert.equal(5, e.code)
		assert.is_nil(journal:get("u1"))
	end)

	it("injects faults for testing", function()
		local journal = Journal.new(memoryStorage())
		local api = fakeApi({
			uploadAsync = { { "T1" } },
			recentUploads = { { { { id = "P1", title = "IMG_1" } } } },
		})
		local up = Uploader.new(deps(), api, journal)
		local id = up:upload("u1", "/x.jpg", FIELDS, {
			fault = function(stage)
				if stage == "afterSend" then
					return { class = "transient", message = "injected" }
				end
			end,
		})
		assert.equal("P1", id)
		assert.equal(1, count(api.calls, "uploadAsync"))
	end)
end)

describe("Uploader.reconcile", function()
	it("links, keeps pending, drops failed and lost-without-trace entries", function()
		local journal = Journal.new(memoryStorage())
		journal:open("done", { title = "A", started = 1, photoId = "P0" })
		journal:open("ticketOk", { title = "B", started = 1, ticket = "T1" })
		journal:open("ticketPending", { title = "C", started = 1, ticket = "T2" })
		journal:open("ticketFailed", { title = "D", started = 1, ticket = "T3" })
		journal:open("noTicketFound", { title = "E", started = 1 })
		journal:open("noTicketGone", { title = "F", started = 1 })
		local api = fakeApi({
			checkTickets = (function()
				local byTicket = {
					T1 = { complete = 1, photoId = "P1" },
					T2 = { complete = 0 },
					T3 = { complete = 2 },
				}
				local answer = function(ids)
					return { [ids[1]] = byTicket[ids[1]] }
				end
				return { answer, answer, answer }
			end)(),
			recentUploads = { { { { id = "P5", title = "E" } } } }, -- one listing for all lost entries
		})
		local r = Uploader.new(deps(), api, journal):reconcile()
		assert.same({ done = "P0", ticketOk = "P1", noTicketFound = "P5" }, r.linked)
		assert.same({ "ticketPending" }, r.pending)
		assert.same({ "noTicketGone", "ticketFailed" }, r.dropped)
		assert.is_nil(journal:get("ticketFailed"))
		assert.is_not_nil(journal:get("ticketPending"))
		assert.is_not_nil(journal:get("ticketOk")) -- closed by the caller after storing the id
		local listings = 0
		for _, c in ipairs(api.calls) do
			listings = listings + (c == "recentUploads" and 1 or 0)
		end
		assert.equal(1, listings)
	end)

	it("does not guess when several lost entries share a title", function()
		local journal = Journal.new(memoryStorage())
		journal:open("a", { title = "IMG", started = 10 })
		journal:open("b", { title = "IMG", started = 20 })
		journal:open("c", { title = "X", started = 30 })
		local api = fakeApi({ recentUploads = { { { { id = "P1", title = "IMG" }, { id = "P2", title = "Y" } } } } })
		local r = Uploader.new(deps(), api, journal):reconcile()
		-- one photo, two lost entries with that title: cannot tell whose upload it was
		assert.same({ a = { "P1" }, b = { "P1" } }, r.ambiguous)
		assert.same({}, r.linked)
		assert.same({ "c" }, r.dropped)
	end)

	it("keeps entries pending when the listing fails", function()
		local journal = Journal.new(memoryStorage())
		journal:open("a", { title = "IMG", started = 10 })
		local api = fakeApi({ recentUploads = { { nil, { class = "transient" } } } })
		local r = Uploader.new(deps(), api, journal):reconcile()
		assert.same({ "a" }, r.pending)
		assert.is_not_nil(journal:get("a"))
	end)
end)

describe("Uploader marker checks", function()
	local function exifFor(markers)
		return function(_, id)
			local uuid = markers[id]
			return uuid and { ["XMP-dc:Identifier"] = "album-sync:uuid=" .. uuid .. ";copy=" } or {}
		end
	end

	it("never takes a same-titled photo of another Lightroom photo after a lost response", function()
		local journal = Journal.new(memoryStorage())
		local api = fakeApi({
			uploadAsync = { { nil, { class = "transient", message = "connection lost" } }, { "T2" } },
			recentUploads = { { { { id = "OTHER", title = "IMG_1" } } }, { {} }, { {} } },
			checkTickets = { { { T2 = { complete = 1, photoId = "MINE" } } } },
		})
		api.exif = exifFor({ OTHER = "someone-else" })
		local id = Uploader.new(deps(), api, journal):upload("u1", "/x.jpg", { title = "IMG_1" })
		assert.equal("MINE", id)
	end)

	it("takes the photo carrying this upload's marker", function()
		local journal = Journal.new(memoryStorage())
		local api = fakeApi({
			uploadAsync = { { nil, { class = "transient", message = "lost" } } },
			recentUploads = { { { { id = "OTHER", title = "IMG_1" }, { id = "MINE", title = "IMG_1" } } } },
		})
		api.exif = exifFor({ OTHER = "someone-else", MINE = "u1" })
		assert.equal("MINE", Uploader.new(deps(), api, journal):upload("u1", "/x.jpg", { title = "IMG_1" }))
	end)

	it("reconciles same-titled lost entries exactly by marker", function()
		local journal = Journal.new(memoryStorage())
		journal:open("a", { title = "IMG", started = 10 })
		journal:open("b", { title = "IMG", started = 20 })
		local api = fakeApi({ recentUploads = { { { { id = "P1", title = "IMG" }, { id = "P2", title = "IMG" } } } } })
		api.exif = exifFor({ P1 = "b", P2 = "a" })
		local r = Uploader.new(deps(), api, journal):reconcile()
		assert.same({ a = "P2", b = "P1" }, r.linked)
	end)
end)

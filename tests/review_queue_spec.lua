local ReviewQueue = require("ReviewQueue")

local function memoryStorage()
	local store = {}
	return {
		load = function()
			return store.value
		end,
		save = function(s)
			store.value = s
		end,
	}
end

describe("ReviewQueue", function()
	it("adds without duplicates, persists and removes", function()
		local storage = memoryStorage()
		local q = ReviewQueue.new(storage)
		assert.equal(2, q:add({ { id = "1", candidates = { "u1" } }, { id = "2", candidates = {} } }))
		assert.equal(0, q:add({ { id = "1" } }))
		local q2 = ReviewQueue.new(storage)
		assert.equal(2, #q2:items())
		assert.is_true(q2:remove("1"))
		assert.is_false(q2:remove("1"))
		assert.equal(1, #ReviewQueue.new(storage):items())
	end)
end)

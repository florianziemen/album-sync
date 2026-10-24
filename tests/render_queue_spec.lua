local RenderQueue = require("RenderQueue")

local function recorder()
	local log = {}
	return log,
		function(item)
			log[#log + 1] = "start " .. item
			return { item = item }
		end,
		function(job)
			log[#log + 1] = "await " .. job.item
			return true, "/tmp/" .. job.item .. ".jpg"
		end
end

describe("RenderQueue", function()
	it("starts at most `ahead` items beyond the current one", function()
		local log, start, await = recorder()
		local q = RenderQueue.new({ "a", "b", "c", "d" }, 2, start, await)

		local item, ok, path = q:take()
		assert.equal("a", item)
		assert.is_true(ok)
		assert.equal("/tmp/a.jpg", path)
		assert.same({ "start a", "start b", "start c", "await a" }, log)

		q:take()
		assert.same({ "start a", "start b", "start c", "await a", "start d", "await b" }, log)
		q:take()
		q:take()
		assert.is_nil(q:take())
	end)

	it("renders strictly one at a time with ahead = 0", function()
		local log, start, await = recorder()
		local q = RenderQueue.new({ "a", "b" }, 0, start, await)
		q:take()
		q:take()
		assert.same({ "start a", "await a", "start b", "await b" }, log)
	end)

	it("passes render failures through", function()
		local q = RenderQueue.new({ "a" }, 2, function()
			return {}
		end, function()
			return false, "disk full"
		end)
		local item, ok, msg = q:take()
		assert.equal("a", item)
		assert.is_false(ok)
		assert.equal("disk full", msg)
	end)

	it("handles an empty list", function()
		assert.is_nil(RenderQueue.new({}, 2, error, error):take())
	end)
end)

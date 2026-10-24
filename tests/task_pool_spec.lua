local TaskPool = require("TaskPool")

-- Cooperative fake scheduler: spawned jobs are coroutines advanced on every sleep().
local function scheduler()
	local s = { jobs = {}, maxActive = 0 }
	function s.spawn(fn)
		s.jobs[#s.jobs + 1] = coroutine.create(fn)
	end
	function s.sleep()
		if coroutine.running() and #s.jobs == 0 then
			coroutine.yield()
			return
		end
		local running = s.jobs
		s.jobs = {}
		for _, co in ipairs(running) do
			coroutine.resume(co)
			if coroutine.status(co) ~= "dead" then
				s.jobs[#s.jobs + 1] = co
			end
		end
	end
	return s
end

describe("TaskPool", function()
	it("runs at most `size` jobs at once and collects all results", function()
		local s = scheduler()
		local active, peak = 0, 0
		local pool = TaskPool.new(2, { spawn = s.spawn, sleep = s.sleep })
		for i = 1, 5 do
			pool:submit(i, function()
				active = active + 1
				peak = math.max(peak, active)
				coroutine.yield() -- simulate a slow upload
				active = active - 1
				return { i = i }
			end)
		end
		local results = pool:collect()
		for _, r in ipairs(pool:drain()) do
			results[#results + 1] = r
		end
		assert.equal(5, #results)
		assert.equal(2, peak)
	end)

	it("turns raised errors into results", function()
		local s = scheduler()
		local pool = TaskPool.new(1, { spawn = s.spawn, sleep = s.sleep })
		pool:submit("ctx", function()
			error("boom")
		end)
		s.sleep()
		local results = pool:drain()
		assert.equal(1, #results)
		assert.equal("ctx", results[1].context)
		assert.truthy(results[1].error:find("boom", 1, true))
	end)
end)

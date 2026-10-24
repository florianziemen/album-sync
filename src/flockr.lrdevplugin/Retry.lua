--[[
Retry with exponential backoff and jitter (docs/DESIGN.md §8).

Only "transient" and "throttle" errors are retried; "throttle" honours Flickr's wait hint
(err.waitSeconds, upload code 14). Dependencies: sleep(seconds), random() in [0, 1), log.
]]

local M = {}

M.DEFAULTS = { attempts = 5, base = 2, factor = 2, cap = 60 }

function M.retryable(err)
	return err ~= nil and (err.class == "transient" or err.class == "throttle")
end

--- Delay before retry number `attempt` (1 = first retry).
function M.delay(err, attempt, opts, random)
	opts = opts or M.DEFAULTS
	if err and err.class == "throttle" and err.waitSeconds then
		return err.waitSeconds
	end
	local d = math.min(opts.cap, opts.base * opts.factor ^ (attempt - 1))
	-- full jitter in [d/2, d]
	return d / 2 + d / 2 * (random and random() or 0.5)
end

--[[
Run fn() until it succeeds, fails permanently, or attempts are exhausted.
fn returns result or nil, err.
opts.beforeRetry(err, attempt) may return a result to stop retrying (e.g. an upload that
did arrive despite a lost response), or false to abort with the last error.
Returns result or nil, err (err.attempts = number of attempts made).
]]
function M.run(deps, label, fn, opts)
	opts = opts or {}
	local policy = opts.policy or M.DEFAULTS
	local attempt = 0
	while true do
		attempt = attempt + 1
		local result, err = fn(attempt)
		if result ~= nil then
			return result
		end
		if not M.retryable(err) or attempt >= policy.attempts then
			if err then
				err.attempts = attempt
			end
			return nil, err
		end
		local wait = M.delay(err, attempt, policy, deps.random01)
		if deps.log then
			deps.log(
				"info",
				string.format(
					"retry %s: attempt %d failed (%s/%s: %s), waiting %.1fs",
					label,
					attempt,
					tostring(err.class),
					tostring(err.code),
					tostring(err.message),
					wait
				)
			)
		end
		deps.sleep(wait)
		if opts.beforeRetry then
			local found = opts.beforeRetry(err, attempt)
			if found == false then
				err.attempts = attempt
				return nil, err
			elseif found ~= nil then
				return found
			end
		end
	end
end

return M

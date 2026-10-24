-- Shared test doubles.
local M = {}

--- Fake deps: records requests, replies from queues (one per transport kind).
function M.fakeDeps(replies, uploadReplies)
	local calls, uploads = {}, {}
	return {
		calls = calls,
		uploads = uploads,
		now = function()
			return 1700000000
		end,
		random = function()
			return 1
		end,
		transport = function(req)
			calls[#calls + 1] = req
			return table.remove(replies or {}, 1)
		end,
		postMultipart = function(req)
			uploads[#uploads + 1] = req
			return table.remove(uploadReplies or {}, 1)
		end,
	}
end

M.CREDS = { consumerKey = "ckey", consumerSecret = "csecret" }

function M.loginReply(id, username)
	return {
		status = 200,
		body = string.format('{"user":{"id":"%s","username":{"_content":"%s"}},"stat":"ok"}', id, username),
	}
end

return M

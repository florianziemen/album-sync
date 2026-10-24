--[[
Stores the user's Flickr API key/secret and OAuth access token in LrPasswords
(OS keychain). Nothing secret goes into prefs or logs.
]]

local LrPasswords = import("LrPasswords")

local PREFIX = "lrflickr."
local FIELDS = { "consumerKey", "consumerSecret", "token", "tokenSecret", "userNsid", "username" }

local M = {}

function M.load()
	local t = {}
	for _, f in ipairs(FIELDS) do
		t[f] = LrPasswords.retrieve(PREFIX .. f)
	end
	return t
end

--- Store the given fields; a field set to false is cleared.
function M.save(values)
	for _, f in ipairs(FIELDS) do
		local v = values[f]
		if v == false then
			LrPasswords.store(PREFIX .. f, nil)
		elseif v ~= nil then
			LrPasswords.store(PREFIX .. f, v)
		end
	end
end

return M

--[[
Base64 encoding (RFC 4648). Pure Lua so core modules stay free of Lr* imports.
]]

local floor = math.floor
local byte, sub = string.byte, string.sub

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local M = {}

function M.encode(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = byte(s, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1, c2 = floor(n / 262144) % 64, floor(n / 4096) % 64
		local c3, c4 = floor(n / 64) % 64, n % 64
		out[#out + 1] = sub(ALPHABET, c1 + 1, c1 + 1)
			.. sub(ALPHABET, c2 + 1, c2 + 1)
			.. (b and sub(ALPHABET, c3 + 1, c3 + 1) or "=")
			.. (c and sub(ALPHABET, c4 + 1, c4 + 1) or "=")
	end
	return table.concat(out)
end

return M

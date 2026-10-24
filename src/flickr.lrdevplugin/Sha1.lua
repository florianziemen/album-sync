--[[
Pure-Lua SHA-1 and HMAC-SHA1 (FIPS 180-4, RFC 2104).

Lua 5.1 has no bit operators, so 32-bit logic ops use 4-bit lookup tables.
Only used for OAuth signing of short strings; speed is irrelevant.
]]

local floor = math.floor
local byte, char, format, rep = string.byte, string.char, string.format, string.rep

local M = {}

local TWO32 = 4294967296

-- 16x16 nibble tables for and/xor; or = a + b - and
local AND4, XOR4 = {}, {}
for a = 0, 15 do
	AND4[a], XOR4[a] = {}, {}
	for b = 0, 15 do
		local r_and, r_xor, bit = 0, 0, 1
		local x, y = a, b
		for _ = 1, 4 do
			local xb, yb = x % 2, y % 2
			if xb == 1 and yb == 1 then
				r_and = r_and + bit
			end
			if xb ~= yb then
				r_xor = r_xor + bit
			end
			x, y, bit = floor(x / 2), floor(y / 2), bit * 2
		end
		AND4[a][b], XOR4[a][b] = r_and, r_xor
	end
end

local function bitop(tbl, a, b)
	local r, scale = 0, 1
	for _ = 1, 8 do
		local an, bn = a % 16, b % 16
		r = r + tbl[an][bn] * scale
		a, b, scale = floor(a / 16), floor(b / 16), scale * 16
	end
	return r
end

local function band(a, b)
	return bitop(AND4, a, b)
end
local function bxor(a, b)
	return bitop(XOR4, a, b)
end
local function bor(a, b)
	return a + b - band(a, b)
end
local function bnot(a)
	return TWO32 - 1 - a
end
local function rotl(a, n)
	local hi = floor(a / 2 ^ (32 - n))
	return (a * 2 ^ n) % TWO32 + hi
end

local function be32(s, i)
	local a, b, c, d = byte(s, i, i + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end

local function u32str(n)
	return char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

--- Raw 20-byte SHA-1 digest of `msg`.
function M.binary(msg)
	local len = #msg
	local bits = len * 8
	msg = msg .. "\128" .. rep("\0", (55 - len) % 64) .. u32str(floor(bits / TWO32)) .. u32str(bits % TWO32)

	local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
	local w = {}
	for chunk = 1, #msg, 64 do
		for i = 0, 15 do
			w[i] = be32(msg, chunk + i * 4)
		end
		for i = 16, 79 do
			w[i] = rotl(bxor(bxor(w[i - 3], w[i - 8]), bxor(w[i - 14], w[i - 16])), 1)
		end
		local a, b, c, d, e = h0, h1, h2, h3, h4
		for i = 0, 79 do
			local f, k
			if i < 20 then
				f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
			elseif i < 40 then
				f, k = bxor(bxor(b, c), d), 0x6ED9EBA1
			elseif i < 60 then
				f, k = bor(bor(band(b, c), band(b, d)), band(c, d)), 0x8F1BBCDC
			else
				f, k = bxor(bxor(b, c), d), 0xCA62C1D6
			end
			local t = (rotl(a, 5) + f + e + k + w[i]) % TWO32
			a, b, c, d, e = t, a, rotl(b, 30), c, d
		end
		h0, h1, h2 = (h0 + a) % TWO32, (h1 + b) % TWO32, (h2 + c) % TWO32
		h3, h4 = (h3 + d) % TWO32, (h4 + e) % TWO32
	end
	return u32str(h0) .. u32str(h1) .. u32str(h2) .. u32str(h3) .. u32str(h4)
end

local function tohex(s)
	return (s:gsub(".", function(c)
		return format("%02x", byte(c))
	end))
end

function M.hex(msg)
	return tohex(M.binary(msg))
end

local function xorpad(key, pad)
	return (key:gsub(".", function(c)
		return char(bxor(byte(c), pad))
	end))
end

--- Raw 20-byte HMAC-SHA1 of `msg` under `key`.
function M.hmacBinary(key, msg)
	if #key > 64 then
		key = M.binary(key)
	end
	key = key .. rep("\0", 64 - #key)
	return M.binary(xorpad(key, 0x5C) .. M.binary(xorpad(key, 0x36) .. msg))
end

function M.hmacHex(key, msg)
	return tohex(M.hmacBinary(key, msg))
end

return M

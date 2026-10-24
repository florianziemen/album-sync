--[[
Wrapping text for dialogs: LrView's static_text only wraps with a fixed width and more than
one line; otherwise long texts are cut off (Plug-in Manager, service settings).
]]

local M = {}

M.CHARS = 70 -- dialog width in characters

--- static_text that wraps `text` to `chars` columns (default M.CHARS).
function M.wrapped(f, text, chars)
	chars = chars or M.CHARS
	local lines = 0
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		-- count characters, not bytes (UTF-8 continuation bytes are 0x80-0xBF)
		local _, n = line:gsub("[^\128-\191]", "")
		lines = lines + math.max(1, math.ceil(n / chars))
	end
	return f:static_text({ title = text, width_in_chars = chars, height_in_lines = lines })
end

return M

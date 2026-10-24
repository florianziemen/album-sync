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
		-- byte length overestimates multi-byte characters: at worst one spare line
		lines = lines + math.max(1, math.ceil(#line / (chars * 0.85)))
	end
	return f:static_text({ title = text, width_in_chars = chars, height_in_lines = lines })
end

return M

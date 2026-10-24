--[[
Text for dialogs that never runs off the edge: LrView's static_text does not reliably wrap
(settings sections cut long lines off), but it does show explicit line breaks. So the text is
broken at word boundaries here, and the view gets exactly that many lines.
]]

local M = {}

M.CHARS = 70 -- characters per line

local function charCount(s)
	local _, n = s:gsub("[^\128-\191]", "") -- UTF-8: skip continuation bytes
	return n
end

--- `text` broken into lines of at most `chars` characters (words longer than that stay whole).
function M.wrap(text, chars)
	chars = chars or M.CHARS
	local out = {}
	for paragraph in (text .. "\n"):gmatch("([^\n]*)\n") do
		local line = ""
		for word in paragraph:gmatch("%S+") do
			if line == "" then
				line = word
			elseif charCount(line) + 1 + charCount(word) <= chars then
				line = line .. " " .. word
			else
				out[#out + 1] = line
				line = word
			end
		end
		out[#out + 1] = line
	end
	return table.concat(out, "\n"), #out
end

--- static_text showing `text` wrapped to `chars` characters per line.
function M.wrapped(f, text, chars)
	local wrapped, lines = M.wrap(text, chars)
	return f:static_text({ title = wrapped, height_in_lines = lines })
end

return M

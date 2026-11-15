--[[
List of fields that differ on Flickr while Lightroom did not change them (RemoteState.diff
"flickrOnly"). They are kept on Flickr; this module formats them for the end-of-publish dialog
and its CSV export. Items: { file, id, url, field, flickr, lightroom }.
]]

local M = {}

M.COLUMNS = { "file", "id", "field", "flickr", "lightroom", "url" }
M.HEADER = { "File", "Flickr ID", "Field", "Flickr value", "Lightroom value", "URL" }

local function csvCell(v)
	local s = tostring(v == nil and "" or v)
	if s:find('[",\r\n]') then
		s = '"' .. s:gsub('"', '""') .. '"'
	end
	return s
end

local function csvLine(cells, n)
	local out = {}
	for i = 1, n do -- cells may contain nil
		out[i] = csvCell(cells[i])
	end
	return table.concat(out, ",")
end

--- RFC 4180 CSV (CRLF line ends), header first.
function M.toCsv(items)
	local n = #M.COLUMNS
	local lines = { csvLine(M.HEADER, n) }
	for _, item in ipairs(items) do
		local cells = {}
		for i, k in ipairs(M.COLUMNS) do
			cells[i] = item[k]
		end
		lines[#lines + 1] = csvLine(cells, n)
	end
	return table.concat(lines, "\r\n") .. "\r\n"
end

--- `s` on one line, cut to at most `chars` characters (UTF-8 aware), with "…" when cut.
function M.shorten(s, chars)
	s = tostring(s or ""):gsub("%s+", " ")
	local out, n = {}, 0
	for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		n = n + 1
		if n > chars then
			return table.concat(out, "", 1, chars - 1) .. "…"
		end
		out[n] = ch
	end
	return s
end

--- One display line per item; long values are shortened (the CSV has them in full).
function M.lines(items, chars)
	chars = chars or 40
	local out = {}
	for i, item in ipairs(items) do
		out[i] = string.format(
			"%s (%s) · %s: Flickr “%s”, Lightroom “%s”",
			tostring(item.file or "?"),
			tostring(item.id),
			tostring(item.field),
			M.shorten(item.flickr, chars),
			M.shorten(item.lightroom, chars)
		)
	end
	return out
end

--- Number of distinct photos in the list.
function M.photoCount(items)
	local seen, n = {}, 0
	for _, item in ipairs(items) do
		if not seen[item.id] then
			seen[item.id] = true
			n = n + 1
		end
	end
	return n
end

return M

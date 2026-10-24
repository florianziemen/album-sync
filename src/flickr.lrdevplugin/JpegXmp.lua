--[[
Adds an identification marker to the XMP packet of a JPEG (docs/DESIGN.md §6c):
dc:identifier = "lrflickr:uuid=<Lightroom photo uuid>;copy=<virtual copy name>".
Flickr's getExif only returns XMP namespaces it knows (a custom namespace was dropped,
2026-10-24), so the marker uses Dublin Core, which Flickr returns and Lightroom leaves empty.
Pure string manipulation of the JPEG container: image data is not touched.

The first <rdf:Description> of the existing XMP APP1 segment gets the attribute (replacing an
earlier marker); a JPEG without XMP gets a minimal packet after its APPn segments.
]]

local M = {}

M.DC = "http://purl.org/dc/elements/1.1/"
M.TAG = "lrflickr:"

local XMP_ID = "http://ns.adobe.com/xap/1.0/\0"
local MAX_PAYLOAD = 65533 -- segment length field covers itself (2 bytes) + payload

local function u16(s, i)
	local a, b = s:byte(i, i + 1)
	return a * 256 + b
end

local function be16(n)
	return string.char(math.floor(n / 256), n % 256)
end

local function escape(v)
	return (tostring(v or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub('"', "&quot;"))
end

--- Marker value for props { uuid, copy }.
function M.value(props)
	return string.format("%suuid=%s;copy=%s", M.TAG, tostring(props.uuid or ""), tostring(props.copy or ""))
end

--- Parse a marker value; nil if the string is not one.
function M.parse(value)
	if type(value) ~= "string" then
		return nil
	end
	local uuid, copy = value:match("^%s*" .. M.TAG .. "uuid=([^;]*);copy=(.*)$")
	if not uuid then
		return nil
	end
	copy = copy:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&quot;", '"')
	return { uuid = uuid ~= "" and uuid or nil, copy = copy }
end

--- Add/replace the marker attribute in an XMP packet string. Returns the new packet or nil, err.
function M.patchPacket(packet, props)
	-- Drop a marker from an earlier run (re-upload of the same file).
	packet = packet:gsub('%s+dc:identifier="' .. M.TAG .. '[^"]*"', "")
	local s, e = packet:find("<rdf:Description", 1, true)
	if not s then
		return nil, "no rdf:Description in XMP packet"
	end
	local tagEnd = packet:find(">", e, true)
	local startTag = packet:sub(s, tagEnd or #packet)
	local attrs = ' dc:identifier="' .. escape(M.value(props)) .. '"'
	if not startTag:find("xmlns:dc=", 1, true) then
		attrs = ' xmlns:dc="' .. M.DC .. '"' .. attrs
	end
	return packet:sub(1, e) .. attrs .. packet:sub(e + 1)
end

function M.newPacket(props)
	return '<?xpacket begin="\239\187\191" id="W5M0MpCehiHzreSzNTczkc9d"?>'
		.. '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
		.. '<rdf:Description rdf:about="" xmlns:dc="'
		.. M.DC
		.. '" dc:identifier="'
		.. escape(M.value(props))
		.. '"/></rdf:RDF></x:xmpmeta>'
		.. '<?xpacket end="w"?>'
end

local function segment(payload)
	return "\255\225" .. be16(#payload + 2) .. payload
end

--[[
jpeg: file contents. props: { uuid, copy }.
Returns the new contents, or nil, err (not a JPEG, packet too large, malformed).
]]
function M.apply(jpeg, props)
	if jpeg:sub(1, 2) ~= "\255\216" then
		return nil, "not a JPEG"
	end
	local pos, lastApp = 3, 3
	while pos + 3 <= #jpeg do
		if jpeg:byte(pos) ~= 0xFF then
			return nil, "malformed JPEG segment at " .. pos
		end
		local marker = jpeg:byte(pos + 1)
		if marker == 0xDA or marker == 0xD9 then
			break -- start of scan / end of image: no XMP found
		end
		local len = u16(jpeg, pos + 2)
		local payloadStart, nextPos = pos + 4, pos + 2 + len
		if marker == 0xE1 and jpeg:sub(payloadStart, payloadStart + #XMP_ID - 1) == XMP_ID then
			local packet = jpeg:sub(payloadStart + #XMP_ID, nextPos - 1)
			local patched, err = M.patchPacket(packet, props)
			if not patched then
				return nil, err
			end
			local payload = XMP_ID .. patched
			if #payload > MAX_PAYLOAD then
				return nil, "XMP packet would exceed one segment"
			end
			return jpeg:sub(1, pos - 1) .. segment(payload) .. jpeg:sub(nextPos)
		end
		if marker >= 0xE0 and marker <= 0xEF then
			lastApp = nextPos
		end
		pos = nextPos
	end
	local payload = XMP_ID .. M.newPacket(props)
	return jpeg:sub(1, lastApp - 1) .. segment(payload) .. jpeg:sub(lastApp)
end

--[[
Read the marker back from Flickr's EXIF (FlickrApi:exif result): any tag whose value is a
marker (normally XMP-dc:Identifier). Returns { uuid, copy } (fields nil when absent).
]]
function M.fromExif(exif)
	for _, value in pairs(exif or {}) do
		local m = M.parse(value)
		if m then
			return m
		end
	end
	return {}
end

return M

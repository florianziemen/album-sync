--[[
Adds identification properties to the XMP packet of a JPEG (docs/DESIGN.md §6c):
lrflickr:uuid (Lightroom photo uuid) and lrflickr:copy (virtual copy name, "" for masters).
Pure string manipulation of the JPEG container: image data is not touched.

The first <rdf:Description> of the existing XMP APP1 segment gets the attributes (replacing
earlier ones); a JPEG without XMP gets a minimal packet after its APPn segments.
]]

local M = {}

M.NS = "http://lrflickr.invalid/ns/1.0/"
M.PREFIX = "lrflickr"

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

local function attributes(props)
	return string.format(
		' xmlns:%s="%s" %s:uuid="%s" %s:copy="%s"',
		M.PREFIX,
		M.NS,
		M.PREFIX,
		escape(props.uuid),
		M.PREFIX,
		escape(props.copy)
	)
end

--- Add/replace our attributes in an XMP packet string. Returns the new packet or nil, err.
function M.patchPacket(packet, props)
	-- Drop attributes from an earlier run (re-upload of the same file).
	packet = packet:gsub("%s+xmlns:" .. M.PREFIX .. '="[^"]*"', "")
	packet = packet:gsub("%s+" .. M.PREFIX .. ':%w+="[^"]*"', "")
	local s, e = packet:find("<rdf:Description", 1, true)
	if not s then
		return nil, "no rdf:Description in XMP packet"
	end
	return packet:sub(1, e) .. attributes(props) .. packet:sub(e + 1)
end

function M.newPacket(props)
	return '<?xpacket begin="\239\187\191" id="W5M0MpCehiHzreSzNTczkc9d"?>'
		.. '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
		.. '<rdf:Description rdf:about=""'
		.. attributes(props)
		.. "/></rdf:RDF></x:xmpmeta>"
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
Read our properties back from Flickr's EXIF (FlickrApi:exif result, keyed by tag and by
"tagspace:tag"). Flickr names unknown XMP namespaces by prefix; match case-insensitively.
Returns { uuid, copy } (fields nil when absent).
]]
function M.fromExif(exif)
	local out = {}
	for key, value in pairs(exif or {}) do
		local k = key:lower()
		if k:find(M.PREFIX, 1, true) or k:find("xmp%-" .. M.PREFIX) then
			if k:find("uuid$") then
				out.uuid = value
			elseif k:find("copy$") then
				out.copy = value
			end
		end
	end
	return out
end

return M

local JpegXmp = require("JpegXmp")

local function seg(marker, payload)
	local len = #payload + 2
	return "\255" .. string.char(marker) .. string.char(math.floor(len / 256), len % 256) .. payload
end

local XMP_ID = "http://ns.adobe.com/xap/1.0/\0"
local SCAN = "\255\218\0\4ab" .. "IMAGEDATA\255\217"
local JFIF = seg(0xE0, "JFIF\0\1\1\0\0\1\0\1\0\0")
local EXIF = seg(0xE1, "Exif\0\0rest-of-exif")
local LR_XMP = '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF><rdf:Description rdf:about="" '
	.. 'xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="3"/></rdf:RDF></x:xmpmeta>'

local function segments(jpeg)
	local out, pos = {}, 3
	while pos < #jpeg do
		local marker = jpeg:byte(pos + 1)
		if marker == 0xDA then
			break
		end
		local len = jpeg:byte(pos + 2) * 256 + jpeg:byte(pos + 3)
		out[#out + 1] = { marker = marker, payload = jpeg:sub(pos + 4, pos + 1 + len) }
		pos = pos + 2 + len
	end
	return out
end

describe("JpegXmp", function()
	it("adds attributes to Lightroom's XMP packet and keeps everything else", function()
		local jpeg = "\255\216" .. JFIF .. EXIF .. seg(0xE1, XMP_ID .. LR_XMP) .. SCAN
		local out = assert(JpegXmp.apply(jpeg, { uuid = "U-1", copy = "Copy 1" }))
		local segs = segments(out)
		assert.equal(3, #segs)
		local xmp = segs[3].payload
		assert.truthy(xmp:find('dc:identifier="flockr:uuid=U-1;copy=Copy 1"', 1, true))
		assert.truthy(xmp:find('xmlns:dc="http://purl.org/dc/elements/1.1/"', 1, true))
		assert.truthy(xmp:find('xmp:Rating="3"', 1, true))
		assert.equal(SCAN, out:sub(-#SCAN))
		assert.equal(EXIF, out:sub(3 + #JFIF, 2 + #JFIF + #EXIF))
	end)

	it("replaces its own attributes on a second run", function()
		local jpeg = "\255\216" .. seg(0xE1, XMP_ID .. LR_XMP) .. SCAN
		local once = assert(JpegXmp.apply(jpeg, { uuid = "A", copy = "" }))
		local twice = assert(JpegXmp.apply(once, { uuid = "B", copy = "x" }))
		local xmp = segments(twice)[1].payload
		assert.is_nil(xmp:find("uuid=A;", 1, true))
		local _, n = xmp:gsub("dc:identifier=", "")
		assert.equal(1, n)
		assert.truthy(xmp:find("flockr:uuid=B;copy=x", 1, true))
	end)

	it("creates a packet after the APP segments when there is none", function()
		local jpeg = "\255\216" .. JFIF .. EXIF .. seg(0xDB, "quant") .. SCAN
		local out = assert(JpegXmp.apply(jpeg, { uuid = "U", copy = 'a"b<c' }))
		local segs = segments(out)
		assert.same({ 0xE0, 0xE1, 0xE1, 0xDB }, { segs[1].marker, segs[2].marker, segs[3].marker, segs[4].marker })
		assert.truthy(segs[3].payload:find("copy=a&quot;b&lt;c", 1, true))
	end)

	it("does not declare the dc namespace twice", function()
		local withDc = '<x:xmpmeta><rdf:RDF><rdf:Description rdf:about="" '
			.. 'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>F</dc:creator></rdf:Description></rdf:RDF></x:xmpmeta>'
		local patched = assert(JpegXmp.patchPacket(withDc, { uuid = "U", copy = "" }))
		local _, n = patched:gsub("xmlns:dc=", "")
		assert.equal(1, n)
	end)

	it("rejects non-JPEG data", function()
		local out, err = JpegXmp.apply("GIF89a", { uuid = "U" })
		assert.is_nil(out)
		assert.equal("not a JPEG", err)
	end)

	it("reads the properties back from Flickr EXIF tags", function()
		local r = JpegXmp.fromExif({ ["XMP-dc:Identifier"] = "flockr:uuid=U-1;copy=Copy 1", Make = "Canon" })
		assert.same({ uuid = "U-1", copy = "Copy 1" }, r)
		assert.same({ uuid = "U-2", copy = "" }, JpegXmp.fromExif({ Identifier = "flockr:uuid=U-2;copy=" }))
		assert.same({}, JpegXmp.fromExif({ Make = "Canon" }))
		-- marker of uploads made before the rename
		assert.same({ uuid = "U-3", copy = "" }, JpegXmp.fromExif({ Identifier = "lrflickr:uuid=U-3;copy=" }))
	end)
end)

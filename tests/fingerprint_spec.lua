local Fingerprint = require("Fingerprint")

local DEVELOP = { Exposure2012 = 0.5, ToneCurvePV2012 = { 0, 0, 255, 255 }, CropTop = 0.1 }
local EXPORT = {
	LR_format = "JPEG",
	LR_jpeg_quality = 0.9,
	LR_size_doConstrain = false,
	LR_export_destinationPathPrefix = "/somewhere",
	LR_tokens = "{{image_name}}",
}

describe("Fingerprint", function()
	it("is independent of table insertion order", function()
		local a = { x = 1, y = { 1, 2 }, z = "s" }
		local b = {}
		b.z, b.y, b.x = "s", { 1, 2 }, 1
		assert.equal(Fingerprint.canonical(a), Fingerprint.canonical(b))
	end)

	it("changes with develop settings", function()
		local changed = { Exposure2012 = 0.6, ToneCurvePV2012 = { 0, 0, 255, 255 }, CropTop = 0.1 }
		assert.are_not.equal(Fingerprint.image(DEVELOP, EXPORT), Fingerprint.image(changed, EXPORT))
	end)

	it("changes with render-relevant export settings only", function()
		local base = Fingerprint.image(DEVELOP, EXPORT)
		local other = {}
		for k, v in pairs(EXPORT) do
			other[k] = v
		end
		other.LR_export_destinationPathPrefix = "/elsewhere"
		other.LR_tokens = "{{custom}}"
		assert.equal(base, Fingerprint.image(DEVELOP, other))
		other.LR_jpeg_quality = 0.6
		assert.are_not.equal(base, Fingerprint.image(DEVELOP, other))
	end)

	it("hashes metadata as sent", function()
		local a = Fingerprint.metadata({ title = "T", description = "" })
		assert.equal(40, #a)
		assert.equal(a, Fingerprint.metadata({ description = "", title = "T" }))
		assert.are_not.equal(a, Fingerprint.metadata({ title = "T2", description = "" }))
	end)

	it("distinguishes types and nil", function()
		assert.are_not.equal(Fingerprint.canonical({ a = "1" }), Fingerprint.canonical({ a = 1 }))
		assert.are_not.equal(Fingerprint.metadata({ title = "" }), Fingerprint.metadata({}))
	end)
end)

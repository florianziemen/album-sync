local Sha1 = require("Sha1")
local Base64 = require("Base64")

describe("Sha1", function()
	it("matches FIPS 180 test vectors", function()
		assert.equal("da39a3ee5e6b4b0d3255bfef95601890afd80709", Sha1.hex(""))
		assert.equal("a9993e364706816aba3e25717850c26c9cd0d89d", Sha1.hex("abc"))
		assert.equal(
			"84983e441c3bd26ebaae4aa1f95129e5e54670f1",
			Sha1.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
		)
	end)

	it("handles messages around the 55/56/64-byte padding boundaries", function()
		assert.equal("c1c8bbdc22796e28c0e15163d20899b65621d65a", Sha1.hex(string.rep("a", 55)))
		assert.equal("c2db330f6083854c99d4b5bfb6e8f29f201be699", Sha1.hex(string.rep("a", 56)))
		assert.equal("0098ba824b5c16427bd7a1122a5a442a25ec644d", Sha1.hex(string.rep("a", 64)))
	end)

	it("matches RFC 2202 HMAC-SHA1 vectors", function()
		assert.equal("b617318655057264e28bc0b6fb378c8ef146be00", Sha1.hmacHex(string.rep("\11", 20), "Hi There"))
		assert.equal("effcdf6ae5eb2fa2d27416d5f184df9c259a7c79", Sha1.hmacHex("Jefe", "what do ya want for nothing?"))
		-- key longer than block size
		assert.equal(
			"aa4ae5e15272d00e95705637ce8a3b55ed402112",
			Sha1.hmacHex(string.rep("\170", 80), "Test Using Larger Than Block-Size Key - Hash Key First")
		)
	end)
end)

describe("Base64", function()
	it("matches RFC 4648 vectors", function()
		local cases = { [""] = "", f = "Zg==", fo = "Zm8=", foo = "Zm9v", foob = "Zm9vYg==", fooba = "Zm9vYmE=" }
		for input, expected in pairs(cases) do
			assert.equal(expected, Base64.encode(input))
		end
		assert.equal("Zm9vYmFy", Base64.encode("foobar"))
	end)
end)

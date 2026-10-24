local OAuth = require("OAuth")

describe("OAuth", function()
	it("percent-encodes per RFC 3986", function()
		assert.equal("abc-._~", OAuth.encode("abc-._~"))
		assert.equal("a%20b%2Bc%26d%3D%2A", OAuth.encode("a b+c&d=*"))
		assert.equal("%C3%A4", OAuth.encode("ä"))
	end)

	it("parses form-encoded bodies", function()
		local t = OAuth.parseForm("oauth_problem=parameter_absent&oauth_parameters_absent=a%26b&x=1+2")
		assert.equal("parameter_absent", t.oauth_problem)
		assert.equal("a&b", t.oauth_parameters_absent)
		assert.equal("1 2", t.x)
	end)

	-- Example from the OAuth 1.0 spec (photos.example.net).
	it("produces the reference HMAC-SHA1 signature", function()
		local signed = OAuth.sign({
			method = "GET",
			url = "http://photos.example.net/photos",
			params = { file = "vacation.jpg", size = "original" },
			consumerKey = "dpf43f3p2l4k3l03",
			consumerSecret = "kd94hf93k423kf44",
			token = "nnch734d00sl2jdk",
			tokenSecret = "pfkkdhi9sl3r4s00",
			nonce = "kllo9940pd9333jh",
			timestamp = 1191242096,
		})
		assert.equal("tR3+Ty81lMeYAr/Fid0kMTYa/WM=", signed.oauth_signature)
		assert.equal("vacation.jpg", signed.file)
	end)

	it("builds the reference base string", function()
		local base = OAuth.baseString("get", "HTTP://Photos.Example.net/photos", { b = "2", a = "1 2" })
		assert.equal("GET&http%3A%2F%2Fphotos.example.net%2Fphotos&a%3D1%25202%26b%3D2", base)
	end)

	it("generates 32-char nonces from the injected random source", function()
		local n = OAuth.nonce(function()
			return 1
		end)
		assert.equal(string.rep("a", 32), n)
	end)
end)

local KeptChanges = require("KeptChanges")

local items = {
	{ file = "a.jpg", id = "1", url = "https://x/1/", field = "title", flickr = "a.jpg", lightroom = "a" },
	{ file = "b.jpg", id = "2", url = "https://x/2/", field = "title", flickr = 'say "hi", ok', lightroom = "b" },
	{ file = "b.jpg", id = "2", url = "https://x/2/", field = "privacy", flickr = "public", lightroom = "private" },
}

describe("KeptChanges", function()
	it("writes CSV with a header and quotes cells that need it", function()
		local csv = KeptChanges.toCsv(items)
		assert.equal(
			"File,Flickr ID,Field,Flickr value,Lightroom value,URL\r\n"
				.. "a.jpg,1,title,a.jpg,a,https://x/1/\r\n"
				.. 'b.jpg,2,title,"say ""hi"", ok",b,https://x/2/\r\n'
				.. "b.jpg,2,privacy,public,private,https://x/2/\r\n",
			csv
		)
	end)

	it("quotes line breaks and writes empty cells for nil", function()
		local csv = KeptChanges.toCsv({ { id = "3", field = "description", flickr = "one\ntwo" } })
		assert.equal('3,description,"one\ntwo",,', csv:match("\r\n,(.*)\r\n$"))
	end)

	it("shortens long values by characters, not bytes", function()
		assert.equal("abc", KeptChanges.shorten("abc", 3))
		assert.equal("ab…", KeptChanges.shorten("abcd", 3))
		assert.equal("äö…", KeptChanges.shorten("äöüß", 3))
		assert.equal("a b", KeptChanges.shorten("a\n  b", 5))
	end)

	it("formats one display line per item", function()
		local lines = KeptChanges.lines(items)
		assert.equal(3, #lines)
		assert.equal("b.jpg (2) · privacy: Flickr “public”, Lightroom “private”", lines[3])
	end)

	it("counts distinct photos", function()
		assert.equal(2, KeptChanges.photoCount(items))
		assert.equal(0, KeptChanges.photoCount({}))
	end)
end)

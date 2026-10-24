local PhotoFields = require("PhotoFields")

describe("PhotoFields", function()
	it("uses the LR title, else the file name without extension", function()
		assert.equal("Sunset", PhotoFields.title({ title = "Sunset", fileName = "IMG_1.CR3" }))
		assert.equal("IMG_1", PhotoFields.title({ title = "  ", fileName = "IMG_1.CR3" }))
		assert.equal("a.b", PhotoFields.title({ fileName = "a.b.jpg" }))
	end)

	it("converts exportable keywords to Flickr tags", function()
		assert.equal('Deckel "New York" cat', PhotoFields.tags("Deckel, New York, cat"))
		assert.equal("a b", PhotoFields.tags(" a ,b, A,, "))
		assert.equal('"say hi"', PhotoFields.tags('say "hi"'))
		assert.equal("", PhotoFields.tags(nil))
		assert.equal("", PhotoFields.tags(""))
	end)

	it("maps caption to description and keywords to tags", function()
		assert.same(
			{ title = "T", description = "C", tags = "Deckel" },
			PhotoFields.metadataFields({ title = "T", fileName = "x.jpg", caption = "C", keywords = "Deckel" })
		)
	end)

	it("uploads private and hidden by default", function()
		local f = PhotoFields.uploadFields(PhotoFields.metadataFields({ fileName = "x.jpg", keywords = "k" }))
		assert.same({
			title = "x",
			description = "",
			tags = "k",
			is_public = "0",
			is_friend = "0",
			is_family = "0",
			hidden = "2",
		}, f)
	end)

	it("applies privacy settings", function()
		local f = PhotoFields.uploadFields({ title = "x" }, { isPublic = true, hidden = false })
		assert.equal("1", f.is_public)
		assert.equal("1", f.hidden)
	end)

	it("builds photo URLs", function()
		assert.equal("https://www.flickr.com/photos/1@N07/42/", PhotoFields.photoUrl("1@N07", "42"))
	end)
end)

local PhotoFields = require("PhotoFields")

describe("PhotoFields", function()
	it("uses the LR title, else the file name without extension", function()
		assert.equal("Sunset", PhotoFields.title({ title = "Sunset", fileName = "IMG_1.CR3" }))
		assert.equal("IMG_1", PhotoFields.title({ title = "  ", fileName = "IMG_1.CR3" }))
		assert.equal("a.b", PhotoFields.title({ fileName = "a.b.jpg" }))
	end)

	it("maps caption to description", function()
		assert.same(
			{ title = "T", description = "C" },
			PhotoFields.metadataFields({ title = "T", fileName = "x.jpg", caption = "C" })
		)
	end)

	it("uploads private and hidden by default, without tags", function()
		local f = PhotoFields.uploadFields({ fileName = "x.jpg" })
		assert.same({
			title = "x",
			description = "",
			is_public = "0",
			is_friend = "0",
			is_family = "0",
			hidden = "2",
		}, f)
	end)

	it("applies privacy settings", function()
		local f = PhotoFields.uploadFields({ fileName = "x" }, { isPublic = true, hidden = false })
		assert.equal("1", f.is_public)
		assert.equal("1", f.hidden)
	end)

	it("builds photo URLs", function()
		assert.equal("https://www.flickr.com/photos/1@N07/42/", PhotoFields.photoUrl("1@N07", "42"))
	end)
end)

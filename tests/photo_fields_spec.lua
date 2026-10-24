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

	it("maps caption, keywords, privacy and location", function()
		local meta = {
			title = "T",
			fileName = "x.jpg",
			caption = "C",
			keywords = "Deckel",
			gps = { latitude = 53.55, longitude = 9.99 },
		}
		assert.same({
			title = "T",
			description = "C",
			tags = "Deckel",
			privacy = "friends",
			location = "53.5500,9.9900",
			latitude = 53.55,
			longitude = 9.99,
		}, PhotoFields.metadataFields(meta, { privacy = "friends", location = true }))
		local noLoc = PhotoFields.metadataFields(meta, { location = false })
		assert.equal("", noLoc.location)
		assert.is_nil(noLoc.latitude)
		assert.equal("private", noLoc.privacy)
	end)

	it("uploads with privacy flags and hidden from search by default", function()
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
		f = PhotoFields.uploadFields({ title = "x", privacy = "public" }, { hidden = false })
		assert.equal("1", f.is_public)
		assert.equal("1", f.hidden)
		f = PhotoFields.uploadFields({ title = "x", privacy = "friendsFamily" })
		assert.same({ "0", "1", "1" }, { f.is_public, f.is_friend, f.is_family })
	end)

	it("builds photo URLs", function()
		assert.equal("https://www.flickr.com/photos/1@N07/42/", PhotoFields.photoUrl("1@N07", "42"))
	end)
end)

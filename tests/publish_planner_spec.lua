local PublishPlanner = require("PublishPlanner")

local SAME = { image = "i1", metadata = "m1" }

local function plan(t)
	return PublishPlanner.plan(t)
end

describe("PublishPlanner", function()
	it("uploads photos unknown to Flickr", function()
		assert.equal("upload", plan({ current = SAME }))
	end)

	it("relinks photos already on Flickr (removed and re-added, or other collection)", function()
		assert.equal("relink", plan({ flickrId = "9", stored = SAME, current = SAME }))
		assert.equal("relink", plan({ flickrId = "9", stored = SAME, current = { image = "i1", metadata = "m2" } }))
		-- known on Flickr but never fingerprinted
		assert.equal("relink", plan({ flickrId = "9", current = SAME }))
	end)

	it("replaces when the image changed, also for relinks", function()
		local changed = { image = "i2", metadata = "m1" }
		assert.equal("replace", plan({ publishedId = "9", stored = SAME, current = changed }))
		assert.equal("replace", plan({ flickrId = "9", stored = SAME, current = changed }))
	end)

	it("updates metadata only when only metadata changed", function()
		assert.equal(
			"metadata",
			plan({ publishedId = "9", stored = SAME, current = { image = "i1", metadata = "m2" } })
		)
	end)

	it("adopts photos published before fingerprints existed", function()
		assert.equal("adopt", plan({ publishedId = "9", current = SAME }))
	end)

	it("does nothing when unchanged", function()
		assert.equal("noop", plan({ publishedId = "9", flickrId = "9", stored = SAME, current = SAME }))
	end)

	it("renders only for upload and replace", function()
		assert.is_true(PublishPlanner.RENDERS.upload)
		assert.is_true(PublishPlanner.RENDERS.replace)
		assert.is_nil(PublishPlanner.RENDERS.metadata)
		assert.is_nil(PublishPlanner.RENDERS.relink)
		assert.is_true(PublishPlanner.RENDERS.reuploadKeep)
		assert.is_true(PublishPlanner.RENDERS.reuploadDelete)
		assert.is_nil(PublishPlanner.RENDERS.metadataOutdated)
	end)

	it("summarizes actions", function()
		assert.same({ upload = 2, noop = 1 }, PublishPlanner.summarize({ "upload", "noop", "upload" }))
	end)
end)

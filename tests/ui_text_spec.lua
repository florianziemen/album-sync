local UiText = require("UiText")

local f = {
	static_text = function(_, props)
		return props
	end,
}

describe("UiText", function()
	it("breaks text at word boundaries", function()
		local text, lines = UiText.wrap("one two three four five", 9)
		assert.equal("one two\nthree\nfour five", text)
		assert.equal(3, lines)
	end)

	it("keeps explicit line breaks and counts characters, not bytes", function()
		local text, lines = UiText.wrap("“quoted” words here\nsecond", 19)
		assert.equal("“quoted” words here\nsecond", text)
		assert.equal(2, lines)
	end)

	it("never splits a long word", function()
		local text = UiText.wrap("File > Plug-in Extras > Album Sync: Log in", 5)
		assert.truthy(text:find("Plug-in", 1, true))
	end)

	it("returns a static_text with the wrapped title and its line count", function()
		local view = UiText.wrapped(f, string.rep("word ", 30)) -- 149 characters
		assert.equal(3, view.height_in_lines)
		assert.is_nil(view.title:find("\n[^\n]*\n[^\n]*\n"))
	end)
end)

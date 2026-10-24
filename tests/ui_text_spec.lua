local UiText = require("UiText")

local f = {
	static_text = function(_, props)
		return props
	end,
}

describe("UiText.wrapped", function()
	it("sets a fixed width and enough lines to wrap", function()
		local short = UiText.wrapped(f, "Short text.")
		assert.same({ title = "Short text.", width_in_chars = 70, height_in_lines = 1 }, short)
		local long = UiText.wrapped(f, string.rep("word ", 30)) -- 150 characters
		assert.equal(3, long.height_in_lines)
	end)

	it("counts explicit line breaks", function()
		assert.equal(2, UiText.wrapped(f, "first\nsecond").height_in_lines)
		assert.equal(4, UiText.wrapped(f, "a\n" .. string.rep("x", 100), 40).height_in_lines)
	end)
end)

--[[
Change detection fingerprints (docs/DESIGN.md §6).

image:    develop settings + render-relevant export settings + scheme version.
metadata: the fields we push to Flickr, as sent.
Not a security hash; SHA-1 hex via the pure-Lua implementation.
]]

local Sha1 = require("Sha1")

local M = {}

-- Bump when the inputs or canonical form change: forces a one-time re-evaluation.
M.SCHEME = 1

-- Export settings that change the rendered pixels.
local RENDER_PREFIXES = {
	"LR_format",
	"LR_jpeg_",
	"LR_size_",
	"LR_outputSharpening",
	"LR_useWatermark",
	"LR_watermarking",
	"LR_export_colorSpace",
	"LR_export_bitDepth",
}

--- Deterministic string form of nested tables (sorted keys, stable number format).
function M.canonical(v)
	local t = type(v)
	if t == "table" then
		local keys = {}
		for k in pairs(v) do
			keys[#keys + 1] = k
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		local parts = {}
		for _, k in ipairs(keys) do
			parts[#parts + 1] = M.canonical(k) .. "=" .. M.canonical(v[k])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif t == "number" then
		return string.format("%.10g", v)
	elseif t == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

function M.renderSubset(exportSettings)
	local subset = {}
	for k, v in pairs(exportSettings or {}) do
		for _, prefix in ipairs(RENDER_PREFIXES) do
			if type(k) == "string" and k:sub(1, #prefix) == prefix then
				subset[k] = v
				break
			end
		end
	end
	return subset
end

function M.image(developSettings, exportSettings)
	return Sha1.hex(M.canonical({
		scheme = M.SCHEME,
		develop = developSettings or {},
		render = M.renderSubset(exportSettings),
	}))
end

--- fields: the table of values sent to Flickr (title, description, ...).
function M.metadata(fields)
	return Sha1.hex(M.canonical({ scheme = M.SCHEME, fields = fields or {} }))
end

return M

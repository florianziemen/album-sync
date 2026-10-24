--[[
Flickr visibility (docs/DESIGN.md §3): service default, overridable per collection (album)
and per photo. The most specific setting wins: photo > collection > service.
]]

local M = {}

M.VALUES = { "public", "friendsFamily", "friends", "family", "private" }

M.TITLES = {
	public = "Public",
	friendsFamily = "Friends and family",
	friends = "Friends",
	family = "Family",
	private = "Private",
}

local FLAGS = {
	public = { 1, 0, 0 },
	friendsFamily = { 0, 1, 1 },
	friends = { 0, 1, 0 },
	family = { 0, 0, 1 },
	private = { 0, 0, 0 },
}

function M.valid(v)
	return FLAGS[v] ~= nil
end

--- Flickr flags { is_public, is_friend, is_family } as "0"/"1" strings.
function M.flags(privacy)
	local f = FLAGS[privacy] or FLAGS.private
	return { is_public = tostring(f[1]), is_friend = tostring(f[2]), is_family = tostring(f[3]) }
end

--- Privacy value from Flickr's ispublic/isfriend/isfamily (numbers or strings).
function M.fromFlags(isPublic, isFriend, isFamily)
	if tonumber(isPublic) == 1 then
		return "public"
	end
	local fr, fa = tonumber(isFriend) == 1, tonumber(isFamily) == 1
	if fr and fa then
		return "friendsFamily"
	elseif fr then
		return "friends"
	elseif fa then
		return "family"
	end
	return "private"
end

--- Most specific valid value wins; "default"/nil fall through. Falls back to "private".
function M.resolve(photoValue, collectionValue, serviceValue)
	-- Explicit order: ipairs would stop at the first nil.
	if M.valid(photoValue) then
		return photoValue
	elseif M.valid(collectionValue) then
		return collectionValue
	elseif M.valid(serviceValue) then
		return serviceValue
	end
	return "private"
end

--- Location switch: collection "on"/"off" overrides the service boolean.
function M.locationEnabled(collectionValue, serviceValue)
	if collectionValue == "on" then
		return true
	elseif collectionValue == "off" then
		return false
	end
	return serviceValue == true
end

--- "lat,lon" rounded to 4 decimals (~10 m), or "" without location.
function M.locationKey(lat, lon)
	lat, lon = tonumber(lat), tonumber(lon)
	if not lat or not lon or (lat == 0 and lon == 0) then
		return ""
	end
	return string.format("%.4f,%.4f", lat, lon)
end

return M

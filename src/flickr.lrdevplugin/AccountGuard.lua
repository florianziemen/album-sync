--[[
Account lock: a publish service is bound to one Flickr account (NSID).
Publishing is refused unless the stored token verifiably belongs to that account.
]]

local FlickrAuth = require("FlickrAuth")

local M = {}

--[[
lockedNsid: NSID the service is locked to (nil = not locked).
Returns the verified user { id, username } or nil, err.
]]
function M.verify(deps, creds, lockedNsid)
	if not lockedNsid or lockedNsid == "" then
		return nil, { class = "auth", message = "This publish service is not locked to a Flickr account." }
	end
	if not (creds.consumerKey and creds.consumerSecret and creds.token and creds.tokenSecret) then
		return nil, { class = "auth", message = "Not logged in to Flickr." }
	end
	local user, e = FlickrAuth.new(deps, creds):testLogin({ token = creds.token, tokenSecret = creds.tokenSecret })
	if not user then
		return nil, e
	end
	if user.id ~= lockedNsid then
		return nil,
			{
				class = "auth",
				message = string.format(
					"Logged in as %s (%s), but this service is locked to %s.",
					tostring(user.username),
					tostring(user.id),
					lockedNsid
				),
			}
	end
	return user
end

return M

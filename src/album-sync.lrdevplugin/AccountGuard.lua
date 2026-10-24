--[[
Account lock: a publish service is bound to one Flickr account (NSID), and a catalog uses at
most one Flickr account (the per-photo Flickr ID assumes this).
Every operation verifies that the stored token belongs to the locked account and carries the
permission it needs (read < write < delete). A read-only login can never change anything.
]]

local FlickrAuth = require("FlickrAuth")

local M = {}

local RANK = { read = 1, write = 2, delete = 3 }

function M.permsAllow(have, need)
	return (RANK[have] or 0) >= (RANK[need] or 99)
end

--[[
lockedNsids: NSIDs of all publish services of this plugin in the catalog.
Returns the single NSID, or nil, err when none or several accounts are used.
]]
function M.catalogAccount(lockedNsids)
	local distinct, list = {}, {}
	for _, nsid in ipairs(lockedNsids or {}) do
		if nsid ~= "" and not distinct[nsid] then
			distinct[nsid] = true
			list[#list + 1] = nsid
		end
	end
	if #list == 0 then
		return nil,
			{
				class = "auth",
				reason = "none",
				message = "No Flickr publish service in this catalog is locked to an account.",
			}
	elseif #list > 1 then
		return nil,
			{
				class = "auth",
				reason = "several",
				message = "This catalog has publish services for several Flickr accounts ("
					.. table.concat(list, ", ")
					.. "). Use one Flickr account per catalog.",
			}
	end
	return list[1]
end

--[[
creds: CredentialStore.account(lockedNsid) (nil if no login for that account).
need: "read" | "write" | "delete".
Returns the verified user { id, username } or nil, err.
]]
function M.verify(deps, creds, lockedNsid, need)
	if not lockedNsid or lockedNsid == "" then
		return nil, { class = "auth", message = "This publish service is not locked to a Flickr account." }
	end
	if not (creds and creds.consumerKey and creds.consumerSecret and creds.token and creds.tokenSecret) then
		return nil,
			{
				class = "auth",
				message = "No Flickr login for account "
					.. lockedNsid
					.. ". Use File > Plug-in Extras > Album Sync: Log in to Flickr.",
			}
	end
	if need and not M.permsAllow(creds.perms, need) then
		return nil,
			{
				class = "auth",
				message = string.format(
					"The login for %s only allows “%s”; this needs “%s”. Log in again with more permissions.",
					tostring(creds.username or lockedNsid),
					tostring(creds.perms),
					need
				),
			}
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
					"The stored login is for %s (%s), but this service is locked to %s.",
					tostring(user.username),
					tostring(user.id),
					lockedNsid
				),
			}
	end
	return user
end

return M

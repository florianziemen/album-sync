--[[
Flickr credentials. The API key/secret (one per user of the plugin) and each account's OAuth
token live in LrPasswords (OS keychain). The list of accounts (NSID, username, permission) is
not secret and lives in the plugin prefs. Nothing secret goes into prefs or logs.
]]

local LrPasswords = import("LrPasswords")
local LrPrefs = import("LrPrefs")

local PREFIX = "album-sync."

local M = {}

-- LrPasswords cannot store nil ("keystring or password is nil"): an empty string means unset.
local function get(name)
	local v = LrPasswords.retrieve(PREFIX .. name)
	if v == "" then
		return nil
	end
	return v
end

local function put(name, value)
	LrPasswords.store(PREFIX .. name, value or "")
end

function M.app()
	return { consumerKey = get("consumerKey"), consumerSecret = get("consumerSecret") }
end

function M.saveApp(consumerKey, consumerSecret)
	put("consumerKey", consumerKey)
	put("consumerSecret", consumerSecret)
end

local function prefs()
	return LrPrefs.prefsForPlugin()
end

-- One-time migration of the single-account storage (before multi-account support).
-- Touches the keychain: call only from tasks (account, saveAccount).
local function migrateLegacy()
	local p = prefs()
	if p.legacyMigrated then
		return
	end
	local nsid, token, secret = get("userNsid"), get("token"), get("tokenSecret")
	if nsid and token and secret then
		put("account." .. nsid .. ".token", token)
		put("account." .. nsid .. ".tokenSecret", secret)
		local accounts = p.accounts or {}
		accounts[nsid] = { username = get("username") or nsid, perms = "delete" }
		p.accounts = accounts
		put("token", nil)
		put("tokenSecret", nil)
	end
	p.legacyMigrated = true
end

--- Array of { nsid, username, perms }, sorted by username. Reads prefs only (no keychain),
--- so it is safe outside tasks, e.g. while building dialogs.
function M.accounts()
	local out = {}
	for nsid, a in pairs(prefs().accounts or {}) do
		out[#out + 1] = { nsid = nsid, username = a.username, perms = a.perms }
	end
	table.sort(out, function(a, b)
		return tostring(a.username) < tostring(b.username)
	end)
	return out
end

--[[
Full credentials for one account, or nil if there is no login for it:
{ consumerKey, consumerSecret, token, tokenSecret, nsid, username, perms }
]]
function M.account(nsid)
	if not nsid or nsid == "" then
		return nil
	end
	migrateLegacy()
	local a = (prefs().accounts or {})[nsid]
	local token, secret = get("account." .. nsid .. ".token"), get("account." .. nsid .. ".tokenSecret")
	if not (a and token and secret) then
		return nil
	end
	local app = M.app()
	return {
		consumerKey = app.consumerKey,
		consumerSecret = app.consumerSecret,
		token = token,
		tokenSecret = secret,
		nsid = nsid,
		username = a.username,
		perms = a.perms,
	}
end

function M.saveAccount(nsid, username, perms, token, tokenSecret)
	migrateLegacy()
	put("account." .. nsid .. ".token", token)
	put("account." .. nsid .. ".tokenSecret", tokenSecret)
	local p = prefs()
	local accounts = p.accounts or {}
	accounts[nsid] = { username = username, perms = perms }
	p.accounts = accounts -- reassign so LrPrefs persists the change
end

return M

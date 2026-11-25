--[[--
Saved BookOrbit accounts.

Pure data over a settings table, so it runs without KOReader. All accounts
share one server address, so a server whose address changes (a home server on
a DHCP address, for example) is updated once for every account. Within the
store an account is keyed by its username; its BookOrbit identity is the
shared address without trailing slashes, a pipe and the username, the same
way the BookOrbit plugin scopes its sync state.

Only the KOSync user key (the MD5 of the password, which is what the BookOrbit
plugin itself stores) is kept, never the password.
]]

local Store = {}
Store.__index = Store

local function trimSlashes(url)
    return (tostring(url):gsub("/+$", ""))
end

local function nonEmpty(value)
    return type(value) == "string" and value ~= ""
end

function Store.identity(server_url, username)
    if not nonEmpty(server_url) or not nonEmpty(username) then return nil end
    return trimSlashes(server_url) .. "|" .. username
end

-- "https://books.example.com/api/v1" -> "books.example.com"
function Store.host(server_url)
    if type(server_url) ~= "string" then return nil end
    local host = server_url:match("^%a[%w+.-]*://([^/]+)")
    return host or server_url
end

local function isAccount(entry)
    return type(entry) == "table" and nonEmpty(entry.username) and nonEmpty(entry.userkey)
end

-- `data` is the persisted table; it is adopted and normalized in place so the
-- caller can save the same reference back. Accounts saved before the address
-- was shared carry their own server_url: the first one becomes the shared
-- address, and a username saved on several servers is kept once.
function Store.new(data, now)
    if type(data) ~= "table" then data = {} end
    local accounts, seen = {}, {}
    for _, entry in ipairs(type(data.accounts) == "table" and data.accounts or {}) do
        if isAccount(entry) and not seen[entry.username] then
            seen[entry.username] = true
            if nonEmpty(entry.server_url) then
                if not nonEmpty(data.server_url) then data.server_url = entry.server_url end
                if entry.label == entry.username .. " @ " .. Store.host(entry.server_url) then
                    entry.label = nil
                end
                entry.server_url = nil
            end
            if not nonEmpty(entry.label) then entry.label = entry.username end
            table.insert(accounts, entry)
        end
    end
    data.accounts = accounts
    data.server_url = nonEmpty(data.server_url) and trimSlashes(data.server_url) or nil
    if data.auto_remember == nil then data.auto_remember = true end
    return setmetatable({ data = data, now = now or os.time }, Store)
end

function Store:serverUrl()
    return self.data.server_url
end

-- Returns whether the address changed.
function Store:setServerUrl(server_url)
    if not nonEmpty(server_url) then return false end
    server_url = trimSlashes(server_url)
    if server_url == self.data.server_url then return false end
    self.data.server_url = server_url
    return true
end

-- Called with the address BookOrbit is signed in to. A sign-in at an address
-- not seen before (BookOrbit's own sign-in page after the server moved) makes
-- it the shared address. BookOrbit still on the address it had before an edit
-- here does not undo that edit. Returns whether the shared address changed.
function Store:observeSignIn(server_url)
    if not nonEmpty(server_url) then return false end
    server_url = trimSlashes(server_url)
    if server_url == self.data.signed_in_server_url then return false end
    self.data.signed_in_server_url = server_url
    return self:setServerUrl(server_url)
end

-- The BookOrbit identity of a saved account at the shared address.
function Store:identityOf(entry)
    return entry and Store.identity(self.data.server_url, entry.username)
end

function Store:list()
    return self.data.accounts
end

function Store:count()
    return #self.data.accounts
end

function Store:indexOf(username)
    if not username then return nil end
    for index, entry in ipairs(self.data.accounts) do
        if entry.username == username then
            return index, entry
        end
    end
end

function Store:find(username)
    local _, entry = self:indexOf(username)
    return entry
end

-- Adds an account or refreshes the key of one already saved (a changed
-- password), keeping its label and position. Returns the entry and whether
-- anything changed.
function Store:upsert(account)
    if not isAccount(account) then return nil, false end
    local existing = self:find(account.username)
    if existing then
        local changed = existing.userkey ~= account.userkey
        existing.userkey = account.userkey
        if nonEmpty(account.label) and account.label ~= existing.label then
            existing.label = account.label
            changed = true
        end
        return existing, changed
    end
    local entry = {
        username = account.username,
        userkey = account.userkey,
        label = nonEmpty(account.label) and account.label or account.username,
        added_at = self.now(),
    }
    table.insert(self.data.accounts, entry)
    return entry, true
end

function Store:remove(username)
    local index = self:indexOf(username)
    if not index then return false end
    table.remove(self.data.accounts, index)
    return true
end

function Store:rename(username, label)
    local entry = self:find(username)
    if not entry or type(label) ~= "string" then return false end
    label = label:match("^%s*(.-)%s*$")
    if label == "" then label = entry.username end
    entry.label = label
    return true
end

function Store:move(username, delta)
    local index = self:indexOf(username)
    if not index then return false end
    local target = index + delta
    if target < 1 or target > #self.data.accounts then return false end
    local accounts = self.data.accounts
    accounts[index], accounts[target] = accounts[target], accounts[index]
    return true
end

function Store:markUsed(username)
    local entry = self:find(username)
    if entry then entry.last_used_at = self.now() end
end

-- The saved account after `username` in list order, wrapping around. With
-- no current account (or an unsaved one) it starts from the first.
function Store:nextAfter(username)
    local accounts = self.data.accounts
    if #accounts == 0 then return nil end
    local index = self:indexOf(username)
    if not index then return accounts[1] end
    if #accounts == 1 then return nil end
    return accounts[index % #accounts + 1]
end

return Store

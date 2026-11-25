--[[--
BookOrbit Account Switcher.

A companion to the BookOrbit Sync plugin (bookorbit.koplugin). It remembers
the accounts you sign in with and switches the BookOrbit plugin between them
without retyping credentials. All saved accounts share one server address.

Switching goes through the BookOrbit plugin's own completeSignIn(), the same
path its sign-in page uses, so the plugin clears its per-account catalog
caches, moves to that account's sync state file and refreshes an open
catalog exactly as after a manual sign-in.

Two things are not scoped per account by the BookOrbit plugin and are guarded
here instead: a switch never happens while a book is open (its close and
suspend syncs would go to the new account) or while a sync runs, and queued
close syncs are offered to be sent before switching.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local T = require("ffi/util").template
local _ = require("gettext")

local Store = require("switcher_store")

local SETTINGS_KEY = "bookorbitswitcher"
local BOOKORBIT_SETTINGS_KEY = "bookorbit"
local CHECK = "\u{2713} "

local Switcher = WidgetContainer:extend{
    name = "bookorbitswitcher",
    is_doc_only = false,
}

function Switcher:init()
    self.store = Store.new(G_reader_settings:readSetting(SETTINGS_KEY))
    self:rememberCurrent()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Switcher:save()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.store.data)
    G_reader_settings:flush()
end

-- The live BookOrbit plugin instance, registered on the UI under its name.
function Switcher:bookOrbit()
    local plugin = self.ui and self.ui.bookorbit
    if type(plugin) == "table" and type(plugin.settings) == "table" then
        return plugin
    end
end

function Switcher:bookOrbitSettings()
    local plugin = self:bookOrbit()
    if plugin then return plugin.settings end
    return G_reader_settings:readSetting(BOOKORBIT_SETTINGS_KEY)
end

-- Returns server_url, username, userkey of the signed-in BookOrbit account.
function Switcher:currentCredentials()
    local settings = self:bookOrbitSettings()
    if type(settings) ~= "table" then return nil end
    return settings.server_url, settings.username, settings.userkey
end

function Switcher:currentIdentity()
    local server_url, username, userkey = self:currentCredentials()
    if not userkey then return nil end
    return Store.identity(server_url, username)
end

function Switcher:isCurrent(entry)
    local identity = self.store:identityOf(entry)
    return identity ~= nil and identity == self:currentIdentity()
end

function Switcher:currentEntry()
    local _server_url, username = self:currentCredentials()
    local entry = self.store:find(username)
    if entry and self:isCurrent(entry) then return entry end
end

-- Saves the signed-in account, or refreshes its key after a password change,
-- so every account used once is one tap away afterwards.
function Switcher:rememberCurrent(force)
    if not force and not self.store.data.auto_remember then return nil end
    local server_url, username, userkey = self:currentCredentials()
    if not (server_url and username and userkey) then return nil end
    local moved = self.store:observeSignIn(server_url)
    local entry, changed = self.store:upsert{ username = username, userkey = userkey }
    if moved or changed then
        self:save()
        logger.info("BookOrbitSwitcher: remembered account", username)
    end
    return entry
end

local function toast(text)
    local ok, Toast = pcall(require, "bookorbit_toast")
    if ok and Toast and Toast.show then
        Toast.show(text)
    else
        Notification:notify(text)
    end
end

local function notice(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function Switcher:hasOpenBook()
    return self.ui ~= nil and self.ui.document ~= nil
end

-- True while the BookOrbit plugin is running a sweep or a queued sync job;
-- switching under it would send the rest of that work to the new account.
function Switcher:isBookOrbitBusy(plugin)
    local ok, Sweep = pcall(require, "bookorbit_sweep")
    if ok and type(Sweep) == "table" and Sweep.isRunning and Sweep.isRunning() then
        return true
    end
    if plugin.getSyncCoordinatorStatus then
        local status_ok, status = pcall(plugin.getSyncCoordinatorStatus, plugin)
        if status_ok and type(status) == "table" and (status.current ~= nil or (status.pending_count or 0) > 0) then
            return true
        end
    end
    return false
end

-- Close and suspend snapshots waiting in the BookOrbit outbox. The outbox is
-- shared by all accounts and drains to whichever account is signed in.
function Switcher:pendingSnapshotCount(plugin)
    if not plugin.getLifecycleOutbox then return 0 end
    local ok, count = pcall(function()
        return plugin:getLifecycleOutbox():status().count
    end)
    if ok and type(count) == "number" then return count end
    return 0
end

function Switcher:applyAccount(plugin, entry)
    local server_url = self.store:serverUrl()
    if not server_url then
        notice(_("Set the BookOrbit server address first in Tools > BookOrbit accounts."))
        return false
    end
    if plugin and plugin.completeSignIn then
        plugin:completeSignIn(server_url, entry.username, entry.userkey)
    else
        local settings = G_reader_settings:readSetting(BOOKORBIT_SETTINGS_KEY)
        if type(settings) ~= "table" then
            notice(_("BookOrbit Sync is not set up on this device. Install it and sign in once first."))
            return false
        end
        if settings.server_url ~= server_url or settings.username ~= entry.username then
            settings.catalog_dashboard_cache = nil
            settings.catalog_detail_cache = nil
        end
        settings.server_url = server_url
        settings.username = entry.username
        settings.userkey = entry.userkey
        G_reader_settings:saveSetting(BOOKORBIT_SETTINGS_KEY, settings)
        G_reader_settings:flush()
    end
    self.store:observeSignIn(server_url)
    return true
end

function Switcher:finishSwitch(plugin, entry, on_done)
    self:rememberCurrent()
    if not self:applyAccount(plugin, entry) then return end
    self.store:markUsed(entry.username)
    self:save()
    logger.info("BookOrbitSwitcher: switched to", entry.username)
    UIManager:nextTick(function()
        toast(T(_("BookOrbit: now using %1"), entry.label))
    end)
    if on_done then on_done() end
end

function Switcher:confirmPendingSnapshots(plugin, entry, pending, on_done)
    local current = self:currentEntry()
    local current_label = current and current.label or _("the current account")
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("%1 closed or suspended book(s) have not finished syncing to %2 yet.\n\nSync them first, or they will be sent to %3 instead."),
            pending, current_label, entry.label),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Switch anyway"),
                    callback = function()
                        UIManager:close(dialog)
                        self:finishSwitch(plugin, entry, on_done)
                    end,
                },
            },
            {
                {
                    text = _("Sync now"),
                    callback = function()
                        UIManager:close(dialog)
                        if plugin.requestLifecycleOutboxDrain then
                            plugin:requestLifecycleOutboxDrain("account_switcher", true)
                        end
                        notice(_("Sending pending syncs. Switch again once BookOrbit has finished."))
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Switcher:switchTo(entry, on_done)
    local plugin = self:bookOrbit()
    if not plugin then
        notice(_("The BookOrbit Sync plugin is not enabled. Enable it in Tools > More tools > Plugin management."))
        return
    end
    if self:isCurrent(entry) then
        toast(T(_("Already using %1"), entry.label))
        return
    end
    if self:hasOpenBook() then
        notice(_("Close the book before switching BookOrbit accounts, so its reading is saved to the account it was read with."))
        return
    end
    if self:isBookOrbitBusy(plugin) then
        notice(_("BookOrbit is syncing. Switch accounts when it has finished."))
        return
    end
    local pending = self:pendingSnapshotCount(plugin)
    if pending > 0 then
        self:confirmPendingSnapshots(plugin, entry, pending, on_done)
        return
    end
    self:finishSwitch(plugin, entry, on_done)
end

function Switcher:switchToNext()
    if self.store:count() == 0 then
        notice(_("No BookOrbit accounts saved yet. Add one in Tools > BookOrbit accounts."))
        return
    end
    local current = self:currentEntry()
    local entry = self.store:nextAfter(current and current.username)
    if not entry then
        toast(_("Only one BookOrbit account is saved"))
        return
    end
    self:switchTo(entry)
end

local function bookOrbitApi()
    local ok, Api = pcall(require, "bookorbit_api")
    if ok and type(Api) == "table" and Api.new then return Api end
end

local function serverRoot(server_url)
    if not server_url then return nil end
    return (server_url:gsub("/api/v1/?$", ""))
end

-- Checks the credentials against the server the same way the BookOrbit
-- sign-in does. Calls on_result(ok, err) on the UI thread.
function Switcher:verify(account, on_result)
    local Api = bookOrbitApi()
    if not Api then
        on_result(false, "plugin_missing")
        return
    end
    NetworkMgr:runWhenOnline(function()
        local checking = InfoMessage:new{ text = _("Checking account..."), dismissable = false }
        UIManager:show(checking)
        UIManager:forceRePaint()
        local client = Api.new{
            server_url = account.server_url,
            username = account.username,
            userkey = account.userkey,
            device_id = G_reader_settings:readSetting("device_id"),
            device_model = Device.model,
        }
        local ok, body, err = pcall(client.auth, client)
        UIManager:close(checking)
        if not ok then
            on_result(false, tostring(body))
        elseif body then
            on_result(true)
        else
            on_result(false, err)
        end
    end)
end

local function verifyErrorText(err)
    if err == 401 or err == 403 then
        return _("Login failed. Check the username and password of your KOReader credentials in BookOrbit web settings.")
    end
    if err == "plugin_missing" then
        return _("The BookOrbit Sync plugin is not enabled, so the account could not be checked.")
    end
    return T(_("Could not reach the BookOrbit server: %1"), tostring(err))
end

-- Verifies, then saves. A network failure offers to save unchecked so an
-- account can be prepared while offline; a rejected login never is saved.
function Switcher:verifyAndSave(account, on_saved)
    self:verify(account, function(ok, err)
        local save = function()
            self.store:setServerUrl(account.server_url)
            local entry = self.store:upsert(account)
            self:save()
            if on_saved then on_saved(entry) end
        end
        if ok then
            save()
            return
        end
        if err == 401 or err == 403 or err == "plugin_missing" then
            notice(verifyErrorText(err))
            return
        end
        UIManager:show(ConfirmBox:new{
            text = verifyErrorText(err) .. "\n\n" .. _("Save the account without checking it?"),
            ok_text = _("Save"),
            ok_callback = save,
        })
    end)
end

function Switcher:offerSwitch(entry, on_done)
    if not entry then return end
    if self:isCurrent(entry) then
        toast(T(_("Saved %1"), entry.label))
        if on_done then on_done() end
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Saved %1.\n\nSwitch to it now?"), entry.label),
        ok_text = _("Switch"),
        cancel_text = _("Later"),
        ok_callback = function() self:switchTo(entry, on_done) end,
        cancel_callback = on_done,
    })
end

function Switcher:showAddAccount(on_done)
    local Api = bookOrbitApi()
    if not Api then
        notice(_("The BookOrbit Sync plugin is not enabled. Enable it in Tools > More tools > Plugin management."))
        return
    end
    local current_server = serverRoot(self.store:serverUrl() or (self:currentCredentials()))
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Add BookOrbit account"),
        fields = {
            {
                description = _("Server address (shared by all accounts)"),
                text = current_server or "https://",
                hint = "https://books.example.com",
            },
            {
                description = _("KOReader username"),
                text = "",
                hint = _("Username"),
            },
            {
                description = _("KOReader password"),
                text = "",
                hint = _("Password"),
                text_type = "password",
            },
            {
                description = _("Name in the list (optional)"),
                text = "",
                hint = _("e.g. Alice"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local server_url = Api.normalizeServerUrl(fields[1])
                        local username = fields[2] and fields[2]:match("^%s*(.-)%s*$") or ""
                        local password = fields[3] or ""
                        if not server_url then
                            notice(_("Enter a valid http:// or https:// server address."))
                            return
                        end
                        if username == "" or password == "" then
                            notice(_("Enter the username and password."))
                            return
                        end
                        UIManager:close(dialog)
                        self:verifyAndSave({
                            server_url = server_url,
                            username = username,
                            userkey = md5(password),
                            label = fields[4] and fields[4]:match("^%s*(.-)%s*$") or nil,
                        }, function(entry) self:offerSwitch(entry, on_done) end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- One address for every saved account. When BookOrbit is signed in to a saved
-- account at the old address, it is moved to the new one straight away.
function Switcher:showServerAddress(on_done)
    local Api = bookOrbitApi()
    if not Api then
        notice(_("The BookOrbit Sync plugin is not enabled. Enable it in Tools > More tools > Plugin management."))
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("BookOrbit server address"),
        description = _("Used by all saved accounts."),
        input = serverRoot(self.store:serverUrl()) or "https://",
        input_hint = "http://192.168.1.20:3000",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local server_url = Api.normalizeServerUrl(dialog:getInputText())
                        if not server_url then
                            notice(_("Enter a valid http:// or https:// server address."))
                            return
                        end
                        UIManager:close(dialog)
                        local current = self:currentEntry()
                        if not self.store:setServerUrl(server_url) then
                            if on_done then on_done() end
                            return
                        end
                        self:save()
                        logger.info("BookOrbitSwitcher: server address changed")
                        if current then
                            self:switchTo(current, on_done)
                        else
                            toast(T(_("Server address set to %1"), Store.host(server_url)))
                            if on_done then on_done() end
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Switcher:showUpdatePassword(entry, on_done)
    local dialog
    dialog = InputDialog:new{
        title = T(_("New password for %1"), entry.label),
        input = "",
        input_hint = _("KOReader password"),
        text_type = "password",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local password = dialog:getInputText()
                        if password == "" then return end
                        UIManager:close(dialog)
                        local was_current = self:isCurrent(entry)
                        local userkey = md5(password)
                        self:verifyAndSave({
                            server_url = self.store:serverUrl(),
                            username = entry.username,
                            userkey = userkey,
                        }, function(saved)
                            -- The signed-in account keeps working with the new key at once.
                            local plugin = self:bookOrbit()
                            if plugin and was_current then
                                self:applyAccount(plugin, saved)
                            end
                            toast(T(_("Updated %1"), saved.label))
                            if on_done then on_done() end
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Switcher:showRename(entry, on_done)
    local dialog
    dialog = InputDialog:new{
        title = _("Account name"),
        input = entry.label,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        self.store:rename(entry.username, dialog:getInputText())
                        self:save()
                        UIManager:close(dialog)
                        if on_done then on_done() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Switcher:confirmForget(entry, on_done)
    local text = T(_("Forget %1 on this device?"), entry.label)
    if self:isCurrent(entry) then
        text = text .. "\n\n" .. _("BookOrbit stays signed in to it; it is only removed from this list. Turn off \"Remember accounts I sign in with\" or it is saved again.")
    end
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Forget"),
        ok_callback = function()
            self.store:remove(entry.username)
            self:save()
            if on_done then on_done() end
        end,
    })
end

function Switcher:showManage(entry, on_done)
    local dialog
    local function run(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    dialog = ButtonDialog:new{
        title = T(_("%1\n%2 on %3"), entry.label, entry.username, Store.host(self.store:serverUrl()) or _("no server set")),
        buttons = {
            {
                { text = _("Switch"), enabled = not self:isCurrent(entry),
                  callback = run(function() self:switchTo(entry, on_done) end) },
                { text = _("Rename"), callback = run(function() self:showRename(entry, on_done) end) },
            },
            {
                { text = _("Move up"), callback = run(function()
                    self.store:move(entry.username, -1)
                    self:save()
                    if on_done then on_done() end
                end) },
                { text = _("Move down"), callback = run(function()
                    self.store:move(entry.username, 1)
                    self:save()
                    if on_done then on_done() end
                end) },
            },
            {
                { text = _("Update password"), callback = run(function() self:showUpdatePassword(entry, on_done) end) },
                { text = _("Forget"), callback = run(function() self:confirmForget(entry, on_done) end) },
            },
        },
    }
    UIManager:show(dialog)
end

function Switcher:accountText(entry)
    return (self:isCurrent(entry) and CHECK or "") .. entry.label
end

-- The quick picker for the gesture action: one tap switches, hold manages.
function Switcher:showSwitcher()
    self:rememberCurrent()
    local dialog
    local reopen = function() self:showSwitcher() end
    local buttons = {}
    for _idx, entry in ipairs(self.store:list()) do
        table.insert(buttons, {{
            text = self:accountText(entry),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:switchTo(entry)
            end,
            hold_callback = function()
                UIManager:close(dialog)
                self:showManage(entry, reopen)
            end,
        }})
    end
    table.insert(buttons, {
        {
            text = _("Close"),
            callback = function() UIManager:close(dialog) end,
        },
        {
            text = _("Add account"),
            callback = function()
                UIManager:close(dialog)
                self:showAddAccount(reopen)
            end,
        },
    })
    dialog = ButtonDialog:new{
        title = self.store:count() > 0 and _("BookOrbit account\nTap to switch, hold to manage")
            or _("No BookOrbit accounts saved yet"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Switcher:onBookOrbitSwitcherShow()
    self:showSwitcher()
    return true
end

function Switcher:onBookOrbitSwitcherNext()
    self:rememberCurrent()
    self:switchToNext()
    return true
end

function Switcher:onDispatcherRegisterActions()
    Dispatcher:registerAction("bookorbitswitcher_show",
        { category = "none", event = "BookOrbitSwitcherShow", title = _("BookOrbit: switch account"), general = true })
    Dispatcher:registerAction("bookorbitswitcher_next",
        { category = "none", event = "BookOrbitSwitcherNext", title = _("BookOrbit: next account"), general = true })
end

function Switcher:menuItems()
    self:rememberCurrent()
    local current = self:currentIdentity()
    local items = {}
    for _idx, entry in ipairs(self.store:list()) do
        table.insert(items, {
            text = entry.label,
            checked_func = function() return self:isCurrent(entry) end,
            radio = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:switchTo(entry, function()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end,
            hold_callback = function(touchmenu_instance)
                self:showManage(entry, function()
                    if touchmenu_instance then
                        touchmenu_instance.item_table = self:menuItems()
                        touchmenu_instance:updateItems()
                    end
                end)
            end,
        })
    end
    if #items > 0 then
        items[#items].separator = true
    end
    table.insert(items, {
        text_func = function()
            local host = Store.host(self.store:serverUrl())
            return host and T(_("Server address: %1"), host) or _("Server address: not set")
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showServerAddress(function()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end)
        end,
    })
    table.insert(items, {
        text = _("Add account"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showAddAccount(function()
                if touchmenu_instance then
                    touchmenu_instance.item_table = self:menuItems()
                    touchmenu_instance:updateItems()
                end
            end)
        end,
    })
    table.insert(items, {
        text = _("Save current account"),
        enabled_func = function()
            local _server_url, username, userkey = self:currentCredentials()
            return userkey ~= nil and self.store:find(username) == nil
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local entry = self:rememberCurrent(true)
            if entry then
                toast(T(_("Saved %1"), entry.label))
                if touchmenu_instance then
                    touchmenu_instance.item_table = self:menuItems()
                    touchmenu_instance:updateItems()
                end
            end
        end,
    })
    table.insert(items, {
        text = _("Remember accounts I sign in with"),
        checked_func = function() return self.store.data.auto_remember == true end,
        callback = function()
            self.store.data.auto_remember = not self.store.data.auto_remember
            self:save()
        end,
        separator = true,
    })
    table.insert(items, {
        text = _("Help"),
        keep_menu_open = true,
        callback = function()
            notice(_([[Tap an account to switch BookOrbit to it. Hold an account to rename, reorder, update its password or forget it.

All accounts share one server address. When the server's address changes, update it once under "Server address".

Accounts you sign in with in BookOrbit are saved here automatically. Only the KOReader sync key is stored, the same one BookOrbit itself keeps, never your password.

Close the book before switching. Each account keeps its own sync state on this device, and gestures can open this list ("BookOrbit: switch account") or jump to the next account ("BookOrbit: next account").]]))
        end,
    })
    if current == nil and #self.store:list() == 0 then
        table.insert(items, 1, {
            text = _("Sign in to BookOrbit once, or add an account below."),
            enabled = false,
        })
    end
    return items
end

function Switcher:addToMainMenu(menu_items)
    menu_items.bookorbit_switcher = {
        text = _("BookOrbit accounts"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:menuItems() end,
    }
end

return Switcher

-- Aleph for Grimmory modification, 2026-11-27: the Grimmory library on the
-- device: recent books, search and shelves, and a book downloaded with a tap.
--[[--
Opened from Settings > Library > Grimmory > Browse Grimmory (and the
gesture "Aleph: Grimmory library"). A list in KOReader's own menu style:

  Recently added     Grimmory's newest books, 30 at a time (More... at the end)
  Search             title, series, author, genre, tag or ISBN
  Shelves            the reader's shelves, then their books

A book already on the device has a check mark. Tapping another asks to
download it into the download folder (Prefs grimmory_folder, else the
library's first folder), named "Author - Title.ext". Once downloaded it is
known as that Grimmory book (aleph_grimmory_sync.lua, state.ids) and the
library is scanned again.

Every request runs in the background (aleph_grimmory_sync.lua's run).
]]

local UIManager = require("ui/uimanager")
local Prefs = require("aleph_prefs")
local _ = require("aleph_gettext")
local try = require("aleph_try").call

local B = {}

local function Sync() return require("aleph_grimmory_sync") end
local function Api() return require("aleph_grimmory_api") end

local function toast(message, ok) Sync()._toast(message, ok) end

-- Where books are downloaded.
function B.folder(browser)
    local f = Prefs.get().grimmory_folder
    if type(f) == "string" and f ~= "" then return f end
    local roots = Prefs.get().library_roots
    if type(roots) == "table" and roots[1] then return roots[1] end
    return G_reader_settings and G_reader_settings:readSetting("home_dir") or nil
end

-- The line shown for a book.
function B.label(book)
    local md = type(book.metadata) == "table" and book.metadata or {}
    local authors = type(md.authors) == "table" and md.authors or {}
    local title = md.title or book.title or "?"
    if md.seriesName and md.seriesNumber then
        title = title .. string.format(" (%s %s)", md.seriesName, tostring(md.seriesNumber):gsub("%.0$", ""))
    end
    return authors[1] and (title .. " · " .. authors[1]) or title
end

local function onDevice()
    local set = {}
    for _path, id in pairs(Sync().state().ids) do set[tonumber(id)] = true end
    return set
end

local menu
local stack = {}

local function show(title, items)
    if menu then
        table.insert(stack, { title = menu.title, items = menu.item_table })
        menu.paths = menu.paths or {}
        table.insert(menu.paths, true)
        menu:switchItemTable(title, items)
    end
end

local function replace(title, items, select_last)
    if menu then menu:switchItemTable(title, items, select_last and #items or nil) end
end

-- A request in the background, with a "Loading" pill.
local function ask(kind, fn, plan, done)
    local pill
    try(function() pill = require("aleph_toast").loading(_("Asking Grimmory…")) end)
    Sync()._run(kind, fn, plan or {}, function(r)
        if pill then try(function() pill:close() end) end
        if not r or r.code == nil then return toast(_("Grimmory did not answer."), false) end
        if r.code == 401 or r.code == 403 then return toast(_("Grimmory signed this device out. Sign in again."), false) end
        if r.code ~= 200 then return toast(_("Grimmory did not answer."), false) end
        done(r)
    end)
end

local function download(book, browser)
    local folder = B.folder(browser)
    if not folder then return toast(_("Choose a download folder first (Settings > Library > Grimmory)."), false) end
    local path = folder:gsub("/$", "") .. "/" .. Api().fileNameFor(book)
    ask("download", function(plan)
        local api = Sync().apiFor(plan)
        return { code = api:download(plan.id, plan.path) }
    end, { id = book.id, path = path }, function()
        local st = Sync().state()
        st.ids[path] = tonumber(book.id)
        Sync().saveState()
        toast(require("ffi/util").template(_("Downloaded: %1"), B.label(book)), true)
        if browser and browser.startScan then try(function() browser:startScan() end) end
        if menu then try(function() menu:updateItems() end) end
    end)
end

local function bookItems(books, more)
    local here = onDevice()
    local items = {}
    for _i, b in ipairs(books or {}) do
        local on = here[tonumber(b.id)]
        items[#items + 1] = {
            text = B.label(b),
            mandatory = on and "✓" or nil,
            book = b,
            callback = function()
                if on then return toast(_("Already on this device."), true) end
                require("aleph_confirm").show{
                    title = _("Download this book?"),
                    text = B.label(b) .. "\n\n" .. require("ffi/util").template(_("Into %1"), B.folder(B.browser) or "?"),
                    ok_label = _("Download"), cancel_label = _("Cancel"),
                    on_ok = function() download(b, B.browser) end,
                }
            end,
        }
    end
    if more then items[#items + 1] = { text = _("More…"), bold = true, callback = more } end
    if #items == 0 then items[1] = { text = _("No books here."), dim = true, callback = function() end } end
    return items
end

local function pageFn(plan)
    local api = Sync().apiFor(plan)
    local code, page = api:page(plan.params, plan.next)
    return { code = code, books = page and page.books, next = page and page.next }
end

local function openPage(title, params)
    local all = {}
    local function load(next_url, first)
        ask("browse", pageFn, { params = params, next = next_url }, function(r)
            for _i, b in ipairs(r.books or {}) do all[#all + 1] = b end
            local more = r.next and function() load(r.next, false) end or nil
            local items = bookItems(all, more)
            if first then show(title, items) else replace(title, items, true) end
        end)
    end
    load(nil, true)
end

local function openShelves()
    ask("browse", function(plan)
        local api = Sync().apiFor(plan)
        local code, shelves = api:shelves()
        return { code = code, shelves = shelves }
    end, {}, function(r)
        local items = {}
        for _i, sh in ipairs(r.shelves or {}) do
            items[#items + 1] = {
                text = tostring(sh.name), mandatory = sh.bookCount and tostring(sh.bookCount) or nil,
                callback = function()
                    ask("browse", function(plan)
                        local api = Sync().apiFor(plan)
                        local code, books = api:shelfBooks(plan.id)
                        return { code = code, books = books }
                    end, { id = sh.id }, function(r2) show(tostring(sh.name), bookItems(r2.books)) end)
                end,
            }
        end
        if #items == 0 then items[1] = { text = _("No shelves in Grimmory."), dim = true, callback = function() end } end
        show(_("Shelves"), items)
    end)
end

local function search()
    require("aleph_input").prompt{
        title = _("Search Grimmory"),
        hint = _("Title, series, author, genre, tag or ISBN"),
        ok_label = _("Search"),
        on_ok = function(text)
            text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if text == "" then return end
            openPage(require("ffi/util").template(_("Search: %1"), text), { query = text, sort = "title" })
        end,
    }
end

local function rootItems()
    return {
        { text = _("Recently added"), callback = function() openPage(_("Recently added"), { sort = "-addedOn" }) end },
        { text = _("Search…"), callback = search },
        { text = _("Shelves"), callback = openShelves },
    }
end

function B.open(browser)
    if not Sync().signedIn() then return toast(_("Sign in to Grimmory first."), false) end
    local okc, connected = pcall(function() return require("ui/network/manager"):isConnected() end)
    if okc and not connected then
        return require("aleph_grimmory").withNetwork(function() B.open(browser) end)
    end
    B.browser = browser
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen
    stack = {}
    menu = Menu:new{
        title = _("Grimmory library"),
        item_table = rootItems(),
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuChoice = function(_self, item)
            if item.callback then item.callback() end
            return true
        end,
        onReturn = function(self)
            local prev = table.remove(stack)
            if self.paths then table.remove(self.paths) end
            if prev then self:switchItemTable(prev.title, prev.items) end
            return true
        end,
        close_callback = function()
            if menu then UIManager:close(menu) end
            menu, stack = nil, {}
        end,
    }
    menu.paths = {}
    UIManager:show(menu)
end

return B

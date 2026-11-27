-- Aleph for Grimmory modification, 2026-11-27: highlights as Grimmory
-- annotations (CFI conversion, the three-way merge, the requests), the single
-- account and the other Grimmory plugins. Run from the plugin folder:
-- luajit tests/grimmory_highlights_test.lua
package.path = "./?.lua;" .. package.path

local tmp = os.getenv("ALEPH_TEST_DIR") or "/tmp"
local store = {}
G_reader_settings = {
    readSetting = function(_self, k) return store[k] end,
    saveSetting = function(_self, k, v) store[k] = v end,
}
package.preload["logger"] = function() return { info = function() end, warn = function() end, dbg = function() end } end
package.preload["datastorage"] = function() return { getSettingsDir = function() return tmp end, getDataDir = function() return tmp end } end
package.preload["ffi/sha2"] = function() return { md5 = function(s) return "md5:" .. s end } end
package.preload["ui/network/manager"] = function() return { isConnected = function() return true end } end
package.preload["aleph_toast"] = function() return { show = function() end } end

-- A JSON null, as KOReader's decoder gives it.
local NULL = function() end

-- The pretend server: annotations and the KOReader user.
local server = { access = "A1", refresh = "R1", ann = {}, next_id = 500, kouser = nil, sync = nil, log = {} }
local function route(o)
    local path = o.url:gsub("^https?://[^/]+", "")
    local h = o.headers or {}
    server.log[#server.log + 1] = (o.method or "GET") .. " " .. path
    if path == "/api/v1/auth/login" then
        if o.json.username == "alex" and o.json.password == "secret" then
            return 200, { accessToken = server.access, refreshToken = server.refresh, expires = 7200 }
        end
        return 401
    end
    if path == "/api/v1/auth/refresh" then
        if o.json.refreshToken ~= server.refresh then return 401 end
        return 200, { accessToken = server.access, refreshToken = server.refresh, expires = 7200 }
    end
    if h["Authorization"] ~= "Bearer " .. server.access then return 401 end
    if path == "/api/v1/koreader-users/me" and (o.method or "GET") == "GET" then
        if not server.kouser then return 404 end
        return 200, server.kouser
    end
    if path == "/api/v1/koreader-users/me" and o.method == "PUT" then
        server.kouser = { id = 1, username = o.json.username, password = o.json.password,
            passwordMD5 = "md5:" .. o.json.password, syncEnabled = false }
        return 200, server.kouser
    end
    local on = path:match("^/api/v1/koreader%-users/me/sync%?enabled=(%a+)$")
    if on and o.method == "PATCH" then server.kouser.syncEnabled = on == "true"; return 204 end
    local book = path:match("^/api/v1/annotations/book/(%d+)$")
    if book then
        local out = {}
        for _i, a in ipairs(server.ann) do if a.bookId == tonumber(book) then out[#out + 1] = a end end
        return 200, out
    end
    if o.method == "POST" and path == "/api/v1/annotations" then
        for _i, a in ipairs(server.ann) do if a.cfi == o.json.cfi then return 409 end end
        server.next_id = server.next_id + 1
        local a = { id = server.next_id, bookId = o.json.bookId, cfi = o.json.cfi, text = o.json.text,
            color = o.json.color, style = o.json.style, note = o.json.note ~= "" and o.json.note or NULL,
            chapterTitle = o.json.chapterTitle, createdAt = "2026-11-27T10:00:00Z" }
        server.ann[#server.ann + 1] = a
        return 201, a
    end
    local aid = path:match("^/api/v1/annotations/(%d+)$")
    if aid then
        for i, a in ipairs(server.ann) do
            if a.id == tonumber(aid) then
                if o.method == "DELETE" then table.remove(server.ann, i); return 204 end
                if o.method == "PUT" then
                    a.color, a.style, a.note = o.json.color or a.color, o.json.style or a.style, o.json.note
                    return 200, a
                end
            end
        end
        return 404
    end
    return 404
end
package.preload["aleph_grimmory_http"] = function()
    return { request = function(o) return route(o) end, escape = function(s) return s end, query = function() return "" end }
end

local Api = require("aleph_grimmory_api")
local S = require("aleph_grimmory_sync")
local H = require("aleph_grimmory_highlights")
local Ann = require("aleph_grimmory_annotations")
local O = require("aleph_grimmory_others")
local cfi = require("aleph_grimmory_cfi")

local failures, count = 0, 0
local function eq(got, want, what)
    count = count + 1
    if got ~= want then
        failures = failures + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- An EPUB as a folder, with the surface of ffi/archiver that the CFI code uses.
local function dirReader()
    local r = {}
    function r:open(path) self.root = path end
    function r:iterate() return function() return nil end end
    function r:extractToMemory(name)
        local f = io.open(self.root .. "/" .. name, "rb")
        if not f then return nil end
        local s = f:read("*a"); f:close(); return s
    end
    function r:close() end
    return r
end
local FIX = "tests/fixtures/grimmory_cfi/"
local function book(name)
    local ok, err = cfi.initBook(FIX .. name, dirReader())
    eq(ok, true, "init " .. name .. " " .. tostring(err))
end

-- ------------------------------------------------------------- CFI
book("minimal")
local xp = "/body/DocFragment[1]/body/p[1]/text()[1].5"
local c = cfi.xpointerToCFI(xp)
eq(type(c) == "string" and c:match("^epubcfi%(") ~= nil, true, "a CFI")
eq(cfi.cfiToXPointer(c), xp, "and back")
local p0, p1 = "/body/DocFragment[1]/body/p[1]/text()[1].1", "/body/DocFragment[1]/body/p[1]/text()[1].7"
local range = cfi.xpointerRangeToCFI(p0, p1)
local b0, b1 = cfi.cfiRangeToXPointers(range)
eq(b0, p0, "range start back"); eq(b1, p1, "range end back")

book("whitespace")
local w0, w1 = "/body/DocFragment[1]/body/p[1]/text()[1].2", "/body/DocFragment[1]/body/p[2]/text()[1].3"
local wr = cfi.xpointerRangeToCFI(w0, w1)
local wb0, wb1 = cfi.cfiRangeToXPointers(wr)
eq(wb0, w0, "over two paragraphs: start"); eq(wb1, w1, "over two paragraphs: end")

book("body_index")
local bx = "/body/DocFragment[1]/body/p[1]/text()[1].3"
local bc = cfi.xpointerToCFI(bx)
eq(bc and bc:match("/[46]/%d") ~= nil, true, "body after head")
eq(cfi.cfiToXPointer(bc), bx, "body after head, back")

book("utf16_surrogate")
local ec = cfi.xpointerToCFI("/body/DocFragment[1]/body/p[1]/text()[1].1")
eq(ec and ec:match(":2%)$") ~= nil, true, "an emoji counts two for Grimmory's reader")

-- ------------------------------------------------------------- pure parts
local cleaned = H.clean({ { id = 1, cfi = "x", note = NULL, text = "t", extra = { 1 } }, { note = "no id" }, "junk" })
eq(#cleaned, 1, "only annotations with an id"); eq(cleaned[1].note, nil, "JSON null dropped"); eq(cleaned[1].extra, nil, "unknown field dropped")
eq(H.eligible("/b/Dune.epub", 7), true, "an EPUB with an id")
eq(H.eligible("/b/Dune.pdf", 7), false, "a PDF: the note instead")
eq(H.eligible("/b/Dune.epub", nil), false, "not matched yet")
eq(H.mark({ { pos0 = "a", pos1 = "b", text = "t" } }) ~= H.mark({ { pos0 = "a", pos1 = "b", text = "t", note = "n" } }), true, "a new note changes the mark")

eq(Api.kosyncFrom({ username = "kobo", passwordMD5 = "ABC" }).key, "abc", "KOReader key from Grimmory")
eq(Api.kosyncFrom({ username = "kobo", password = "pw" }).key, "md5:pw", "or made from the password")
eq(Api.kosyncFrom({ username = "kobo" }), nil, "no key, nothing")
eq(Api.kosyncFrom(nil), nil, "no user")
local pw = Api.newPassword()
eq(#pw, 24, "a long password"); eq(pw ~= Api.newPassword(), true, "a new one each time")

local owns = O.decide({ grimmory_sync = "/p/grimmory_sync.koplugin" }, { annotations = true })
eq(owns.progress, "grimmory_sync", "Grimmory Sync sends progress"); eq(owns.annotations, "grimmory_sync", "and highlights when on")
eq(owns.sessions, nil, "sessions off there: Aleph sends them")
owns = O.decide({ grimmory = "/p/grimmory.koplugin", grimmory_official = true }, {})
eq(owns.progress, "grimmory", "Grimmory's plugin"); eq(owns.annotations, "grimmory", "its highlights")
owns = O.decide({ grimmory = "/p/grimmory.koplugin", grimmory_official = false }, {})
eq(owns.progress, nil, "a library-only plugin of that name: Aleph does all")
eq(next(O.decide({}, {})), nil, "no other plugin")
O._reset({})
eq(O.owns("progress"), nil, "nothing found on the device")

-- ------------------------------------------------------------- the single account
local tokens_out = tmp .. "/aleph_grimmory_tokens_hl.lua"
local r = S.workLogin({ base = "http://h", tokens = {}, tokens_out = tokens_out, user = "alex", password = "secret", kosync = true })
eq(r.code, 200, "signed in"); eq(r.kosync and r.kosync.user, "alex", "KOReader user made")
eq(r.kosync and r.kosync.key, server.kouser.passwordMD5, "with its key")
eq(server.kouser.syncEnabled, true, "and its sync turned on")
local made = server.kouser.password
r = S.workLogin({ base = "http://h", tokens = {}, tokens_out = tokens_out, user = "alex", password = "secret", kosync = true })
eq(server.kouser.password, made, "an existing KOReader user is kept")
eq(r.kosync.key, "md5:" .. made, "and read back")
r = S.workLogin({ base = "http://h", tokens = {}, tokens_out = tokens_out, user = "alex", password = "secret", kosync = false })
eq(r.kosync, nil, "progress already set up by hand: left alone")
eq(S.workLogin({ base = "http://h", tokens = {}, tokens_out = tokens_out, user = "alex", password = "no", kosync = true }).code, 401, "wrong password")

-- ------------------------------------------------------------- highlights both ways
local api = Api.new("http://h", {}, function() end)
api:login("alex", "secret")
local plan_base = { base = "http://h", tokens = api.tokens, tokens_out = tokens_out }
local function plan(items, shadow)
    local p = {}
    for k, v in pairs(plan_base) do p[k] = v end
    p.book_id, p.items, p.shadow = 7, items, shadow
    return p
end

book("minimal")
-- One highlight on the device, none in Grimmory: it goes there.
local locals = { { pos0 = p0, pos1 = p1, text = "highlighted", color = "yellow", drawer = "lighten", chapter = "One", datetime = "2026-11-27 10:00:00" },
    { page = 3, text = "a bookmark" } }
local items = Ann.fromLocal(locals, cfi, 7)
eq(#items, 1, "a bookmark is not sent")
r = H.work(plan(items, {}))
eq(r.code, 200, "sent"); eq(#server.ann, 1, "created in Grimmory"); eq(server.ann[1].color, "#FFC107", "yellow as Grimmory's yellow")
eq(server.ann[1].cfi, range, "at its CFI")
local merged = Ann.mergeLocal(locals, r.remote, cfi, r.conflicts)
eq(#merged, 2, "bookmark kept"); eq(merged[1].grimmory_id, server.ann[1].id, "the local highlight knows its Grimmory id")
local shadow = Ann.shadowFor(r.remote)

-- Again with nothing changed: nothing sent.
local before = #server.log
r = H.work(plan(Ann.fromLocal(merged, cfi, 7), shadow))
local writes = 0
for i = before + 1, #server.log do if not server.log[i]:match("^GET") then writes = writes + 1 end end
eq(writes, 0, "nothing changed, nothing written")

-- A note added on the device: an update.
merged[1].note = "a thought"
r = H.work(plan(Ann.fromLocal(merged, cfi, 7), shadow))
eq(server.ann[1].note, "a thought", "note sent")
merged = Ann.mergeLocal(merged, r.remote, cfi, r.conflicts)
shadow = Ann.shadowFor(r.remote)

-- Made in Grimmory's reader: it comes to the device.
local w_range = cfi.xpointerRangeToCFI("/body/DocFragment[1]/body/p[1]/text()[1].0", "/body/DocFragment[1]/body/p[1]/text()[1].3")
server.ann[#server.ann + 1] = { id = 900, bookId = 7, cfi = w_range, text = "web", color = "#4ADE80", style = "underline", note = NULL }
r = H.work(plan(Ann.fromLocal(merged, cfi, 7), shadow))
merged = Ann.mergeLocal(merged, r.remote, cfi, r.conflicts)
local web
for _i, a in ipairs(merged) do if a.grimmory_id == 900 then web = a end end
eq(web and web.color, "green", "green comes as green"); eq(web and web.drawer, "underscore", "underline as underline")
eq(web and web.pos0, "/body/DocFragment[1]/body/p[1]/text()[1].0", "at the right place")
shadow = Ann.shadowFor(r.remote)

-- Removed on the device: removed in Grimmory.
local kept = {}
for _i, a in ipairs(merged) do if a.grimmory_id ~= 900 then kept[#kept + 1] = a end end
r = H.work(plan(Ann.fromLocal(kept, cfi, 7), shadow))
local still = false
for _i, a in ipairs(server.ann) do if a.id == 900 then still = true end end
eq(still, false, "deleted in Grimmory")
merged = Ann.mergeLocal(kept, r.remote, cfi, r.conflicts)
shadow = Ann.shadowFor(r.remote)

-- Changed on both sides differently: neither overwritten.
server.ann[1].note = "web note"
merged[1].note = "device note"
r = H.work(plan(Ann.fromLocal(merged, cfi, 7), shadow))
eq(server.ann[1].note, "web note", "Grimmory's kept")
local n = 0
for _k in pairs(r.conflicts) do n = n + 1 end
eq(n, 1, "one conflict")
merged = Ann.mergeLocal(merged, r.remote, cfi, r.conflicts)
eq(merged[1].note, "device note", "the device's kept")

-- Removed in Grimmory: removed on the device.
merged[1].note = "web note"     -- (the reader settles it)
shadow = Ann.shadowFor(r.remote)
server.ann = {}
r = H.work(plan(Ann.fromLocal(merged, cfi, 7), shadow))
merged = Ann.mergeLocal(merged, r.remote, cfi, r.conflicts)
local hl = 0
for _i, a in ipairs(merged) do if a.pos0 then hl = hl + 1 end end
eq(hl, 0, "gone from the device too"); eq(#merged, 1, "the bookmark stays")

-- Signed out: stops at once.
server.access, server.refresh = "Z", "Z"
api.tokens.access_exp = 0
eq(H.work(plan({}, {})).code ~= 200, true, "signed out")

-- ------------------------------------------------------------- in the reader
-- A book opens, a highlight is made, the book closes; then the same book
-- with a highlight from Grimmory, written back to its settings file.
server.access, server.refresh = "A1", "R1"
server.ann = {}
local scheduled = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_self, _t, fn) scheduled[#scheduled + 1] = fn end,
    unschedule = function(_self, fn) for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end end,
    setDirty = function() end,
}
package.loaded["aleph_job"] = { available = function() return false end }
local files = {}
package.loaded["docsettings"] = { open = function(_self, path)
    files[path] = files[path] or {}
    local f = files[path]
    return { saveSetting = function(_s, k, v) f[k] = v end, flush = function() f.flushed = true end }
end }
local Prefs = require("aleph_prefs")
Prefs.set("grimmory_url", "http://h")
Prefs.set("grimmory_api", { refresh = "R1", user = "alex" })
S.state().ids[FIX .. "minimal.epub"] = 7
-- (initBook is given the fixture folder through a reader that ignores the name.)
local real_init = cfi.initBook
cfi.initBook = function(_path) return real_init(FIX .. "minimal", dirReader()) end
local saved_settings = {}
local ui = { document = { file = FIX .. "minimal.epub" },
    annotation = { annotations = {} },
    doc_settings = { readSetting = function(_s, k) return saved_settings[k] end, saveSetting = function(_s, k, v) saved_settings[k] = v end } }
H._reset()
H.open(ui)
eq(H._book() and H._book().id, 7, "the book is followed")
ui.annotation.annotations[1] = { pos0 = p0, pos1 = p1, text = "highlighted", color = "yellow", drawer = "lighten" }
H.changed()
eq(#scheduled, 1, "sent a little later")
scheduled[1](); table.remove(scheduled, 1)
eq(#server.ann, 1, "in Grimmory"); eq(ui.annotation.annotations[1].grimmory_id, server.ann[1].id, "the open book knows its id")
eq(saved_settings.annotations_externally_modified, true, "KOReader told the highlights changed")
H.changed()
eq(#scheduled, 0, "Aleph's own writing back is not a change")
server.ann[#server.ann + 1] = { id = 901, bookId = 7, cfi = w_range, text = "web", color = "#F472B6", style = "highlight" }
H.close(ui)
local f = files[FIX .. "minimal.epub"]
eq(f and #f.annotations, 2, "written to the closed book's settings")
eq(f and f.flushed, true, "and saved")
eq(H._book(), nil, "the book let go")
eq(S.state().ann and S.state().ann["7"] ~= nil, true, "what both agree on is kept")
Prefs.set("grimmory_highlights", false)
H.open(ui)
eq(H._book(), nil, "turned off: nothing")
cfi.initBook = real_init

cfi.clearCache()
os.remove(tokens_out)
print(string.format("%d checks, %d failed", count, failures))
os.exit(failures == 0 and 0 or 1)

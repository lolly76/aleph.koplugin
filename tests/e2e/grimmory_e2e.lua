-- Aleph for Grimmory modification, 2026-11-28: Aleph's Grimmory code against
-- a real Grimmory (started by tests/e2e/run.sh). Run from the plugin folder:
--   luajit tests/e2e/grimmory_e2e.lua <base> <user> <password> <epub> <epub folder> <partial md5>
package.path = "./?.lua;" .. package.path
local base, user, pass, epub, epub_dir, hash = arg[1], arg[2], arg[3], arg[4], arg[5], arg[6]
assert(hash, "usage: grimmory_e2e.lua base user password epub epub_dir partial_md5")
local tmp = os.getenv("ALEPH_TEST_DIR") or "/tmp"

-- KOReader's parts, made of LuaSocket and cjson.
local cjson = require("cjson")
package.preload["json"] = function()
    return { encode = cjson.encode, decode = function(s)
        -- (KOReader's decoder gives JSON null as a function; cjson as a lightuserdata.)
        return cjson.decode(s)
    end }
end
package.preload["socketutil"] = function()
    local http = require("socket.http")
    return { set_timeout = function(_self, block) http.TIMEOUT = block end, reset_timeout = function() http.TIMEOUT = 60 end }
end
package.preload["ffi/sha2"] = function()
    return { md5 = function(s)
        local f = io.open(tmp .. "/md5.in", "wb"); f:write(s); f:close()
        local p = io.popen("md5sum '" .. tmp .. "/md5.in'"); local out = p:read("*a"); p:close()
        return out:match("^(%x+)")
    end }
end
local store = {}
G_reader_settings = {
    readSetting = function(_self, k) return store[k] end,
    saveSetting = function(_self, k, v) store[k] = v end,
    flush = function() end,
}
package.preload["logger"] = function() local n = function() end; return { info = n, warn = n, dbg = n } end
package.preload["datastorage"] = function() return { getSettingsDir = function() return tmp end, getDataDir = function() return tmp end } end
package.preload["ui/network/manager"] = function() return { isConnected = function() return true end } end
package.preload["aleph_toast"] = function() return { show = function() end } end
package.preload["aleph_gettext"] = function() return function(s) return s end end
package.preload["ui/uimanager"] = function() return { scheduleIn = function() end, unschedule = function() end } end
package.preload["aleph_job"] = function() return { available = function() return false end } end
package.preload["device"] = function() return { model = "E2E" } end

local failures, count = 0, 0
local function eq(got, want, what)
    count = count + 1
    if got ~= want then
        failures = failures + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    else
        print("ok   " .. what)
    end
end

local Prefs = require("aleph_prefs")
local G = require("aleph_grimmory")
local S = require("aleph_grimmory_sync")
local Api = require("aleph_grimmory_api")
local H = require("aleph_grimmory_highlights")
local Ann = require("aleph_grimmory_annotations")
local cfi = require("aleph_grimmory_cfi")

Prefs.set("grimmory_url", base)
local function plan(extra)
    local p = { base = base, tokens = S.tokens(), tokens_out = tmp .. "/tokens_e2e.lua" }
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
end
local function saveTokensFrom(p) local t = require("aleph_file").read(p.tokens_out); if t then S._saveTokens(t) end end
local function api() local p = plan(); return S.apiFor(p), p end

-- Signing in, with the KOReader user made for progress.
local said
S.login(user, "wrong-password", function(ok) said = ok end)
eq(said, false, "a wrong password is refused")
S.login(user, pass, function(ok, message) said = ok; print("     " .. tostring(message)) end)
eq(said, true, "signed in")
eq(S.signedIn(), true, "tokens kept")
eq(G.configured(), true, "progress sync set up from the account")
G.test(function(ok) said = ok end)
eq(said, true, "the KOReader user is accepted")

-- The library matched.
local lib = S.workLibrary(plan({ shelves = true }))
eq(lib.code, 200, "the library read")
local size = io.open(epub, "rb"):seek("end")
local found = Api.match({ { path = epub, title = "Aleph Test Book", authors = { "Ada Tester" }, size = size } }, lib.books)
local id = found[epub]
eq(type(id), "number", "the book matched")
S.state().ids[epub] = id

local function book()
    local a = api()
    local c, b = a:call("GET", "/api/v1/books/" .. tostring(id))
    return c == 200 and b or {}
end

-- Progress, then a status set by hand that the progress would reset.
local cred = { base = base, user = G.user(), key = Prefs.get().grimmory_key }
local xp = "/body/DocFragment[1]/body/p[2]/text()[1].3"
local r = G.work({ cred = cred, auth = true, device = "E2E", device_id = "e2e-1",
    push = { { hash = hash, pct = 0.42, progress = xp, time = os.time() } }, pull = { hash } })
eq(r.auth, 200, "progress sync: signed in")
eq(r.pushed[hash], true, "the position sent")
eq(r.pulled[hash] and math.floor(r.pulled[hash].pct * 100 + 0.5), 42, "and read back")
eq(r.pulled[hash] and r.pulled[hash].progress, xp, "with its place")
eq(book().readStatus, "READING", "Grimmory set Reading from the percentage")

local function sendChanges(b, opts)
    local ops = S.changes(b, S.state().sent[id], opts)
    local ready = S.ready(ops, S.state().ids)
    local p = plan({ ops = ready })
    local res = S.workOps(p)
    saveTokensFrom(p)
    for i, op in ipairs(ready) do
        if res.done[i] then
            local sent = S.state().sent[id] or {}
            if op.op == "status" then sent.status = op.status elseif op.op == "rating" then sent.rating = op.rating end
            S.state().sent[id] = sent
        end
    end
    return #ready, res
end
eq((sendChanges({ path = epub, status = "abandoned" }, { notes = false, stars = false, pct = 0.42 })), 1, "On hold sent")
eq(book().readStatus, "PAUSED", "Grimmory has it Paused")
G.work({ cred = cred, device = "E2E", device_id = "e2e-1", push = { { hash = hash, pct = 0.45, progress = xp, time = os.time() } } })
eq(book().readStatus, "READING", "the next position resets it (Grimmory's rule)")
eq((sendChanges({ path = epub, status = "abandoned" }, { notes = false, stars = false, pct = 0.45 })), 1, "so Aleph sends it again after")
eq(book().readStatus, "PAUSED", "and Grimmory keeps On hold")

-- Stars, the note, a session.
sendChanges({ path = epub, stars = 4 }, { status = false, notes = false })
eq(book().personalRating, 8, "4 stars are 8 out of 10")
local n, res = sendChanges({ path = epub, highlights = { { text = "Hello world", chapter = "One" } } }, { status = false, stars = false })
eq(n == 1 and res.done[1], true, "the highlights note sent")
local a = api()
local c, notes = a:notes(id)
eq(c == 200 and notes[1] and notes[1].title, Api.NOTE_TITLE, "and found on the book")
local session = Api.sessionBody({ book_id = id, started = os.time() - 600, ended = os.time(), from = 0.4, to = 0.45, format = "epub" })
local p = plan({ ops = { { op = "session", id = id, body = session } } })
eq(S.workOps(p).done[1], true, "a reading session accepted")
saveTokensFrom(p)

-- Highlights as Grimmory's own.
local function dirReader()
    local rd = {}
    function rd:open(path) self.root = path end
    function rd:iterate() return function() return nil end end
    function rd:extractToMemory(name)
        local f = io.open(self.root .. "/" .. name, "rb")
        if not f then return nil end
        local s = f:read("*a"); f:close(); return s
    end
    function rd:close() end
    return rd
end
eq(cfi.initBook(epub_dir, dirReader()), true, "the EPUB read for CFI")
local locals = { { pos0 = "/body/DocFragment[1]/body/p[1]/text()[1].0", pos1 = "/body/DocFragment[1]/body/p[1]/text()[1].11",
    text = "Hello world", chapter = "One", color = "yellow", drawer = "lighten", note = "first", datetime = "2026-11-28 08:00:00" } }
local items = Ann.fromLocal(locals, cfi, id)
p = plan({ book_id = id, items = items, shadow = {} })
local hr = H.work(p)
saveTokensFrom(p)
eq(hr.code, 200, "highlights sent")
eq(#(hr.remote or {}), 1, "one Grimmory highlight")
local merged = Ann.mergeLocal(locals, hr.remote, cfi, hr.conflicts)
eq(merged[1] and type(merged[1].grimmory_id), "number", "the local highlight knows its Grimmory id")
eq(merged[1] and merged[1].pos0, locals[1].pos0, "its place kept through the CFI")
eq(merged[1] and merged[1].datetime and merged[1].datetime:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") ~= nil, true, "a date in KOReader's form")
p = plan({ book_id = id, items = Ann.fromLocal(merged, cfi, id), shadow = Ann.shadowFor(hr.remote) })
hr = H.work(p)
saveTokensFrom(p)
eq(#(hr.remote or {}), 1, "a second sync makes no copy")
merged[1].note = "changed here"
p = plan({ book_id = id, items = Ann.fromLocal(merged, cfi, id), shadow = Ann.shadowFor(hr.remote) })
hr = H.work(p)
saveTokensFrom(p)
eq(hr.remote and hr.remote[1] and hr.remote[1].note, "changed here", "a note changed on the device reaches Grimmory")

-- Browse and download.
a = api()
local cp, page = a:page({ sort = "-addedOn" })
eq(cp, 200, "a page of the library"); eq(page and #page.books >= 1, true, "with the book")
cp, page = a:page({ query = "Aleph", sort = "title" })
eq(page and #page.books, 1, "search finds it")
local out = tmp .. "/download.epub"
eq(a:download(id, out), 200, "downloaded")
local f = io.open(out, "rb"); eq(f and f:seek("end"), size, "the whole file"); if f then f:close() end

-- A refresh token is refused for its first 2 minutes: that is no sign-out.
local t = S.tokens(); t.access_exp = 0; S._saveTokens(t)
local got
S._run("ops", function(pl) return { code = (S.apiFor(pl):call("GET", "/api/v1/shelves")) } end, {}, function(rr) got = rr and rr.code end)
eq(got, 401, "too soon after signing in: refused")
eq(S.signedIn(), true, "but still signed in")
-- Later, renewed; and the old token is then taken back, which is why runs go
-- one at a time.
print("     waiting 125 s for the refresh token to be usable...")
os.execute("sleep 125")
local before_refresh = S.tokens().refresh
t = S.tokens(); t.access_exp = 0; S._saveTokens(t)
S._run("ops", function(pl) return { code = (S.apiFor(pl):call("GET", "/api/v1/shelves")) } end, {}, function(rr) got = rr and rr.code end)
eq(got, 200, "renewed and answered")
eq(S.tokens().refresh ~= before_refresh, true, "a new refresh token kept")
eq(Api.new(base, { refresh = before_refresh }):refresh() ~= 200, true, "the old one is taken back by Grimmory")
eq(S.signedIn(), true, "still signed in")

-- Signing out takes the token back on the server.
local old = S.tokens().refresh
S.logout()
eq(S.signedIn(), false, "signed out")
local code = Api.new(base, { refresh = old }):refresh()
eq(code ~= 200, true, "the old refresh token no longer works")

print(string.format("%d checks, %d failed", count, failures))
if failures > 0 then os.exit(1) end

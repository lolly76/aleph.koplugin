-- Aleph for Grimmory modification, 2026-11-28: tests of the fixes made before
-- the first tests on a device: one Grimmory run at a time with the tokens the
-- run before left, chapters parsed once, a status set by hand sent again
-- after the position, sessions cut by sleep, safe file names and addresses.
-- Run from the plugin folder: luajit tests/grimmory_fixes_test.lua
package.path = "./?.lua;" .. package.path

local tmp = os.getenv("ALEPH_TEST_DIR") or "/tmp"
local store = {}
local flushed = 0
G_reader_settings = {
    readSetting = function(_self, k) return store[k] end,
    saveSetting = function(_self, k, v) store[k] = v end,
    flush = function() flushed = flushed + 1 end,
}
package.preload["logger"] = function() return { info = function() end, warn = function() end, dbg = function() end } end
package.preload["datastorage"] = function() return { getSettingsDir = function() return tmp end, getDataDir = function() return tmp end } end
package.preload["ffi/sha2"] = function() return { md5 = function(s) return "md5:" .. s end } end
local connected = true
package.preload["ui/network/manager"] = function() return { isConnected = function() return connected end } end
package.preload["aleph_toast"] = function() return { show = function() end } end
package.preload["ui/uimanager"] = function() return { scheduleIn = function() end, unschedule = function() end, show = function() end, close = function() end } end
package.preload["aleph_gettext"] = function() return function(s) return s end end

-- Background processes that end only when the test says so.
local jobs = {}
package.preload["aleph_job"] = function()
    return {
        available = function() return true end,
        start = function(fn) jobs[#jobs + 1] = { fn = fn }; return #jobs end,
        watch = function(pid, o) jobs[pid].on_done = o.on_done; jobs[pid].timeout = o.timeout end,
    }
end
local function finishJob(pid)
    local j = jobs[pid]
    j.fn()
    j.on_done(false)
end

-- A pretend Grimmory that takes the old refresh token back on each renewal.
local server = { access = "A1", refresh = "R1", n = 1, refused = 0 }
package.preload["aleph_grimmory_http"] = function()
    return {
        request = function(o)
            local path = o.url:gsub("^https?://[^/]+", "")
            if path == "/api/v1/auth/refresh" then
                if o.json.refreshToken ~= server.refresh then server.refused = server.refused + 1; return 401 end
                server.n = server.n + 1
                server.access, server.refresh = "A" .. server.n, "R" .. server.n
                return 200, { accessToken = server.access, refreshToken = server.refresh, expires = 7200 }
            end
            if (o.headers or {})["Authorization"] ~= "Bearer " .. server.access then return 401 end
            return 200, {}
        end,
        escape = function(s) return s end, query = function() return "" end,
    }
end

local failures, count = 0, 0
local function eq(got, want, what)
    count = count + 1
    if got ~= want then
        failures = failures + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

local Prefs = require("aleph_prefs")
local G = require("aleph_grimmory")
local S = require("aleph_grimmory_sync")
local Api = require("aleph_grimmory_api")

-- ------------------------------------------------- P0-1: one run at a time
Prefs.set("grimmory_url", "http://grimmory.lan:6060")
-- Signed in two hours ago: the access token has run out.
Prefs.set("grimmory_api", { user = "alex", access = "A1", access_exp = os.time() - 10, refresh = "R1", refresh_exp = os.time() + 86400 })
local function call(plan) return { code = (S.apiFor(plan):call("GET", "/api/v1/shelves")) } end
local got = {}
S._run("ops", call, {}, function(r) got.ops = r and r.code end)
S._run("highlights", call, {}, function(r) got.hl = r and r.code end)
eq(#jobs, 1, "the second run waits for the first")
finishJob(1)
eq(got.ops, 200, "the first run renewed the token and was answered")
eq(#jobs, 2, "then the second one starts")
finishJob(2)
eq(got.hl, 200, "with the new token: answered too")
eq(server.refused, 0, "no refresh token used twice")
eq(S.signedIn(), true, "still signed in")
eq(S.tokens().refresh, "R2", "the renewed refresh token kept")
eq(flushed > 0, true, "and written out at once")
eq(select(1, S._busy()), false, "nothing left running")

-- A refresh token Grimmory does not take yet (its first 2 minutes) is kept.
server.refresh = "R-other"
local young = Api.new("http://g", { refresh = "R2", refresh_at = os.time() - 30 })
eq(young:refresh(), 401, "refused while too young")
eq(young.tokens.refresh, "R2", "and kept, not taken for a sign-out")
local old_one = Api.new("http://g", { refresh = "R2", refresh_at = os.time() - 3600 })
old_one:refresh()
eq(old_one.tokens.refresh, nil, "an old one refused: signed out")
server.refresh = "R2"

-- ------------------------------------------------- P0-2: chapters parsed once
local cfi = require("aleph_grimmory_cfi")
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
cfi.initBook("tests/fixtures/grimmory_cfi/whitespace", dirReader())
local w0, w1 = "/body/DocFragment[1]/body/p[1]/text()[1].2", "/body/DocFragment[1]/body/p[2]/text()[1].3"
local range
for _i = 1, 20 do range = cfi.xpointerRangeToCFI(w0, w1) end
for _i = 1, 20 do cfi.cfiRangeToXPointers(range) end
eq(cfi.parses, 1, "one chapter parsed once for 80 conversions")
local b0, b1 = cfi.cfiRangeToXPointers(range)
eq(b0, w0, "the cached answer is right: start"); eq(b1, w1, "end")
cfi.clearCache()
eq(cfi.parses, 0, "a new book starts afresh")

-- ------------------------------------------------- P0-3: status after the position
eq(G.statusFromPercent(0.4), "READING", "Grimmory's own rule: reading")
eq(G.statusFromPercent(0.996), "READ", "read from 99.5 %")
eq(G.statusFromPercent(0.001), "UNREAD", "unread below 0.25 %")
local sent = { status = "PAUSED" }
local ops = S.changes({ path = "/b.epub", status = "abandoned" }, sent, { notes = false, stars = false, pct = 0.4 })
eq(#ops, 1, "On hold sent again after a position, though sent before")
eq(ops[1] and ops[1].status, "PAUSED", "as Paused")
ops = S.changes({ path = "/b.epub", status = "complete" }, { status = "READ" }, { notes = false, stars = false, pct = 0.98 })
eq(#ops, 1, "Finished at 98 %: sent again")
ops = S.changes({ path = "/b.epub", status = "complete" }, { status = "READ" }, { notes = false, stars = false, pct = 1 })
eq(#ops, 0, "Finished at the end: Grimmory says Read itself")
ops = S.changes({ path = "/b.epub", status = "abandoned" }, { status = "PAUSED" }, { notes = false, stars = false })
eq(#ops, 0, "no position sent: not sent twice")
ops = S.changes({ path = "/b.epub", status = "reading" }, nil, { notes = false, stars = false, pct = 0.5 })
eq(#ops, 0, "Reading is left to the percentage")

eq(G.unchanged({ pct = 0.5, progress = "/body/x" }, { pct = 0.5001, progress = "/body/x" }), true, "same place: not sent again")
eq(G.unchanged({ pct = 0.5, progress = "/body/x" }, { pct = 0.6, progress = "/body/y" }), false, "moved: sent")
eq(G.unchanged(nil, { pct = 0.5, progress = "/body/x" }), false, "never seen: sent")

-- The account's changes wait for the positions being sent.
local order = {}
local after_ran = false
G.isRunning = function() return true end
local saved_after = G.after
G.after = function(fn) order[#order + 1] = "after"; after_ran = fn end
S.flush()
eq(order[1], "after", "a flush waits while positions are being sent")
G.isRunning = function() return false end
G.after = saved_after

-- ------------------------------------------------- P1-1: a plain table of settings
local book = S._bookFrom("/b.epub", { summary = { status = "complete", rating = 4 } })
eq(book.status, "complete", "status from a plain table"); eq(book.stars, 4, "stars too")

-- ------------------------------------------------- P1-2: sleep ends a session
local doc = { file = "/b.epub" }
local ui = { document = doc, rolling = { getLastPercent = function() return 0.3 end, getLastProgress = function() return "/body/a" end } }
Prefs.set("grimmory_ops", nil)
local t0 = os.time
local now = 1000000
os.time = function(t) if t then return t0(t) end return now end
S.open(ui)
now = now + 600
S.suspend(ui)
local q = S.ops()
eq(#q, 1, "going to sleep queues the session so far")
eq(q[1] and q[1].body_parts and (q[1].body_parts.ended - q[1].body_parts.started), 600, "ten minutes, not the night")
now = now + 8 * 3600
S.resume(ui)
now = now + 120
S.suspend(ui)
q = S.ops()
eq(#q, 2, "another session after waking")
eq(q[2] and q[2].body_parts and (q[2].body_parts.ended - q[2].body_parts.started), 120, "two minutes")
os.time = t0
Prefs.set("grimmory_ops", nil)

-- ------------------------------------------------- P1-3: another server
S.state().ids["/b.epub"] = 7
local before = #jobs
S.serverChanged("http://grimmory.lan:6060")
eq(S.signedIn(), false, "another server: signed out")
eq(#jobs, before + 1, "the tokens are taken back on the old server")
finishJob(#jobs)
eq(S.signedIn(), false, "and signing out there does not sign in again")
eq(S.idOf("/b.epub"), nil, "the old server's book ids forgotten")
eq(type(S.state().forget_ann_ids), "number", "highlights' old ids dropped as books open")
local H = require("aleph_grimmory_highlights")
local anns = { { pos0 = "a", grimmory_id = 5, grimmory_cfi = "c" }, { pos0 = "b" } }
eq(H.forgetIds(anns), 1, "one highlight had an id")
eq(anns[1].grimmory_id, nil, "id gone"); eq(anns[1].pos0, "a", "the highlight kept")

-- ------------------------------------------------- P1-4: downloads
local B = require("aleph_grimmory_browse")
local taken = { ["/b/Dune.epub"] = true, ["/b/Dune (2).epub"] = true }
eq(B.freePath("/b/Dune.epub", function(p) return taken[p] end), "/b/Dune (3).epub", "an existing book is never replaced")
eq(B.freePath("/b/New.epub", function(p) return taken[p] end), "/b/New.epub", "a free name kept")
local name = Api.fileNameFor({ id = 1, metadata = { title = "Dune" }, primaryFile = { extension = "ep/../ub" } })
eq(name, "Dune.epub", "the server's extension cleaned")
local long = string.rep("é", 100)
local cut = Api.cut(long, 151)
eq(#cut, 150, "cut before a broken character")
eq(cut:match("^[\128-\255]*$") ~= nil and #cut % 2 == 0, true, "whole characters only")

-- ------------------------------------------------- P1-6: dates
local Ann = require("aleph_grimmory_annotations")
eq(Ann.localDate("2026-11-27T09:00:00.123456"), "2026-11-27 09:00:00", "Grimmory's date in KOReader's form")
eq(Ann.localDate("nonsense"), nil, "not a date")
local z = Ann.localDate("2026-11-27T09:00:00Z")
eq(type(z) == "string" and z:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") ~= nil, true, "a UTC date in the device's time")

-- ------------------------------------------------- P2: addresses
eq(Api.onServer("http://g.lan:6060", "/api/v1/books/page?cursor=x"), "http://g.lan:6060/api/v1/books/page?cursor=x", "a path on the server")
eq(Api.onServer("http://g.lan:6060", "http://G.LAN:6060/api/v1/x"), "http://G.LAN:6060/api/v1/x", "the same server spelled otherwise")
eq(Api.onServer("http://g.lan:6060", "http://evil.example/api"), nil, "never another server")
eq(G.insecure("http://192.168.1.10:6060"), false, "home network: no warning")
eq(G.insecure("http://grimmory.local"), false, ".local: no warning")
eq(G.insecure("http://100.101.1.2:6060"), false, "Tailscale: no warning")
eq(G.insecure("http://books.example.org"), true, "http on the internet: warned")
eq(G.insecure("https://books.example.org"), false, "https: fine")

print(string.format("%d checks, %d failed", count, failures))
if failures > 0 then os.exit(1) end

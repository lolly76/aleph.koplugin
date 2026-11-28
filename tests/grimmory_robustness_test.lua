-- Aleph for Grimmory modification, 2026-11-28: Aleph with no Grimmory account
-- (nothing goes online, nothing is written), Wi-Fi lost in the middle of a
-- run, weeks of changes waiting, and a big library.
-- Run from the plugin folder: luajit tests/grimmory_robustness_test.lua
package.path = "./?.lua;" .. package.path

local tmp = os.getenv("ALEPH_TEST_DIR") or "/tmp"
os.remove(tmp .. "/aleph_grimmory_state.lua")
local store = {}
local writes = 0
G_reader_settings = {
    readSetting = function(_self, k) return store[k] end,
    saveSetting = function(_self, k, v) writes = writes + 1; store[k] = v end,
    flush = function() end,
}
package.preload["logger"] = function() return { info = function() end, warn = function() end, dbg = function() end } end
package.preload["datastorage"] = function() return { getSettingsDir = function() return tmp end, getDataDir = function() return tmp end } end
package.preload["ffi/sha2"] = function() return { md5 = function(s) return "md5:" .. s end } end
package.preload["ffi/util"] = function() return { template = function(s) return s end } end
local connected = true
package.preload["ui/network/manager"] = function() return { isConnected = function() return connected end, runWhenOnline = function() end } end
package.preload["aleph_toast"] = function() return { show = function() end } end
local ticks = {}
package.preload["ui/uimanager"] = function() return {
    scheduleIn = function(_s, _t, fn) ticks[#ticks + 1] = fn end, nextTick = function(_s, fn) ticks[#ticks + 1] = fn end,
    unschedule = function() end, show = function() end, close = function() end, setDirty = function() end } end
local function runTicks() while #ticks > 0 do table.remove(ticks, 1)() end end
package.preload["aleph_gettext"] = function() return function(s) return s end end
package.preload["ui/event"] = function() return { new = function(_s, ...) return { ... } end } end
package.preload["util"] = function() return { partialMD5 = function() return "hash" end } end
package.preload["luasettings"] = function() return { open = function() return { readSetting = function() end } end } end

-- Every request and background process counted.
local requests, jobs_started = 0, 0
local answer = function() return 200, {} end
package.preload["aleph_grimmory_http"] = function()
    return {
        request = function(o) requests = requests + 1; return answer(o) end,
        escape = function(s) return s end, query = function() return "" end,
    }
end
package.preload["aleph_job"] = function()
    return {
        available = function() return false end,
        start = function() jobs_started = jobs_started + 1 end,
        watch = function() end,
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
local H = require("aleph_grimmory_highlights")
local Remote = require("aleph_remote_progress")

-- ------------------------------------------------ no Grimmory account at all
-- A book open in the reader, as main.lua's hooks see it.
local ds_store = { summary = { status = "complete", rating = 4 }, partial_md5_checksum = "hash",
    annotations = { { pos0 = "/body/DocFragment[2]/body/p[1]/text().0", pos1 = "/body/DocFragment[2]/body/p[1]/text().5", text = "Hello", datetime = "2026-11-28 10:00:00" } } }
local ds = {
    readSetting = function(_s, k) return ds_store[k] end,
    saveSetting = function(_s, k, v) ds_store[k] = v end,
}
local ui = {
    document = { file = tmp .. "/Book.epub" },
    doc_settings = ds,
    rolling = { getLastPercent = function() return 0.5 end, getLastProgress = function() return "/body/DocFragment[3]" end },
    annotation = { annotations = ds_store.annotations },
    doc_props = { display_title = "Book" },
}
local before = writes
-- Reader opens, highlights change, sleep, wake, Wi-Fi back, status set from
-- Home, Home opens, the library shows another device's progress, book closes.
G.open(ui); S.open(ui); H.open(ui)
H.changed()
S.suspend(ui); S.resume(ui)
G.flush(); S.flush(); H.connected()
S.docChanged(ui.document.file, ds)
S.syncIfDue()
Remote.other({ md5 = "hash", path = ui.document.file })
G.close(ui); S.close(ui); H.close(ui)
runTicks()
eq(requests, 0, "no account: no request")
eq(jobs_started, 0, "no account: no background process")
eq(writes, before, "no account: no setting written")
eq(store.aleph, nil, "no account: Aleph's settings untouched")
eq(G.enabled(), false, "progress sync off"); eq(S.signedIn(), false, "not signed in"); eq(H.on(), false, "highlights off")
local f = io.open(tmp .. "/aleph_grimmory_state.lua")
eq(f, nil, "no account: no state file"); if f then f:close() end

-- A server set but no account yet: still nothing.
Prefs.set("grimmory_url", "http://grimmory.lan:6060")
before = writes
G.open(ui); S.open(ui); H.open(ui); G.close(ui); S.close(ui); H.close(ui); G.flush(); S.flush()
eq(requests, 0, "server only: no request")
eq(writes, before, "server only: no setting written")

-- ---------------------------------------- progress: Wi-Fi lost in the middle
Prefs.set("grimmory_user", "alex"); Prefs.set("grimmory_key", "k")
local queue = {}
for i = 1, 4 do queue[i] = { hash = "h" .. i, pct = 0.1 * i, progress = "/body/DocFragment[" .. i .. "]", time = 100 + i } end
Prefs.set("grimmory_queue", queue)
local sent = 0
answer = function(o)
    if o.method ~= "PUT" then return 200, {} end
    sent = sent + 1
    if sent == 2 then connected = false end
    if not connected then return nil end   -- (no answer: the network is gone)
    return 200, {}
end
G.flush()
local q = G.queue()
eq(#q, 3, "Wi-Fi lost: the first position sent, three kept")
eq(sent, 2, "Wi-Fi lost: stopped at the first one with no answer")
local tries = 0
for _i, e in ipairs(q) do tries = tries + (tonumber(e.tries) or 0) end
eq(tries, 0, "Wi-Fi lost: not counted as failures (ten would drop them)")
-- Ten times out of reach (a café's Wi-Fi, the server at home): nothing lost.
for _i = 1, 12 do connected = true; sent = 1; G.flush() end
eq(#G.queue(), 3, "out of reach twelve times: still kept")
-- A server error still counts.
connected = true
answer = function(o) if o.method == "PUT" then return 500 end return 200, {} end
G.flush()
eq(tonumber(G.queue()[1].tries), 1, "a server error counts")

-- No answer when the book opens: what Grimmory said last is not forgotten.
G._remember("hash", { pct = 0.7, progress = "/body/DocFragment[9]", time = 5 })
answer = function() return nil end
G.open(ui)
eq(G.cached("hash") and G.cached("hash").pct, 0.7, "no answer: the remembered position kept")

-- ---------------------------------------- progress: weeks of books waiting
queue = {}
for i = 1, 20 do queue[i] = { hash = "w" .. i, pct = 0.5, progress = "x", time = 200 + i } end
Prefs.set("grimmory_queue", queue)
local per_run, run_sizes = 0, {}
answer = function(o) if o.method == "PUT" then per_run = per_run + 1 end return 200, {} end
local base_run = G.run
G.run = function(plan, done)
    per_run = 0
    local r = base_run(plan, done)
    run_sizes[#run_sizes + 1] = per_run
    return r
end
G.flush(); runTicks()
G.run = base_run
eq(#G.queue(), 0, "twenty positions: all sent in the end")
eq(run_sizes[1], G.BATCH, "a few a run")
eq(#run_sizes, math.ceil(20 / G.BATCH), "runs one after the other")

-- ------------------------------------------- the account: Wi-Fi lost, batches
Prefs.set("grimmory_api", { user = "alex", access = "A", access_exp = os.time() + 3600, refresh = "R", refresh_exp = os.time() + 86400 })
S._resetState({ ids = {}, sent = {}, shelves = { books = {}, placed = {} } })
S._resetRuns()
local ops = {}
for i = 1, 60 do
    local path = "/b/" .. i .. ".epub"
    S.state().ids[path] = i
    ops[i] = { op = "status", path = path, status = "READ", time = 300 + i }
end
Prefs.set("grimmory_ops", ops)
local calls = 0
connected = true
answer = function()
    calls = calls + 1
    if calls == 4 then connected = false end
    if not connected then return nil end
    return 200, {}
end
S.flush(); runTicks()
eq(#S.ops(), 57, "account, Wi-Fi lost: three sent, the rest kept")
tries = 0
for _i, op in ipairs(S.ops()) do tries = tries + (tonumber(op.tries) or 0) end
eq(tries, 0, "account, Wi-Fi lost: not counted as failures")
-- Back online: all of it, a batch at a time.
connected = true
local batch_calls = {}
answer = function() calls = calls + 1; return 200, {} end
local base_work = S.workOps
S.workOps = function(plan) batch_calls[#batch_calls + 1] = #plan.ops; return base_work(plan) end
S.flush(); runTicks()
S.workOps = base_work
eq(#S.ops(), 0, "account, back online: all sent")
eq(batch_calls[1], S.BATCH, "account: a batch a run")
eq(#batch_calls, math.ceil(57 / S.BATCH), "account: batches one after the other")
-- Signed out on the server: nothing counted against the changes.
Prefs.set("grimmory_ops", { { op = "status", path = "/b/1.epub", status = "READ", time = 1 } })
answer = function() return 401 end
S.flush()
eq(#S.ops(), 1, "signed out: the change kept")
eq(tonumber(S.ops()[1].tries) or 0, 0, "signed out: not counted")
Prefs.set("grimmory_ops", nil)

-- ------------------------------------------------------------ a big library
local N = 20000
local books = {}
for i = 1, N do
    books[i] = { id = i, metadata = { title = "Title " .. i, authors = { "Author " .. i }, isbn13 = tostring(9780000000000 + i), isbn10 = tostring(1000000000 + i) },
        primaryFile = { fileName = "book_" .. i .. ".epub", fileSizeKb = 300 } }
end
local locals = {}
for i = 1, N do locals[i] = { path = "/mnt/onboard/books/book_" .. i .. ".epub", title = "Title " .. i, authors = { "Author " .. i }, size = 300 * 1024 } end
answer = function(o)
    if o.url:match("/api/v1/books$") then return 200, books end
    return 200, {}
end
Prefs.set("grimmory_api", { user = "alex", access = "A", access_exp = os.time() + 3600, refresh = "R", refresh_exp = os.time() + 86400 })
local r = S.workLibrary({ base = "http://grimmory.lan:6060", tokens = S.tokens(), tokens_out = tmp .. "/aleph_robust_tokens", locals = locals, shelves = false })
eq(r.code, 200, "big library read"); eq(r.books, nil, "only the matches handed back"); eq(r.remote, N, "every Grimmory book counted")
local n = 0
for _p in pairs(r.found or {}) do n = n + 1 end
eq(n, N, "every book matched in the background")
-- Handed back to KOReader in a file, as a background process does.
local File = require("aleph_file")
local out = tmp .. "/aleph_robust_result.lua"
File.write(out, r)
local back = File.read(out)
os.remove(out)
os.remove(tmp .. "/aleph_grimmory_state.lua")
eq(back and back.remote, N, "the answer for 20,000 books read back")

print(string.format("%d checks, %d failed", count, failures))
os.exit(failures == 0 and 0 or 1)

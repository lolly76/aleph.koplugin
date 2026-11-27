-- Aleph for Grimmory modification, 2026-11-27: tests of aleph_grimmory_api.lua
-- and aleph_grimmory_sync.lua's parts that need neither KOReader's screen
-- nor a network. Run from the plugin folder: luajit tests/grimmory_api_test.lua
package.path = "./?.lua;" .. package.path

local tmp = os.getenv("ALEPH_TEST_DIR") or "/tmp"
local store = {}
G_reader_settings = {
    readSetting = function(_self, k) return store[k] end,
    saveSetting = function(_self, k, v) store[k] = v end,
}
package.preload["logger"] = function() return { info = function() end, warn = function() end } end
package.preload["datastorage"] = function() return { getSettingsDir = function() return tmp end } end
package.preload["ui/network/manager"] = function() return { isConnected = function() return true end } end
package.preload["aleph_toast"] = function() return { show = function() end } end
package.preload["aleph_local"] = function() return { ratingOf = function(s) return tonumber(s.rating) end } end
package.preload["libs/libkoreader-lfs"] = function() return { attributes = function() return nil end } end
package.preload["ffi/util"] = function() return { realpath = function(p) return p end } end
-- KOReader's collections, as aleph_calibre_collections.lua uses them.
local RC = { coll = { Favorites = {} } }
function RC:addCollection(name) self.coll[name] = {} end
function RC:addItem(path, name) self.coll[name][path] = { file = path } end
function RC:removeItem(path, name) self.coll[name][path] = nil end
function RC:write() end
package.preload["readcollection"] = function() return RC end

local Api = require("aleph_grimmory_api")
local S = require("aleph_grimmory_sync")
local Prefs = require("aleph_prefs")

local failures, count = 0, 0
local function eq(got, want, what)
    count = count + 1
    if got ~= want then
        failures = failures + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- Statuses and stars
eq(Api.statusFor("complete"), "READ", "complete"); eq(Api.statusFor("abandoned"), "PAUSED", "on hold")
eq(Api.statusFor("reading"), "READING", "reading"); eq(Api.statusFor("whatever"), nil, "unknown")
eq(Api.ratingFor(4), 8, "4 stars"); eq(Api.ratingFor(4.5), 9, "half star"); eq(Api.ratingFor(0), nil, "no stars")
eq(Api.ratingFor(7), 10, "capped")

-- Links and times
eq(Api.nextLink({ { rel = "self", href = "/a" }, { rel = "next", href = "/b" } }), "/b", "next link")
eq(Api.nextLink({ { rel = { "first", "next" }, href = "/c" } }), "/c", "next among rels")
eq(Api.nextLink({ { rel = "self", href = "/a" } }), nil, "last page")
eq(Api.isoTime(0), "1970-01-01T00:00:00Z", "ISO time")

-- Sessions
local body = Api.sessionBody{ book_id = 7, started = 1000, ended = 1000 + 3725, from = 0.1, to = 0.25, format = "epub", to_pos = "/body/x" }
eq(body.bookId, 7, "session book"); eq(body.durationSeconds, 3725, "duration"); eq(body.durationFormatted, "1h 2m 5s", "formatted")
eq(body.startProgress, 10, "start %"); eq(body.endProgress, 25, "end %"); eq(body.progressDelta, 15, "delta")
eq(body.bookType, "EPUB", "type"); eq(body.endLocation, "/body/x", "location")
eq(Api.sessionBody{ book_id = 7, started = 0, ended = 30 }, nil, "under a minute")

-- Notes
local notes = Api.notesContent{ { text = "Line one\nline two", note = "Mine", chapter = "Ch. 1" }, { text = "" }, { text = "Other" } }
eq(notes, "## Ch. 1\n\n> Line one\n> line two\n\nMine\n\n---\n\n> Other", "notes text")
eq(Api.notesContent{}, nil, "no highlights")
eq(Api.digest("abc") == Api.digest("abc"), true, "digest stable"); eq(Api.digest("abc") ~= Api.digest("abd"), true, "digest changes")

-- Matching
eq(Api.fold("L'Étranger — Été"), "l etranger ete", "fold")
local remotes = {
    { id = 1, metadata = { title = "Dune", authors = { "Frank Herbert" } }, primaryFile = { fileName = "dune.epub", fileSizeKb = 500 } },
    { id = 2, metadata = { title = "Fondation", authors = { "Isaac Asimov" }, isbn13 = "978-2-07-036053-8" } },
    { id = 3, metadata = { title = "L'Étranger : roman", authors = { "Albert Camus" } } },
    { id = 4, metadata = { title = "Twin", authors = { "A. Writer" } } },
    { id = 5, metadata = { title = "Twin", authors = { "B. Writer" } } },
    { id = 6, metadata = { title = "Same", authors = { "Writer" } } },
    { id = 7, metadata = { title = "Same", authors = { "Writer" } } },
}
local locals = {
    { path = "/b/dune.epub", size = 500 * 1024 + 300, title = "Something else" },
    { path = "/b/f.epub", isbn = "9782070360538", title = "Foundation" },
    { path = "/b/e.epub", title = "L’étranger", authors = { "Camus, Albert" } },
    { path = "/b/same.epub", title = "Same", authors = { "Writer" } },
    { path = "/b/none.epub", title = "Nothing", authors = { "Nobody" } },
    { path = "/b/dune2/dune.epub", size = 10, title = "Dune 2" },
}
local found, how = Api.match(locals, remotes)
eq(found["/b/dune.epub"], 1, "by file"); eq(how["/b/dune.epub"], "file", "how file")
eq(found["/b/f.epub"], 2, "by ISBN"); eq(found["/b/e.epub"], 3, "by title and author")
eq(found["/b/same.epub"], nil, "two candidates: none"); eq(found["/b/none.epub"], nil, "no match")
eq(found["/b/dune2/dune.epub"], nil, "same name, other size")
eq(Api.isbnOf({ props = { identifiers = "uuid:x\nisbn:978-2-07-036053-8" } }), "9782070360538", "ISBN from props")
eq(Api.fileNameFor({ id = 9, metadata = { title = "Q/A: why?", authors = { "Me" } }, primaryFile = { extension = "EPUB" } }), "Me - Q_A_ why_.epub", "file name")

-- Queue
local q = S.enqueue({}, { op = "status", path = "a", status = "READ" })
q = S.enqueue(q, { op = "status", path = "a", status = "PAUSED" })
q = S.enqueue(q, { op = "session", path = "a" }); q = S.enqueue(q, { op = "session", path = "a" })
eq(#q, 3, "one status, two sessions"); eq(q[1].status, "PAUSED", "newest status")

-- Changes
local ch = S.changes({ path = "a", status = "complete", stars = 4, highlights = { { text = "hi" } } }, nil, {})
eq(#ch, 3, "three changes"); eq(ch[1].status, "READ", "status op"); eq(ch[2].rating, 8, "rating op"); eq(ch[3].op, "notes", "notes op")
local sent = { status = "READ", rating = 8, notes = ch[3].digest }
eq(#S.changes({ path = "a", status = "complete", stars = 4, highlights = { { text = "hi" } } }, sent, {}), 0, "nothing new")
eq(#S.changes({ path = "a", status = "reading" }, nil, {}), 0, "reading left to the percentage")
eq(#S.changes({ path = "a", status = "reading" }, { status = "PAUSED" }, {}), 1, "back to reading")
eq(#S.changes({ path = "a", status = "complete", stars = 4 }, nil, { status = false, stars = false }), 0, "turned off")

-- Ready: only matched books
local ready = S.ready({ { op = "status", path = "a" }, { op = "status", path = "b" } }, { a = 5 })
eq(#ready, 1, "one ready"); eq(ready[1].id, 5, "with its id")

-- Sessions waiting for their book's id
S._resetState({ ids = { ["/b/x.epub"] = 12 }, sent = {}, shelves = { books = {}, placed = {} } })
local ops = {
    { op = "session", path = "/b/x.epub", body_parts = { started = 0, ended = 600, from = 0, to = 0.1 } },
    { op = "session", path = "/b/y.epub", body_parts = { started = 0, ended = 600 } },
    { op = "session", path = "/b/y.epub", body_parts = { started = 0, ended = 10 } },
}
S.finishSessions(ops)
eq(#ops, 2, "short session dropped"); eq(ops[1].body.bookId, 12, "body made"); eq(ops[2].body, nil, "kept for later")

-- Shelves to collections
local changed = S.applyShelves({ { name = "SF", ids = { 12 } }, { name = "Favorites", ids = { 12 } } }, { ["/b/x.epub"] = 12, ["/b/z.epub"] = 13 })
eq(changed, 2, "two places"); eq(RC.coll.SF["/b/x.epub"] ~= nil, true, "in SF")
changed = S.applyShelves({ { name = "SF", ids = {} } }, { ["/b/x.epub"] = 12 })
eq(RC.coll.SF["/b/x.epub"], nil, "taken out of SF"); eq(RC.coll.Favorites["/b/x.epub"], nil, "taken out of Favorites")

-- Flush: done ops leave, sent remembered, failed ones counted
store.aleph = { grimmory_url = "http://h", grimmory_api = { user = "a", refresh = "r" } }
S._resetState({ ids = { a = 5, b = 6 }, sent = {}, shelves = { books = {}, placed = {} } })
Prefs.set("grimmory_ops", {
    { op = "status", path = "a", status = "READ", time = 1 },
    { op = "rating", path = "b", rating = 6, time = 1 },
    { op = "status", path = "c", status = "READ", time = 1 },
})
S._run = function(kind, fn, plan, done) done({ done = { [1] = true }, failed = { [2] = 500 }, note_ids = {} }) end
S.flush()
local left = S.ops()
eq(#left, 2, "two left"); eq(left[1].path, "b", "failed kept"); eq(left[1].tries, 1, "try counted"); eq(left[2].path, "c", "unmatched kept")
eq(S.state().sent[5].status, "READ", "sent remembered")

-- Tokens: only what is needed kept
S._saveTokens({ user = "a", access = "x", refresh = "y", other = "z" })
eq(Prefs.get().grimmory_api.other, nil, "nothing else kept"); eq(Prefs.get().grimmory_api.refresh, "y", "refresh kept")
S._saveTokens({ user = "a" })
eq(Prefs.get().grimmory_api.refresh, nil, "signed out"); eq(Prefs.get().grimmory_api.user, "a", "name kept")

print(string.format("%d checks, %d failed", count, failures))
os.exit(failures == 0 and 0 or 1)

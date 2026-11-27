-- Aleph for Grimmory modification, 2026-11-27: the requests Aleph makes,
-- against a pretend Grimmory (its routes as in grimmory-tools/grimmory's
-- controllers). Run from the plugin folder: luajit tests/grimmory_server_test.lua
package.path = "./?.lua;" .. package.path

local tmp = os.getenv("ALEPH_TEST_DIR") or "/tmp"
local store = {}
G_reader_settings = {
    readSetting = function(_self, k) return store[k] end,
    saveSetting = function(_self, k, v) store[k] = v end,
}
package.preload["logger"] = function() return { info = function() end, warn = function() end } end
package.preload["datastorage"] = function() return { getSettingsDir = function() return tmp end } end
package.preload["ffi/sha2"] = function() return { md5 = function(s) return "md5:" .. s end } end

-- The pretend server.
local server = { access = "A1", refresh = "R1", log = {}, notes = {}, progress = {}, books = { [7] = true } }
local function route(o)
    local path = o.url:gsub("^https?://[^/]+", "")
    local h = o.headers or {}
    server.log[#server.log + 1] = (o.method or "GET") .. " " .. path
    if path:match("^/api/koreader/") then
        if h["x-auth-user"] ~= "kobo" or h["x-auth-key"] ~= "md5:pw" then return 401 end
        if path == "/api/koreader/users/auth" then return 200, { username = "kobo" } end
        if o.method == "PUT" and path == "/api/koreader/syncs/progress" then
            if o.json.document == "unknown" then return 404 end
            server.progress[o.json.document] = o.json
            return 200, { status = "progress updated" }
        end
        local hash = path:match("^/api/koreader/syncs/progress/(.+)$")
        if hash then
            local p = server.progress[hash]
            if not p then return 404 end
            return 200, { document = hash, percentage = p.percentage, progress = p.progress, device = p.device, device_id = p.device_id, timestamp = 5 }
        end
        return 404
    end
    if path == "/api/v1/auth/login" then
        if o.json.username == "alex" and o.json.password == "secret" then
            return 200, { accessToken = server.access, refreshToken = server.refresh, expires = 7200 }
        end
        return 401
    end
    if path == "/api/v1/auth/refresh" then
        if o.json.refreshToken ~= server.refresh then return 401 end
        server.access, server.refresh = server.access .. "+", server.refresh .. "+"
        return 200, { accessToken = server.access, refreshToken = server.refresh, expires = 7200 }
    end
    if h["Authorization"] ~= "Bearer " .. server.access then return 401 end
    local id = path:match("^/api/v1/book%-notes/book/(%d+)$")
    if id then return 200, server.notes[tonumber(id)] or {} end
    if o.method == "POST" and path == "/api/v1/book-notes" then
        local list = server.notes[o.json.bookId] or {}
        server.notes[o.json.bookId] = list
        if o.json.id then
            for _i, n in ipairs(list) do if n.id == o.json.id then n.content = o.json.content end end
            return 200, { id = o.json.id }
        end
        local n = { id = 100 + #list, title = o.json.title, content = o.json.content }
        list[#list + 1] = n
        return 200, n
    end
    if path == "/api/v1/books/status" then
        if not server.books[o.json.bookIds[1]] then return 404 end
        return 200, {}
    end
    if path == "/api/v1/books/personal-rating" then return 200, {} end
    if path == "/api/v1/reading-sessions" then return 202 end
    if path:match("^/api/v1/books/page") then
        if path:match("cursor=") then return 200, { content = { { id = 3 } }, links = { { rel = "self", href = "/x" } } } end
        return 200, { content = { { id = 1 }, { id = 2 } }, links = { { rel = "next", href = "/api/v1/books/page?cursor=abc" } } }
    end
    if path == "/api/v1/books" then return 200, { { id = 7, metadata = { title = "Dune", authors = { "Frank Herbert" } }, primaryFile = { fileName = "dune.epub", fileSizeKb = 1 } } } end
    if path == "/api/v1/shelves" then return 200, { { id = 1, name = "SF" } } end
    if path == "/api/v1/shelves/1/books" then return 200, { { id = 7 } } end
    return 404
end
package.preload["aleph_grimmory_http"] = function()
    local Http = { request = function(o) return route(o) end }
    function Http.escape(s) return (tostring(s):gsub("[^%w%-_%.~]", function(ch) return string.format("%%%02X", ch:byte()) end)) end
    function Http.query(p)
        local keys, parts = {}, {}
        for k in pairs(p or {}) do keys[#keys + 1] = k end
        table.sort(keys)
        for _i, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. Http.escape(p[k]) end
        return table.concat(parts, "&")
    end
    return Http
end

local G = require("aleph_grimmory")
local Api = require("aleph_grimmory_api")
local S = require("aleph_grimmory_sync")

local failures, count = 0, 0
local function eq(got, want, what)
    count = count + 1
    if got ~= want then
        failures = failures + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- KOReader interface: auth, a push, a book Grimmory lacks, a pull
local cred = { base = "http://h", user = "kobo", key = "md5:pw" }
eq(G.work({ cred = cred, auth = true }).auth, 200, "auth")
eq(G.work({ cred = { base = "http://h", user = "kobo", key = "bad" }, auth = true }).auth, 401, "refused")
local r = G.work({ cred = cred, push = { { hash = "abc", pct = 0.4, progress = "/body/p" }, { hash = "unknown", pct = 0.1 } }, device = "Kobo", device_id = "D1" })
eq(r.pushed.abc, true, "pushed"); eq(r.unknown.unknown, true, "unknown book")
r = G.work({ cred = cred, pull = { "abc", "nothing" } })
eq(r.pulled.abc.pct, 0.4, "pulled pct"); eq(r.pulled.abc.progress, "/body/p", "pulled position"); eq(r.pulled.abc.device_id, "D1", "pulled device")
eq(r.pulled.nothing, false, "no position")

-- API: sign in, then a call with an expired access token renews it once
local saved
local api = Api.new("http://h", {}, function(t) saved = t.refresh end)
eq(api:login("alex", "wrong"), 401, "wrong password")
eq(api:login("alex", "secret"), 200, "signed in"); eq(saved, "R1", "tokens handed back")
server.access = "A2"   -- the server no longer takes A1
local code = api:setStatus(7, "READ")
eq(code, 200, "after a renewal"); eq(saved, "R1+", "new refresh token kept"); eq(api.tokens.access, "A2+", "new access token")
local page
code, page = api:page({ sort = "-addedOn" })
eq(#page.books, 2, "a page"); eq(page.next, "/api/v1/books/page?cursor=abc", "next page")
code, page = api:page(nil, page.next)
eq(#page.books, 1, "next page read"); eq(page.next, nil, "last page")

-- Background work for the queue: notes created once, then changed in place
local plan = { base = "http://h", tokens = api.tokens, tokens_out = tmp .. "/aleph_grimmory_tokens_test.lua", ops = {
    { op = "status", id = 7, status = "READ" },
    { op = "rating", id = 7, rating = 8 },
    { op = "notes", id = 7, content = "> one" },
    { op = "session", id = 7, body = { bookId = 7 } },
    { op = "status", id = 99, status = "READ" },
} }
r = S.workOps(plan)
eq(r.done[1] and r.done[2] and r.done[3] and r.done[4], true, "all sent"); eq(r.done[5], true, "a book gone from Grimmory: dropped")
eq(r.note_ids[7], 100, "note made"); eq(#server.notes[7], 1, "one note")
r = S.workOps({ base = "http://h", tokens = api.tokens, tokens_out = plan.tokens_out, ops = { { op = "notes", id = 7, content = "> two" } } })
eq(#server.notes[7], 1, "still one note (found by its title)"); eq(server.notes[7][1].content, "> two", "note changed")

-- Library: books made small, shelves with their books
local lib = S.workLibrary({ base = "http://h", tokens = api.tokens, tokens_out = plan.tokens_out, shelves = true })
eq(lib.code, 200, "library"); eq(lib.books[1].primaryFile.fileName, "dune.epub", "file kept"); eq(lib.shelves[1].ids[1], 7, "shelf books")

-- Signed out on the server: the refresh token is refused and forgotten
server.access, server.refresh = "Z", "Z"
api.tokens.access_exp = 0
eq(api:setStatus(7, "READ"), 401, "signed out"); eq(api.tokens.refresh, nil, "refresh forgotten")
os.remove(plan.tokens_out)

print(string.format("%d checks, %d failed", count, failures))
os.exit(failures == 0 and 0 or 1)

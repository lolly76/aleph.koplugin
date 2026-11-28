-- Aleph for Grimmory modification, 2026-11-27: the reader's Grimmory
-- account: books matched, statuses, stars, highlights, reading sessions and
-- shelves.
--[[--
Signed in with the reader's Grimmory account (aleph_grimmory_api.lua),
Aleph keeps Grimmory up to date with what happens on the device:

  a book opens     the reading session starts
  the book closes  the session (when a minute or more) goes to Grimmory's
                   reading statistics; KOReader's status of the book
                   (Finished, On hold...), its stars and, for books
                   other than EPUB, its highlights (one note, "KOReader
                   highlights") when they changed; an EPUB's highlights go
                   as Grimmory's own (aleph_grimmory_highlights.lua)
  status or stars changed in the file browser: sent too

Offline, these wait in a queue (grimmory_ops) and go when Wi-Fi is back.

To know which Grimmory book a local book is, Aleph matches them (Sync with
Grimmory, after signing in, and once a day when Home opens): a book
downloaded from Grimmory in Aleph is known at once; others by the same file
name and size, the same ISBN, or the same title and first author. The
answers are kept in settings/aleph_grimmory_state.lua:

  ids      [path] = Grimmory book id
  sent     [id] = { status, rating, notes (fingerprint), note_id }
  shelves  what aleph_calibre_collections.lua's CC.apply needs to put
           books in KOReader collections named after Grimmory's shelves,
           and take them out again when Grimmory no longer has them there

Progress itself goes through Grimmory's KOReader interface
(aleph_grimmory.lua), which also sets Reading and Read from the percentage.

Settings (Prefs): grimmory_api (tokens and user name), grimmory_status,
grimmory_stars, grimmory_notes, grimmory_sessions, grimmory_shelves (each on
unless turned off), grimmory_ops (the queue).
]]

local Prefs = require("aleph_prefs")
local try = require("aleph_try").call

local S = {}

S.TIMEOUT = 120           -- a background run is stopped after this long
S.TRIES = 10              -- a change that failed this many times is dropped
S.DAY = 86400
S.QUEUE_MAX = 300         -- the oldest changes dropped past this (books never matched)

-- ------------------------------------------------------------- state

local function stateFile()
    return require("datastorage"):getSettingsDir() .. "/aleph_grimmory_state.lua"
end

local state_cache
function S.state()
    if state_cache then return state_cache end
    local s = require("aleph_file").read(stateFile())
    s = type(s) == "table" and s or {}
    s.ids = type(s.ids) == "table" and s.ids or {}
    s.sent = type(s.sent) == "table" and s.sent or {}
    s.shelves = type(s.shelves) == "table" and s.shelves or {}
    s.shelves.books = type(s.shelves.books) == "table" and s.shelves.books or {}
    s.shelves.placed = type(s.shelves.placed) == "table" and s.shelves.placed or {}
    state_cache = s
    return s
end

function S.saveState()
    if state_cache then require("aleph_file").write(stateFile(), state_cache) end
end

function S._resetState(s) state_cache = s end

function S.tokens()
    local t = Prefs.get().grimmory_api
    return type(t) == "table" and t or {}
end

local function saveTokens(t)
    local keep = { user = t.user, access = t.access, access_exp = t.access_exp,
        refresh = t.refresh, refresh_exp = t.refresh_exp, refresh_at = t.refresh_at }
    Prefs.set("grimmory_api", keep.refresh and keep or (keep.user and { user = keep.user } or nil))
end
S._saveTokens = saveTokens

function S.signedIn()
    local t = S.tokens()
    return require("aleph_grimmory").url() ~= nil and type(t.refresh) == "string"
end

function S.user() return S.tokens().user end

function S.on(key) return S.signedIn() and Prefs.on(key) end

function S.ops()
    local q = Prefs.get().grimmory_ops
    return type(q) == "table" and q or {}
end

-- The Grimmory id of a local book (by its path), or nil.
function S.idOf(path)
    return path and tonumber(S.state().ids[path]) or nil
end

-- ------------------------------------------------------------- pure parts

-- One change a book and kind, the newest: a session is never replaced (each
-- one counts), the others are.
function S.enqueue(queue, op)
    queue = type(queue) == "table" and queue or {}
    if op.op ~= "session" then
        for i = #queue, 1, -1 do
            if queue[i].op == op.op and queue[i].path == op.path then table.remove(queue, i) end
        end
    end
    queue[#queue + 1] = op
    while #queue > S.QUEUE_MAX do table.remove(queue, 1) end
    return queue
end

-- What changed for a book since it was last sent: a list of ops.
-- book: { path, status (KOReader's), stars, highlights }; sent: S.state().sent[id].
function S.changes(book, sent, opts)
    local Api = require("aleph_grimmory_api")
    local ops = {}
    sent = sent or {}
    opts = opts or {}
    local now = os.time()
    if opts.status ~= false then
        local status = Api.statusFor(book.status)
        -- Reading and Read come from the percentage (aleph_grimmory.lua);
        -- sent here only when KOReader's status says something else, or Read
        -- by hand before the end.
        -- Aleph for Grimmory modification, 2026-11-28: a position sent at the
        -- same time (opts.pct) makes Grimmory set Reading or Read from its
        -- percentage, so Finished before the end, or On hold, is sent again
        -- after it, even when it was sent before.
        local from_pct = opts.pct and require("aleph_grimmory").statusFromPercent(opts.pct)
        local overridden = from_pct and (status == "READ" or status == "PAUSED") and status ~= from_pct
        if status and (overridden or (status ~= sent.status and status ~= "UNREAD" and not (status == "READING" and not sent.status))) then
            ops[#ops + 1] = { op = "status", path = book.path, status = status, time = now }
        end
    end
    if opts.stars ~= false then
        local rating = Api.ratingFor(book.stars)
        if rating and rating ~= sent.rating then
            ops[#ops + 1] = { op = "rating", path = book.path, rating = rating, time = now }
        end
    end
    if opts.notes ~= false then
        local content = Api.notesContent(book.highlights)
        local digest = content and Api.digest(content) or nil
        if content and digest ~= sent.notes then
            ops[#ops + 1] = { op = "notes", path = book.path, content = content, digest = digest, time = now }
        elseif not content and sent.notes then
            -- Every highlight removed: the note goes too.
            ops[#ops + 1] = { op = "notes", path = book.path, content = false, time = now }
        end
    end
    return ops
end

-- The ops a run can send now: those of books whose Grimmory id is known.
function S.ready(queue, ids)
    local out = {}
    for _i, op in ipairs(queue or {}) do
        local id = op.id or (op.path and tonumber(ids[op.path]))
        if id then
            local copy = {}
            for k, v in pairs(op) do copy[k] = v end
            copy.id = id
            out[#out + 1] = copy
        end
    end
    return out
end

-- ------------------------------------------------ in the background process

local function tokensPath()
    return require("datastorage"):getSettingsDir() .. "/aleph_grimmory_tokens.lua"
end

-- New tokens written at once, so a run stopped halfway never loses the new
-- refresh token (Grimmory takes the old one back when it gives a new one).
local function apiFor(plan)
    local Api = require("aleph_grimmory_api")
    local File = require("aleph_file")
    return Api.new(plan.base, plan.tokens, function(t) File.write(plan.tokens_out, t) end)
end
S.apiFor = apiFor

-- Sends the ops. Returns { done = { [index] = true }, failed = { [index] = code },
-- note_ids = { [id] = note id }, auth = code when signed out }.
function S.workOps(plan)
    local api = apiFor(plan)
    local r = { done = {}, failed = {}, note_ids = {} }
    for i, op in ipairs(plan.ops) do
        local code
        if op.op == "status" then
            code = api:setStatus(op.id, op.status)
        elseif op.op == "rating" then
            code = api:setRating(op.id, op.rating)
        elseif op.op == "session" then
            code = api:session(op.body)
        elseif op.op == "notes" and not op.content then
            local note_id = op.note_id
            if not note_id then
                local c, notes = api:notes(op.id)
                code = c
                for _j, n in ipairs(notes or {}) do
                    if n.title == require("aleph_grimmory_api").NOTE_TITLE then note_id = n.id end
                end
            end
            -- (No note found: nothing to delete, and code is the lookup's.)
            if note_id then code = api:deleteNote(note_id) end
        elseif op.op == "notes" then
            local note_id = op.note_id
            if not note_id then
                local c, notes = api:notes(op.id)
                code = c
                for _j, n in ipairs(notes or {}) do
                    if n.title == require("aleph_grimmory_api").NOTE_TITLE then note_id = n.id end
                end
            end
            if op.note_id or code == 200 then
                local c, answer = api:saveNote{ id = note_id, bookId = op.id,
                    title = require("aleph_grimmory_api").NOTE_TITLE, content = op.content }
                code = c
                if type(answer) == "table" and answer.id then r.note_ids[op.id] = answer.id end
            end
        end
        if code and code >= 200 and code < 300 then r.done[i] = true
        elseif code == 404 then r.done[i] = true   -- the book is gone from Grimmory
        else r.failed[i] = code or false end
        if code == 401 then r.auth = code; break end
    end
    return r
end

-- Signs in; with plan.kosync, also gets (or makes) the account's KOReader
-- user and turns its sync on. Returns { code, kosync = { user, key } }.
function S.workLogin(plan)
    local Api = require("aleph_grimmory_api")
    local api = apiFor(plan)
    local code = api:login(plan.user, plan.password)
    if code ~= 200 or not plan.kosync then return { code = code } end
    local r = { code = 200 }
    local c, me = api:koreaderUser()
    local creds = c == 200 and Api.kosyncFrom(me) or nil
    if not creds and (c == 200 or c == 404) then
        local password = Api.newPassword()
        local c2 = api:setKoreaderUser(plan.user, password)
        if c2 and c2 >= 200 and c2 < 300 then
            creds = { user = plan.user, key = Api.md5(password) }
            me = nil
        end
    end
    if creds then
        if not (type(me) == "table" and me.syncEnabled == true) then api:setKoreaderSync(true) end
        r.kosync = creds
    end
    return r
end

-- Every book and shelf, made small: { books = { { id, title, authors, isbn13,
-- isbn10, fileName, kb } }, shelves = { { id, name, ids = { book ids } } } }.
function S.workLibrary(plan)
    local api = apiFor(plan)
    local code, books = api:books()
    if code ~= 200 then return { code = code } end
    local small = {}
    for _i, b in ipairs(books or {}) do
        local md = type(b.metadata) == "table" and b.metadata or {}
        local f = type(b.primaryFile) == "table" and b.primaryFile or {}
        small[#small + 1] = { id = b.id, title = md.title or b.title,
            metadata = { title = md.title or b.title, authors = md.authors, isbn13 = md.isbn13, isbn10 = md.isbn10 },
            primaryFile = { fileName = f.fileName, fileSizeKb = f.fileSizeKb } }
    end
    local shelves = {}
    if plan.shelves then
        local c2, list = api:shelves()
        for _i, sh in ipairs(c2 == 200 and list or {}) do
            local c3, in_shelf = api:shelfBooks(sh.id)
            if c3 == 200 then
                local ids = {}
                for _j, b in ipairs(in_shelf or {}) do ids[#ids + 1] = b.id end
                shelves[#shelves + 1] = { id = sh.id, name = sh.name, ids = ids }
            end
        end
    end
    return { code = 200, books = small, shelves = shelves }
end

-- ------------------------------------------------------------- KOReader side

local running = {}

local function resultPath(kind)
    return require("datastorage"):getSettingsDir() .. "/aleph_grimmory_" .. kind .. ".lua"
end

local function unique()
    return tostring(os.time()) .. tostring(math.random(100000, 999999))
end

-- Aleph for Grimmory modification, 2026-11-28: one run at a time. Grimmory
-- takes a refresh token back when it gives a new one, so two runs renewing
-- with the same token at once signed the device out (the second one was
-- refused). Runs asked for while one is out wait their turn, and each starts
-- with the tokens the one before it left.
local active = false
local waiting = {}

local function saveTokensNow(t)
    saveTokens(t)
    -- Written out at once: a crash before KOReader saves its settings would
    -- keep a refresh token Grimmory has already taken back.
    pcall(function() G_reader_settings:flush() end)
end

local start

local function nextRun()
    active = false
    local w = table.remove(waiting, 1)
    if w then start(w.kind, w.fn, w.plan, w.done) end
end

-- Runs fn(plan) in the background; done(result) in KOReader's loop. Tokens a
-- run renewed are kept whatever happens to it.
start = function(kind, fn, plan, done)
    local Job = require("aleph_job")
    local File = require("aleph_file")
    plan.base = plan.base or require("aleph_grimmory").url()
    if not plan.base then
        running[kind] = nil
        if done then pcall(done, nil) end
        return nextRun()
    end
    active = true
    -- (Read now, not when asked: the run before may have renewed them.)
    if plan.tokens == nil then plan.tokens = S.tokens() end
    plan.tokens_out = tokensPath() .. "." .. unique()
    os.remove(plan.tokens_out)
    local finished = false
    local function finish(r)
        if finished then return end
        finished = true
        local t = File.read(plan.tokens_out)
        os.remove(plan.tokens_out)
        if type(t) == "table" then saveTokensNow(t) end
        running[kind] = nil
        if done then
            local ok, err = pcall(done, type(r) == "table" and not r.error and r or nil)
            if not ok then require("aleph_try").report("Grimmory " .. kind, err) end
        end
        nextRun()
    end
    if not Job.available() then
        local ok, r = pcall(fn, plan)
        finish(ok and r or nil)
        return
    end
    local out = resultPath(kind) .. "." .. unique()
    local pid = Job.start(function()
        local ok, r = pcall(fn, plan)
        File.write(out, ok and r or { error = tostring(r) })
    end, { name = "grimmory " .. kind })
    if not pid then return finish(nil) end
    Job.watch(pid, { every = 0.5, timeout = plan.timeout or S.TIMEOUT, on_done = function()
        local r = File.read(out)
        os.remove(out)
        finish(r)
    end })
end

local function run(kind, fn, plan, done)
    running[kind] = true
    if active then
        waiting[#waiting + 1] = { kind = kind, fn = fn, plan = plan, done = done }
    else
        start(kind, fn, plan, done)
    end
    return true
end
S._busy = function() return active, #waiting end
S._resetRuns = function() active, waiting, running = false, {}, {} end
S._run = run

local function online()
    local ok, on = pcall(function() return require("ui/network/manager"):isConnected() end)
    return ok and on
end

local function toast(message, ok)
    try(function() require("aleph_toast").show(message, { icon = ok and "check" or "triangle-alert", timeout = ok and 2.5 or 6 }) end)
end

-- Signs in; done(ok, message).
function S.login(user, password, done)
    local _ = require("aleph_gettext")
    if not require("aleph_grimmory").url() then return done(false, _("Set the server and the account first.")) end
    if not online() then return require("aleph_grimmory").withNetwork(function() S.login(user, password, done) end) end
    local G = require("aleph_grimmory")
    S._run("login", S.workLogin, { tokens = {}, user = user, password = password,
        kosync = not G.configured() }, function(r)
        local code = r and r.code
        if code == 200 then
            local t = S.tokens()
            t.user = user
            saveTokens(t)
            -- One account: the KOReader user for progress comes with it.
            if r.kosync and r.kosync.user and r.kosync.key and not G.configured() then
                Prefs.set("grimmory_user", r.kosync.user)
                Prefs.set("grimmory_key", r.kosync.key)
                return done(true, _("Signed in to Grimmory. Progress sync is set up too."))
            end
            return done(true, _("Signed in to Grimmory."))
        end
        if code == 401 or code == 403 then return done(false, _("Grimmory refused the user name or password.")) end
        if code == 429 then return done(false, _("Too many tries. Wait a few minutes and try again.")) end
        return done(false, _("Grimmory did not answer."))
    end)
end

-- Signing out forgets what was sent (another account may sign in next);
-- which local book is which Grimmory book is kept until the next match.
-- Aleph for Grimmory modification, 2026-11-28: the tokens taken back on
-- the server as well, when it can be reached (in the background; the
-- device forgets them at once either way). Renewed tokens are not kept.
function S.workLogout(plan)
    local Api = require("aleph_grimmory_api")
    local api = Api.new(plan.base, plan.old_tokens)
    return { code = api:logout() }
end

-- base: the server the tokens are from (the one set now unless given).
function S.logout(base)
    local old = S.tokens()
    base = base or require("aleph_grimmory").url()
    if base and type(old.refresh) == "string" and online() then
        local copy = {}
        for k, v in pairs(old) do copy[k] = v end
        try(function() S._run("logout", S.workLogout, { base = base, old_tokens = copy, tokens = {} }) end)
    end
    Prefs.set("grimmory_api", nil)
    Prefs.set("grimmory_ops", nil)
    local st = S.state()
    st.sent = {}
    st.ann = nil
    -- Highlights keep the Grimmory ids of this account until each book is
    -- opened again; they are dropped then (aleph_grimmory_highlights.lua),
    -- and the next account finds them again by their place.
    st.forget_ann_ids = os.time()
    S.saveState()
    pcall(function() G_reader_settings:flush() end)
end

-- Aleph for Grimmory modification, 2026-11-28: another server. Its tokens,
-- book ids, what was sent and the highlights' state belonged to the old
-- one: all forgotten (the books are matched again after signing in), and the
-- progress queue and positions too. Highlights keep their text and place;
-- their old Grimmory ids are dropped as each book opens (H.forgetIds).
function S.serverChanged(old_base)
    S.logout(old_base)
    local st = S.state()
    st.ids = {}
    st.last_sync = nil
    S.saveState()
    Prefs.set("grimmory_queue", nil)
    Prefs.set("grimmory_remote", nil)
end

-- The library's books, as matching wants them.
local function localBooks()
    local Local = require("aleph_local")
    local lib = Local.shared() or Local.new(Prefs.get())
    local Api = require("aleph_grimmory_api")
    local out = {}
    for _i, b in ipairs(lib and lib.books or {}) do
        out[#out + 1] = { path = b.path, title = b.title, authors = b.authors, size = b.size, isbn = Api.isbnOf(b), md5 = b.md5 }
    end
    return out
end
S._localBooks = localBooks

-- Puts the matched books in collections named after their shelves.
function S.applyShelves(shelves, ids)
    local by_id = {}
    for path, id in pairs(ids) do by_id[tonumber(id)] = by_id[tonumber(id)] or {}; table.insert(by_id[tonumber(id)], path) end
    local st = S.state().shelves
    local names = {}
    for _i, sh in ipairs(shelves or {}) do
        for _j, id in ipairs(sh.ids or {}) do
            for _k, path in ipairs(by_id[tonumber(id)] or {}) do
                names[path] = names[path] or {}
                table.insert(names[path], tostring(sh.name))
            end
        end
    end
    local paths = {}
    st.books = {}
    for path in pairs(ids) do
        paths[#paths + 1] = path
        st.books[path] = { c = names[path] or false }
    end
    local changed = 0
    try(function() changed = require("aleph_calibre_collections").apply(st, paths) end)
    return changed
end

-- Matches the library with Grimmory's books (and fills the collections from
-- its shelves). done(result) with result { matched, total, remote, shelves }
-- or nil and a message.
function S.syncLibrary(done)
    local _ = require("aleph_gettext")
    if running.library then if done then done(nil, _("Already running.")) end return end
    if not S.signedIn() then if done then done(nil, _("Sign in to Grimmory first.")) end return end
    if not online() then
        -- Asked for by the reader (done given): Wi-Fi turned on first.
        if done then require("aleph_grimmory").withNetwork(function() S.syncLibrary(done) end) end
        return
    end
    local shelves_on = Prefs.on("grimmory_shelves")
    S._run("library", S.workLibrary, { shelves = shelves_on, timeout = 300 }, function(r)
        if not r or r.code ~= 200 then
            if done then done(nil, (r and (r.code == 401 or r.code == 403)) and _("Grimmory signed this device out. Sign in again.") or _("Grimmory did not answer.")) end
            return
        end
        local Api = require("aleph_grimmory_api")
        local locals = localBooks()
        local found = Api.match(locals, r.books)
        local st = S.state()
        -- Downloads stay known even when their name changed since.
        local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
        for path, id in pairs(st.ids) do
            if found[path] == nil and lfs_ok and lfs.attributes(path, "mode") == "file" then found[path] = id end
        end
        st.ids = found
        st.last_sync = os.time()
        local n = 0
        for _p in pairs(found) do n = n + 1 end
        local changed = 0
        if shelves_on then changed = S.applyShelves(r.shelves, found) end
        S.saveState()
        S.flush()
        if done then done({ matched = n, total = #locals, remote = #(r.books or {}), shelves = #(r.shelves or {}), placed = changed }) end
    end)
end

-- Once a day, quietly (Home opening).
function S.syncIfDue()
    if not S.signedIn() or running.library then return end
    if os.time() - (tonumber(S.state().last_sync) or 0) < S.DAY then return end
    S.syncLibrary(nil)
end

-- Sends what waits. done(result, why) optional.
function S.flush(done)
    local why = running.ops and "busy" or not S.signedIn() and "off" or not online() and "offline" or nil
    local queue = S.ops()
    if not why and #queue == 0 then why = "empty" end
    local st = S.state()
    local ops
    if not why then
        ops = S.ready(queue, st.ids)
        for _i, op in ipairs(ops) do
            if op.op == "notes" then op.note_id = (st.sent[op.id] or {}).note_id end
        end
        if #ops == 0 then why = "unmatched" end
    end
    if why then if done then done(nil, why) end return end
    S._run("ops", S.workOps, { ops = ops }, function(r)
        if r then
            local done_keys, failed_keys = {}, {}
            local function key(op) return op.op .. "|" .. tostring(op.path) .. "|" .. tostring(op.time) end
            for i, op in ipairs(ops) do
                if r.done[i] then
                    done_keys[key(op)] = true
                    local sent = st.sent[op.id] or {}
                    if op.op == "status" then sent.status = op.status
                    elseif op.op == "rating" then sent.rating = op.rating
                    elseif op.op == "notes" and not op.content then sent.notes = nil; sent.note_id = nil
                    elseif op.op == "notes" then sent.notes = op.digest; sent.note_id = r.note_ids[op.id] or sent.note_id end
                    st.sent[op.id] = sent
                elseif r.failed[i] ~= nil then
                    failed_keys[key(op)] = true
                end
            end
            local left = {}
            for _i, op in ipairs(S.ops()) do
                if not done_keys[key(op)] then
                    if failed_keys[key(op)] then op.tries = (tonumber(op.tries) or 0) + 1 end
                    if (tonumber(op.tries) or 0) < S.TRIES then left[#left + 1] = op end
                end
            end
            Prefs.set("grimmory_ops", #left > 0 and left or nil)
            S.saveState()
        end
        if done then done(r, not r and "failed" or nil) end
    end)
end

local function enqueueAll(ops)
    if #ops == 0 then return end
    local q = S.ops()
    for _i, op in ipairs(ops) do q = S.enqueue(q, op) end
    Prefs.set("grimmory_ops", q)
end

local function optsNow(path)
    local others = require("aleph_grimmory_others")
    local notes = Prefs.on("grimmory_notes") and not others.owns("annotations")
    -- An EPUB whose highlights go as real Grimmory highlights has no note.
    if notes and path and require("aleph_grimmory_highlights").handles(path) then notes = false end
    return { status = Prefs.on("grimmory_status"), stars = Prefs.on("grimmory_stars"), notes = notes }
end

-- A book's status, stars and highlights from its settings.
local function bookFrom(path, ds)
    -- (A DocSettings, or a plain table of settings.)
    local function read(key)
        if type(ds) ~= "table" then return nil end
        if type(ds.readSetting) == "function" then return ds:readSetting(key) end
        return ds[key]
    end
    local summary = read("summary") or {}
    local stars
    try(function() stars = require("aleph_local").ratingOf(summary) end)
    local highlights = {}
    for _i, a in ipairs(read("annotations") or {}) do
        if a.pos0 and a.text and a.text ~= "" then
            highlights[#highlights + 1] = { text = a.text, note = a.note, chapter = a.chapter, datetime = a.datetime }
        end
    end
    return { path = path, status = summary.status, stars = stars or tonumber(summary.rating), highlights = highlights }
end
S._bookFrom = bookFrom

-- ------------------------------------------------------------- reader hooks

local session              -- { path, started, from, from_pos }

local function position(ui)
    local view = ui and (ui.paging or ui.rolling)
    if not view then return nil end
    local pct = view.getLastPercent and view:getLastPercent() or nil
    local pos = view.getLastProgress and view:getLastProgress() or nil
    return tonumber(pct), pos
end

function S.open(ui)
    if not S.signedIn() or not ui or not ui.document then return end
    local pct, pos = position(ui)
    session = { path = ui.document.file, started = os.time(), from = pct, from_pos = pos }
end

-- The session so far, as an op (nil when there is none to send).
local function sessionOp(ui, path)
    if not (session and session.path == path and Prefs.on("grimmory_sessions")
            and not require("aleph_grimmory_others").owns("sessions")) then return nil end
    local pct, pos = position(ui)
    return { op = "session", path = path, time = os.time(), body_parts = {
        started = session.started, ended = os.time(), from = session.from, to = pct,
        from_pos = session.from_pos, to_pos = pos, format = path:match("%.([^%.]+)$") } }
end

-- Aleph for Grimmory modification, 2026-11-28: time asleep is not reading.
-- The device going to sleep ends the session; waking up starts another.
function S.suspend(ui)
    if not S.signedIn() or not ui or not ui.document or not session then return end
    local op = sessionOp(ui, ui.document.file)
    session = nil
    if not op then return end
    local ops = { op }
    S.finishSessions(ops)
    enqueueAll(ops)
end

function S.resume(ui)
    if not S.signedIn() or not ui or not ui.document or session then return end
    S.open(ui)
end

function S.close(ui)
    if not S.signedIn() or not ui or not ui.document then return end
    local path = ui.document.file
    local ops = {}
    local sop = sessionOp(ui, path)
    if sop then ops[#ops + 1] = sop end
    session = nil
    local id = S.idOf(path)
    local book = bookFrom(path, ui.doc_settings)
    local sent = id and S.state().sent[id] or nil
    local opts = optsNow(path)
    -- (Progress sync sends the position as the book closes: aleph_grimmory.lua.)
    if require("aleph_grimmory").enabled() then opts.pct = select(1, position(ui)) end
    for _i, op in ipairs(S.changes(book, sent, opts)) do ops[#ops + 1] = op end
    -- The session's body is made now its book id may be known (or when sent).
    S.finishSessions(ops)
    enqueueAll(ops)
    S.flush()
end

-- A session op's body (needs the book's Grimmory id: left for later
-- otherwise, and made when the id is known).
function S.finishSessions(ops)
    local Api = require("aleph_grimmory_api")
    for i = #ops, 1, -1 do
        local op = ops[i]
        if op.op == "session" and not op.body then
            local id = S.idOf(op.path)
            if id and op.body_parts then
                local parts = op.body_parts
                parts.book_id = id
                op.body = Api.sessionBody(parts)
                op.body_parts = nil
                if not op.body then table.remove(ops, i) end
            elseif op.body_parts then
                local p = op.body_parts
                if (tonumber(p.ended) or 0) - (tonumber(p.started) or 0) < 60 then table.remove(ops, i) end
            end
        end
    end
end

-- Status or stars changed from the file browser (or the book's page).
function S.docChanged(file, doc_settings)
    if not S.signedIn() or not file then return end
    local opts = optsNow(file)
    opts.notes = false
    local id = S.idOf(file)
    local ops = S.changes(bookFrom(file, doc_settings), id and S.state().sent[id] or nil, opts)
    enqueueAll(ops)
    if #ops > 0 then S.flush() end
end

-- Before a run, sessions queued before their book was matched get their body.
local base_flush = S.flush
function S.flush(done)
    -- Aleph for Grimmory modification, 2026-11-28: after the positions being
    -- sent (a status goes after the position that would reset it).
    local G = require("aleph_grimmory")
    if G.isRunning and G.isRunning() then
        return G.after(function() S.flush(done) end)
    end
    local q = S.ops()
    if #q > 0 then
        S.finishSessions(q)
        Prefs.set("grimmory_ops", #q > 0 and q or nil)
    end
    return base_flush(done)
end

S._toast = toast
return S

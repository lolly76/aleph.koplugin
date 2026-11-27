-- Aleph for Grimmory modification, 2026-11-27: KOReader highlights as real
-- Grimmory annotations, both ways.
--[[--
Signed in to Grimmory (aleph_grimmory_sync.lua), an EPUB whose Grimmory book
is known has its highlights kept the same here and in Grimmory's own reader:

  the book opens          Grimmory's highlights come in, the device's go out
  a highlight changes     the same, a few seconds later (with a network)
  the book closes         once more

Positions go through EPUB CFI (aleph_grimmory_cfi.lua). What changed is
worked out against the last time both agreed (a "shadow" per book, kept in
settings/aleph_grimmory_state.lua as ann[id]), so a highlight removed on one
side is removed on the other, and one changed on both sides is left as it is
on each side (a conflict) rather than one overwriting the other. The merging
itself is aleph_grimmory_annotations.lua.

Other books (PDF, CBZ...) keep the single "KOReader highlights" note.

Setting (Prefs): grimmory_highlights (on unless turned off).
Nothing here runs without a Grimmory account.
]]

local Prefs = require("aleph_prefs")
local try = require("aleph_try").call

local H = {}

H.DELAY = 3             -- seconds after a highlight changes

local function Sync() return require("aleph_grimmory_sync") end
local function Ann() return require("aleph_grimmory_annotations") end

-- --------------------------------------------------------------- pure parts

local FIELDS = { "id", "bookId", "cfi", "text", "color", "style", "note",
    "chapterTitle", "createdAt", "updatedAt" }

-- Grimmory's annotations made plain (JSON null and anything else that is
-- not text or a number dropped), so they can go through a result file.
function H.clean(list)
    local out = {}
    for _i, a in ipairs(type(list) == "table" and list or {}) do
        if type(a) == "table" then
            local c = {}
            for _j, k in ipairs(FIELDS) do
                local v = a[k]
                if type(v) == "string" or type(v) == "number" then c[k] = v end
            end
            if c.id ~= nil then out[#out + 1] = c end
        end
    end
    return out
end

-- A short mark of the local highlights, to know whether they changed while
-- a run was out.
function H.mark(annotations)
    local parts = {}
    for _i, a in ipairs(type(annotations) == "table" and annotations or {}) do
        parts[#parts + 1] = table.concat({ tostring(a.pos0), tostring(a.pos1), tostring(a.text),
            tostring(a.note), tostring(a.color), tostring(a.drawer), tostring(a.grimmory_id) }, "\1")
    end
    return table.concat(parts, "\2")
end

-- What a book is, for this sync: an EPUB with a Grimmory id.
function H.eligible(path, id)
    return id ~= nil and type(path) == "string" and path:lower():match("%.epub3?$") ~= nil
end

-- -------------------------------------------------- in the background process

-- plan: { book_id, items (fromLocal), shadow }. Returns { code, remote,
-- conflicts, errors }.
function H.work(plan)
    local api = Sync().apiFor(plan)
    local code, first = api:annotations(plan.book_id)
    if code ~= 200 or type(first) ~= "table" then return { code = code or false } end
    local p = Ann().plan(plan.items, H.clean(first), plan.shadow)
    local conflicts, errors = p.conflicts, {}
    local function ok(c) return c and c >= 200 and c < 300 end
    for _i, d in ipairs(p.deletes) do
        local c = api:deleteAnnotation(d.id)
        if not (ok(c) or c == 404) then
            errors[#errors + 1] = "delete " .. tostring(d.id)
            conflicts[tostring(d.id)] = "delete-failed"
        end
        if c == 401 then return { code = 401 } end
    end
    for _i, u in ipairs(p.updates) do
        local c = api:updateAnnotation(u.id, u.body)
        if not ok(c) then
            errors[#errors + 1] = "update " .. tostring(u.id)
            conflicts[tostring(u.id)] = "update-failed"
        end
        if c == 401 then return { code = 401 } end
    end
    for _i, item in ipairs(p.creates) do
        local c = api:createAnnotation(item.body)
        -- 409: already there (an earlier answer lost); the last look below
        -- finds it by its range.
        if not (ok(c) or c == 409) then errors[#errors + 1] = "create " .. tostring(item.index) end
        if c == 401 then return { code = 401 } end
    end
    local c2, final = api:annotations(plan.book_id)
    if c2 ~= 200 or type(final) ~= "table" then
        return { code = c2 or false, errors = errors }
    end
    return { code = 200, remote = H.clean(final), conflicts = conflicts, errors = errors }
end

-- ------------------------------------------------------------- KOReader side

local book = nil      -- { path, id, ui } of the open book whose CFI is loaded
local busy, again = false, false
local scheduled = nil

function H.on()
    return Sync().signedIn() and Prefs.on("grimmory_highlights")
        and not require("aleph_grimmory_others").owns("annotations")
end

local function localAnnotations(ui)
    if ui and ui.annotation and type(ui.annotation.annotations) == "table" then
        return ui.annotation.annotations
    end
    return ui and ui.doc_settings and ui.doc_settings:readSetting("annotations") or {}
end

local function online()
    local ok, on = pcall(function() return require("ui/network/manager"):isConnected() end)
    return ok and on
end

-- The merged highlights written back: to the open book, or to the closed
-- book's settings file.
local function save(path, annotations)
    local ui = book and book.path == path and book.ui or nil
    if ui and ui.document then
        ui.annotation.annotations = annotations
        if ui.doc_settings then
            ui.doc_settings:saveSetting("annotations", annotations)
            ui.doc_settings:saveSetting("annotations_externally_modified", true)
        end
        try(function()
            if ui.annotation.updateAnnotations then ui.annotation:updateAnnotations(true, true) end
        end)
        try(function() require("ui/uimanager"):setDirty(ui.dialog or "all", "ui") end)
        return true
    end
    local okd, ds = pcall(function() return require("docsettings"):open(path) end)
    if not okd or not ds then return false end
    ds:saveSetting("annotations", annotations)
    ds:saveSetting("annotations_externally_modified", true)
    ds:flush()
    return true
end

local function release()
    if not (book and book.ui) then
        try(function() require("aleph_grimmory_cfi").clearCache() end)
        book = nil
    end
end

-- One sync of the open (or just closed) book.
function H.sync()
    if not book or not H.on() then return end
    if busy then again = true; return end
    if not online() then return release() end
    local cfi = require("aleph_grimmory_cfi")
    local path, id = book.path, book.id
    local annotations = (book.ui and localAnnotations(book.ui)) or book.closed or {}
    local items, rejected = Ann().fromLocal(annotations, cfi, id)
    local st = Sync().state()
    st.ann = st.ann or {}
    local shadow = st.ann[tostring(id)] or {}
    local before = H.mark(annotations)
    busy = true
    Sync()._run("highlights", H.work, { book_id = id, items = items, shadow = shadow }, function(r)
        busy = false
        local function finish()
            if again and book then again = false; return H.sync() end
            again = false
            release()
        end
        if not r or r.code ~= 200 or type(r.remote) ~= "table" then return finish() end
        -- Another book took the CFI since, or the highlights changed while
        -- the run was out: left for the next run.
        if not book or book.path ~= path then return finish() end
        local now = book.ui and localAnnotations(book.ui) or book.closed
        if H.mark(now) ~= before then again = true; return finish() end
        local conflicts = r.conflicts or {}
        local merged = Ann().mergeLocal(annotations, r.remote, cfi, conflicts)
        if not save(path, merged) then return finish() end
        if not book.ui then book.closed = merged end
        book.synced = H.mark(merged)
        local next_shadow = Ann().shadowFor(r.remote)
        for cid in pairs(conflicts) do next_shadow[cid] = shadow[cid] end
        st = Sync().state()
        st.ann = st.ann or {}
        st.ann[tostring(id)] = next_shadow
        Sync().saveState()
        local n = 0
        for _k in pairs(conflicts) do n = n + 1 end
        if n > 0 and n ~= (book.told or 0) then
            book.told = n
            local _ = require("aleph_gettext")
            Sync()._toast(require("ffi/util").template(
                _("%1 highlights were changed both here and in Grimmory: each side keeps its own."), n), false)
        end
        finish()
    end)
end

function H.open(ui)
    if not ui or not ui.document or not H.on() then return end
    local path = ui.document.file
    local id = Sync().idOf(path)
    if not H.eligible(path, id) then return end
    local cfi = require("aleph_grimmory_cfi")
    local ok, res, err = pcall(cfi.initBook, path)
    if not ok or not res then
        require("logger").warn("Aleph Grimmory: CFI unavailable:", tostring(ok and err or res))
        book = nil
        return
    end
    book = { path = path, id = id, ui = ui }
    if online() then H.sync() end
end

function H.close(ui)
    if not book or not ui or not ui.document or book.path ~= ui.document.file then return end
    if scheduled then try(function() require("ui/uimanager"):unschedule(scheduled) end); scheduled = nil end
    book.closed = localAnnotations(ui)
    book.ui = nil
    if busy then again = true else H.sync() end
end

-- A highlight added, changed or removed.
function H.changed()
    if not book or not book.ui then return end
    -- (Aleph's own writing back is not a change.)
    if book.synced and H.mark(localAnnotations(book.ui)) == book.synced then return end
    local UIManager = require("ui/uimanager")
    if scheduled then UIManager:unschedule(scheduled) end
    scheduled = function() scheduled = nil; H.sync() end
    UIManager:scheduleIn(H.DELAY, scheduled)
end

-- Wi-Fi back with a book open.
function H.connected()
    if book and book.ui then H.sync() end
end

-- Whether a book is handled here (so its note is not sent).
function H.handles(path)
    return H.on() and H.eligible(path, Sync().idOf(path))
end

function H._reset() book, busy, again, scheduled = nil, false, false, nil end
function H._book() return book end

return H

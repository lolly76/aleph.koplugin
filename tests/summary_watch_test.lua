-- Aleph for Grimmory modification, 2026-11-28: tests of aleph_summary_watch.lua,
-- which lets Goodreads and Grimmory hear of a status or stars changed in
-- KOReader's own screens (filemanagerutil.saveSummary).
-- Run from the plugin folder: luajit tests/summary_watch_test.lua
package.path = "./?.lua;" .. package.path

local failures, count = 0, 0
local function eq(got, want, what)
    count = count + 1
    if got ~= want then
        failures = failures + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- KOReader's filemanagerutil, as far as saveSummary goes.
local saved = {}
local util = {}
function util.saveSummary(doc_settings_or_file, summary)
    saved[#saved + 1] = summary
    if type(doc_settings_or_file) == "string" then
        return { readSetting = function(_self, k) if k == "summary" then return summary end end }
    end
    return doc_settings_or_file
end
package.preload["apps/filemanager/filemanagerutil"] = function() return util end

local gr, grim = {}, {}
package.preload["aleph_gr"] = function()
    return { docChanged = function(ui, file, ds) gr[#gr + 1] = { ui = ui, file = file, status = ds.summary.status } end }
end
local grim_fails = false
package.preload["aleph_grimmory_sync"] = function()
    return { docChanged = function(file, ds)
        if grim_fails then error("boom") end
        grim[#grim + 1] = { file = file, ds = ds }
    end }
end
local fm = { name = "file manager" }
package.preload["apps/reader/readerui"] = function() return {} end
package.preload["apps/filemanager/filemanager"] = function() return { instance = fm } end

local Watch = require("aleph_summary_watch")

-- Installed once, however many times Aleph starts (one per window).
eq(Watch.install(), true, "installed")
local wrapped = util.saveSummary
eq(Watch.install(), true, "installed again")
eq(util.saveSummary, wrapped, "wrapped only once")

-- A DocSettings (the file browser's dialog).
local ds = { readSetting = function(_self, k) if k == "doc_path" then return "/books/a.epub" end end }
local back = util.saveSummary(ds, { status = "complete" })
eq(back, ds, "KOReader's result returned")
eq(#saved, 1, "KOReader's own saveSummary ran")
eq(#gr, 1, "Goodreads told")
eq(gr[1].file, "/books/a.epub", "Goodreads: the book")
eq(gr[1].status, "complete", "Goodreads: the status")
eq(gr[1].ui, fm, "Goodreads: the open window")
eq(#grim, 1, "Grimmory told")
eq(grim[1].file, "/books/a.epub", "Grimmory: the book")
eq(grim[1].ds, ds, "Grimmory: the DocSettings")

-- A path (several books at once, Book information).
util.saveSummary("/books/b.pdf", { status = "abandoned" })
eq(gr[2].file, "/books/b.pdf", "a path: Goodreads")
eq(grim[2].file, "/books/b.pdf", "a path: Grimmory")
eq(grim[2].ds:readSetting("summary").status, "abandoned", "a path: Grimmory reads the summary")

-- One side failing stops neither KOReader nor the other side.
grim_fails = true
local ok = pcall(util.saveSummary, ds, { status = "reading" })
eq(ok, true, "a failure does not reach KOReader")
eq(#saved, 3, "KOReader saved")
eq(#gr, 3, "Goodreads still told")
grim_fails = false

-- No book to name: nobody told.
util.saveSummary({ readSetting = function() return nil end }, { status = "reading" })
eq(#gr, 3, "no path: Goodreads not told")

-- A KOReader without filemanagerutil.saveSummary: nothing to wrap.
Watch._reset()
package.loaded["apps/filemanager/filemanagerutil"] = {}
eq(Watch.install(), false, "nothing to wrap")

print(count .. " checks, " .. failures .. " failed")
if failures > 0 then os.exit(1) end

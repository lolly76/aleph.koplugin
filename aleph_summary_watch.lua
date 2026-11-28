-- Aleph for Grimmory modification, 2026-11-28: a book's status or stars
-- changed in KOReader's own screens (the file browser's long-press dialog,
-- Book information, several books at once) reach Goodreads and Grimmory.
--[[--
KOReader sends no event for these changes (main.lua used to wait for a
DocSettingsItemsChanged event that KOReader does not have). They all go
through filemanagerutil.saveSummary, so Aleph wraps it once: KOReader's own
saveSummary runs first, unchanged, then Goodreads and Grimmory each look at
the summary. Both stop at their first check when not set up, so nothing
goes on the network without a Goodreads sign-in or a Grimmory account.
Changes made in Aleph's own screens go through Local:saveSummary
(aleph_local.lua), not here.

    Watch.install()  wraps filemanagerutil.saveSummary (once; nothing on a
                     KOReader without it).
]]

local Watch = {}

local installed = false

-- The book a saveSummary call is about: its path, or a DocSettings' doc_path.
function Watch.fileOf(doc_settings_or_file)
    if type(doc_settings_or_file) == "string" then return doc_settings_or_file end
    if type(doc_settings_or_file) == "table" and type(doc_settings_or_file.readSetting) == "function" then
        local ok, path = pcall(doc_settings_or_file.readSetting, doc_settings_or_file, "doc_path")
        if ok and type(path) == "string" and path ~= "" then return path end
    end
    return nil
end

local function openUI()
    for _i, mod in ipairs({ "apps/reader/readerui", "apps/filemanager/filemanager" }) do
        local ok, UI = pcall(require, mod)
        if ok and type(UI) == "table" and UI.instance then return UI.instance end
    end
    return nil
end

-- Goodreads and Grimmory hear of the new summary (each on its own: one
-- failing does not stop the other).
function Watch.changed(file, doc_settings, summary)
    if not file or type(summary) ~= "table" then return end
    pcall(function() require("aleph_gr").docChanged(openUI(), file, { summary = summary }) end)
    pcall(function()
        local ds = type(doc_settings) == "table" and type(doc_settings.readSetting) == "function"
            and doc_settings or { summary = summary }
        require("aleph_grimmory_sync").docChanged(file, ds)
    end)
end

function Watch.install()
    if installed then return true end
    local ok, util = pcall(require, "apps/filemanager/filemanagerutil")
    if not ok or type(util) ~= "table" or type(util.saveSummary) ~= "function" then return false end
    local original = util.saveSummary
    util.saveSummary = function(doc_settings_or_file, summary, ...)
        local result = original(doc_settings_or_file, summary, ...)
        pcall(Watch.changed, Watch.fileOf(doc_settings_or_file) or Watch.fileOf(result), result, summary)
        return result
    end
    installed = true
    return true
end

-- For tests.
function Watch._reset() installed = false end

return Watch

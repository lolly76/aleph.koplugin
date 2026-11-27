-- Aleph for Grimmory modification, 2026-11-27: other Grimmory plugins on the
-- device, so the same thing is not sent to Grimmory twice.
--[[--
Two other plugins talk to Grimmory:

  grimmory           Grimmory's own plugin (grimmory-tools/grimmory.koplugin):
                     progress, reading sessions, highlights
                     (ManorianOTP's library plugin has the same name but only
                     browses: it has no grimmory/synchronize.lua)
  grimmory_sync      ManorianOTP's Grimmory Sync: progress always; highlights
                     and sessions when turned on in it (settings/grimmory.lua)

When one of them is on, Aleph leaves it what it does (progress, sessions,
highlights, the highlights note) and keeps the rest (browsing, downloads,
status, stars, shelves, which sending twice does not harm). The settings
page says so.

O.owns(what), what = "progress", "sessions" or "annotations": the other
plugin's name when it does it, else nil.
]]

local O = {}

local cache, cache_at = nil, 0

local function exists(path)
    local okl, lfs = pcall(require, "libs/libkoreader-lfs")
    if not okl then return false end
    return lfs.attributes(path, "mode") ~= nil
end

local function pluginDirs()
    local dirs = {}
    local okd, DataStorage = pcall(require, "datastorage")
    if okd then dirs[#dirs + 1] = DataStorage:getDataDir() .. "/plugins" end
    dirs[#dirs + 1] = "plugins"
    return dirs
end

local function disabled(name)
    local list = G_reader_settings and G_reader_settings:readSetting("plugins_disabled")
    return type(list) == "table" and list[name] == true
end

-- The folder of an installed, enabled plugin, or nil.
function O.find(name, dirs)
    if disabled(name) then return nil end
    for _i, d in ipairs(dirs or pluginDirs()) do
        local p = d .. "/" .. name .. ".koplugin"
        if exists(p .. "/main.lua") then return p end
    end
    return nil
end

local function otherSettings()
    local okd, DataStorage = pcall(require, "datastorage")
    if not okd then return {} end
    local okl, s = pcall(function()
        return require("luasettings"):open(DataStorage:getSettingsDir() .. "/grimmory.lua")
    end)
    if not okl or not s then return {} end
    return {
        annotations = s:readSetting("sync_annotations") == true,
        sessions = s:readSetting("sync_reading_sessions") == true,
    }
end

-- Pure: what each plugin found does. found = { grimmory = folder or nil,
-- grimmory_official = bool, grimmory_sync = folder or nil }, opts = what
-- Grimmory Sync has turned on.
function O.decide(found, opts)
    opts = opts or {}
    local owns = {}
    if found.grimmory_sync then
        owns.progress = "grimmory_sync"
        if opts.annotations then owns.annotations = "grimmory_sync" end
        if opts.sessions then owns.sessions = "grimmory_sync" end
    end
    if found.grimmory and found.grimmory_official then
        owns.progress = owns.progress or "grimmory"
        owns.sessions = owns.sessions or "grimmory"
        owns.annotations = owns.annotations or "grimmory"
    end
    return owns
end

function O.scan()
    if cache and os.time() - cache_at < 60 then return cache end
    local found = {}
    found.grimmory_sync = O.find("grimmory_sync")
    found.grimmory = O.find("grimmory")
    found.grimmory_official = found.grimmory and exists(found.grimmory .. "/grimmory/synchronize.lua") or false
    cache = O.decide(found, found.grimmory_sync and otherSettings() or {})
    cache_at = os.time()
    return cache
end

function O.owns(what)
    local ok, owns = pcall(O.scan)
    return ok and owns[what] or nil
end

-- The plugin's name as people know it.
function O.label(name)
    if name == "grimmory_sync" then return "Grimmory Sync" end
    if name == "grimmory" then return "Grimmory" end
    return tostring(name)
end

function O._reset(v) cache, cache_at = v, v and os.time() or 0 end

return O

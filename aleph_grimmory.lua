-- Aleph for Grimmory modification, 2026-11-27: reading progress kept on a
-- Grimmory server.
--[[--
Grimmory (https://github.com/grimmory-tools/grimmory), a self-hosted
library, speaks KOReader's own progress-sync protocol under /api/koreader:

  GET  /api/koreader/users/auth                   the account is right
  GET  /api/koreader/syncs/progress/<partial md5> where a book was left
  PUT  /api/koreader/syncs/progress               where it is now

The account is a "KOReader user" made in Grimmory (Settings > Devices >
KOReader), sent as two headers: x-auth-user (the name) and x-auth-key (the
MD5 of the password, as KOReader's own Progress sync sends it). Grimmory
finds the book by the same partial MD5 KOReader keeps for every book
(partial_md5_checksum), so nothing has to be matched by hand: a book that
came from Grimmory (or the same file put on the server) is found.

  a book opens     where Grimmory has it is asked for; further on there
                   (and from another device), Aleph offers to go there
  the book closes  where it closed is sent; offline, it waits in a queue
                   (one entry a book, the newest) sent when Wi-Fi is back

Every request runs in a background process (aleph_job.lua), so a slow
server never holds up the reader. What Grimmory last said for each book is
kept (grimmory_remote) for the library and the book's page: "60% on
Grimmory" (aleph_remote_progress.lua).

Settings, all in Aleph's table (aleph_prefs.lua): grimmory_url,
grimmory_user, grimmory_key (the MD5, never the password), grimmory_on,
grimmory_ask (offer to jump, on unless off), grimmory_queue, grimmory_remote.
]]

local Prefs = require("aleph_prefs")
local try = require("aleph_try").call

local G = {}

G.TIMEOUT = 25            -- a background request is stopped after this long
G.REMOTE_MAX = 400        -- books whose Grimmory position is remembered
G.SAME = 0.005            -- positions closer than this (0..1) are the same
G.TRIES = 10              -- a position that failed this many times is dropped

-- ------------------------------------------------------------- pure parts

-- "grimmory.local:6060/" -> "http://grimmory.local:6060"; "" -> nil.
function G.normalizeUrl(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    if not s:match("^https?://") then s = "http://" .. s end
    s = s:gsub("/+$", "")
    -- The sync address KOReader's plugin is given ends in /api/koreader:
    -- accepted too.
    s = s:gsub("/api/koreader$", "")
    return s
end

-- Aleph for Grimmory modification, 2026-11-28: an http address outside the
-- home network (the password, key and tokens would travel in clear).
function G.insecure(url)
    if type(url) ~= "string" or not url:match("^http://") then return false end
    local host = url:match("^http://%[?([^/%]]+)") or ""
    host = host:gsub(":%d+$", ""):lower()
    if host == "localhost" or host:match("%.local$") or host:match("%.lan$") or host:match("%.home$")
            or host:match("^127%.") or host:match("^10%.") or host:match("^192%.168%.")
            or host:match("^169%.254%.") or not host:find("%.") then return false end
    local b = tonumber(host:match("^172%.(%d+)%."))
    if b and b >= 16 and b <= 31 then return false end
    local c = tonumber(host:match("^100%.(%d+)%."))   -- Tailscale and other CGNAT
    if c and c >= 64 and c <= 127 then return false end
    return true
end

function G.api(base)
    return base .. "/api/koreader"
end

-- The body of a PUT, from what the reader knows.
function G.body(entry, device, device_id)
    return {
        document = entry.hash,
        progress = entry.progress and tostring(entry.progress) or nil,
        percentage = tonumber(entry.pct) or 0,
        device = device,
        device_id = device_id,
    }
end

-- Grimmory's answer to a GET, made plain: { pct (0..1), progress, device,
-- device_id, time } or nil (no position yet, or an answer not understood).
function G.parseProgress(data)
    if type(data) ~= "table" then return nil end
    local pct = tonumber(data.percentage)
    if not pct then return nil end
    if pct > 1 then pct = pct / 100 end
    -- (JSON null comes back as a sentinel value, not nil: only text and
    -- numbers are positions.)
    local progress = data.progress
    if (type(progress) ~= "string" and type(progress) ~= "number") or progress == "" then progress = nil end
    local function str(v) return type(v) == "string" and v ~= "" and v or nil end
    return {
        pct = math.max(0, math.min(1, pct)),
        progress = progress and tostring(progress) or nil,
        device = str(data.device),
        device_id = str(data.device_id),
        time = tonumber(data.timestamp) or 0,
    }
end

-- Whether to offer the jump: Grimmory further on than here, from another
-- device.
function G.offerJump(remote, here_pct, my_id)
    if type(remote) ~= "table" or not remote.pct then return false end
    if my_id and remote.device_id == my_id then return false end
    return remote.pct > (tonumber(here_pct) or 0) + G.SAME
end

-- The queue keeps one entry a book: the newest.
function G.enqueue(queue, entry)
    queue = type(queue) == "table" and queue or {}
    for i = #queue, 1, -1 do
        if queue[i].hash == entry.hash then table.remove(queue, i) end
    end
    queue[#queue + 1] = entry
    return queue
end

-- ------------------------------------------------------------- settings

function G.url() return G.normalizeUrl(Prefs.get().grimmory_url) end
function G.user()
    local u = Prefs.get().grimmory_user
    return type(u) == "string" and u ~= "" and u or nil
end
function G.configured()
    local p = Prefs.get()
    return G.url() ~= nil and G.user() ~= nil and type(p.grimmory_key) == "string" and p.grimmory_key ~= ""
end
-- On once an account is set, unless turned off.
function G.enabled()
    return G.configured() and Prefs.on("grimmory_on")
        and not require("aleph_grimmory_others").owns("progress")
end

function G.setAccount(user, password)
    Prefs.set("grimmory_user", user ~= "" and user or nil)
    if password and password ~= "" then
        Prefs.set("grimmory_key", require("ffi/sha2").md5(password))
    end
end

local function credentials()
    local p = Prefs.get()
    return { base = G.url(), user = G.user(), key = p.grimmory_key }
end

local function deviceName()
    local ok, name = pcall(function() return require("device").model end)
    return ok and type(name) == "string" and name or "KOReader"
end

local function deviceId()
    return G_reader_settings and G_reader_settings:readSetting("device_id") or nil
end
G.deviceId = deviceId

function G.queue()
    local q = Prefs.get().grimmory_queue
    return type(q) == "table" and q or {}
end

-- What Grimmory last said for a book (by its partial MD5), for the library.
function G.cached(hash)
    if type(hash) ~= "string" or hash == "" then return nil end
    local all = Prefs.get().grimmory_remote
    return type(all) == "table" and all[hash] or nil
end

local function remember(hash, remote)
    if not hash then return end
    local all = Prefs.get().grimmory_remote
    all = type(all) == "table" and all or {}
    if remote then
        all[hash] = { pct = remote.pct, progress = remote.progress, device = remote.device, device_id = remote.device_id, time = remote.time, seen = os.time() }
    else
        all[hash] = nil
    end
    -- The oldest forgotten past REMOTE_MAX.
    local keys = {}
    for k, v in pairs(all) do keys[#keys + 1] = { k = k, t = tonumber(v.seen) or 0 } end
    if #keys > G.REMOTE_MAX then
        table.sort(keys, function(a, b) return a.t < b.t end)
        for i = 1, #keys - G.REMOTE_MAX do all[keys[i].k] = nil end
    end
    Prefs.set("grimmory_remote", all)
end
G._remember = remember

-- KOReader's own Progress sync pointed at the same server: both would send.
function G.kosyncSameServer()
    local url = G.url()
    if not url then return false end
    local ks = G_reader_settings and G_reader_settings:readSetting("kosync")
    local server = type(ks) == "table" and G.normalizeUrl(ks.custom_server)
    return server ~= nil and server == url
end

-- ------------------------------------------------ in the background process

-- One request: status code (or nil) and the decoded JSON answer.
function G.request(method, url, cred, body)
    local code, answer = require("aleph_grimmory_http").request{
        method = method, url = url, json = body,
        accept = "application/vnd.koreader.v1+json",
        headers = { ["x-auth-user"] = cred.user, ["x-auth-key"] = cred.key },
    }
    return code, answer
end

-- What a plan asks, done one after the other. plan: { cred, auth = true,
-- push = { entries }, pull = { hashes }, device, device_id }. Returns
-- { auth = code, pushed = { [hash] = true }, unknown = { [hash] = true }
-- (a book Grimmory does not have: 404), failed = { [hash] = code },
-- pulled = { [hash] = remote or false } }.
function G.work(plan)
    local r = { pushed = {}, unknown = {}, failed = {}, pulled = {} }
    local cred = plan.cred
    local api = G.api(cred.base)
    if plan.auth then
        r.auth = G.request("GET", api .. "/users/auth", cred) or false
        if r.auth ~= 200 then return r end
    end
    for _i, e in ipairs(plan.push or {}) do
        local code = G.request("PUT", api .. "/syncs/progress", cred, G.body(e, plan.device, plan.device_id))
        if code == 200 or code == 202 then r.pushed[e.hash] = true
        elseif code == 404 then r.unknown[e.hash] = true
        else r.failed[e.hash] = code or false end
        if code == 401 or code == 403 then r.auth = code; break end
    end
    for _i, hash in ipairs(plan.pull or {}) do
        local code, answer = G.request("GET", api .. "/syncs/progress/" .. hash, cred)
        if code == 200 then r.pulled[hash] = G.parseProgress(answer) or false
        elseif code == 401 or code == 403 then r.auth = code; break
        else r.pulled[hash] = false end
    end
    return r
end

-- ------------------------------------------------------------- KOReader side

local running = false
local after_flush = {}

-- Aleph for Grimmory modification, 2026-11-28: fn once the positions being
-- sent are sent (at once when none are). Grimmory sets a book's status from
-- the percentage each time a position arrives, so a status set by hand
-- (aleph_grimmory_sync.lua) goes after it, not before.
function G.after(fn)
    if running then after_flush[#after_flush + 1] = fn else fn() end
end
function G.isRunning() return running end

local function afterFlushed()
    local list = after_flush
    after_flush = {}
    for _i, fn in ipairs(list) do try(fn) end
end

local function resultPath()
    return require("datastorage"):getSettingsDir() .. "/aleph_grimmory_job.lua"
end

-- Runs a plan in the background; done(result) in KOReader's loop (nil when
-- nothing could be asked).
function G.run(plan, done)
    local Job = require("aleph_job")
    local File = require("aleph_file")
    plan.cred = plan.cred or credentials()
    plan.device = plan.device or deviceName()
    plan.device_id = plan.device_id or deviceId()
    if not plan.cred.base then if done then done(nil) end return false end
    if not Job.available() then
        -- No background process on this device: asked here, with the
        -- request's own short timeouts.
        local ok, r = pcall(G.work, plan)
        if done then done(ok and r or nil) end
        return ok
    end
    local out = resultPath() .. "." .. tostring(os.time()) .. tostring(math.random(1000, 9999))
    local pid = Job.start(function()
        local ok, r = pcall(G.work, plan)
        File.write(out, ok and r or { error = tostring(r) })
    end, { name = "grimmory" })
    if not pid then if done then done(nil) end return false end
    Job.watch(pid, { every = 0.5, timeout = G.TIMEOUT, on_done = function()
        local r = File.read(out)
        os.remove(out)
        if done then done(type(r) == "table" and not r.error and r or nil) end
    end })
    return true
end

local function online()
    local ok, on = pcall(function()
        local NetworkMgr = require("ui/network/manager")
        return NetworkMgr:isConnected()
    end)
    return ok and on
end

-- Runs fn now when there is a network; otherwise KOReader turns Wi-Fi on
-- (asking first, as set in its network settings) and runs it once online.
-- For what the reader asked for (a test, signing in, Sync now), never for
-- what runs on its own.
function G.withNetwork(fn)
    if online() then return fn() end
    local ok = pcall(function()
        local NetworkMgr = require("ui/network/manager")
        NetworkMgr:runWhenOnline(fn)
    end)
    if not ok then return fn() end
end

-- Sends what waits, when there is a network. done(result, why) optional:
-- result nil and why "busy", "off", "offline", "empty" or "failed".
function G.flush(done)
    local why = running and "busy" or not G.enabled() and "off" or not online() and "offline" or nil
    local queue = G.queue()
    if not why and #queue == 0 then why = "empty" end
    if why then if done then done(nil, why) end return end
    running = true
    local started = G.run({ push = queue }, function(r)
        running = false
        afterFlushed()
        if r then
            -- Sent, or a book Grimmory does not have: done with. Failed:
            -- kept for the next time, up to TRIES times.
            -- (A book closed again while this ran has a newer entry: kept.)
            local sent_at = {}
            for _i, e in ipairs(queue) do sent_at[e.hash] = e.time end
            local left = {}
            for _i, e in ipairs(G.queue()) do
                local this_one = sent_at[e.hash] == e.time
                if not (this_one and (r.pushed[e.hash] or r.unknown[e.hash])) then
                    if this_one and r.failed[e.hash] ~= nil then e.tries = (tonumber(e.tries) or 0) + 1 end
                    if (tonumber(e.tries) or 0) < G.TRIES then left[#left + 1] = e end
                end
            end
            Prefs.set("grimmory_queue", #left > 0 and left or nil)
            for _i, e in ipairs(queue) do
                if r.pushed[e.hash] then
                    remember(e.hash, { pct = e.pct, progress = e.progress, device = deviceName(), device_id = deviceId(), time = e.time })
                end
            end
        end
        if done then done(r, not r and "failed" or nil) end
    end)
    if not started and running then running = false; afterFlushed() end
end

-- The open book: its partial MD5, percentage (0..1) and position.
function G.position(ui)
    if not ui or not ui.document then return nil end
    local hash = ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum")
    if not hash then
        local ok, h = pcall(function() return require("util").partialMD5(ui.document.file) end)
        hash = ok and h or nil
    end
    if not hash then return nil end
    local view = ui.paging or ui.rolling
    if not view then return nil end
    local pct = view.getLastPercent and view:getLastPercent() or nil
    local progress = view.getLastProgress and view:getLastProgress() or nil
    return { hash = hash, pct = tonumber(pct) or 0, progress = progress, time = os.time(),
        title = ui.doc_props and ui.doc_props.display_title or nil }
end

-- A book closes: where it closed goes in the queue, sent now if it can be.
function G.close(ui)
    if not G.enabled() then return end
    local pos = G.position(ui)
    if not pos then return end
    -- Aleph for Grimmory modification, 2026-11-28: a book closed where
    -- Grimmory already has it is not sent again (each position sent also
    -- resets the book's status in Grimmory from its percentage).
    if G.unchanged(G.cached(pos.hash), pos) then return end
    Prefs.set("grimmory_queue", G.enqueue(G.queue(), pos))
    G.flush()
end

-- Whether Grimmory already has this position (pure).
function G.unchanged(cached, pos)
    if type(cached) ~= "table" or type(pos) ~= "table" then return false end
    if cached.progress == nil or tostring(cached.progress) ~= tostring(pos.progress) then return false end
    return math.abs((tonumber(cached.pct) or -1) - (tonumber(pos.pct) or 0)) < G.SAME
end

-- The status Grimmory gives a book from a position's percentage (0..1), as
-- its KOReader interface does (KoreaderService.updateReadStatus).
function G.statusFromPercent(pct)
    pct = tonumber(pct)
    if not pct then return nil end
    if pct * 100 >= 99.5 then return "READ" end
    if pct * 100 >= 0.25 then return "READING" end
    return "UNREAD"
end

local function jump(ui, remote)
    local Event = require("ui/event")
    if remote.progress then
        -- (Only a crengine position: anything else goes by the percentage.)
        if ui.rolling and tostring(remote.progress):match("^/body/") then
            ui:handleEvent(Event:new("GotoXPointer", remote.progress))
            return
        elseif ui.paging and tonumber(remote.progress) then
            ui:handleEvent(Event:new("GotoPage", tonumber(remote.progress)))
            return
        end
    end
    -- Only a percentage (a position from Grimmory's own web reader, say).
    if ui.rolling then
        ui:handleEvent(Event:new("GotoPercent", remote.pct * 100))
    elseif ui.paging and ui.document then
        local pages = ui.document:getPageCount()
        ui:handleEvent(Event:new("GotoPage", math.max(1, math.floor(remote.pct * pages + 0.5))))
    end
end
G._jump = jump

-- A book opens: where Grimmory has it, and the offer to go there.
function G.open(ui)
    if not G.enabled() or not online() then return end
    local pos = G.position(ui)
    if not pos then return end
    local file = ui.document and ui.document.file
    G.run({ pull = { pos.hash } }, function(r)
        if not r or r.pulled[pos.hash] == nil then return end
        local remote = r.pulled[pos.hash] or nil
        remember(pos.hash, remote)
        -- Still the same book, and Aleph may ask.
        if not remote or not ui.document or ui.document.file ~= file then return end
        if not Prefs.on("grimmory_ask") then return end
        local here = G.position(ui)
        if not G.offerJump(remote, here and here.pct or pos.pct, deviceId()) then return end
        local _ = require("aleph_gettext")
        local T = require("ffi/util").template
        local pct = math.floor(remote.pct * 100 + 0.5)
        require("aleph_confirm").show{
            title = _("Further on in Grimmory"),
            text = remote.device and T(_("Grimmory has this book at %1%, from %2."), pct, remote.device)
                or T(_("Grimmory has this book at %1%."), pct),
            ok_label = _("Go there"), cancel_label = _("Stay here"),
            on_ok = function() try(jump, ui, remote) end,
        }
    end)
end

-- Settings > Library > Grimmory > Test the connection. done(ok, message).
function G.test(done)
    local _ = require("aleph_gettext")
    if not G.configured() then return done(false, _("Set the server and the account first.")) end
    if not online() then return G.withNetwork(function() G.test(done) end) end
    G.run({ auth = true }, function(r)
        if not r then return done(false, _("Grimmory did not answer.")) end
        if r.auth == 200 then return done(true, _("Connected to Grimmory.")) end
        if r.auth == 401 or r.auth == 403 then
            return done(false, _("Grimmory refused the account. Check the KOReader user in Grimmory (Settings > Devices > KOReader) and that its sync is on."))
        end
        if r.auth == 404 then return done(false, _("No Grimmory at that address.")) end
        return done(false, _("Grimmory did not answer."))
    end)
end

return G

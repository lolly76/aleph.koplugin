-- Aleph for Grimmory modification, 2026-11-27: tests of aleph_grimmory.lua's
-- parts that need neither KOReader's screen nor a network.
-- Run from the plugin folder: luajit tests/grimmory_test.lua
package.path = "./?.lua;" .. package.path

-- Just enough of KOReader for the module to load.
local store = {}
G_reader_settings = {
    readSetting = function(_self, k) return store[k] end,
    saveSetting = function(_self, k, v) store[k] = v end,
}
package.preload["logger"] = function() return { info = function() end, warn = function() end } end
package.preload["ffi/sha2"] = function() return { md5 = function(s) return "md5:" .. s end } end
package.preload["ui/network/manager"] = function() return { isConnected = function() return true end } end
package.preload["aleph_job"] = function() return { available = function() return false end } end

local G = require("aleph_grimmory")
local Prefs = require("aleph_prefs")
local failures, count = 0, 0
local function eq(got, want, what)
    count = count + 1
    if got ~= want then
        failures = failures + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- Addresses
eq(G.normalizeUrl("grimmory.local:6060/"), "http://grimmory.local:6060", "scheme added, slash dropped")
eq(G.normalizeUrl("  https://books.example.org  "), "https://books.example.org", "spaces trimmed")
eq(G.normalizeUrl("https://b.example.org/api/koreader"), "https://b.example.org", "sync address accepted")
eq(G.normalizeUrl(""), nil, "empty")
eq(G.api("http://h:6060"), "http://h:6060/api/koreader", "api base")

-- Answers
local r = G.parseProgress({ percentage = 0.42, progress = "/body/DocFragment[3]", device = "Kobo", device_id = "abc", timestamp = 100 })
eq(r.pct, 0.42, "pct"); eq(r.progress, "/body/DocFragment[3]", "progress"); eq(r.device, "Kobo", "device"); eq(r.time, 100, "time")
eq(G.parseProgress({ percentage = 63 }).pct, 0.63, "percent as 0-100")
eq(G.parseProgress({ percentage = 0.5, progress = {} }).progress, nil, "JSON null position")
eq(G.parseProgress({ progress = "x" }), nil, "no percentage")
eq(G.parseProgress(nil), nil, "no answer")

-- Offer to jump
eq(G.offerJump({ pct = 0.6, device_id = "other" }, 0.3, "me"), true, "further on elsewhere")
eq(G.offerJump({ pct = 0.6, device_id = "me" }, 0.3, "me"), false, "from this device")
eq(G.offerJump({ pct = 0.302, device_id = "other" }, 0.3, "me"), false, "same place")
eq(G.offerJump({ pct = 0.2, device_id = "other" }, 0.3, "me"), false, "behind")

-- Queue: one entry a book, the newest
local q = G.enqueue({}, { hash = "a", pct = 0.1, time = 1 })
q = G.enqueue(q, { hash = "b", pct = 0.2, time = 2 })
q = G.enqueue(q, { hash = "a", pct = 0.3, time = 3 })
eq(#q, 2, "queue length"); eq(q[2].hash, "a", "newest last"); eq(q[2].pct, 0.3, "newest kept")

-- Body of a PUT
local b = G.body({ hash = "h", pct = 0.5, progress = 12 }, "Kindle", "id1")
eq(b.document, "h", "document"); eq(b.progress, "12", "progress as text"); eq(b.percentage, 0.5, "percentage"); eq(b.device_id, "id1", "device id")

-- Settings
eq(G.configured(), false, "not configured")
Prefs.set("grimmory_url", "http://h:6060")
G.setAccount("alex", "secret")
eq(Prefs.get().grimmory_key, "md5:secret", "only the MD5 kept")
eq(G.configured(), true, "configured"); eq(G.enabled(), true, "on by default")
Prefs.set("grimmory_on", false); eq(G.enabled(), false, "turned off"); Prefs.set("grimmory_on", nil)
store.kosync = { custom_server = "http://h:6060/" }
eq(G.kosyncSameServer(), true, "kosync on the same server")

-- Remembered positions, oldest dropped past REMOTE_MAX
G.REMOTE_MAX = 2
G._remember("x", { pct = 0.1 }); G._remember("y", { pct = 0.2 })
Prefs.get().grimmory_remote.x.seen = 1
G._remember("z", { pct = 0.3 })
eq(G.cached("x"), nil, "oldest dropped"); eq(G.cached("z").pct, 0.3, "newest kept")

-- Flush: what was sent leaves the queue; a book Grimmory lacks too; a failure stays
G.run = function(plan, done)
    done({ pushed = { a = true }, unknown = { b = true }, failed = { c = 500 }, pulled = {} })
end
Prefs.set("grimmory_queue", { { hash = "a", time = 1 }, { hash = "b", time = 1 }, { hash = "c", time = 1 } })
G.flush()
local left = G.queue()
eq(#left, 1, "one left"); eq(left[1].hash, "c", "the failed one"); eq(left[1].tries, 1, "a try counted")

print(string.format("%d checks, %d failed", count, failures))
os.exit(failures == 0 and 0 or 1)

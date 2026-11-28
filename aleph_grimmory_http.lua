-- Aleph for Grimmory modification, 2026-11-27: one HTTP request to a
-- Grimmory server, for aleph_grimmory.lua (progress) and
-- aleph_grimmory_api.lua (the rest).
--[[--
    local Http = require("aleph_grimmory_http")
    local code, answer, raw = Http.request{
        method = "GET",               -- GET (default), POST, PUT, DELETE
        url = "https://...",
        headers = { ... },            -- added to Accept / Content-Type
        json = { ... },               -- sent as the JSON body, if given
        file = "/path/to/save",       -- the answer written there instead (a download)
        accept = "application/json",
        block = 10, total = 20,       -- timeouts (s), see below; total -1: none
    }

code: the HTTP status, or nil when the server could not be reached.
answer: the decoded JSON answer (nil when none, or not JSON). raw: the
answer's text (nil for a download). A download goes to file .. ".part"
first and is moved in place only when whole (status 200).

Meant for a background process: it waits for the server (10 s for each
step, 20 s in all unless block / total say otherwise; a download waits
30 s for each step and has no limit in all, so a big book on slow Wi-Fi
still arrives while data keeps coming).
]]

local Http = {}

function Http.request(o)
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local url = o.url
    local http = url:match("^https:") and require("ssl.https") or require("socket.http")
    local headers = { ["Accept"] = o.accept or "application/json" }
    for k, v in pairs(o.headers or {}) do headers[k] = v end
    local data
    if o.json ~= nil then
        data = require("json").encode(o.json)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#data)
    elseif (o.method == "POST" or o.method == "PUT") then
        headers["Content-Length"] = "0"
    end
    local out, sink, fh = {}, nil, nil
    if o.file then
        fh = io.open(o.file .. ".part", "wb")
        if not fh then return nil end
        sink = ltn12.sink.file(fh)       -- closes fh when done
    else
        sink = ltn12.sink.table(out)
    end
    if o.file then
        socketutil:set_timeout(o.block or 30, o.total or -1)
    else
        socketutil:set_timeout(o.block or 10, o.total or 20)
    end
    local ok, code = pcall(function()
        local _r, status = http.request{
            url = url, method = o.method or "GET", headers = headers,
            source = data and ltn12.source.string(data) or nil,
            sink = sink,
        }
        return status
    end)
    socketutil:reset_timeout()
    code = ok and tonumber(code) or nil
    if fh then pcall(fh.close, fh) end   -- (already closed when the answer came)
    if o.file then
        if code == 200 then
            os.remove(o.file)
            if not os.rename(o.file .. ".part", o.file) then code = nil end
        else
            os.remove(o.file .. ".part")
        end
        return code
    end
    local raw = table.concat(out)
    local answer
    if raw ~= "" then
        local okj, v = pcall(require("json").decode, raw)
        if okj then answer = v end
    end
    return code, answer, raw
end

-- "a b/é" -> "a%20b%2F%C3%A9"
function Http.escape(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(ch) return string.format("%%%02X", ch:byte()) end))
end

-- { a = 1, b = "x y" } -> "a=1&b=x%20y" (keys in order, nils left out).
function Http.query(params)
    local keys = {}
    for k in pairs(params or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _i, k in ipairs(keys) do
        local v = params[k]
        if v ~= nil and v ~= "" then parts[#parts + 1] = Http.escape(k) .. "=" .. Http.escape(v) end
    end
    return table.concat(parts, "&")
end

return Http

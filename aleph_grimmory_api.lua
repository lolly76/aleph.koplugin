-- Aleph for Grimmory modification, 2026-11-27: Grimmory's own API, for the
-- library, statuses, stars, highlights, shelves and reading sessions.
--[[--
Progress goes through Grimmory's KOReader interface (aleph_grimmory.lua).
Everything else goes through Grimmory's API (/api/v1), signed in as the
reader's own Grimmory account (the one used on its website):

  POST /api/v1/auth/login            { username, password } -> tokens
  POST /api/v1/auth/refresh          { refreshToken } -> new tokens
  GET  /api/v1/books                 every book (title, authors, ISBN, file)
  GET  /api/v1/books/page            a page: query, sort, cursor (next link)
  GET  /api/v1/books/{id}/download   the book's file
  GET  /api/v1/media/book/{id}/thumbnail
  GET  /api/v1/shelves, /api/v1/shelves/{id}/books
  POST /api/v1/books/status          { bookIds, status }
  PUT  /api/v1/books/personal-rating { ids, rating }   (1 to 10)
  GET  /api/v1/book-notes/book/{id}, POST /api/v1/book-notes { id, bookId, title, content }
  POST /api/v1/reading-sessions      { bookId, startTime, endTime, durationSeconds, ... }

The password is used once, to sign in, and never kept: Grimmory answers
with an access token (2 hours) and a refresh token (30 days, a new one each
time it is used). Both are kept (Prefs grimmory_api); a reader away for more
than 30 days signs in again.

    local Api = require("aleph_grimmory_api")
    local api = Api.new(base, tokens, on_tokens)   -- on_tokens(tokens) when they change
    local code = api:login(user, password)
    local code, data = api:call("GET", "/api/v1/shelves")

The pure parts (matching books, statuses, stars, notes) are below the
client, and tested in tests/grimmory_test.lua.
]]

local Http = require("aleph_grimmory_http")

local Api = {}
Api.__index = Api

function Api.new(base, tokens, on_tokens)
    return setmetatable({ base = base, tokens = tokens or {}, on_tokens = on_tokens }, Api)
end

local function now() return os.time() end

function Api:_setTokens(answer)
    if type(answer) ~= "table" or type(answer.accessToken) ~= "string" then return false end
    local t = self.tokens
    t.access = answer.accessToken
    if type(answer.refreshToken) == "string" and answer.refreshToken ~= "" then t.refresh = answer.refreshToken end
    t.access_exp = now() + math.max(60, (tonumber(answer.expires) or 7200) - 120)
    t.refresh_exp = now() + 30 * 86400
    if self.on_tokens then pcall(self.on_tokens, t) end
    return true
end

-- Signs in. Returns the status code (200 when signed in).
function Api:login(user, password)
    local code, answer = Http.request{ method = "POST", url = self.base .. "/api/v1/auth/login",
        json = { username = user, password = password } }
    if code == 200 and not self:_setTokens(answer) then code = nil end
    if code == 200 then self.tokens.user = user end
    return code
end

function Api:refresh()
    if not self.tokens.refresh then return 401 end
    local code, answer = Http.request{ method = "POST", url = self.base .. "/api/v1/auth/refresh",
        json = { refreshToken = self.tokens.refresh } }
    if code == 200 and not self:_setTokens(answer) then code = nil end
    if code == 401 or code == 403 then
        -- The refresh token is no longer good: signed out.
        self.tokens.access, self.tokens.refresh = nil, nil
        if self.on_tokens then pcall(self.on_tokens, self.tokens) end
    end
    return code
end

function Api:signedIn() return self.tokens.refresh ~= nil or self.tokens.access ~= nil end

-- One call, signed in. path: "/api/v1/..." (or a whole address). file: the
-- answer saved there (a download). Returns code, answer (decoded JSON).
-- A refused access token is renewed once and the call made again.
function Api:call(method, path, json, file)
    if not self:signedIn() then return 401 end
    if not self.tokens.access or now() >= (tonumber(self.tokens.access_exp) or 0) then
        local rc = self:refresh()
        if rc ~= 200 then return rc end
    end
    local url = path:match("^https?://") and path or (self.base .. path)
    local function go()
        return Http.request{ method = method, url = url, json = json, file = file,
            accept = file and "*/*" or nil,
            headers = { ["Authorization"] = "Bearer " .. tostring(self.tokens.access) } }
    end
    local code, answer = go()
    if code == 401 then
        local rc = self:refresh()
        if rc ~= 200 then return rc end
        code, answer = go()
    end
    return code, answer
end

-- ------------------------------------------------------------ the calls

function Api:books()
    local code, data = self:call("GET", "/api/v1/books")
    return code, type(data) == "table" and data or nil
end

-- One page of books: { books, next } (next: the address of the next page).
-- params: query, sort ("-addedOn", "title"...), size; or next from a page before.
function Api:page(params, next_url)
    local path = next_url or ("/api/v1/books/page?" .. Http.query{
        query = params and params.query, sort = params and params.sort or "-addedOn",
        size = params and params.size or 30 })
    local code, data = self:call("GET", path)
    if code ~= 200 or type(data) ~= "table" then return code end
    return code, { books = type(data.content) == "table" and data.content or {}, next = Api.nextLink(data.links) }
end

function Api:shelves()
    local code, data = self:call("GET", "/api/v1/shelves")
    return code, type(data) == "table" and data or nil
end

function Api:shelfBooks(id)
    local code, data = self:call("GET", "/api/v1/shelves/" .. tostring(id) .. "/books")
    return code, type(data) == "table" and data or nil
end

function Api:download(id, file)
    return self:call("GET", "/api/v1/books/" .. tostring(id) .. "/download", nil, file)
end

function Api:thumbnail(id, file)
    return self:call("GET", "/api/v1/media/book/" .. tostring(id) .. "/thumbnail", nil, file)
end

function Api:setStatus(id, status)
    return self:call("POST", "/api/v1/books/status", { bookIds = { id }, status = status })
end

function Api:setRating(id, rating)
    return self:call("PUT", "/api/v1/books/personal-rating", { ids = { id }, rating = rating })
end

function Api:notes(id)
    local code, data = self:call("GET", "/api/v1/book-notes/book/" .. tostring(id))
    return code, type(data) == "table" and data or nil
end

-- note: { id (to change one), bookId, title, content }
function Api:saveNote(note)
    return self:call("POST", "/api/v1/book-notes", note)
end

function Api:deleteNote(note_id)
    return self:call("DELETE", "/api/v1/book-notes/" .. tostring(note_id))
end

-- The KOReader user of the signed-in account (what Grimmory's KOReader
-- interface, aleph_grimmory.lua, signs in with).
function Api:koreaderUser()
    local code, data = self:call("GET", "/api/v1/koreader-users/me")
    return code, type(data) == "table" and data or nil
end

function Api:setKoreaderUser(user, password)
    return self:call("PUT", "/api/v1/koreader-users/me", { username = user, password = password })
end

function Api:setKoreaderSync(on)
    return self:call("PATCH", "/api/v1/koreader-users/me/sync?enabled=" .. tostring(on and true or false))
end

-- Annotations (highlights with a CFI range): Grimmory's own, shown in its reader.
function Api:annotations(book_id)
    local code, data = self:call("GET", "/api/v1/annotations/book/" .. tostring(book_id))
    return code, type(data) == "table" and data or nil
end

function Api:createAnnotation(body)
    return self:call("POST", "/api/v1/annotations", body)
end

-- body: { color, style, note } (the range and text never change)
function Api:updateAnnotation(id, body)
    return self:call("PUT", "/api/v1/annotations/" .. tostring(id), body)
end

function Api:deleteAnnotation(id)
    return self:call("DELETE", "/api/v1/annotations/" .. tostring(id))
end

function Api:session(s)
    return self:call("POST", "/api/v1/reading-sessions", s)
end

-- ------------------------------------------------------------ pure parts

-- The "next" link of a page's links, or nil. A link's rel is a word or a list.
function Api.nextLink(links)
    for _i, l in ipairs(type(links) == "table" and links or {}) do
        local rel = l.rel
        local is_next = rel == "next"
        if type(rel) == "table" then
            for _j, r in ipairs(rel) do if r == "next" then is_next = true end end
        end
        if is_next and type(l.href) == "string" then return l.href end
    end
end

-- KOReader's status of a book -> Grimmory's (nil: leave Grimmory's as it is).
local STATUS = { complete = "READ", reading = "READING", abandoned = "PAUSED", new = "UNREAD" }
function Api.md5(text) return require("ffi/sha2").md5(text) end

-- The KOReader user name and key (MD5) from koreader-users/me, or nil.
function Api.kosyncFrom(me)
    if type(me) ~= "table" or type(me.username) ~= "string" or me.username == "" then return nil end
    local key = type(me.passwordMD5) == "string" and me.passwordMD5 ~= "" and me.passwordMD5:lower() or nil
    if not key and type(me.password) == "string" and me.password ~= "" then key = Api.md5(me.password) end
    if not key then return nil end
    return { user = me.username, key = key }
end

-- A password for a KOReader user Aleph makes: nobody types it.
function Api.newPassword()
    local f = io.open("/dev/urandom", "rb")
    local bytes = f and f:read(12)
    if f then f:close() end
    if not bytes or #bytes < 12 then
        math.randomseed(os.time() + math.floor((os.clock() * 1e6) % 1e6))
        local t = {}
        for i = 1, 12 do t[i] = string.char(math.random(0, 255)) end
        bytes = table.concat(t)
    end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function Api.statusFor(koreader_status) return STATUS[koreader_status] end

-- KOReader's stars (1 to 5) -> Grimmory's rating (1 to 10); none -> nil.
function Api.ratingFor(stars)
    stars = tonumber(stars)
    if not stars or stars < 1 then return nil end
    return math.max(1, math.min(10, math.floor(stars * 2 + 0.5)))
end

-- "2026-11-27T09:00:00Z"
function Api.isoTime(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end

-- A reading session for Grimmory, or nil (under a minute: not counted).
-- s: { book_id, started, ended, from (0..1), to (0..1), format, from_pos, to_pos }
local TYPES = { EPUB = "EPUB", PDF = "PDF", CBZ = "CBX", CBR = "CBX", CB7 = "CBX", FB2 = "FB2", MOBI = "MOBI", AZW3 = "AZW3", AZW = "AZW3" }
function Api.sessionBody(s)
    local secs = math.floor((tonumber(s.ended) or 0) - (tonumber(s.started) or 0))
    if secs < 60 or not s.book_id then return nil end
    local function pct(x) return x and math.floor(tonumber(x) * 1000 + 0.5) / 10 or nil end
    local h, m, sec = math.floor(secs / 3600), math.floor(secs % 3600 / 60), secs % 60
    local formatted = h > 0 and string.format("%dh %dm %ds", h, m, sec) or string.format("%dm %ds", m, sec)
    local from, to = pct(s.from), pct(s.to)
    return {
        bookId = s.book_id,
        bookType = s.format and TYPES[tostring(s.format):upper()] or nil,
        startTime = Api.isoTime(s.started), endTime = Api.isoTime(s.ended),
        durationSeconds = secs, durationFormatted = formatted,
        startProgress = from, endProgress = to,
        progressDelta = (from and to) and math.floor((to - from) * 10 + 0.5) / 10 or nil,
        startLocation = s.from_pos and tostring(s.from_pos) or nil,
        endLocation = s.to_pos and tostring(s.to_pos) or nil,
    }
end

Api.NOTE_TITLE = "KOReader highlights"

-- The book's highlights as one note's text (nil when there are none).
-- highlights: { text, note, chapter, datetime } each, in reading order.
function Api.notesContent(highlights)
    local parts = {}
    for _i, h in ipairs(highlights or {}) do
        if type(h.text) == "string" and h.text ~= "" then
            local block = {}
            if h.chapter and h.chapter ~= "" then block[#block + 1] = "## " .. tostring(h.chapter) end
            block[#block + 1] = "> " .. h.text:gsub("%s*\n%s*", "\n> ")
            if type(h.note) == "string" and h.note ~= "" then block[#block + 1] = h.note end
            if h.datetime then block[#block + 1] = "_" .. tostring(h.datetime) .. "_" end
            parts[#parts + 1] = table.concat(block, "\n\n")
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "\n\n---\n\n")
end

-- A short fingerprint of a text, to see whether it changed.
function Api.digest(text)
    local ok, md5 = pcall(function() return require("ffi/sha2").md5(text) end)
    if ok then return md5 end
    local h = 0
    for i = 1, #text do h = (h * 31 + text:byte(i)) % 4294967296 end
    return tostring(#text) .. ":" .. tostring(h)
end

-- ------------------------------------------------------------ matching

local function fold(s)
    s = tostring(s or ""):lower()
    -- Capital accented letters (UTF-8 C3 80 to C3 9E) to small ones.
    s = s:gsub("\195([\128-\158])", function(c)
        local b = c:byte()
        return b == 151 and "\195\151" or ("\195" .. string.char(b + 32))
    end)
    -- Accents of Latin letters, in UTF-8, to their plain letter.
    local map = { ["à"]="a",["á"]="a",["â"]="a",["ä"]="a",["ã"]="a",["å"]="a",["ç"]="c",["è"]="e",["é"]="e",["ê"]="e",["ë"]="e",
        ["ì"]="i",["í"]="i",["î"]="i",["ï"]="i",["ñ"]="n",["ò"]="o",["ó"]="o",["ô"]="o",["ö"]="o",["õ"]="o",["ù"]="u",["ú"]="u",
        ["û"]="u",["ü"]="u",["ý"]="y",["ÿ"]="y",["œ"]="oe",["æ"]="ae" }
    s = s:gsub("[\195\197][\128-\191]", function(ch) return map[ch] or ch end)
    -- Typographic punctuation (’ “ ” – — … and the like, U+2000 to U+206F).
    s = s:gsub("\226\128[\128-\191]", " "):gsub("\226\129[\128-\175]", " ")
    -- Non-breaking spaces and guillemets.
    s = s:gsub("\194[\160\171\187]", " ")
    s = s:gsub("[%p%c]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return s
end
Api.fold = fold

local function digits(s) return (tostring(s or ""):gsub("[^%dXx]", ""):upper()) end

-- The first author's surname-ish key: the longest word of the name.
local function authorKey(name)
    local best = ""
    for w in fold(name):gmatch("%S+") do if #w > #best then best = w end end
    return best
end

local function titleKey(title)
    -- A subtitle after ":" is left out (shops and files disagree about it).
    local t = tostring(title or ""):gsub("%s*[:%(].*$", "")
    return fold(t)
end

-- Local books -> Grimmory ids. locals: { path, title, authors = { names },
-- size (bytes), isbn }; remotes: Grimmory's books. Returns { [path] = id },
-- and how each was found ({ [path] = "file" | "isbn" | "title" }).
-- In order: the same file name and size, the same ISBN, the same title and
-- first author (only when one Grimmory book has them).
function Api.match(locals, remotes)
    local by_file, by_isbn, by_title, title_count = {}, {}, {}, {}
    for _i, r in ipairs(remotes or {}) do
        local id = tonumber(r.id)
        local md = type(r.metadata) == "table" and r.metadata or {}
        local f = type(r.primaryFile) == "table" and r.primaryFile or {}
        if id then
            if type(f.fileName) == "string" then
                by_file[f.fileName:lower()] = by_file[f.fileName:lower()] or {}
                table.insert(by_file[f.fileName:lower()], { id = id, kb = tonumber(f.fileSizeKb) })
            end
            for _j, isbn in ipairs({ md.isbn13, md.isbn10 }) do
                local d = digits(isbn)
                if #d >= 10 then by_isbn[d] = id end
            end
            local authors = type(md.authors) == "table" and md.authors or {}
            local key = titleKey(md.title or r.title) .. "|" .. authorKey(authors[1])
            if key ~= "|" then
                by_title[key] = id
                title_count[key] = (title_count[key] or 0) + 1
            end
        end
    end
    local out, how = {}, {}
    for _i, b in ipairs(locals or {}) do
        local path = b.path
        local name = type(path) == "string" and path:match("([^/]+)$")
        local found
        if name and by_file[name:lower()] then
            for _j, c in ipairs(by_file[name:lower()]) do
                -- Grimmory gives the size in KB, rounded: a KB either way.
                if not c.kb or not b.size or math.abs(c.kb - b.size / 1024) <= 1.5 then found = c.id; break end
            end
            if found then how[path] = "file" end
        end
        if not found and b.isbn then
            local d = digits(b.isbn)
            if by_isbn[d] then found = by_isbn[d]; how[path] = "isbn" end
        end
        if not found then
            local authors = type(b.authors) == "table" and b.authors or { b.authors }
            local key = titleKey(b.title) .. "|" .. authorKey(authors[1])
            if title_count[key] == 1 then found = by_title[key]; how[path] = "title" end
        end
        if found and path then out[path] = found end
    end
    return out, how
end

-- A local book's ISBN, from what KOReader read in the file.
function Api.isbnOf(book)
    local props = type(book) == "table" and type(book.props) == "table" and book.props or {}
    local ids = tostring(props.identifiers or "")
    local isbn = ids:match("[Ii][Ss][Bb][Nn]:?%s*([%dXx%-]+)") or ids:match("(97[89][%d%-]+)")
    if isbn and #digits(isbn) >= 10 then return digits(isbn) end
end

-- A file name for a downloaded book: "Author - Title.epub", without the
-- characters file systems refuse.
function Api.fileNameFor(book)
    local md = type(book.metadata) == "table" and book.metadata or {}
    local f = type(book.primaryFile) == "table" and book.primaryFile or {}
    local ext = (type(f.extension) == "string" and f.extension ~= "" and f.extension)
        or (type(f.fileName) == "string" and f.fileName:match("%.([^%.]+)$")) or "epub"
    local authors = type(md.authors) == "table" and md.authors or {}
    local title = md.title or book.title or ("book " .. tostring(book.id))
    local name = (authors[1] and (authors[1] .. " - ") or "") .. title
    name = name:gsub('[\\/:%*%?"<>|%c]', "_"):gsub("%s+", " "):gsub("^[%s%.]+", ""):sub(1, 150)
    return name .. "." .. ext:lower()
end

return Api

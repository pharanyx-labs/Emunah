--- The Achaea web API: real data, instead of inference.
---
--- `https://api.achaea.com/characters/<name>.json` returns what the game itself knows about
--- a character. This is a categorically better source than anything parsed out of game
--- text, and it is worth being explicit about why:
---
---   * It is CANONICAL. `HONOURS` output is prose that has to be pattern-matched and
---     re-matched every time IRE reflows a line. The API is a flat JSON object with stable
---     keys.
---   * It carries the character's OWN spelling of their name, so a name lifted out of a
---     honorific ("Khaalis Saibel Aristata") can be confirmed rather than guessed at.
---   * It costs no game balance, no equilibrium and no line of scrollback. HONOURS costs
---     all three, and doing it for forty people is not something anyone will do twice.
---
--- Observed payloads, 2026-08-02 (see docs/game/api.md):
---
---   {"name":"Saemora","fullname":"Saemora, of Targossas","city":"targossas",
---    "house":"(none)","level":"44","class":"priest","mob_kills":"290","player_kills":"0",
---    "xp_rank":"1017","explorer_rank":"1074"}
---
---   404-equivalent is an HTTP 403 with
---   {"error":{"code":403,"message":"Character not found: zzzznotarealname"}}
---
--- EVERY VALUE IS A STRING, including the numbers, and `mob_kills` is sometimes abbreviated
--- ("451k"). Nothing here assumes a field is a number because it looks like one.
---
--- BEING A GOOD CITIZEN
--- --------------------
--- Walking into a market square would otherwise fire thirty simultaneous requests at a
--- volunteer-run service. Requests are therefore serialised through one queue with a
--- minimum interval between them, results are cached, and MISSES are cached too -- a name
--- that is not a character (a mis-resolved honorific, a mob) must not be re-asked every
--- time it scrolls past.

local M = {}

local util  = emunah.util
local log   = emunah.log
local event = emunah.event

M.HOST   = "https://api.achaea.com"
M.ONLINE = M.HOST .. "/characters.json"

--- How long a fetched record stays fresh. Cities and classes change, but not hourly, and a
--- stale city is a far smaller problem than hammering the service.
M.TTL      = 6 * 3600
--- A negative result is cached longer: "this is not a character" does not become false.
M.MISS_TTL = 24 * 3600
--- The online roster changes constantly, so it is cached only long enough to serve a burst
--- of name resolutions from one CW or CLWHO listing.
M.ONLINE_TTL = 60

--- Seconds between requests leaving the queue.
M.INTERVAL = 1.0
--- Give up on a request that never lands, or the queue stalls forever behind it.
M.TIMEOUT  = 15.0

M.cache   = {}   -- name(lower) -> { at, data | miss = true }
M.online  = {}   -- name(lower) -> true
M.onlineAt = nil

M.queue    = {}
M.inflight = nil
M.counters = { sent = 0, ok = 0, missing = 0, failed = 0, served = 0 }

--- Turned off entirely by `emunah ndb api off`. Nothing in Emunah reaches the network
--- without this being true.
M.enabled = true

-- ---------------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------------

--- Decode JSON.
---
--- Mudlet bundles yajl and `yajl.to_value` is the right tool, but it is used through a
--- pcall and backed by the decoder below rather than trusted outright: this module is the
--- one place in Emunah that consumes text from outside the game, and a decoder erroring on
--- an unexpected payload must degrade to "no data" rather than to a stack trace inside an
--- event handler.
--- @return table|nil value, string|nil err
function M.decode(text)
   if type(text) ~= "string" or text == "" then return nil, "empty response" end

   if type(yajl) == "table" and type(yajl.to_value) == "function" then
      local ok, value = pcall(yajl.to_value, text)
      if ok and type(value) == "table" then return value end
   end

   local ok, value = pcall(M.parse, text)
   if not ok then return nil, tostring(value) end
   if type(value) ~= "table" then return nil, "not an object" end
   return value
end

--- A small strict JSON reader, used when yajl is absent or unhappy.
---
--- Deliberately minimal: this parses the subset the API actually emits (objects, arrays,
--- strings, numbers, true/false/null) and raises on anything else rather than guessing.
function M.parse(text)
   local pos = 1

   local function fail(why)
      error(string.format("%s at %d", why, pos), 0)
   end

   local function skip()
      local _, stop = text:find("^[ \t\r\n]+", pos)
      if stop then pos = stop + 1 end
   end

   local readValue

   local function readString()
      if text:sub(pos, pos) ~= '"' then fail("expected a string") end
      pos = pos + 1
      local out = {}
      while true do
         local char = text:sub(pos, pos)
         if char == "" then fail("unterminated string") end
         if char == '"' then pos = pos + 1 break end
         if char == "\\" then
            local escape = text:sub(pos + 1, pos + 1)
            pos = pos + 2
            if escape == "n" then out[#out + 1] = "\n"
            elseif escape == "t" then out[#out + 1] = "\t"
            elseif escape == "r" then out[#out + 1] = "\r"
            elseif escape == "b" then out[#out + 1] = "\b"
            elseif escape == "f" then out[#out + 1] = "\f"
            elseif escape == "u" then
               -- The API escapes forward slashes in URIs and nothing more exotic, so a
               -- \uXXXX below 128 is passed through and anything above it is replaced
               -- rather than half-decoded into broken UTF-8.
               local hex = text:sub(pos, pos + 3)
               pos = pos + 4
               local code = tonumber(hex, 16)
               out[#out + 1] = (code and code < 128) and string.char(code) or "?"
            else
               out[#out + 1] = escape          -- covers \" \\ \/
            end
         else
            out[#out + 1] = char
            pos = pos + 1
         end
      end
      return table.concat(out)
   end

   local function readNumber()
      local literal = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
      if not literal or literal == "" then fail("expected a number") end
      pos = pos + #literal
      return tonumber(literal) or fail("bad number")
   end

   readValue = function()
      skip()
      local char = text:sub(pos, pos)

      if char == "{" then
         pos = pos + 1
         local out = {}
         skip()
         if text:sub(pos, pos) == "}" then pos = pos + 1 return out end
         while true do
            skip()
            local field = readString()
            skip()
            if text:sub(pos, pos) ~= ":" then fail("expected ':'") end
            pos = pos + 1
            out[field] = readValue()
            skip()
            local next_ = text:sub(pos, pos)
            pos = pos + 1
            if next_ == "}" then return out end
            if next_ ~= "," then fail("expected ',' or '}'") end
         end
      end

      if char == "[" then
         pos = pos + 1
         local out = {}
         skip()
         if text:sub(pos, pos) == "]" then pos = pos + 1 return out end
         while true do
            out[#out + 1] = readValue()
            skip()
            local next_ = text:sub(pos, pos)
            pos = pos + 1
            if next_ == "]" then return out end
            if next_ ~= "," then fail("expected ',' or ']'") end
         end
      end

      if char == '"' then return readString() end
      if text:find("^true", pos) then pos = pos + 4 return true end
      if text:find("^false", pos) then pos = pos + 5 return false end
      if text:find("^null", pos) then pos = pos + 4 return nil end
      return readNumber()
   end

   local value = readValue()
   skip()
   return value
end

-- ---------------------------------------------------------------------------
-- transport
-- ---------------------------------------------------------------------------
--
-- Two mechanisms, because Mudlet grew a second one. getHTTP() keeps the body in memory and
-- is what recent Mudlet wants; downloadFile() writes to disk and exists everywhere. The
-- choice is made once, here, so nothing above this line has to care -- and either way the
-- result arrives as an EVENT, never as a return value, which is why every caller in this
-- module is written as a callback.

local pending = {}      -- url or path -> { onDone, onFail, timer }

--- Raw tempTimer rather than core/timers, on purpose.
---
--- core/timers is a registry of NAMED cooldowns -- starting "herb" twice cancels the first,
--- which is exactly right for a balance and exactly wrong here, where two requests can be
--- outstanding and each needs its own deadline. These are also not cooldowns in any sense
--- the UI should see. A stale one firing after a reload settles nothing, because `pending`
--- is a fresh local table in the new generation.
local function later(delay, fn)
   return tempTimer(delay, fn)
end

local function settle(handleFor, ok, body)
   local waiting = pending[handleFor]
   if not waiting then return false end
   pending[handleFor] = nil
   if waiting.timer then killTimer(waiting.timer) end
   if ok then waiting.onDone(body) else waiting.onFail(body) end
   return true
end

--- True when this Mudlet can fetch in memory rather than through a temporary file.
function M.canGetHTTP()
   return type(getHTTP) == "function"
end

local function tmpPath(url)
   -- One file per URL, in the profile directory, overwritten on each fetch. Not cleaned up
   -- on purpose: it is a handful of bytes and it makes a failed parse inspectable.
   local slug = url:gsub("[^%w]", "_")
   return getMudletHomeDir() .. "/emunah-api-" .. slug:sub(-60) .. ".json"
end

--- Fetch a URL. `onDone(body)` or `onFail(reason)`; exactly one of them, exactly once.
function M.request(url, onDone, onFail)
   if not M.enabled then onFail("the web API is off") return false end

   local handle = M.canGetHTTP() and url or tmpPath(url)
   if pending[handle] then
      onFail("already in flight")
      return false
   end

   pending[handle] = {
      onDone = onDone,
      onFail = onFail,
      -- Without this, one dropped response wedges the queue permanently: `inflight` never
      -- clears and every later lookup sits behind it forever.
      timer = later(M.TIMEOUT, function()
         settle(handle, false, "timed out after " .. M.TIMEOUT .. "s")
      end),
   }

   M.counters.sent = M.counters.sent + 1
   if M.canGetHTTP() then
      getHTTP(url)
   else
      downloadFile(handle, url)
   end
   return true
end

event.register("sysGetHttpDone", function(_, url, body)
   settle(url, true, body)
end, "namedb-api")

event.register("sysGetHttpError", function(_, response, url)
   -- A "Character not found" is an HTTP 403 and arrives here, not as a body. That is a
   -- perfectly good answer to the question "is this a character", so it is reported as a
   -- normal failure rather than logged as a fault.
   settle(url, false, tostring(response))
end, "namedb-api")

event.register("sysDownloadDone", function(_, path)
   if not pending[path] then return end
   local file = io.open(path, "r")
   if not file then settle(path, false, "downloaded file could not be opened") return end
   local body = file:read("*a")
   file:close()
   settle(path, true, body)
end, "namedb-api")

event.register("sysDownloadError", function(_, reason, path)
   settle(path, false, tostring(reason))
end, "namedb-api")

-- ---------------------------------------------------------------------------
-- the queue
-- ---------------------------------------------------------------------------

local function pump()
   if M.inflight or #M.queue == 0 or not M.enabled then return end

   local job = table.remove(M.queue, 1)
   M.inflight = job

   local function finish()
      M.inflight = nil
      -- Space the next one out rather than firing it from inside this callback. The point
      -- is the interval between requests LEAVING, not between them arriving.
      later(M.INTERVAL, pump)
   end

   M.request(job.url,
      function(body)
         local data, why = M.decode(body)
         finish()
         if not data then
            M.counters.failed = M.counters.failed + 1
            job.onFail(why or "unreadable response")
         elseif data.error then
            M.counters.missing = M.counters.missing + 1
            job.onFail((data.error.message) or "not found")
         else
            M.counters.ok = M.counters.ok + 1
            job.onDone(data)
         end
      end,
      function(reason)
         finish()
         -- An HTTP 403 IS the "no such character" answer; see the header.
         if tostring(reason):find("403") then
            M.counters.missing = M.counters.missing + 1
         else
            M.counters.failed = M.counters.failed + 1
         end
         job.onFail(tostring(reason))
      end)
end

--- Put a URL on the queue. Nothing goes out immediately; see pump().
function M.enqueue(url, onDone, onFail)
   -- Collapse duplicates. Twelve people walking into a room produce twelve Room.Players
   -- events, and without this each one re-queues the same eleven names.
   for _, job in ipairs(M.queue) do
      if job.url == url then return false end
   end
   if M.inflight and M.inflight.url == url then return false end

   M.queue[#M.queue + 1] = { url = url, onDone = onDone or function() end,
                             onFail = onFail or function() end }
   pump()
   return true
end

function M.pending()
   return #M.queue + (M.inflight and 1 or 0)
end

-- ---------------------------------------------------------------------------
-- characters
-- ---------------------------------------------------------------------------

local function cacheKey(name)
   return util.trim(tostring(name or "")):lower()
end

--- A cached character, or nil. `false` means "cached as not a character".
---
--- Written out as ifs, not as `age < TTL and false or nil`. That idiom cannot express this
--- function: `x and false or nil` evaluates to nil for EVERY value of x, so a cached miss
--- reported as "never asked", every lookup was retried, and the negative cache -- the whole
--- reason a mis-resolved honorific is not re-asked forever -- did nothing at all.
function M.cached(name)
   local entry = M.cache[cacheKey(name)]
   if not entry then return nil end
   local age = util.now() - entry.at

   if entry.miss then
      if age < M.MISS_TTL then return false end
      return nil
   end
   if age < M.TTL then return entry.data end
   return nil
end

--- Fetch one character. Serves the cache when it can, and calls back either way.
--- @param onDone function|nil receives the decoded table
--- @param onFail function|nil receives a reason string
--- @param force boolean|nil ignore the cache
function M.character(name, onDone, onFail, force)
   local id = cacheKey(name)
   if id == "" then if onFail then onFail("no name") end return false end

   if not force then
      local hit = M.cached(id)
      if hit then
         M.counters.served = M.counters.served + 1
         if onDone then onDone(hit) end
         return true
      end
      if hit == false then
         if onFail then onFail("not a character") end
         return false
      end
   end

   return M.enqueue(M.HOST .. "/characters/" .. id .. ".json",
      function(data)
         M.cache[id] = { at = util.now(), data = data }
         if onDone then onDone(data) end
      end,
      function(reason)
         -- Only a definite "not found" is cached as a miss. A timeout or a DNS failure
         -- says nothing about whether the character exists, and caching it as a miss
         -- would blacklist a real person for a day over a dropped packet.
         if tostring(reason):find("not found") or tostring(reason):find("403") then
            M.cache[id] = { at = util.now(), miss = true }
         end
         if onFail then onFail(reason) end
      end)
end

--- Everyone online, from `/characters.json`.
---
--- One request for the entire roster, which is what makes resolving a honorific out of a CW
--- or CLWHO listing cheap: the set of possible names is small, known, and already in hand.
function M.roster(onDone, onFail, force)
   if not force and M.onlineAt and (util.now() - M.onlineAt) < M.ONLINE_TTL then
      if onDone then onDone(M.online) end
      return true
   end

   return M.enqueue(M.ONLINE,
      function(data)
         local fresh = {}
         for _, entry in ipairs(data.characters or {}) do
            if entry.name then fresh[tostring(entry.name):lower()] = tostring(entry.name) end
         end
         M.online, M.onlineAt = fresh, util.now()
         if onDone then onDone(M.online) end
      end,
      onFail)
end

--- Is this name online, according to the last roster we pulled? nil when we have not asked
--- recently enough to have an opinion.
function M.isOnline(name)
   if not M.onlineAt then return nil end
   return M.online[cacheKey(name)] ~= nil
end

-- ---------------------------------------------------------------------------
-- mapping the payload onto a record
-- ---------------------------------------------------------------------------

--- The API's own spelling of "we do not know" / "there is none".
local function present(value)
   if value == nil then return nil end
   local text = util.trim(tostring(value))
   if text == "" or text == "(none)" or text == "None" then return nil end
   return text
end

--- API key -> the record field it fills, and how.
---
--- Kept as a table rather than a run of if-statements so that the set of fields the API can
--- write is inspectable -- which matters, because everything NOT in this table is the
--- user's and is never overwritten by a fetch.
M.MAPPING = {
   { from = "fullname",      to = "fullname" },
   { from = "class",         to = "class" },
   { from = "city",          to = "city" },
   { from = "house",         to = "house" },
   { from = "level",         to = "level",       number = true },
   { from = "xp_rank",       to = "xprank",      number = true },
   { from = "explorer_rank", to = "explorerrank", number = true },
   -- Left as text on purpose: observed as "451k" for a high-kill character, and a
   -- tonumber() of that is 451, which is off by three orders of magnitude and looks
   -- perfectly plausible in a roster.
   { from = "mob_kills",     to = "mobkills" },
   { from = "player_kills",  to = "playerkills" },
}

--- Write a decoded payload onto a record.
---
--- WHAT THIS IS ALLOWED TO OVERWRITE is the whole question. The API is authoritative for
--- what it carries -- someone's city today beats the city we recorded a month ago -- so
--- those fields are replaced outright. Everything the API does not carry is judgement or
--- observation of ours (`iff`, notes, importance, mark, infamy, dragon, highlight) and is
--- never touched by a fetch.
--- @return table|nil record, number fields written
function M.apply(data)
   if type(data) ~= "table" or not data.name then return nil, 0 end
   local ndb = emunah.namedb

   local person = ndb.record(data.name)
   if not person then return nil, 0 end

   -- The API's spelling of the name wins. It is the character's own.
   person.name = tostring(data.name)

   local written = 0
   for _, map in ipairs(M.MAPPING) do
      local value = present(data[map.from])
      if value ~= nil then
         local ok = ndb.set(person.name, map.to, value)
         if ok then written = written + 1 end
      elseif map.clears then
         person[map.to] = nil
      end
   end

   person.api = { at = util.now(), ok = true }
   ndb.save()
   -- A city, house or order may have just become known, and with it whether they are an
   -- enemy. presences.lua re-judges the latest angel scan on this.
   emunah.event.raise("namedb.updated", person.name)
   return person, written
end

--- Fetch a character and write them into the database.
--- @param onDone function|nil receives (record, fieldsWritten)
function M.enrich(name, onDone, force)
   return M.character(name, function(data)
      local person, written = M.apply(data)
      if onDone then onDone(person, written) end
   end, function(reason)
      -- Record the failure on the record when there is one, so `whois` can say "we asked
      -- and there is nothing" rather than looking like it never tried.
      local person = emunah.namedb.get(name)
      if person then person.api = { at = util.now(), ok = false, why = tostring(reason) } end
      if onDone then onDone(nil, 0, reason) end
   end, force)
end

--- Should we go and look this person up?
---
--- The gate for the automatic path. Deliberately conservative: never for ourselves, never
--- for a record we refreshed recently, and never when the queue has already backed up --
--- walking a busy area should not build an hour-long tail of requests.
function M.wants(name)
   if not M.enabled then return false end
   local ndb = emunah.namedb
   if ndb.isSelf(name) then return false end
   if M.pending() > 40 then return false end

   local person = ndb.get(name)
   if not person then return true end
   if person.api and person.api.ok and (util.now() - person.api.at) < M.TTL then
      return false
   end
   -- A recent definite failure is not retried; see the miss cache.
   if M.cached(name) == false then return false end
   if person.api and not person.api.ok and (util.now() - person.api.at) < 300 then
      return false
   end
   return true
end

function M.status()
   return {
      enabled  = M.enabled,
      transport = M.canGetHTTP() and "getHTTP" or "downloadFile",
      queued   = #M.queue,
      inflight = M.inflight and M.inflight.url or nil,
      cached   = util.count(M.cache),
      online   = M.onlineAt and util.count(M.online) or nil,
      onlineAge = M.onlineAt and (util.now() - M.onlineAt) or nil,
      counters = M.counters,
   }
end

return M

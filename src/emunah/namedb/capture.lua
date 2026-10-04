--- Mining names out of the game's own listings.
---
--- Every pattern here is written against verbatim output in docs/game/help/who-listings.txt
--- and nothing else. Read that file before changing any of them.
---
--- THE HARD PART IS NOT THE PARSE, IT IS THE NAME
--- ----------------------------------------------
--- CW and CLWHO list HONORIFIC fullnames, and the character's actual name sits at no fixed
--- position inside one. From a single real CW listing:
---
---     Saemora, of Targossas                          -> first word
---     Seeker Kaellyn, Oathsworn of Targossas         -> second word
---     Lady Sultana Erishka Khalimat, Auroran Knight  -> third word
---     'The' Mistell Magnet, Thelek Ar'kena           -> AFTER the comma
---     Khaalis Saibel Aristata                        -> middle word, no comma at all
---
--- There is no rule to find. Slicing on the comma, taking the first word, taking the last
--- word before the comma -- each of those is right about half the time, which is the worst
--- possible outcome: a database that looks populated and has invented people called Lady,
--- Seeker and Knight.
---
--- So this module never slices. It generates CANDIDATES (every capitalised word) and then
--- resolves them against a set of names that are known to be real:
---
---   1. names already in the database, then
---   2. `https://api.achaea.com/characters.json` -- the whole online roster in one request,
---      which is exactly the population a who-listing draws from, then
---   3. as a last resort and rate-limited, asking the API about a single candidate and
---      accepting it only if the fullname it returns matches the line we are looking at.
---
--- Anything still unresolved is REMEMBERED AND REPORTED (`emunah ndb capture`) rather than
--- guessed at. An honest gap prompts a question; a guess ships a bug.

local M = {}

local util  = emunah.util
local log   = emunah.log
local event = emunah.event

local function api() return emunah.namedb.api end
local function ndb() return emunah.namedb end

--- Fullnames we saw and could not turn into a name. Shown by `emunah ndb capture`.
M.unresolved = {}

M.counters = { lines = 0, resolved = 0, unresolved = 0, records = 0 }

-- ---------------------------------------------------------------------------
-- resolving a name out of a honorific
-- ---------------------------------------------------------------------------

--- Words that are capitalised in a honorific and are never a character name.
---
--- This is an optimisation, not a correctness measure -- a word on this list that IS
--- somebody's name still resolves, because resolution checks the database and the online
--- roster before it ever consults this. It exists to stop the last-resort API probe from
--- spending requests on "Lady" forty times an hour.
local NEVER = util.set({
   "The", "Of", "A", "An", "And", "To", "In", "On", "For",
   "Lady", "Lord", "Sir", "Ser", "Dame", "Seeker", "Unsworn", "Knight", "Commander",
   "Director", "Hierophant", "Magelord", "Aspiring", "Champion", "Tiny", "Toad", "Frog",
   "Friendliest", "Leviathan", "Bait", "Retired", "Candidate", "Redemption", "Oathsworn",
   "Justiciar", "Nine", "Vows", "Auroran", "Caefir", "Targossas", "Ashtan", "Cyrene",
   "Eleusis", "Hashan", "Mhaldor", "Citizen", "Rank", "Class", "On", "Off",
})

--- Capitalised words in a line, longest-first.
---
--- Longest-first because a real name is usually the longest capitalised token on the line,
--- so the last-resort probe spends its one request on the likeliest candidate.
function M.candidates(text)
   local seen, out = {}, {}
   for word in tostring(text or ""):gmatch("%a[%a']*") do
      -- Trailing possessives and the apostrophes inside surnames ("Ar'kena", "Si'Talvace")
      -- are stripped: a character name is plain letters.
      local plain = word:gsub("'.*$", "")
      if #plain >= 2 and plain:match("^%u%l") and not seen[plain] and not NEVER[plain] then
         seen[plain] = true
         out[#out + 1] = plain
      end
   end
   table.sort(out, function(a, b)
      if #a ~= #b then return #a > #b end
      return a < b
   end)
   return out
end

--- Resolve a honorific to a character name using only what we already hold.
--- @return string|nil name, table candidates that were tried
function M.resolve(text)
   local candidates = M.candidates(text)
   for _, candidate in ipairs(candidates) do
      if ndb().known(candidate) then return candidate, candidates end
   end
   for _, candidate in ipairs(candidates) do
      local canonical = api().online[candidate:lower()]
      if canonical then return canonical, candidates end
   end
   return nil, candidates
end

--- Does an API fullname match the one we read off the screen?
---
--- CW truncates with a literal "..." at the column width, so an exact comparison fails on
--- precisely the long names that are hardest to resolve any other way. Compare on the
--- surviving prefix instead.
function M.fullnameMatches(seen, fromApi)
   seen, fromApi = util.trim(seen), util.trim(fromApi)
   if seen == "" or fromApi == "" then return false end
   if seen == fromApi then return true end
   local head = seen:match("^(.-)%.%.%.$")
   if head and head ~= "" then
      return fromApi:sub(1, #head) == head
   end
   return false
end

--- The last resort: ask the API about one candidate and accept it only if the fullname it
--- returns is the one we are looking at. Costs a request, so it is used sparingly and only
--- after the roster has failed.
local function probe(fullname, candidates, onResolved)
   local index = 0
   local function attempt()
      index = index + 1
      local candidate = candidates[index]
      if not candidate then
         M.unresolved[fullname] = util.now()
         M.counters.unresolved = M.counters.unresolved + 1
         return
      end
      api().character(candidate, function(data)
         if data.fullname and M.fullnameMatches(fullname, data.fullname) then
            api().apply(data)
            M.counters.resolved = M.counters.resolved + 1
            if onResolved then onResolved(tostring(data.name)) end
         else
            attempt()
         end
      end, attempt)
   end
   -- Only the two likeliest candidates are ever probed. A five-word honorific would
   -- otherwise cost five requests to learn one name.
   attempt()
end

--- Turn a honorific into a record, going as far as it has to.
--- @param onResolved function|nil receives the resolved name
function M.record(fullname, onResolved)
   fullname = util.trim(fullname)
   if fullname == "" then return end

   local name, candidates = M.resolve(fullname)

   -- No capitalised word that could be anybody. A custom prompt, a rule of dashes, a blank
   -- -- lines a collector may see at the edges of a listing. Not a failure to resolve, and
   -- recording it as one would fill the unresolved report with noise and spend API requests
   -- probing for a character called "You".
   if #candidates == 0 then return end

   -- Our own entry in our own city's roster. Every consumer of this database wants "other
   -- people", and a record of ourselves would sit in every roster, be counted in every
   -- total, and be the one name the highlighter is specifically built never to touch.
   if name and ndb().isSelf(name) then return end

   M.counters.lines = M.counters.lines + 1
   if name then
      M.counters.resolved = M.counters.resolved + 1
      local person = ndb().seen(name, fullname)
      if person then M.counters.records = M.counters.records + 1 end
      M.enrich(name)
      if onResolved then onResolved(name) end
      return
   end

   -- Nothing known matched. Pull the online roster -- one request for the whole
   -- population -- and try again before spending anything per-candidate.
   api().roster(function()
      local retry = M.resolve(fullname)
      if retry then
         M.counters.resolved = M.counters.resolved + 1
         ndb().seen(retry, fullname)
         M.enrich(retry)
         if onResolved then onResolved(retry) end
      else
         probe(fullname, { candidates[1], candidates[2] }, onResolved)
      end
   end, function()
      probe(fullname, { candidates[1], candidates[2] }, onResolved)
   end)
end

--- Queue an API lookup for a name, if it is worth one.
function M.enrich(name)
   if not emunah.config.get("namedb.autoFetch", true) then return false end
   if not api().wants(name) then return false end
   return api().enrich(name)
end

-- ---------------------------------------------------------------------------
-- the rolling line buffer
-- ---------------------------------------------------------------------------
--
-- QW has no header line, so the start of its name list cannot be detected as it arrives --
-- only its terminator can ("Plus another 8 whose presence you cannot fully sense"). The
-- buffer lets that terminator read BACKWARDS over the lines that preceded it.
--
-- Deliberately small. This is not a scrollback; it is just enough to hold the longest
-- wrapped QW output plausibly seen on a busy day.

-- A RING, not a queue, and the difference is measurable. This fills on every line of game
-- output -- it is behind a bare `^` trigger, which is the whole point of it -- and the
-- previous shape was:
--
--    M.buffer[#M.buffer + 1] = line
--    while #M.buffer > M.BUFFER do table.remove(M.buffer, 1) end
--
-- `table.remove(t, 1)` shifts every remaining element down one. So steady state was a
-- sixteen-element memmove per line, forever, to maintain a buffer only the QW terminator
-- ever reads. A write cursor modulo the size does the same job with one store.
--
-- The cost of that is that M.buffer is no longer in arrival order once it has wrapped, so
-- nothing may index it directly any more -- M.recent() below is the only way in.
M.BUFFER = 16
M.buffer = {}

--- How many lines have EVER been remembered. Not the buffer length: it is what turns "the
--- nth most recent" into a slot, and it keeps counting past M.BUFFER.
local written = 0

local function remember(line)
   written = written + 1
   M.buffer[(written - 1) % M.BUFFER + 1] = line
end

--- The nth-most-recent line, 1 being the one that just arrived; nil past what we still hold.
function M.recent(n)
   if type(n) ~= "number" or n < 1 or n > M.BUFFER or n > written then return nil end
   return M.buffer[(written - n) % M.BUFFER + 1]
end

--- Drop everything remembered so far.
---
--- Exists so nothing has to reach in and assign `M.buffer = {}`, which USED to be a
--- perfectly good reset and is now half of one: it empties the slots but leaves the write
--- cursor where it was, so the next M.recent() walk reads holes.
function M.forgetLines()
   M.buffer = {}
   written = 0
end

-- ---------------------------------------------------------------------------
-- collectors
-- ---------------------------------------------------------------------------
--
-- CW and CLWHO are both "a header, then N body lines, then something that is not a body
-- line". A collector is armed by the header and disarmed by the first line the body pattern
-- refuses, which is self-delimiting and needs no timer.

M.active = nil   -- { kind, count, clan, matched, misses, tolerance }

--- How many consecutive non-body lines a listing may contain before it is considered over.
---
--- CW needs one: there is a rule of dashes between its header and its first row. CLWHO has
--- no such line -- the first member follows the header directly -- so it gets none, and
--- that matters, because its row pattern is necessarily loose ("a line beginning with a
--- capitalised word") and a generous tolerance would let it swallow whatever the game
--- printed next.
--- HONOURS gets three: its optional lines are not all recognised, and two unrecognised ones
--- in a row is normal ("She has been divorced once." / "She bears the arms: ...") right
--- before the line that finally names the subject. Ending the block there would discard the
--- whole thing. It is disarmed explicitly by the DEEDS line in the ordinary case, so this
--- tolerance only ever matters when that line is absent.
local TOLERANCE = { cw = 1, clwho = 0, honours = 3 }

local function arm(kind, extra)
   M.active = { kind = kind, count = 0, matched = true, misses = 0,
                tolerance = TOLERANCE[kind] or 0 }
   for key, value in pairs(extra or {}) do M.active[key] = value end
end

local function disarm()
   if not M.active then return end
   local was = M.active
   M.active = nil
   log.debug("namedb capture: %s listing ended, %d entries", was.kind, was.count)
   emunah.event.raise("emunah.namedb.captured", was.kind, was.count)
end

--- `Citizen   Rank CT  Class` -- the CW header. Anchored on all four column titles so an
--- ordinary line of prose containing the word "Citizen" cannot arm the collector.
local CW_HEADER = [[^Citizen\s+Rank\s+CT\s+Class\s*$]]

--- A CW body row: a fullname, then rank, then the CT column, then the class.
---
--- The fullname group is lazy and the rank is anchored to the run of padding that follows,
--- so the column gap cannot be eaten into the name.
---
--- The CT column is captured as `\S+` rather than as `(On|Off)`, and the fullname is
--- unbounded rather than `{2,60}`. Both are avoidable PCRE-isms, and avoiding them keeps
--- this pattern expressible as a Lua pattern too -- which is what test/mock_mudlet.lua has
--- to translate it into. A pattern that only works in Mudlet is a pattern no test can hold
--- to account. Nothing is read out of the CT column regardless: its meaning has not been
--- established. See docs/game/help/who-listings.txt.
local CW_ROW = [[^(.+?)\s\s+(\d+)\s+(\S+)\s+(\w+)\s*$]]

--- The CLWHO header. Captures the clan, which is a real fact worth storing.
local CLWHO_HEADER = [[^The following members of the clan of (.+) are in the realms:\s*$]]

--- A CLWHO body row: a fullname, sometimes trailed by "(off channel)".
---
--- The leading `[A-Z][a-z]` is not decoration. `^[A-Z]` alone also matches a custom prompt
--- ("H:100% M:100% ..."), which would be read as a clan member on the line immediately
--- after the listing -- the exact place this pattern is most likely to be tested.
---
--- The "(off channel)" suffix is stripped in code rather than made an optional group. An
--- optional GROUP is PCRE-only; Lua patterns can make a character optional but not a
--- parenthesised run, and a pattern the mock cannot translate is one no test can exercise.
local CLWHO_ROW = [[^([A-Z][a-z].*)$]]
local OFF_CHANNEL = "%s*%(off channel%)%s*$"

--- The QW terminator. The only unambiguous landmark that output has.
local QW_END = [[^Plus another (\d+) whose presence you cannot fully sense \((\d+) total\)\.\s*$]]

-- HONOURS
--
-- The richest source here, and the only one that carries might, age and race at all. It is
-- also the only one where the character's NAME appears nowhere until the very last line:
--
--     Khalayx, Tzin Ahuacatl (male Grook).        <- name first
--     Khaalis Saibel Aristata (female Mhun).      <- name in the middle
--     ...
--     See HONOURS DEEDS KHALAYX to view his 26 special honours.   <- unambiguous, capitals
--
-- So the block is buffered and applied when that last line names its subject. Every body
-- line begins with the subject's pronoun, which is why the patterns below start at `\w+`
-- rather than trying to alternate He/She -- alternation is a PCRE-ism the test mock cannot
-- translate, and a pattern no test can exercise is a pattern that works until it doesn't.

local HONOURS_HEADER = [[^(.+) \((\w+) (\w+)\)\.\s*$]]
--- Six literal dashes and then one-or-more, rather than `-{6,}`. A bounded quantifier is a
--- PCRE-ism with no Lua-pattern equivalent, so `{6,}` would be matched as literal braces by
--- the test mock: the rule never confirms, the block is never read, and every HONOURS
--- lookup silently records nothing while working perfectly in Mudlet.
local HONOURS_RULE   = [[^------+\s*$]]
local HONOURS_DEEDS  = [[^See HONOURS DEEDS ([A-Z]+) to view \w+ (\d+) special honours\.]]

--- Body lines, each mapped to what it means. Order matters only in that the first match
--- wins, so nothing here may be a prefix of anything below it.
local HONOURS_LINES = {
   { pattern = "^%a+ is (%d+) years old", field = "age" },
   { pattern = "^%a+ is ranked (%d+)%a* in Achaea%.", field = "xprank" },
   { pattern = "^%a+ is an? (.+) character%.", field = "credibility" },
   { pattern = "^%a+ is a member of the (%a+) class%.", field = "class" },
   { pattern = "^%a+ is considered to be approximately (%d+)%% of your might%.",
     field = "might" },
   { pattern = "^%a+ motto: '(.+)'%s*$", field = "motto" },

   -- "not known for acts of infamy" is unambiguous and means none. The POSITIVE wording
   -- has never been observed, so there is deliberately no pattern claiming to match it --
   -- a guess here would mark innocents infamous.
   { pattern = "^%a+ is not known for acts of infamy%.", field = "infamy", value = 0 },
   { pattern = "^%a+ is a mentor and able to take on proteges%.",
     field = "mentor", value = true },
}

--- The guardian angel's report.
---
--- ANCHORED AT THE START, and that is load-bearing rather than tidiness. The real line wraps
--- and its continuation carries a parenthesised list of numbers and a city name that is NOT
--- to be read -- see docs/game/help/who-listings.txt. Anchoring here means the continuation
--- cannot match this pattern at all, whatever it happens to contain.
---
--- The mana figure is OPTIONAL. In play the line breaks right after "a mana of" (2026-10-03,
--- with every script off: "...on a health of 9407 and a mana of" / "7233."), and requiring
--- the number lost the whole sighting -- name, room and health -- for want of the mana.
local ANGEL = [[^Your guardian angel senses ([A-Z][a-z]+) at (.+?), on a health of (\d+) and a mana of\s*(\d*)]]

-- ---------------------------------------------------------------------------
-- handling a line
-- ---------------------------------------------------------------------------

--- CW gives a city rank and a class that the web API does not carry, so it is genuinely
--- additive rather than a slower way of getting what a fetch would give anyway.
---
--- It does NOT set a city. A bare CW is only known to list our own city, `CW <othercity>`
--- has never been observed to be legal syntax, and writing everyone in the listing into our
--- own city on that assumption is precisely the class of guess this project does not make.
function M.cwRow(fullname, rank, class)
   M.active.count = M.active.count + 1
   M.record(fullname, function(name)
      ndb().set(name, "cityrank", rank)
      ndb().set(name, "class", class)
   end)
end

function M.clwhoRow(fullname, clan)
   M.active.count = M.active.count + 1
   fullname = tostring(fullname):gsub(OFF_CHANNEL, "")
   M.record(fullname, function(name)
      if clan then ndb().set(name, "clan", clan) end
   end)
end

--- Read the QW list backwards from its terminator.
---
--- Walks up through the buffer taking lines that are made only of comma-separated
--- capitalised words, and stops at the first line that is not one. That is what makes it
--- safe without a header: a line of ordinary prose fails the shape test, so the walk cannot
--- run off the top of the listing into whatever was on screen before it.
function M.qwTail()
   -- Start ABOVE the terminator. The ring buffer is filled before any listing pattern runs,
   -- so the "Plus another N..." line that triggered this is itself the last entry -- and it
   -- fails the shape test, which ended the walk immediately and read nothing at all.
   --
   -- Counted back through M.recent() rather than indexed into M.buffer: the buffer is a ring
   -- and its slot order is not arrival order once it has wrapped.
   local names, back = {}, 2
   while true do
      local line = M.recent(back)
      if not line then break end
      -- "Aeowynn, Akri, ... Erishka," or "... and Zargoth."
      if line:match("^%s*%u%a+[%a,%s'-]*[.,]?%s*$") and line:find(",") then
         for word in line:gmatch("%u%a+") do
            if word ~= "Plus" then names[#names + 1] = word end
         end
         back = back + 1
      else
         break
      end
   end

   for _, name in ipairs(names) do
      if not ndb().isSelf(name) then
         ndb().seen(name)
         M.enrich(name)
      end
   end
   M.counters.records = M.counters.records + #names
   emunah.event.raise("emunah.namedb.captured", "qw", #names)
   return #names
end

--- Read one HONOURS body line into the pending block.
---
--- A line that matches nothing is KEPT VERBATIM rather than dropped. Several real lines
--- carry meaning nobody has established -- "He is one of The Dauntless.", "She is a
--- Dominion in Mhaldor." -- and the choice is between guessing at them and losing them.
--- Keeping the text does neither: the dossier shows it under a heading that says plainly it
--- has not been interpreted, and the user can read what the game said.
function M.honoursLine(line)
   local pending = M.active
   if not (pending and pending.kind == "honours") then return false end

   for _, rule in ipairs(HONOURS_LINES) do
      local captured = line:match(rule.pattern)
      if captured then
         pending.fields[rule.field] = rule.value ~= nil and rule.value or captured
         pending.matched = true
         return true
      end
   end

   -- EVERY body line begins with the subject's pronoun -- see the observed output in
   -- docs/game/help/who-listings.txt. That is what separates a real statement about them
   -- from a wrapped continuation of the line above: the birth sentence wraps onto a second
   -- line reading "Seleucarian Empire.", which is not a fact about anybody and must not be
   -- kept as one. The pronoun is known because the header gave us the subject's sex.
   local first = line:match("^(%a+) ")
   if first and pending.pronouns[first] then
      pending.rest[#pending.rest + 1] = util.trim(line)
      pending.matched = true
      return true
   end
   return false
end

--- Apply a finished HONOURS block to a name.
function M.honoursApply(name, pending)
   local person = ndb().record(name)
   if not person then return false end

   if pending.fullname then ndb().set(name, "fullname", pending.fullname) end
   if pending.sex then ndb().set(name, "sex", pending.sex) end
   if pending.race then ndb().set(name, "race", pending.race) end
   for field, value in pairs(pending.fields) do
      ndb().set(name, field, value)
   end
   if pending.deeds then ndb().set(name, "deeds", pending.deeds) end

   -- Verbatim, uninterpreted. Replaced wholesale rather than appended: this is the game's
   -- current answer about this person, not a log of every time we asked.
   person.honours = pending.rest
   person.honoursAt = util.now()

   ndb().touch()
   M.counters.records = M.counters.records + 1
   emunah.event.raise("emunah.namedb.honours", name)
   return true
end

--- Where someone was, the last time an angel found them.
---
--- Stored on the record rather than merely logged: "seen at Fish Street on 6831 health four
--- seconds ago" is the single most actionable thing this database can hold, and it is the
--- reason the angel line is worth a pattern at all.
function M.sensed(name, where, health, mana)
   local person = ndb().record(name)
   if not person then return end
   person.sensed = {
      at = util.now(), where = util.trim(where),
      health = tonumber(health), mana = tonumber(mana),
   }
   person.seen = util.now()
   M.enrich(name)
   ndb().save()
   -- event.raise() adds the "emunah." itself; this used to pass it too, and so raised
   -- "emunah.emunah.namedb.sensed", which nothing could listen for.
   emunah.event.raise("namedb.sensed", name, person.sensed)
end

-- ---------------------------------------------------------------------------
-- triggers
-- ---------------------------------------------------------------------------

local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.captureTriggers = emunah._persist.captureTriggers or {}
   return emunah._persist.captureTriggers
end

function M.killAll()
   local n = 0
   for _, id in ipairs(registry()) do
      if killTrigger(id) then n = n + 1 end
   end
   emunah._persist.captureTriggers = {}
   return n
end

local function keep(id)
   if id then table.insert(registry(), id) end
   return id
end

-- ---------------------------------------------------------------------------
-- CITY ENEMIES
-- ---------------------------------------------------------------------------
--
-- Verbatim, 19:29:26.17 on 2026-10-04:
--
--   Enemies of the Radiant Nation of Targossas:
--   Khaseem, Ziel, Erikarn, Jems, Proficy, Fitz, Theosis, Accipiter, Shecks, Imyrr, Naz, Paine,
--   Dochitha, Saibel, ...
--   ..., Aletheia, Luz, Kralik, Vostyr, Hoyt
--   Total: 95
--
-- Names, comma-separated, wrapped by the game; a wrapped line ends in a comma. Read only
-- after you typed CITY ENEMIES, so the header in a tell or an illusion does nothing, and
-- the total is the check: a listing that does not add up flags who it named and clears no
-- one, since the names it missed would otherwise be cleared.

--- The enemy listing being read: { names = {...} }, or nil.
M.enemies = nil

--- How long after CITY ENEMIES goes out its header is believed.
M.ENEMIES_WINDOW = 10

function M.enemiesHeader()
   local outgoing = emunah.outgoing
   if not (outgoing and outgoing.sentRecently("^city enemies$", M.ENEMIES_WINDOW)) then return end
   M.enemies = { names = {} }
end

--- One line of the listing: names, the total, or the end of it.
function M.enemiesLine(line)
   local listing = M.enemies
   if not listing then return end
   local total = line:match("^Total: (%d+)%s*$")
   if total then
      M.enemies = nil
      total = tonumber(total)
      local complete = total == #listing.names
      if not complete then
         log.warn("CITY ENEMIES says %d and %d were read -- flagging those, clearing no one.",
            total, #listing.names)
      end
      local added, cleared = ndb().setCityEnemies(listing.names, complete)
      log.info("City enemies: %d (%d new, %d no longer).", #listing.names, added, cleared)
      return
   end
   local names = {}
   for piece in (line .. ","):gmatch("([^,]*),") do
      piece = util.trim(piece)
      if piece ~= "" then
         if not piece:match("^%u%l+$") then
            -- Not a line of names: the listing ended without its total. Nothing applied.
            M.enemies = nil
            return
         end
         names[#names + 1] = piece
      end
   end
   for _, name in ipairs(names) do listing.names[#listing.names + 1] = name end
end

M.killAll()

-- REGISTRATION ORDER IS THE CONTROL FLOW. Mudlet fires triggers in the order they were
-- created, so the three phases below have to be registered in this order and no other:
--
--   1. remember the line, before anything can act on it (QW is read backwards out of it)
--   2. the listing patterns, which set `matched` when the line belonged to a listing
--   3. the accounting pass, which can only decide "that line was not part of the listing"
--      AFTER phase 2 has had its chance to say otherwise
--
-- Written the other way round, the accounting pass judges the PREVIOUS line, and a CW
-- listing is abandoned at its rule of dashes before a single citizen is read.

--- Checked inside every handler rather than around the registration below.
---
--- Gating the registration would make `namedb.capture` a setting that appears to work and
--- does nothing until a reload -- the trigger set is built once, at load, and a config
--- change afterwards cannot reach it. Reading the flag per line costs a table lookup and
--- makes the toggle mean what it says.
M.enabled = emunah.config.get("namedb.capture", true)

function M.setEnabled(on)
   M.enabled = on and true or false
   emunah.config.set("namedb.capture", M.enabled)
   if not M.enabled then M.active = nil end
   return M.enabled
end

do
   keep(tempRegexTrigger([[^]], function()
      if not M.enabled then return end
      local line = getCurrentLine()
      if type(line) == "string" then remember(line) end
   end))

   keep(tempRegexTrigger(CW_HEADER, function()
      if not M.enabled then return end
      arm("cw")
   end))

   keep(tempRegexTrigger(CW_ROW, function()
      if not (M.active and M.active.kind == "cw") then return end
      M.active.matched = true
      M.cwRow(matches[2], matches[3], matches[5])
   end))

   keep(tempRegexTrigger(CLWHO_HEADER, function()
      if not M.enabled then return end
      arm("clwho", { clan = util.trim(matches[2]) })
   end))

   keep(tempRegexTrigger(CLWHO_ROW, function()
      if not (M.active and M.active.kind == "clwho") then return end
      M.active.matched = true
      M.clwhoRow(matches[2], M.active.clan)
   end))

   keep(tempRegexTrigger(QW_END, function()
      if not M.enabled then return end
      M.qwTail()
   end))

   -- HONOURS. The header alone is a weak signature -- any line ending in "(word word)."
   -- would match -- so it only arms a CANDIDATE, which the rule of dashes on the very next
   -- line has to confirm. Two lines together are unmistakable.
   keep(tempRegexTrigger(HONOURS_HEADER, function()
      if not M.enabled then return end
      local sex = tostring(matches[3]):lower()
      if sex ~= "male" and sex ~= "female" then return end
      arm("honours", {
         fullname = util.trim(matches[2]), sex = sex, race = matches[4],
         fields = {}, rest = {}, confirmed = false,
         pronouns = sex == "male" and { He = true, His = true }
                                   or { She = true, Her = true },
      })
   end))

   keep(tempRegexTrigger(HONOURS_RULE, function()
      if not (M.active and M.active.kind == "honours") then return end
      M.active.confirmed = true
      M.active.matched = true
   end))

   keep(tempRegexTrigger([[^]], function()
      if not (M.active and M.active.kind == "honours" and M.active.confirmed) then return end
      local line = getCurrentLine()
      if type(line) == "string" then M.honoursLine(line) end
   end))

   keep(tempRegexTrigger(HONOURS_DEEDS, function()
      local pending = M.active
      if not (pending and pending.kind == "honours") then return end
      pending.deeds = tonumber(matches[3])
      M.active = nil

      -- The name, at last, and in capitals. Nothing else in the block can be trusted to
      -- carry it, so everything gathered above has been waiting for this line.
      local name = util.capitalise(matches[2])
      if ndb().isSelf(name) then return end
      M.honoursApply(name, pending)
      M.enrich(name)
   end))

   keep(tempRegexTrigger(ANGEL, function()
      if not M.enabled then return end
      M.sensed(matches[2], matches[3], matches[4], matches[5])
   end))

   -- CITY ENEMIES: the header, then every line until the total. Not gated on
   -- namedb.capture: you typed it to have the list kept.
   keep(tempRegexTrigger([[^Enemies of (.+):$]], function() M.enemiesHeader() end))
   keep(tempRegexTrigger([[^]], function()
      if not M.enemies then return end
      if type(isPrompt) == "function" and isPrompt() then M.enemies = nil return end
      local line = getCurrentLine()
      if type(line) == "string" and not line:match("^Enemies of .+:$") then M.enemiesLine(line) end
   end))

   keep(tempRegexTrigger([[^]], function()
      if not M.active then return end
      if M.active.matched then
         M.active.misses = 0
      else
         M.active.misses = M.active.misses + 1
      end
      M.active.matched = false
      if M.active.misses > M.active.tolerance then disarm() end
   end))
end

-- ---------------------------------------------------------------------------
-- the automatic path
-- ---------------------------------------------------------------------------
--
-- Everyone who walks into the room, and everyone who speaks. namedb.lua already records
-- the sighting; this is what turns a bare name into a filled-in record.

event.register("emunah.room.players", function()
   local room = emunah.gmcp.room
   if not room then return end
   for name in pairs(room.players or {}) do
      if not ndb().isSelf(name) then M.enrich(name) end
   end
end, "namedb-capture")

event.register("emunah.comm.text", function(_, message)
   if message and message.talker and not ndb().isSelf(message.talker) then
      M.enrich(message.talker)
   end
end, "namedb-capture")

return M

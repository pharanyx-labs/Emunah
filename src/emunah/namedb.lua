--- NameDB -- who is a person, and what are they.
---
--- A record per player character: the organisations they belong to, the standing that
--- follows from those, and the handful of facts about a name that change how you treat it
--- on sight -- their class, whether they are marked, whether they outrank you badly.
---
--- WHY A DATABASE RATHER THAN A LIST
--- ---------------------------------
--- The alternative is a hand-maintained enemy list, which is wrong in both directions the
--- moment anyone changes city or the tide of a conflict turns. A record that carries WHERE
--- someone stands lets the relationship be derived, so a city change re-answers every
--- question about that person at once, and an explicit override is still available for the
--- cases judgement beats data.
---
--- WHAT IS DERIVED AND WHAT IS DECLARED
--- ------------------------------------
--- `iff` is the declaration: "ally", "enemy", or "auto". It always wins, because a name
--- known to be dangerous is not something a table lookup should be allowed to overrule.
---
--- Everything else is derived by relationship() from organisation membership against our
--- own. The ordering inside that derivation is deliberate and is documented at the
--- function -- it is the part most likely to be "simplified" into something unsafe.
---
--- WHERE THE DATA COMES FROM
--- -------------------------
--- Every source is exact, and that is a rule rather than a coincidence:
---
---   * GMCP names everyone in the room and every channel talker without ambiguity.
---   * `api.achaea.com` publishes class, city, house, level and ranks as JSON.
---   * CW, CLWHO, QW, HONOURS and the guardian angel are parsed in namedb/capture.lua,
---     each against verbatim output kept in docs/game/help/.
---   * `emunah ndb set` is the user typing a fact in.
---
--- `M.sources` lists all of them, which are implemented, and precisely what text each
--- unfinished one is still waiting on; `emunah ndb capture` prints it. What is NOT there is
--- as deliberate as what is: a pattern written from memory produces a database that looks
--- populated and is quietly wrong about who is safe to stand next to.

local M = {}

local util  = emunah.util
local log   = emunah.log
local event = emunah.event

local PATH = getMudletHomeDir() .. "/emunah-namedb.lua"

--- name (lower) -> record
M.people = {}

--- Bumped every time the SET OF NAMES changes -- a person added, forgotten, pruned,
--- imported or loaded. Not bumped when a field on an existing record changes, because
--- nothing that reads this cares about fields.
---
--- ui/names.lua compiles the whole roster into one trigger pattern and has to know when
--- that pattern is stale. A timestamp would not do: the dangerous case is a record added
--- and read back inside the same tick, and the safe answer to "did the roster change" has
--- to be exact rather than nearly. Bump at the mutation site, the same rule
--- gmcp/items.lua's `generation` follows.
M.generation = 0

local function nameSetChanged()
   M.generation = M.generation + 1
end

--- Cities, houses and orders we treat as hostile. Derived relationships read this.
M.hostile = { city = {}, house = {}, order = {} }

--- The six cities.
---
--- PROVENANCE: general knowledge, not observed play. That is a weaker source than this
--- project usually accepts, so it is confined to
--- things that cannot break: colour choice, demonyms, and tab-completion-style hints. No
--- command is ever built from this list, and an unrecognised city is stored and displayed
--- perfectly well -- it simply gets the default colour.
M.CITIES = { "Ashtan", "Cyrene", "Eleusis", "Hashan", "Mhaldor", "Targossas" }

--- Cosmetic only; see the note on M.CITIES. Singular and plural.
local DEMONYM = {
   ashtan    = { "Ashtani", "Ashtani" },
   cyrene    = { "Cyrenian", "Cyrenians" },
   eleusis   = { "Eleusian", "Eleusians" },
   hashan    = { "Hashani", "Hashani" },
   mhaldor   = { "Mhaldorian", "Mhaldorians" },
   targossas = { "Targossian", "Targossians" },
}

-- ---------------------------------------------------------------------------
-- the shape of a record
-- ---------------------------------------------------------------------------
--
-- Every field is optional. A name seen once in a room is worth recording, and a partial
-- record is worth more than none -- so nothing here is required and nothing defaults to a
-- value that would be a claim. Numeric unknowns are nil, never 0, because 0 might is a
-- real reading and "we never asked" is not.

--- Coercions. A field declares how the string a user typed becomes what we store, so
--- `emunah ndb set X dragon yes` stores a boolean and `... might 40` stores a number --
--- rather than every field being a string that later code has to guess the type of.
local COERCE = {
   string = function(v) return util.trim(tostring(v)) end,
   lower  = function(v) return util.trim(tostring(v)):lower() end,
   title  = function(v) return util.capitalise(util.trim(tostring(v))) end,

   number = function(v)
      local n = tonumber(v)
      if not n then return nil, "not a number" end
      return n
   end,

   -- Achaea's own affirmations, plus the ones anyone would actually type. Note "0" is
   -- handled explicitly: in Lua it is truthy, and a boolean field that silently reads "0"
   -- as yes is the same family of bug as util.bool() exists to prevent.
   bool = function(v)
      local s = util.trim(tostring(v)):lower()
      if s == "yes" or s == "yep" or s == "y" or s == "true" or s == "on" or s == "1" then
         return true
      end
      if s == "no" or s == "nope" or s == "n" or s == "false" or s == "off" or s == "0" then
         return false
      end
      return nil, "expected yes or no"
   end,
}

--- Ordered so the dossier and the roster can walk one list and stay in agreement about
--- what a record contains and in what order it reads.
M.FIELDS = {
   { name = "fullname", type = "string", label = "title",
     help = "the honorific form, as the game prints it" },
   { name = "class",    type = "lower",  label = "class" },
   { name = "city",     type = "title",  label = "city" },
   { name = "cityrank", type = "number", label = "city rank", min = 0, max = 6,
     help = "0 = a known citizen, 1-6 = CR1..CR6" },
   { name = "house",    type = "title",  label = "house" },
   { name = "order",    type = "title",  label = "order" },
   { name = "clan",     type = "string", label = "clan",
     help = "from CLWHO; the API does not carry it" },
   { name = "level",    type = "number", label = "level", min = 0 },
   { name = "xprank",   type = "number", label = "xp rank", min = -2,
     help = "-1 unknown, -2 unranked" },
   { name = "explorerrank", type = "number", label = "explorer rank", min = -2 },
   -- Text, not numbers. The web API abbreviates a large count as "451k", and tonumber()
   -- of that is 451 -- wrong by three orders of magnitude and entirely plausible-looking
   -- in a roster, which is the worst way for a number to be wrong.
   { name = "mobkills",    type = "string", label = "mob kills" },
   { name = "playerkills", type = "string", label = "player kills" },
   -- NOT a 0-100 scale. HONOURS says "considered to be approximately 510% of your might",
   -- so this is a RATIO AGAINST US and is routinely far above 100 -- an upper bound of 100
   -- silently rejected every real reading the game ever gave. 100 means an even match.
   { name = "might",    type = "number", label = "might", min = -1,
     help = "percent of YOUR might; 100 is even, -1 unknown" },
   { name = "sex",      type = "lower",  label = "sex" },
   { name = "race",     type = "title",  label = "race" },
   { name = "age",      type = "number", label = "age", min = 0 },
   -- The game's own words, stored verbatim and never interpreted. "extremely credible" is
   -- a point on a scale whose full range has not been observed, so turning it into a
   -- number would be inventing the scale.
   { name = "credibility", type = "string", label = "credibility" },
   { name = "mentor",   type = "bool",   label = "mentor" },
   { name = "motto",    type = "string", label = "motto" },
   { name = "deeds",    type = "number", label = "special honours", min = 0 },
   { name = "infamy",   type = "number", label = "infamy", min = -1, max = 7,
     help = "-1 unknown, 0 none, 1 nearly, 2-7 the infamy levels" },
   { name = "mark",     type = "lower",  label = "mark",
     values = { ivory = true, quisalis = true, none = "false" },
     help = "ivory, quisalis, or none" },
   { name = "dragon",   type = "bool",   label = "dragon" },
   { name = "immortal", type = "bool",   label = "immortal",
     help = "Immortal, Guide, God or Celani" },
   { name = "importance", type = "number", label = "importance",
     help = "your own priority number; the roster can sort on it" },

   -- Enemy status is a fact the game states about a person, not a marking of ours. Kept
   -- separate from `iff` for exactly that reason: one is evidence, one is judgement.
   { name = "cityenemy",  type = "bool", label = "city enemy" },
   { name = "houseenemy", type = "bool", label = "house enemy" },
   { name = "orderenemy", type = "bool", label = "order enemy" },

   { name = "highlight",  type = "bool", label = "highlight",
     help = "no to keep this name out of the highlighter" },
   { name = "iff",        type = "lower", label = "declared",
     values = { ally = true, enemy = true, auto = true } },
}

local FIELD = {}
for _, spec in ipairs(M.FIELDS) do FIELD[spec.name] = spec end
M.field = function(name) return FIELD[tostring(name or ""):lower()] end

local ORGS = { "city", "house", "order" }
local ENEMY_FLAG = { city = "cityenemy", house = "houseenemy", order = "orderenemy" }

local function key(name)
   return tostring(name or ""):lower():match("^%s*(.-)%s*$")
end

--- Coerce and validate one field's value against its spec.
--- @return any value, string|nil why it was rejected
local function coerce(spec, value)
   local converted, why = COERCE[spec.type](value)
   if converted == nil then return nil, why or "bad value" end

   if spec.values then
      local allowed = spec.values[converted]
      if allowed == nil then
         return nil, "must be one of " .. table.concat(util.keys(spec.values), ", ")
      end
      -- A named value may stand for something other than itself: `mark none` stores false.
      if allowed == "false" then return false end
   end
   if spec.min and converted < spec.min then return nil, "minimum is " .. spec.min end
   if spec.max and converted > spec.max then return nil, "maximum is " .. spec.max end
   return converted
end

-- ---------------------------------------------------------------------------
-- records
-- ---------------------------------------------------------------------------

--- The record for a name, creating an empty one if it is new.
function M.record(name)
   local id = key(name)
   if id == "" then return nil end
   if not M.people[id] then
      M.people[id] = {
         name  = util.capitalise(util.trim(tostring(name))),
         iff   = "auto",
         notes = {},
         seen  = util.now(),
         first = os.time(),
      }
      nameSetChanged()
      -- The whole point of the fix: a name we merely SAW is worth keeping.
      M.touch()
   end
   return M.people[id]
end

--- The record for a name, or nil. Read-only lookups use this so a typo does not silently
--- create an entry.
function M.get(name)
   return M.people[key(name)]
end

function M.known(name)
   return M.get(name) ~= nil
end

--- Note that we have seen this person, wherever we saw them.
--- @param fullname string|nil the honorific form, when the source carries one
function M.seen(name, fullname)
   local person = M.record(name)
   if not person then return nil end
   person.seen = util.now()
   person.sightings = (person.sightings or 0) + 1
   if fullname and fullname ~= "" then person.fullname = util.trim(tostring(fullname)) end
   M.touch()
   return person
end

--- Set one field. Returns false for a field this record does not carry, rather than
--- silently storing something nothing will ever read.
--- @return boolean ok, string|nil why
function M.set(name, field, value)
   local spec = M.field(field)
   if not spec then
      return false, "unknown field " .. tostring(field) .. " (try: emunah ndb fields)"
   end

   local person = M.record(name)
   if not person then return false, "no name given" end

   -- Clearing is always allowed and always means "we do not know", never a zero value.
   if value == nil or util.trim(tostring(value)) == "" then
      person[spec.name] = nil
      if spec.name == "iff" then person.iff = "auto" end
      M.touch()
      return true
   end

   local converted, why = coerce(spec, value)
   if converted == nil and why then return false, why end

   person[spec.name] = converted
   M.touch()
   return true
end

--- Read one field, coerced. nil means "we do not know".
---
--- Written out rather than as `spec and person[spec.name] or nil`, which collapses a
--- stored `false` to nil -- and every flag on a record is exactly that: "known not to be
--- one" is a different answer from "never asked".
function M.field_of(name, field)
   local person = M.get(name)
   if not person then return nil end
   local spec = M.field(field)
   if not spec then return nil end
   return person[spec.name]
end

--- Add a note. Notes accumulate; they are the part of a record that is judgement rather
--- than data, and overwriting the last one would lose exactly that.
function M.note(name, text)
   text = util.trim(text)
   if text == "" then return false end
   local person = M.record(name)
   if not person then return false end
   person.notes = person.notes or {}
   person.notes[#person.notes + 1] = { text = text, at = os.time() }
   M.touch()
   return true
end

--- Drop one note by index, or every note when index is nil.
function M.unnote(name, index)
   local person = M.get(name)
   if not person then return false, "not in the database" end
   if not index then person.notes = {} M.touch() return true end
   index = tonumber(index)
   if not index or not (person.notes or {})[index] then return false, "no note " .. tostring(index) end
   table.remove(person.notes, index)
   M.touch()
   return true
end

--- Declare a relationship, or hand it back to derivation with "auto".
function M.iff(name, status)
   local ok, why = M.set(name, "iff", status)
   if not ok then return false, why or "iff must be ally, enemy or auto" end
   log.info("%s is now <ansi_cyan>%s<ansi_yellow>.", M.get(name).name, M.get(name).iff)
   return true
end

--- Forget one person entirely.
function M.forget(name)
   local id = key(name)
   if not M.people[id] then return false end
   M.people[id] = nil
   nameSetChanged()
   M.touch()
   return true
end

--- Forget everyone. Returns how many went, so a caller can require confirmation against a
--- real number rather than a shrug.
function M.forgetAll()
   local n = M.count()
   M.people = {}
   nameSetChanged()
   M.touch()
   return n
end

--- Drop records that are only a name.
---
--- The obvious version of this is "delete unranked", which needs an xp rank we cannot
--- read. The
--- honest version of the same idea: a record carrying nothing we did not learn from merely
--- watching someone walk past is not worth the file. Anything declared, noted, or given a
--- single fact by hand survives -- so this can never quietly discard judgement.
--- @param days number|nil also require the last sighting to be at least this old
--- @return number removed, table names
function M.prune(days)
   local cutoff = days and (util.now() - (tonumber(days) * 86400))
   local removed, names = 0, {}

   for id, person in pairs(M.people) do
      local bare = true
      for _, spec in ipairs(M.FIELDS) do
         -- fullname and highlight come from passive sighting and from the highlighter;
         -- neither is a fact anyone typed, so neither keeps a record alive.
         if spec.name ~= "fullname" and spec.name ~= "highlight" and spec.name ~= "iff"
            and person[spec.name] ~= nil then
            bare = false
            break
         end
      end
      if bare and (person.iff or "auto") ~= "auto" then bare = false end
      if bare and #(person.notes or {}) > 0 then bare = false end
      if bare and cutoff and (person.seen or 0) > cutoff then bare = false end

      if bare then
         names[#names + 1] = person.name
         M.people[id] = nil
         removed = removed + 1
      end
   end

   table.sort(names)
   if removed > 0 then nameSetChanged() end
   M.touch()
   return removed, names
end

-- ---------------------------------------------------------------------------
-- relationship
-- ---------------------------------------------------------------------------

--- Our own organisations, from Char.Status.
local function ours()
   local status = emunah.gmcp.status
   if not status then return {} end
   return {
      city  = status.get and status.get("city"),
      house = status.get and status.get("house"),
      order = status.get and status.get("order"),
   }
end

M.ours = ours

--- Is this name us? Never treat ourselves as a third party.
function M.isSelf(name)
   local id = key(name)
   local mine = emunah.gmcp.character or (emunah.gmcp.status and emunah.gmcp.status.name())
   return mine ~= nil and id == key(mine)
end

--- "ally" | "enemy" | "neutral" | "self"
---
--- The order of these tests is the whole design, and it is not the obvious one.
---
--- 1. Ourselves. Nothing downstream should ever have to special-case our own name.
--- 2. An explicit `iff`. A name someone took the trouble to mark carries information no
---    organisation table has, and it beats every derived answer beneath it.
--- 3. A declared enemying -- `cityenemy` and friends. That is the GAME stating a fact about
---    this person, so it outranks our own shared-organisation inference: a housemate who
---    has been enemied to the city is a problem regardless of the house.
--- 4. A shared organisation. Ally.
--- 5. An organisation we have marked hostile. Enemy.
--- 6. Neutral, which is the honest answer for a stranger.
---
--- 4 BEFORE 5 is the load-bearing bit, and it is deliberately the opposite way round from
--- 3. `hostile` is our own broad brush across an entire city; a shared house is a specific
--- fact about this person. Ordering it the other way makes "I marked Mhaldor hostile" turn
--- my own housemates into attackable targets, which is precisely the accident attackable()
--- exists to prevent.
function M.relationship(name)
   if M.isSelf(name) then return "self" end

   local person = M.get(name)
   if person and person.iff and person.iff ~= "auto" then return person.iff end
   if not person then return "neutral" end

   for _, org in ipairs(ORGS) do
      if person[ENEMY_FLAG[org]] then return "enemy" end
   end

   local mine = ours()
   for _, org in ipairs(ORGS) do
      local theirs = person[org]
      if theirs and theirs ~= "" and mine[org]
         and tostring(theirs):lower() == tostring(mine[org]):lower() then
         return "ally"
      end
   end

   for _, org in ipairs(ORGS) do
      local theirs = person[org]
      if theirs and theirs ~= "" and M.hostile[org][tostring(theirs):lower()] then
         return "enemy"
      end
   end

   return "neutral"
end

function M.isAlly(name)  return M.relationship(name) == "ally" end
function M.isEnemy(name) return M.relationship(name) == "enemy" end

--- Enemied to our city specifically, ignoring house and order.
---
--- Separate from isEnemy() because the two answer different questions: this one is about
--- where you may legally be attacked and by whom, and a house enemy is not that.
function M.isCityEnemy(name)
   local person = M.get(name)
   if not person then return false end
   if person.cityenemy then return true end
   local mine = ours()
   return not not (person.city and mine.city
      and M.hostile.city[tostring(person.city):lower()])
end

--- Is this someone an offensive ability may be aimed at?
---
--- Deliberately narrow: NOT us, and NOT an ally. A stranger is a legitimate target for an
--- explicitly-chosen action, which is what PvP targeting already requires -- but an ally
--- never is, whatever else is true, and that check belongs in one place.
function M.attackable(name)
   local relation = M.relationship(name)
   return relation ~= "self" and relation ~= "ally"
end

--- Mark a whole organisation hostile, so everyone in it derives as an enemy at once.
function M.setHostile(kind, org, hostile)
   kind = tostring(kind or ""):lower()
   if not M.hostile[kind] then return false, "kind must be city, house or order" end
   local id = util.trim(tostring(org or "")):lower()
   if id == "" then return false, "no organisation given" end
   M.hostile[kind][id] = hostile ~= false or nil
   M.touch()
   return true
end

--- Every organisation currently marked hostile, as { kind, name } pairs.
function M.hostiles()
   local out = {}
   for _, kind in ipairs(ORGS) do
      for org in pairs(M.hostile[kind] or {}) do
         out[#out + 1] = { kind = kind, name = util.capitalise(org) }
      end
   end
   table.sort(out, function(a, b)
      if a.kind ~= b.kind then return a.kind < b.kind end
      return a.name < b.name
   end)
   return out
end

-- ---------------------------------------------------------------------------
-- the convenience API
-- ---------------------------------------------------------------------------
--
-- Thin readers over the record. They exist so consumers -- the highlighter, PvP, a user's
-- own alias -- ask questions in the vocabulary of the game rather than reaching into the
-- table and depending on the field layout.
--
-- All of them distinguish "we have no record" (nil) from "we have a record and it does not
-- say" (also nil) only where the caller could act on the difference; where it could not,
-- both read as nil on purpose.

function M.getClass(name) return M.field_of(name, "class") end
function M.getCity(name)  return M.field_of(name, "city") end
function M.getHouse(name) return M.field_of(name, "house") end
function M.getOrder(name) return M.field_of(name, "order") end
function M.getRank(name)  return M.field_of(name, "xprank") end
function M.getMight(name) return M.field_of(name, "might") end

function M.setClass(name, class) return M.set(name, "class", class) end
function M.setCity(name, city)   return M.set(name, "city", city) end
function M.setMark(name, mark)   return M.set(name, "mark", mark) end
function M.setDragon(name, is)   return M.set(name, "dragon", is) end

function M.isClass(name, class)
   local known = M.getClass(name)
   return known ~= nil and known == util.trim(tostring(class or "")):lower()
end

function M.isCity(name, city)
   local known = M.getCity(name)
   return known ~= nil and known:lower() == util.trim(tostring(city or "")):lower()
end

function M.isDragon(name)   return M.field_of(name, "dragon") == true end
function M.isImmortal(name) return M.field_of(name, "immortal") == true end

--- The mark type, or false for "known not to be one", or nil for "never asked".
function M.getMark(name)
   local person = M.get(name)
   if not person then return nil end
   return person.mark
end

--- -1 unknown, 0 not infamous, 1 nearly, 2-7 the infamy levels.
function M.infamy(name)
   local value = M.field_of(name, "infamy")
   if value == nil then return -1 end
   return value
end

function M.isInfamous(name) return M.infamy(name) >= 2 end

function M.notes(name)
   local person = M.get(name)
   return (person and person.notes) or {}
end

--- Demonym for a city. Cosmetic; see M.CITIES.
function M.demonym(city, count)
   local pair = DEMONYM[util.trim(tostring(city or "")):lower()]
   if not pair then return util.capitalise(tostring(city or "")) end
   return ((count or 1) == 1) and pair[1] or pair[2]
end

-- ---------------------------------------------------------------------------
-- finding names in text
-- ---------------------------------------------------------------------------
--
-- An Achaean character name is a single capitalised word, so the candidate set from a line
-- is cheap to produce. What makes this safe is that a candidate is only ever returned if it
-- is ALREADY in the database -- this never invents a person from a capitalised noun at the
-- start of a sentence, which is the failure mode a looser matcher has.

--- Every known name in a line, in order of appearance, with duplicates preserved so a
--- caller styling the line can count occurrences.
function M.findNames(line)
   local out = {}
   if type(line) ~= "string" then return out end
   for word in line:gmatch("%a+") do
      if word:match("^%u%l") and M.people[word:lower()] then
         out[#out + 1] = word
      end
   end
   return out
end

--- The first known name in a line, or nil.
function M.findName(line)
   return M.findNames(line)[1]
end

-- ---------------------------------------------------------------------------
-- where records come from
-- ---------------------------------------------------------------------------
--
-- GMCP names people exactly, which is why it is the only automatic source implemented.
-- Room players and channel talkers are both real sightings; neither says anything about
-- allegiance, so they only ever create or touch a record, never set a relationship.
--
-- The unimplemented entries are not oversights and are not TODOs to be guessed at. Each
-- names the exact game output it needs. Paste that into docs/game/help/, write the pattern
-- against it, and set `implemented`. Anything less produces a database that looks populated
-- and is quietly wrong about who is safe to stand next to.

M.sources = {
   { name = "web api", implemented = true,
     what = "api.achaea.com/characters/<name>.json",
     gives = "fullname, class, city, house, level, xp rank, explorer rank, kills" },

   { name = "roster", implemented = true,
     what = "api.achaea.com/characters.json -- everyone online, in one request",
     gives = "the name set that CW and CLWHO honorifics are resolved against" },

   { name = "room", implemented = true,
     what = "everyone standing in the room, from Room.Players",
     gives = "name, honorific, and a web API lookup" },

   { name = "channels", implemented = true,
     what = "anyone who speaks on a channel, from Comm.Channel.Text",
     gives = "name, and a web API lookup" },

   { name = "cw", implemented = true,
     what = "CW -- the city roster",
     gives = "city rank and class, which the web API does not carry" },

   { name = "clwho", implemented = true,
     what = "CLWHO -- a clan roster",
     gives = "clan membership" },

   { name = "qw", implemented = true,
     what = "QW -- everyone you can sense",
     gives = "names, read backwards from the 'Plus another N' line" },

   { name = "angel", implemented = true,
     what = "a guardian angel's life-presence report",
     gives = "where someone is, on what health and mana, and when" },

   { name = "honours", implemented = true,
     what = "HONOURS <person>",
     gives = "might, age, race, sex, class, xp rank, credibility, motto, mentor, deeds" },

   { name = "honours+", implemented = false,
     what = "the parts of HONOURS still unread",
     gives = "order, dragon, mark, and a positive infamy",
     needs = "HONOURS for someone WITH a Mark, a Dragon, an Order or actual infamy -- "
        .. "only the negative infamy wording has been seen, and guessing the positive "
        .. "one would mark innocents" },

   { name = "enemies", implemented = false,
     what = "CITY ENEMIES / HOUSE ENEMIES / ORDER ENEMIES",
     gives = "the cityenemy / houseenemy / orderenemy flags",
     needs = "verbatim output of each of the three enemy listings" },
}

event.register("emunah.room.players", function()
   local room = emunah.gmcp.room
   if not room then return end
   for name, fullname in pairs(room.players or {}) do
      if not M.isSelf(name) then M.seen(name, fullname) end
   end
end, "namedb")

event.register("emunah.comm.text", function(_, message)
   if message and message.talker and not M.isSelf(message.talker) then
      M.seen(message.talker)
   end
end, "namedb")

-- ---------------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------------

-- PERSISTENCE
--
-- Two problems, one mechanism.
--
-- The first is that the passive paths -- record() and seen(), which is how almost every
-- name gets here -- did not write at all. A name learned from Room.Players, a channel or a
-- QW listing lived in memory and was gone at the end of the session, so the database only
-- ever retained people something had ALSO written a field to. That is the opposite of what
-- a name database is for.
--
-- The second is that writing on every change is not the fix. One API enrichment sets ten
-- fields, and a CW listing enriches forty people: saving per field is four hundred full
-- serialisations of the entire database for one command.
--
-- So every mutation calls touch(), which marks the database dirty and coalesces the write
-- into a single flush a few seconds later, and the flush is forced on the way out.

M.dirty = false
M.SAVE_DELAY = 5

--- Write now, whatever is pending.
function M.save()
   local ok, err = pcall(table.save, PATH, { people = M.people, hostile = M.hostile })
   if not ok then
      log.error("Could not save the name database: %s", tostring(err))
      return false
   end
   M.dirty = false
   return true
end

--- Note that something changed, and make sure it reaches disk.
---
--- The pending timer is tracked on _persist so a reload cannot orphan it -- and, more to
--- the point, so a reload with unwritten changes still has exactly one flush outstanding
--- rather than none.
function M.touch()
   M.dirty = true
   emunah._persist = emunah._persist or {}
   if emunah._persist.namedbSaveTimer then return true end

   emunah._persist.namedbSaveTimer = tempTimer(M.SAVE_DELAY, function()
      emunah._persist.namedbSaveTimer = nil
      if M.dirty then M.save() end
   end)
   return true
end

--- Flush on the way out.
---
--- sysExitEvent is Mudlet closing and sysDisconnectionEvent is the connection dropping;
--- both can arrive with a write still coalescing. Without these, quitting within
--- SAVE_DELAY of learning a name loses it -- which is precisely the window a session ends
--- in, because the last thing anyone does before quitting is look at who is around.
event.registerAll({ "sysExitEvent", "sysDisconnectionEvent" }, function()
   if M.dirty then M.save() end
end, "namedb")

function M.load()
   local file = io.open(PATH, "r")
   if not file then return false end
   file:close()

   local loaded = {}
   local ok, err = pcall(table.load, PATH, loaded)
   if not ok then
      log.error("Name database at %s is unreadable (%s).", PATH, tostring(err))
      return false
   end
   M.people  = loaded.people or {}
   M.hostile = loaded.hostile or { city = {}, house = {}, order = {} }
   for _, kind in ipairs(ORGS) do
      M.hostile[kind] = M.hostile[kind] or {}
   end
   nameSetChanged()
   return true
end

M.path = PATH

--- Merge records from another database rather than replacing ours.
---
--- Import is additive on purpose. Someone else's file is evidence about people we have not
--- met, not a correction of the judgement we have already recorded about people we have --
--- so our own explicit `iff` and our own notes survive a merge intact.
--- @return number added, number updated
function M.import(data)
   if type(data) ~= "table" then return 0, 0 end
   local added, updated = 0, 0

   for id, incoming in pairs(data.people or {}) do
      local existing = M.people[id]
      if not existing then
         M.people[id] = incoming
         added = added + 1
      else
         for _, spec in ipairs(M.FIELDS) do
            -- `iff` and `highlight` are ours; they are handled below and not at all.
            if spec.name ~= "iff" and spec.name ~= "highlight"
               and incoming[spec.name] ~= nil and existing[spec.name] == nil then
               existing[spec.name] = incoming[spec.name]
               updated = updated + 1
            end
         end
         for _, note in ipairs(incoming.notes or {}) do
            existing.notes = existing.notes or {}
            existing.notes[#existing.notes + 1] = note
         end
         if (existing.iff or "auto") == "auto" and incoming.iff and incoming.iff ~= "auto" then
            existing.iff = incoming.iff
         end
      end
   end

   -- Hostile markings merge too; they are the other half of what makes an export useful to
   -- someone else, and they only ever add.
   for _, kind in ipairs(ORGS) do
      for org, flag in pairs((data.hostile or {})[kind] or {}) do
         if flag then M.hostile[kind][org] = true end
      end
   end

   if added > 0 then nameSetChanged() end

   M.save()
   return added, updated
end

--- Everything we know, as a plain table ready for table.save or another profile's import.
---
--- Selective by design: an export shared with an ally should be able to carry who is in
--- which city without also carrying your private notes on how each of them opens a fight.
--- @param opts table|nil { fields = {...}, names = {...}, notes = boolean }
function M.export(opts)
   opts = opts or {}
   local wanted = opts.fields and util.set(opts.fields)
   local only   = nil
   if opts.names then
      only = {}
      for _, name in ipairs(opts.names) do only[key(name)] = true end
   end

   local people = {}
   for id, person in pairs(M.people) do
      if not only or only[id] then
         local copy = { name = person.name, seen = person.seen }
         for _, spec in ipairs(M.FIELDS) do
            if (not wanted or wanted[spec.name]) and person[spec.name] ~= nil then
               copy[spec.name] = person[spec.name]
            end
         end
         if opts.notes ~= false and #(person.notes or {}) > 0 then
            copy.notes = util.copy(person.notes)
         end
         people[id] = copy
      end
   end

   return { people = people, hostile = util.copy(M.hostile) }
end

--- Write an export to a file, for handing to another profile or another person.
--- @return boolean ok, string path or reason
function M.exportFile(path, opts)
   path = path or (getMudletHomeDir() .. "/emunah-namedb-export.lua")
   local ok, err = pcall(table.save, path, M.export(opts))
   if not ok then return false, tostring(err) end
   return true, path
end

--- Read an export and merge it. Never replaces; see M.import.
--- @return boolean ok, number|string added or reason, number|nil updated
function M.importFile(path)
   local file = io.open(path, "r")
   if not file then return false, "no file at " .. tostring(path) end
   file:close()

   local data = {}
   local ok, err = pcall(table.load, path, data)
   if not ok then return false, tostring(err) end
   local added, updated = M.import(data)
   return true, added, updated
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

--- Records matching a filter, sorted.
---
--- The filter is the same vocabulary the roster command takes, so `emunah ndb city Mhaldor`
--- and a script asking the same question go through one implementation.
--- @param filter table|nil { relationship=, city=, house=, order=, class=, mark=,
---                           dragon=, infamous=, sort= }
function M.list(filter)
   -- A bare string is the common case and the old signature: filter by standing.
   if type(filter) == "string" then filter = { relationship = filter } end
   filter = filter or {}
   local out = {}

   for _, person in pairs(M.people) do
      local keep = true
      if filter.relationship and M.relationship(person.name) ~= filter.relationship then
         keep = false
      end
      for _, org in ipairs({ "city", "house", "order", "class" }) do
         if keep and filter[org] then
            local value = person[org]
            keep = value ~= nil
               and tostring(value):lower() == tostring(filter[org]):lower()
         end
      end
      if keep and filter.mark ~= nil then
         keep = filter.mark == true and person.mark ~= nil and person.mark ~= false
            or person.mark == filter.mark
      end
      if keep and filter.dragon then keep = person.dragon == true end
      if keep and filter.infamous then keep = M.isInfamous(person.name) end
      if keep then out[#out + 1] = person end
   end

   local sort = filter.sort or "name"
   table.sort(out, function(a, b)
      if sort == "importance" then
         local ai, bi = a.importance or 0, b.importance or 0
         if ai ~= bi then return ai > bi end
      elseif sort == "seen" then
         if (a.seen or 0) ~= (b.seen or 0) then return (a.seen or 0) > (b.seen or 0) end
      end
      return tostring(a.name):lower() < tostring(b.name):lower()
   end)
   return out
end

function M.count()
   return util.count(M.people)
end

--- Population counts: how many we know, how they break down, and where the gaps are.
function M.stats()
   local out = {
      total = 0,
      standing = { ally = 0, enemy = 0, neutral = 0, self = 0 },
      cities = {}, classes = {},
      unknownCity = 0, unknownClass = 0,
      dragons = 0, marks = 0, infamous = 0,
      noted = 0,
   }

   for _, person in pairs(M.people) do
      out.total = out.total + 1
      local standing = M.relationship(person.name)
      out.standing[standing] = (out.standing[standing] or 0) + 1

      if person.city and person.city ~= "" then
         out.cities[person.city] = (out.cities[person.city] or 0) + 1
      else
         out.unknownCity = out.unknownCity + 1
      end

      if person.class and person.class ~= "" then
         out.classes[person.class] = (out.classes[person.class] or 0) + 1
      else
         out.unknownClass = out.unknownClass + 1
      end

      if person.dragon then out.dragons = out.dragons + 1 end
      if person.mark then out.marks = out.marks + 1 end
      if M.isInfamous(person.name) then out.infamous = out.infamous + 1 end
      if #(person.notes or {}) > 0 then out.noted = out.noted + 1 end
   end

   return out
end

--- Everyone in the room right now, with their standing. What a highlighter and the PvP
--- loop both actually want.
function M.here()
   local room = emunah.gmcp.room
   if not room then return {} end
   local out = {}
   for name in pairs(room.players or {}) do
      out[#out + 1] = {
         name = name,
         relationship = M.relationship(name),
         class = M.getClass(name),
         city = M.getCity(name),
      }
   end
   table.sort(out, function(a, b) return a.name < b.name end)
   return out
end

M.load()

return M

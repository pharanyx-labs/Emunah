--- NameDB -- who is a person, and what are they.
---
--- A record per player character: name, the organisations they belong to, and the one
--- question everything else exists to answer -- are they an ally, an enemy, or neither.
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
--- own. Shared city, house or order reads as an ally; a city we have marked hostile reads
--- as an enemy; anything else is neutral, which is the honest answer for a stranger.
---
--- WHAT THIS DOES NOT DO YET, AND WHY
--- ----------------------------------
--- It does not populate itself from HONOURS, QUICKWHO or a city's enemy list. Those are
--- parsed from game text, and the exact wording of that output has not been observed --
--- writing patterns for it from memory would produce a database that looks populated and
--- is quietly wrong about who is safe to stand next to. Records come from GMCP (which
--- names everyone in the room and on every channel) and from `emunah ndb set`, both of
--- which are exact. See docs/game/README.md for how to add the rest.

local M = {}

local util  = emunah.util
local log   = emunah.log
local event = emunah.event

local PATH = getMudletHomeDir() .. "/emunah-namedb.lua"

--- name (lower) -> record
M.people = {}

--- Cities, houses and orders we treat as hostile. Derived relationships read this.
M.hostile = { city = {}, house = {}, order = {} }

--- Fields a record carries. Everything is optional: a name seen once in a room is still
--- worth recording, and a partial record is more useful than none.
M.FIELDS = {
   "name", "fullname", "class", "city", "house", "order",
   "rank", "might", "notes", "iff", "seen",
}

local IFF = { auto = true, ally = true, enemy = true }

local function key(name)
   return tostring(name or ""):lower():match("^%s*(.-)%s*$")
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
         name  = tostring(name),
         iff   = "auto",
         notes = {},
         seen  = util.now(),
      }
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
   if fullname and fullname ~= "" then person.fullname = tostring(fullname) end
   return person
end

--- Set one field. Returns false for a field this record does not carry, rather than
--- silently storing something nothing will ever read.
function M.set(name, field, value)
   field = tostring(field or ""):lower()
   if field == "notes" or field == "seen" then return false, "not settable directly" end
   if not util.contains(M.FIELDS, field) then
      return false, "unknown field " .. field
   end

   local person = M.record(name)
   if not person then return false, "no name given" end

   if field == "iff" then return M.iff(name, value) end
   person[field] = value ~= nil and tostring(value) or nil
   M.save()
   return true
end

--- Add a note. Notes accumulate; they are the part of a record that is judgement rather
--- than data, and overwriting the last one would lose exactly that.
function M.note(name, text)
   text = tostring(text or ""):match("^%s*(.-)%s*$")
   if text == "" then return false end
   local person = M.record(name)
   if not person then return false end
   person.notes = person.notes or {}
   person.notes[#person.notes + 1] = { text = text, at = os.time() }
   M.save()
   return true
end

--- Declare a relationship, or hand it back to derivation with "auto".
function M.iff(name, status)
   status = tostring(status or ""):lower()
   if not IFF[status] then return false, "iff must be ally, enemy or auto" end
   local person = M.record(name)
   if not person then return false, "no name given" end
   person.iff = status
   M.save()
   log.info("%s is now <ansi_cyan>%s<ansi_yellow>.", person.name, status)
   return true
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

--- Is this name us? Never treat ourselves as a third party.
function M.isSelf(name)
   local id = key(name)
   local mine = emunah.gmcp.character or (emunah.gmcp.status and emunah.gmcp.status.name())
   return mine ~= nil and id == key(mine)
end

--- "ally" | "enemy" | "neutral" | "self"
---
--- Declaration beats derivation, always. A name someone has taken the trouble to mark is
--- carrying information no organisation table has.
function M.relationship(name)
   if M.isSelf(name) then return "self" end

   local person = M.get(name)
   if person and person.iff and person.iff ~= "auto" then return person.iff end
   if not person then return "neutral" end

   local mine = ours()
   for _, org in ipairs({ "city", "house", "order" }) do
      local theirs = person[org]
      if theirs and theirs ~= "" then
         if M.hostile[org][tostring(theirs):lower()] then return "enemy" end
         if mine[org] and tostring(theirs):lower() == tostring(mine[org]):lower() then
            return "ally"
         end
      end
   end
   return "neutral"
end

function M.isAlly(name)  return M.relationship(name) == "ally" end
function M.isEnemy(name) return M.relationship(name) == "enemy" end

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
   M.hostile[kind][tostring(org or ""):lower()] = hostile ~= false or nil
   M.save()
   return true
end

-- ---------------------------------------------------------------------------
-- population from GMCP
-- ---------------------------------------------------------------------------
--
-- GMCP names people exactly, which is why it is the only automatic source here. Room
-- players and channel talkers are both real sightings; neither says anything about
-- allegiance, so they only ever create or touch a record, never set a relationship.

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

function M.save()
   local ok, err = pcall(table.save, PATH, { people = M.people, hostile = M.hostile })
   if not ok then
      log.error("Could not save the name database: %s", tostring(err))
      return false
   end
   return true
end

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
   for _, kind in ipairs({ "city", "house", "order" }) do
      M.hostile[kind] = M.hostile[kind] or {}
   end
   return true
end

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
         for _, field in ipairs({ "name", "fullname", "class", "city", "house", "order",
                                  "rank", "might" }) do
            if incoming[field] and not existing[field] then
               existing[field] = incoming[field]
               updated = updated + 1
            end
         end
         -- Notes merge; an explicit iff of ours is never overwritten.
         for _, note in ipairs(incoming.notes or {}) do
            existing.notes = existing.notes or {}
            existing.notes[#existing.notes + 1] = note
         end
         if existing.iff == "auto" and incoming.iff and incoming.iff ~= "auto" then
            existing.iff = incoming.iff
         end
      end
   end
   M.save()
   return added, updated
end

--- Everything we know, as a plain table ready for table.save or another profile's import.
function M.export()
   return { people = M.people, hostile = M.hostile }
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

--- Every record, sorted by name.
function M.list(relation)
   local out = {}
   for _, person in pairs(M.people) do
      if not relation or M.relationship(person.name) == relation then
         out[#out + 1] = person
      end
   end
   table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
   return out
end

function M.count()
   return util.count(M.people)
end

--- Everyone in the room right now, with their relationship. What a highlighter and the PvP
--- loop both actually want.
function M.here()
   local room = emunah.gmcp.room
   if not room then return {} end
   local out = {}
   for name in pairs(room.players or {}) do
      out[#out + 1] = { name = name, relationship = M.relationship(name) }
   end
   table.sort(out, function(a, b) return a.name < b.name end)
   return out
end

M.load()

return M

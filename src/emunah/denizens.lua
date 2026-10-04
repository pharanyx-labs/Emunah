--- Denizen tracking and the per-area kill list.
---
--- Two separate things, deliberately kept apart:
---
---   THE LIST is durable and per-area: which *kinds* of denizen you are willing to kill
---   in a given area, by name -- "a pixie warrior", "an androgynous pixie child".
---
---   THE TARGET is live and per-instance: the specific creature standing in front of you
---   right now, identified by its REPLICA NUMBER.
---
--- WHY THE REPLICA NUMBER MATTERS
--- ------------------------------
--- Achaea gives every object in a room a unique id, which `ih` shows appended to a short
--- name:
---
---     pixie307246         an androgynous pixie child
---     warrior107736       a pixie warrior
---     pixie308635         a pixie
---     pixie196510         a pixie
---
--- Two of those are "a pixie". Attacking `pixie` is ambiguous -- Achaea picks one, and
--- which one changes as they move, die and respawn. You can spend a fight hitting a
--- creature you already killed the twin of, or retarget mid-swing without noticing.
--- Attacking `308635` cannot be misread. The id is what GMCP's Char.Items carries as
--- `item.id`, so we always target that and only ever use the name for the list.
---
--- Stored separately from the settings file: the kill list grows per area and there are
--- 379 areas in Achaea, so it does not belong in emunah-config.lua.

local M = {}

local util = emunah.util
local log  = emunah.log

local PATH = getMudletHomeDir() .. "/emunah-denizens.lua"

--- area name -> { [name lowercased] = { name, seen, wanted } }
M.areas = {}

-- ---------------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------------

function M.save()
   local ok, err = pcall(table.save, PATH, M.areas)
   if not ok then
      log.error("Could not save the denizen list: %s", tostring(err))
      return false
   end
   return true
end

function M.load()
   local file = io.open(PATH, "r")
   if not file then return false end
   file:close()

   local loaded = {}
   local ok = pcall(table.load, PATH, loaded)
   if not ok then
      log.warn("Denizen list at %s is unreadable; starting fresh.", PATH)
      return false
   end
   M.areas = loaded
   if M.dropListingRows() > 0 then M.save() end
   return true
end

--- Remove "denizens" that are really rows of a listing, and say how many went.
---
--- ih.lua used to treat every "noun123  text" line as IH, so ELIST's bare vials were
--- recorded as denizens named for the rest of the row, its sip and month columns
--- included: "an elixir of mana              42       88". No creature's name ends in a
--- gap and two numbers, so that shape is what is dropped.
function M.dropListingRows()
   local dropped = 0
   for _, list in pairs(M.areas) do
      for key, entry in pairs(list) do
         local name = type(entry) == "table" and entry.name or key
         if tostring(name):find("%s%s+%d+%s+%d+%s*$") then
            list[key] = nil
            dropped = dropped + 1
         end
      end
   end
   return dropped
end

-- ---------------------------------------------------------------------------
-- live room contents
-- ---------------------------------------------------------------------------

--- Current area name, or nil before Room.Info has arrived.
function M.area()
   local room = emunah.gmcp.room
   return room and room.area or nil
end

--- Our own creatures, which carry the `m` attribute like any denizen but are not one: the
--- guardian angel (`attrib="m"`, id 318870, the same in the 10:09:48 and 11:52:12 traces of
--- 2026-10-04) by name, and the mount (`attrib="mx"`) by its replica number.
M.COMPANIONS = { ["a guardian angel"] = true }

local function companion(item)
   if M.COMPANIONS[tostring(item.name or ""):lower()] then return true end
   local riding = emunah.riding
   if not (riding and riding.mount) then return false end
   local _, mount = riding.mount()
   return mount ~= nil and tostring(item.id) == mount
end

--- Denizens standing in this room right now.
---
--- Identified by the GMCP `m` attribute, and corpses (`d`) are excluded -- a corpse is
--- still a monster as far as the attribute string is concerned, and queuing an attack on
--- one is a wasted balance.
---
--- Our companions are excluded too. Counted, they kept every room "alive" for good: at
--- 11:52:09 (2026-10-04) the last sentinel died, its gold landed, and the pickup answered
--- "something is still alive here" -- the angel and the horse -- until the walker left.
--- @return table array of { id, name }
function M.here()
   local items = emunah.gmcp.items
   if not items then return {} end

   local out = {}
   for _, item in ipairs(items.at("room")) do
      local attrib = items.attrib(item)
      if attrib.monster and not attrib.dead and not companion(item) then
         out[#out + 1] = { id = item.id, name = item.name or "" }
      end
   end
   return out
end

-- ---------------------------------------------------------------------------
-- the list
-- ---------------------------------------------------------------------------

local function areaTable(area, create)
   area = area or M.area()
   if not area then return nil, nil end
   if not M.areas[area] and create then M.areas[area] = {} end
   return M.areas[area], area
end

--- How many recently-seen replica numbers to remember per denizen kind.
---
--- Achaea replica numbers are unique and never reused, so this only has to be long enough
--- to recognise the same creature across repeated room-list pushes -- not to remember
--- every pixie that ever lived. Without a bound it would grow forever.
M.REPLICA_MEMORY = 32

--- Record a denizen into an area's list.
---
--- `seen` counts DISTINCT REPLICA NUMBERS, not sightings. Counting sightings is what
--- produced "a pixie warrior seen 25" in a village holding three of them: every
--- Char.Items.List push for the room re-counted every creature in it, so the number
--- measured how long you stood there rather than how many creatures exist. Passing the id
--- makes the count mean something -- and a nil id (a manual `emunah mobs add`) still
--- records the kind without inventing a sighting.
---
--- @param id string|nil the replica number, when recording from a live room
--- @param wanted boolean|nil defaults to true
function M.add(name, area, wanted, id)
   if not name or name == "" then return false end
   local list, resolved = areaTable(area, true)
   if not list then
      log.warn("No current area -- cannot record %q.", tostring(name))
      return false
   end

   local key = tostring(name):lower()
   local entry = list[key]

   if not entry then
      entry = { name = tostring(name), seen = 0, wanted = wanted ~= false, replicas = {} }
      list[key] = entry
      log.debug("Recorded %q in %s.", name, resolved)
   end

   entry.replicas = entry.replicas or {}
   if wanted ~= nil then entry.wanted = wanted end

   if id then
      id = tostring(id)
      -- Already counted this individual: nothing new to learn.
      for _, known in ipairs(entry.replicas) do
         if known == id then return true end
      end
      table.insert(entry.replicas, id)
      while #entry.replicas > M.REPLICA_MEMORY do table.remove(entry.replicas, 1) end
      entry.seen = (entry.seen or 0) + 1
   elseif entry.seen == 0 then
      -- Manually added and never actually seen; show it as known rather than as zero.
      entry.seen = 0
   end

   return true
end

function M.remove(name, area)
   local list = areaTable(area, false)
   if not list or not name then return false end
   local key = tostring(name):lower()
   if not list[key] then return false end
   list[key] = nil
   M.save()
   return true
end

--- Mark a denizen as one to leave alone, without forgetting it exists.
function M.setWanted(name, wanted, area)
   local list = areaTable(area, false)
   if not list or not name then return false end
   local entry = list[tostring(name):lower()]
   if not entry then return false end
   entry.wanted = wanted
   M.save()
   return true
end

--- Flip a denizen's wanted state. What clickable UI links call (see
--- announceNewDenizen() below and ui/roompanel.lua) so one link always does the right
--- thing regardless of current state, rather than a one-way action that cannot be undone
--- from the same click.
--- @return boolean|nil the new state, or nil if this denizen is not recorded here at all
function M.toggleWanted(name, area)
   local list = areaTable(area, false)
   if not list or not name then return nil end
   local entry = list[tostring(name):lower()]
   if not entry then return nil end
   entry.wanted = entry.wanted == false
   M.save()
   return entry.wanted
end

--- Is this denizen on the kill list for an area?
function M.wanted(name, area)
   local list = areaTable(area, false)
   if not list or not name then return false end
   local entry = list[tostring(name):lower()]
   return entry ~= nil and entry.wanted ~= false
end

--- Is this denizen recorded at all in an area, regardless of wanted state? What
--- distinguishes "first sighting" from "already known" for any source that reports a
--- denizen kind outside the normal GMCP room-item flow (see ih.lua).
function M.known(name, area)
   local list = areaTable(area, false)
   if not list or not name then return false end
   return list[tostring(name):lower()] ~= nil
end

--- Record a confirmed kill of a kind.
---
--- KILLS ARE THE USEFUL NUMBER, not sightings.
---
--- `seen` counts distinct replica numbers ever encountered, which is honest but nearly
--- meaningless: every butterfly in every room of a 23-room area is a separate individual,
--- and they respawn, so walking Minia a few times legitimately produces "a red admiral
--- butterfly 100 distinct" without you having done anything to 100 butterflies. It grows
--- forever and answers a question nobody asked. What you actually want to know about a
--- kill list is what you have been killing.
function M.recordKill(name, area)
   if not name or name == "" then return false end
   local list = areaTable(area, true)
   if not list then return false end

   local key = tostring(name):lower()
   local entry = list[key]
   if not entry then
      entry = { name = tostring(name), seen = 0, killed = 0, wanted = true, replicas = {} }
      list[key] = entry
   end
   entry.killed = (entry.killed or 0) + 1
   M.save()
   return true
end

--- How many of a kind are in this room right now.
function M.hereCount(name)
   local needle = tostring(name or ""):lower()
   local n = 0
   for _, denizen in ipairs(M.here()) do
      if denizen.name:lower() == needle then n = n + 1 end
   end
   return n
end

--- Everything recorded for an area, most-killed first, then most-seen.
function M.forArea(area)
   local list = areaTable(area, false)
   if not list then return {} end
   local out = {}
   for _, entry in pairs(list) do out[#out + 1] = entry end
   table.sort(out, function(a, b)
      local ak, bk = a.killed or 0, b.killed or 0
      if ak ~= bk then return ak > bk end
      return (a.seen or 0) > (b.seen or 0)
   end)
   return out
end

function M.areaNames()
   return util.keys(M.areas)
end

-- ---------------------------------------------------------------------------
-- targeting
-- ---------------------------------------------------------------------------

--- Replica numbers already dealt with this visit.
---
--- Keyed by id, so a bashing loop can mark one done and have next() move on to a DIFFERENT
--- creature rather than re-picking the same one. Without this, "attack the first wanted
--- denizen here" means attacking the same pixie forever while its three identical
--- neighbours stand untouched -- the room list still contains it, and it is still first.
M.engaged = {}

--- Is this replica a denizen we can see in the room right now?
---
--- The authority is Achaea's own `monster` attribute on the room item, not our kill list:
--- a player, an ally's pet, a shopkeeper and a corpse are all things the attribute
--- excludes, and none of them should ever be the object of an offensive ability. Anything
--- that spends a balance on a named target checks this first, so a misparsed name or a
--- stale id cannot turn into an action aimed at a person.
--- @return boolean
function M.isDenizen(id)
   if not id then return false end
   id = tostring(id)
   for _, denizen in ipairs(M.here()) do
      if denizen.id == id then return true end
   end
   return false
end

--- Room denizens whose name matches, exactly and case-insensitively.
---
--- Game text names creatures by description ("a young rat"), never by replica number, so
--- resolving one back to an id is the only way to act on something a message mentioned.
--- Returns every match, because the caller has to decide what an ambiguous answer means --
--- two young rats in a room make the description useless as an identifier.
--- @return table array of { id, name }
function M.findByName(name)
   name = tostring(name or ""):lower()
   if name == "" then return {} end

   local out = {}
   for _, denizen in ipairs(M.here()) do
      if denizen.name:lower() == name then out[#out + 1] = denizen end
   end
   return out
end

--- Mark a replica as handled (killed, fled, or deliberately passed over).
function M.engage(id)
   if not id then return false end
   M.engaged[tostring(id)] = emunah.util.now()
   return true
end

function M.isEngaged(id)
   return id ~= nil and M.engaged[tostring(id)] ~= nil
end

--- Forget which replicas have been dealt with. Called on room change: a new room is a
--- fresh set of creatures, and ids do not repeat anyway.
function M.clearEngaged()
   M.engaged = {}
end

--- The next denizen worth attacking here.
---
--- Returns the whole record so callers can log the name while attacking the id -- the two
--- must not be confused, which is the entire point of this module.
--- @param includeEngaged boolean|nil true to ignore the engaged set
--- @return table|nil { id, name }
function M.next(includeEngaged)
   for _, denizen in ipairs(M.here()) do
      if M.wanted(denizen.name) and (includeEngaged or not M.isEngaged(denizen.id)) then
         return denizen
      end
   end
   return nil
end

--- Every wanted denizen here that has not been dealt with yet.
function M.pending()
   local out = {}
   for _, denizen in ipairs(M.here()) do
      if M.wanted(denizen.name) and not M.isEngaged(denizen.id) then
         out[#out + 1] = denizen
      end
   end
   return out
end

--- Set the game's target to the next wanted denizen, BY REPLICA NUMBER.
--- @return string|nil the id targeted
function M.target()
   local denizen = M.next()
   if not denizen then return nil end

   local ire = emunah.gmcp.ire
   if ire and ire.setTarget then ire.setTarget(denizen.id) end

   log.info("Target: <ansi_cyan>%s<ansi_yellow> (%s)", denizen.name, denizen.id)
   return denizen.id
end

--- How many wanted denizens are here and not yet dealt with.
function M.count()
   return #M.pending()
end

-- ---------------------------------------------------------------------------
-- auto-recording
-- ---------------------------------------------------------------------------

--- Announce a denizen kind seen for the first time ever in this area, as a clickable line
--- in the main window rather than a silent decision made on the player's behalf.
---
--- cechoLink's command argument is Lua SOURCE, evaluated fresh on every click -- so the
--- name and area are baked in with %q (proper Lua-string escaping) rather than trusted to
--- still be current when the player gets around to clicking. A scrolling chat line can sit
--- there a while; by the time it is clicked the player may well be in a different area.
local function announceNewDenizen(name, area)
   local command = string.format("emunah.denizens.acceptNewDenizen(%q, %q)", name, area)
   local hint = string.format("Click to allow killing %q in %s.", name, area)
   local text = string.format("[emunah] New: %s -- click to allow killing it", name)
   local ok = pcall(cechoLink, text, command, hint, true)
   if not ok then
      -- No client to click in (e.g. this Lua state, or a very old Mudlet) -- fall back to
      -- a plain line so the information is not lost, just not clickable.
      emunah.log.info("New denizen: %s (emunah mobs kill %q to allow it)", name, name)
   end
end

--- What the click above actually runs: allow it, and say so.
function M.acceptNewDenizen(name, area)
   if not M.setWanted(name, true, area) then return false end
   emunah.log.info("<ansi_cyan>%s<ansi_yellow> added to the kill list for %s.",
      tostring(name), tostring(area))
   return true
end

--- Record everything currently in the room.
---
--- Auto-recording on sight rather than on kill means the list fills up as you explore,
--- including things you would never attack (shopkeepers, Vellis the butterfly collector).
--- That is the deliberate trade: a list you prune is far more useful than an empty one you
--- have to build by hand -- but pruning-after-the-fact means every new kind is briefly
--- attackable the moment it is seen, which for a shopkeeper is a real (if usually harmless)
--- mistake to make even once. So a kind seen here for the FIRST TIME EVER in this area is
--- recorded but NOT added to the kill list -- see announceNewDenizen() above, which offers
--- a one-click opt-in instead. A kind already known keeps whatever wanted state it already
--- has; this only changes what happens on first contact.
function M.recordRoom()
   if not emunah.config.get("denizens.autoRecord", true) then return 0 end
   local area = M.area()
   if not area then return 0 end

   local added = 0
   for _, denizen in ipairs(M.here()) do
      if denizen.name ~= "" then
         local list = areaTable(area, false)
         local before = list and list[denizen.name:lower()]
         local beforeSeen = before and before.seen or -1
         local isNew = before == nil

         -- Pass the replica number so `seen` counts individuals, not sightings. A brand
         -- new kind is force-recorded as NOT wanted; an existing one is left untouched.
         --
         -- NOT `isNew and false or nil` -- the classic Lua and/or-ternary trap. Because the
         -- "true" branch value here is itself `false`, `and` short-circuits to `false`, and
         -- `false or nil` then falls through to the SECOND operand regardless of `isNew`.
         -- The expression silently always evaluates to `nil`, which is exactly the kind of
         -- bug that looks correct, compiles, and passes a test that happens to assert the
         -- old behaviour -- it was caught here only by tracing actual values, not by review.
         local forceWanted = nil
         if isNew then forceWanted = false end
         M.add(denizen.name, area, forceWanted, denizen.id)

         if isNew then announceNewDenizen(denizen.name, area) end

         local after = areaTable(area, false)[denizen.name:lower()]
         if after.seen ~= beforeSeen then added = added + 1 end
      end
   end
   if added > 0 then M.save() end
   return added
end

emunah.event.registerAll({
   "emunah.items.list",
   "emunah.items.added",
}, function(_, location)
   -- Only the room list is interesting; inventory changes are not denizens.
   if location ~= "room" then return end
   M.recordRoom()
end, "denizens")

-- A creature that leaves is no longer ours to deal with. Dropping it from the engaged set
-- keeps that set small and means a creature that wanders back in is reconsidered.
emunah.event.register("emunah.items.removed", function(_, location, item)
   if location == "room" and item and item.id then
      M.engaged[tostring(item.id)] = nil
   end
end, "denizens")

-- New room, new set of creatures. Replica numbers never repeat, so nothing is lost.
emunah.event.register("emunah.room", function()
   M.clearEngaged()
end, "denizens")

M.load()

return M

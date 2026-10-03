--- Char.Items -- inventory, room contents, and container contents.
---
--- Messages:
---   Char.Items.List    { location, items = { {id, name, icon, attrib}, ... } }
---   Char.Items.Add     { location, item }
---   Char.Items.Remove  { location, item }
---   Char.Items.Update  { location, item }
---
--- `location` is "inv", "room", or "repNNN" for the contents of container NNN.
---
--- Two mistakes are easy to make here, and both fail silently:
---
---   1. An Update handler that builds its replacement by copying the *existing* entry
---      rather than the incoming one discards the new data on every update -- item names
---      never change and container flags never appear. We copy from the incoming item.
---
---   2. Storing `gmcp.Char.Items.Add.item` by reference. Mudlet replaces the gmcp
---      subtables on each message, so a stored reference is mutated underneath you. We
---      store a copy.

local M = {}

local util  = emunah.util
local event = emunah.event
local log   = emunah.log

--- location -> array of items
M.locations = { inv = {}, room = {} }

--- Have we actually SEEN an inventory list, as opposed to not having asked yet?
---
--- An empty table means both, and the difference is expensive. A reload re-executes this
--- file, so inventory starts empty with the character still holding everything -- and any
--- consumer that reads "no entries" as "I am carrying nothing" acts on it. The restocker
--- did: after each `emreload` it pulled three of every curative afresh, which is where 9
--- ash and 6 bloodroot came from against a target of 3.
M.inventoryListed = false

--- Whether we can currently perceive NEW item movements.
---
--- Char.Items.Add/Update/Remove go silent while blind without mindseye up -- the initial
--- Char.Items.Inv answers normally, but the incremental stream does not, the same shape as
--- Char.Afflictions during blackout (see curing/engine.lua's M.BLINDING). Confirmed with
--- `emunah debug gmcp` 16:22:24-16:22:31: every `outr` pull in that window produced
--- IRE.Rift.Change and the room's own "You remove N X..." confirmation, but no
--- Char.Items.Add -- so the pull was never recorded, and queueRestock() kept re-pulling
--- against a phantom zero, eventually giving up with "Pulled X 3 times and still count 0."
--- The instant `touch mindseye` landed (Char.Defences.Add name="mindseye" at 16:22:35), the
--- very next `outr` produced a normal Char.Items.Add.
function M.sighted()
   local defences = emunah.gmcp.defences
   if not defences then return true end
   -- Char.Defences calls this defence `blindness`, not `blind` -- confirmed the same way
   -- curing/deflist.lua's M.commands.blindness was: keep-up raising `blind` (`eat bayberry`)
   -- never registered, and its own diagnostic named `blindness` as an unclaimed Char.Defences
   -- name. Kept as a literal here rather than a dependency on deflist -- this module sits
   -- below curing/ and only needs the one fact, not the lookup machinery.
   if not defences.has("blindness") then return true end
   return defences.has("mindseye")
end

--- True once inventory is known well enough to make decisions about what we are carrying.
---
--- Requires sight too: a snapshot taken before going blind is not wrong, but anything that
--- happened during the blind window since is invisible to it, and a restocker or looter
--- acting on it would be making decisions against data it has no way to know is stale.
function M.inventoryKnown()
   return M.inventoryListed and M.sighted()
end

--- IRE attribute letters. Used by attrib() below; the full set is worth documenting
--- because it is the only way to tell a container from a corpse from a weapon.
M.ATTRIBUTES = {
   w = "worn",      W = "wearable",   l = "wielded_left", L = "wielded_right",
   g = "groupable", c = "container",  r = "riftable",     t = "takeable",
   m = "monster",   d = "dead",       f = "fluid",        e = "edible",
   D = "dangerous", x = "special",
}

--- Shared empty list, returned for a location we know nothing about.
---
--- Never handed to anything that mutates it. M.at() used to answer a miss with a fresh
--- `{}`, which is a table allocated per call in the middle of the query path -- and a miss
--- is not rare, since every room query before the first Char.Items.Room is one.
local NOTHING = {}

--- Normalise a GMCP location to our key: "inv", "room", or the bare container id.
local function locationKey(location)
   -- The two common cases first, and without tostring(): this sits under every item query
   -- in the system, and "inv" is what nearly all of them pass.
   if location == "inv" or location == "room" then return location end
   location = tostring(location or "")
   if location == "inv" or location == "room" then return location end
   return location:match("%d+$") or location
end

--- Items at an ALREADY-NORMALISED key.
---
--- The query functions below normalise once and then pass the key down; going back through
--- M.at() would normalise it a second time on every call.
local function rawAt(key)
   return M.locations[key] or NOTHING
end

--- Bumped every time anything at any location changes.
---
--- count() and quantity() memoise against this, because the questions they are asked are
--- both few and repeated: restocking asks "how many bloodroot" once per prompt with the
--- same thirty names, while the answer only changes when Achaea sends a Char.Items message
--- -- which in a fight is a handful of times, not several times a second.
---
--- ONE COUNTER FOR EVERY LOCATION, deliberately. Per-location generations would be finer
--- grained and would also be one more thing to get wrong; a room list arriving does not
--- make an inventory query expensive enough to be worth that risk. The dangerous failure
--- here is a STALE count -- believing we hold a herb we have already eaten, which would
--- have the engine queue a cure that cannot fire -- so every mutation site below calls
--- touch(), and the memo is dropped wholesale rather than surgically.
M.generation = 0

local function touch()
   M.generation = M.generation + 1
end

--- Defensive copy of an item, so we never retain a reference into the live gmcp table.
local function copyItem(item)
   if type(item) ~= "table" then return nil end
   local name = item.name and tostring(item.name)
   return {
      id     = item.id and tostring(item.id),
      name   = name,
      icon   = item.icon and tostring(item.icon),
      attrib = item.attrib and tostring(item.attrib) or "",
      -- Lowercased once, here, because this is the only place an item enters storage and
      -- because every lookup below is a case-insensitive substring match.
      --
      -- This was THE hot spot of the whole system, by a factor of three over anything else.
      -- Restocking asks have.quantity() for every consumable the cure tables can call for
      -- -- around thirty items -- on every prompt, and each of those calls used to lowercase
      -- every name in the inventory again. Thirty scans times a full pack, several times a
      -- second, all recomputing a string that only changes when Achaea sends Char.Items.
      search = name and name:lower(),
   }
end

local function isContainer(item)
   return item and item.attrib and item.attrib:find("c", 1, true) ~= nil
end

--- Ask the game what is inside a container we just learned about.
local function requestContents(item)
   if not (item and item.id) then return end
   emunah.gmcp.request("Char.Items.Contents " .. item.id)
end

--- We have been told about a location we are not tracking. Re-sync rather than guess.
local function resync(key)
   if key == "inv" then
      emunah.gmcp.request("Char.Items.Inv")
   elseif key == "room" then
      -- Mark it ours, or onList will read the reply as the next room's contents arriving
      -- early and refuse to treat it as current. Every path that asks for a room list has
      -- to do this; "unsolicited" only means anything if we account for all our own asks.
      M.roomPollOutstanding = true
      emunah.gmcp.request("Char.Items.Room")
   else
      emunah.gmcp.request("Char.Items.Contents " .. key)
   end
end

-- ---------------------------------------------------------------------------
-- handlers
-- ---------------------------------------------------------------------------

-- Forward declaration: onList cancels the pending room-list retry, which is defined with
-- the room-entry logic further down. Without this it would resolve to a nil global and
-- error the moment a room list arrived.
local cancelRoomRetry

local function onList()
   local payload = gmcp.Char.Items.List
   if type(payload) ~= "table" then return end
   local key = locationKey(payload.location)

   local items = {}
   for _, raw in ipairs(payload.items or {}) do
      local item = copyItem(raw)
      if item then
         items[#items + 1] = item
         if key == "inv" and isContainer(item) then requestContents(item) end
      end
   end

   M.locations[key] = items
   touch()
   if key == "inv" then M.inventoryListed = true end

   if key == "room" then
      -- WHICH ROOM DOES THIS LIST DESCRIBE?
      --
      -- Two cases, and conflating them is expensive. If we asked for it, it describes where
      -- we are now, and it is current the moment it lands. If we did NOT ask for it, Achaea
      -- is volunteering the contents of the room we are walking INTO -- it always sends that
      -- ahead of the matching Room.Info -- and it does not become current until we actually
      -- arrive.
      --
      -- The list is treated as current either way, and deliberately so. It is tempting to
      -- withhold that in the unsolicited case -- during a speedwalk it really does describe
      -- the room ahead -- but "we did not ask for it" does not actually mean "we are
      -- moving": a manual LOOK produces an unsolicited list for the room you are standing
      -- in, and refusing to treat that as current stalls every consumer until the next room
      -- change. Transit is a question about the walker, so bashing.lua asks the walker (see
      -- its tick), rather than having this module guess from message ordering.
      --
      -- Note we still do NOT stamp the room number from gmcp.Room.Info here: in the
      -- unsolicited case that field names the room we are leaving.
      if not M.roomPollOutstanding then
         M.roomListEarlyForNext = true
      end
      M.roomPollOutstanding = false
      M.roomListVerified = true
      cancelRoomRetry()
   end

   event.raise("items.list", key, #items)
end

local function onAdd()
   local payload = gmcp.Char.Items.Add
   if type(payload) ~= "table" then return end
   local key  = locationKey(payload.location)
   local item = copyItem(payload.item)
   if not item then return end

   if not M.locations[key] then
      resync(key)
      return
   end

   table.insert(M.locations[key], item)
   touch()
   if key == "inv" and isContainer(item) then requestContents(item) end

   event.raise("items.added", key, item)
end

local function onRemove()
   local payload = gmcp.Char.Items.Remove
   if type(payload) ~= "table" then return end
   local key  = locationKey(payload.location)
   local item = payload.item
   if not (item and item.id) then return end

   local bucket = M.locations[key]
   if not bucket then
      resync(key)
      return
   end

   local id = tostring(item.id)
   for index, stored in ipairs(bucket) do
      if stored.id == id then
         table.remove(bucket, index)
         touch()
         event.raise("items.removed", key, stored)
         return
      end
   end
end

local function onUpdate()
   local payload = gmcp.Char.Items.Update
   if type(payload) ~= "table" then return end
   local key  = locationKey(payload.location)
   local item = copyItem(payload.item)
   if not item then return end

   local bucket = M.locations[key]
   if not bucket then
      resync(key)
      return
   end

   for index, stored in ipairs(bucket) do
      if stored.id == item.id then
         bucket[index] = item          -- the incoming item, not a copy of the old one
         touch()
         if key == "inv" and isContainer(item) then requestContents(item) end
         event.raise("items.updated", key, item)
         return
      end
   end

   -- An update for something we do not have means our view has drifted.
   if key == "inv" then resync(key) end
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

--- Everything at a location.
function M.at(location)
   return M.locations[locationKey(location)] or NOTHING
end

--- Does this item's name contain `needle`? `needle` must already be lowercased.
---
--- Reads the `search` field copyItem() built rather than lowercasing again. The fallback
--- is for an item that predates that field -- it should not happen, since copyItem() is the
--- only way into M.locations, but a nil here would silently stop matching an item the
--- character really is carrying, and failing to find a herb you hold is the expensive
--- direction to be wrong in.
local function matches(item, needle)
   local haystack = item.search or (item.name and item.name:lower())
   return haystack ~= nil and haystack:find(needle, 1, true) ~= nil
end

--- Find items whose name contains `pattern` (plain substring, case-insensitive).
--- @param location string|nil defaults to "inv"
--- @return table array of matching items
function M.find(pattern, location)
   local needle = tostring(pattern):lower()
   local out = {}
   for _, item in ipairs(rawAt(locationKey(location or "inv"))) do
      if matches(item, needle) then out[#out + 1] = item end
   end
   return out
end

--- First match, or nil.
---
--- Stops at the first hit instead of building the whole list and taking [1]. This is the
--- form have.pipe() and the loot scan use, where the answer is "is there one" and the rest
--- of the list was allocated only to be discarded.
function M.first(pattern, location)
   local needle = tostring(pattern):lower()
   for _, item in ipairs(rawAt(locationKey(location or "inv"))) do
      if matches(item, needle) then return item end
   end
   return nil
end

--- How many items match. With no pattern, how many items are at the location -- this is
--- the form gmcp/init.lua's snapshot uses.
--- Memoised answers, keyed location -> needle -> number, valid for one generation.
---
--- Dropped wholesale the moment anything moves; see M.generation. Two separate tables
--- rather than one holding a pair, so a hit costs two hash lookups and no allocation.
local countCache, quantityCache = {}, {}
local cachedGeneration = -1

--- Drop the memo if anything has moved since it was filled.
--- Callers read countCache/quantityCache *after* calling this: they are upvalues shared
--- with the assignment below, so both see whatever this rebound them to.
local function freshen()
   if cachedGeneration ~= M.generation then
      countCache, quantityCache = {}, {}
      cachedGeneration = M.generation
   end
end

--- The per-location bucket inside one of the memo roots.
local function bucketIn(root, key)
   local bucket = root[key]
   if not bucket then
      bucket = {}
      root[key] = bucket
   end
   return bucket
end

function M.count(pattern, location)
   if pattern == "inv" or pattern == "room" then
      return #M.at(pattern)
   end
   if not pattern then return #M.at(location or "inv") end

   -- Counted in place rather than via find(). have.cure() asks this for every cure option
   -- it considers, which in a lock is dozens of times per prompt, and every one of those
   -- built a table purely to read its length.
   local key    = locationKey(location or "inv")
   local needle = tostring(pattern):lower()

   freshen()
   local bucket = bucketIn(countCache, key)
   local hit = bucket[needle]
   if hit then return hit end

   local n = 0
   for _, item in ipairs(rawAt(key)) do
      if matches(item, needle) then n = n + 1 end
   end
   bucket[needle] = n
   return n
end

--- How MANY of a thing we are carrying, as opposed to how many inventory entries mention
--- it. Achaea groups stackable curatives, so one entry is not one herb.
---
--- The count is in the NAME, and the wording is verbatim from a GMCP trace at 11:42:02
--- after `outr 5 irid`:
---
---     {attrib="gre" icon="curative" id="344362" name="a group of 5 pieces of irid moss"}
---
--- so "a group of N ..." is the form, not a leading number -- a guess this file previously
--- carried, which read that stack as 1 and would have had the restocker pulling forever.
--- The `g` in attrib marks the entry as grouped, which is the corroboration.
---
--- An entry with no number is one item. That is the cautious direction for a restocker: it
--- under-counts, so we pull a few too many rather than believe we are stocked when we are
--- not -- and engine.queueRestock() stops after a bounded number of pulls that do not move
--- the count, so an unrecognised wording cannot empty the rift into the pack.
function M.quantity(pattern, location)
   -- Summed in place, for the same reason count() is, and memoised for the same reason
   -- again: this is the single most-called query in the system -- restocking asks it once
   -- per restockable consumable on every prompt, and the two string matches below run per
   -- matching entry.
   local key    = locationKey(location or "inv")
   local needle = tostring(pattern):lower()

   freshen()
   local bucket = bucketIn(quantityCache, key)
   local hit = bucket[needle]
   if hit then return hit end

   local total = 0
   for _, item in ipairs(rawAt(key)) do
      if matches(item, needle) then
         local name = item.name or ""
         local count = tonumber(name:match("group of (%d+)")) or tonumber(name:match("^(%d+)%s"))
         total = total + (count or 1)
      end
   end
   bucket[needle] = total
   return total
end

function M.has(pattern, location)
   return M.first(pattern, location) ~= nil
end

--- Decoded attrib strings, keyed by the raw string itself.
---
--- Keyed on the STRING, not the item: Achaea sends the same handful of attrib strings ("m",
--- "t", "c", "mt", "") for every item in the game, so the cache is tiny and shared across
--- every item that carries the same flags -- and it needs no invalidation at all, because
--- the decoding of a given string cannot change. Keying on the item would need the
--- generation dance that count()/quantity() use, and would still miss on every new item.
---
--- Worth caching because ui/roompanel.lua asks once per room item per repaint, and each miss
--- allocates a fourteen-key table and runs fourteen string.find calls.
local attribCache = {}

--- Shared answer for an item with no attrib string at all. Read-only, like every shared
--- table this codebase hands out.
local NO_ATTRIB = {}

--- Decode an item's attrib string into named booleans.
---
--- The returned table is shared and must be treated as read-only.
function M.attrib(item)
   local raw = item and item.attrib
   if type(raw) ~= "string" then return NO_ATTRIB end

   local hit = attribCache[raw]
   if hit then return hit end

   hit = {}
   for letter, name in pairs(M.ATTRIBUTES) do
      hit[name] = raw:find(letter, 1, true) ~= nil
   end
   attribCache[raw] = hit
   return hit
end

--- Containers currently in inventory.
function M.containers()
   local out = {}
   for _, item in ipairs(M.at("inv")) do
      if isContainer(item) then out[#out + 1] = item end
   end
   return out
end

--- Ask for a full re-read of inventory and room.
function M.refresh()
   M.refreshInventory()
   M.roomPollOutstanding = true   -- ours -- see resync()
   emunah.gmcp.request("Char.Items.Room")
end

--- Ask for a full re-read of inventory only.
---
--- Split out of M.refresh() because "What do you want to eat?" needs this and nothing
--- else -- it is a question about what we hold, not where we are standing. Watched in an
--- arena death 2026-08-03 15:52:18-23: the eat-failure handler called M.refresh(), which
--- also polled Char.Items.Room and, via onList()'s per-container requestContents(), fired
--- six more Char.Items.Contents round trips -- none of which curing needs, since container
--- contents are never merged into "inv" for have.quantity() to see. That ran the character
--- through five real seconds of silence, taking only bleed damage, before the next cure
--- went out.
function M.refreshInventory()
   emunah.gmcp.request("Char.Items.Inv")
end

event.gmcp("Char.Items.List",   onList,   "gmcp.items")
event.gmcp("Char.Items.Add",    onAdd,    "gmcp.items")
event.gmcp("Char.Items.Remove", onRemove, "gmcp.items")
event.gmcp("Char.Items.Update", onUpdate, "gmcp.items")

event.register("sysDisconnectionEvent", function()
   M.locations = { inv = {}, room = {} }
   touch()
   M.inventoryListed = false
end, "gmcp.items")

-- SIGHT REGAINED -- CATCH UP. Whatever picked up while blind without mindseye never sent
-- Char.Items.Add, so the moment sight returns, `M.locations.inv` is missing everything that
-- happened during the gap. inventoryKnown() already stops decisions being made ON that gap
-- (see M.sighted() above); this is what closes it, the same role M.reconcile() plays for
-- afflictions when blackout lifts.
local wasSighted = true

local function checkSight()
   local isSighted = M.sighted()
   if isSighted and not wasSighted then
      log.info("Sight restored -- resyncing inventory against whatever Char.Items missed.")
      resync("inv")
      -- THE LIST MAY ALREADY BE IN. Char.Items.Inv answers while blind; what goes silent
      -- is the incremental stream. inventoryKnown() flips true on this edge, and svof's
      -- canoutr does not wait on equilibrium, balance, or the next prompt. Waiting for the
      -- next Char.Vitals left the first outr idle until mindseye's 3.00s came back
      -- (17:31:34.08 sight restored, 17:31:37.10 `outr 1 ash` on the same prompt as
      -- `perform bliss`). The resync still goes out for anything the blind window missed.
      -- It is not what the first pull waits on. restockNow() itself no-ops until the rift
      -- list has been seen, and it still will not pull while unsighted.
      local engine = emunah.curing and emunah.curing.engine
      if engine and engine.restockNow then engine.restockNow() end
   end
   wasSighted = isSighted
end

event.register("emunah.defence.added", checkSight, "gmcp.items")
event.register("emunah.defence.lost", checkSight, "gmcp.items")

-- ---------------------------------------------------------------------------
-- room contents on entry
-- ---------------------------------------------------------------------------
--
-- Achaea does not reliably push a Char.Items.List for the room when you walk in, so we
-- have to ask. Asking once is not enough either: the reply can be lost in the burst of
-- traffic that accompanies a room change, and the timing varies with latency. An empty
-- room list is not a harmless cosmetic gap -- denizens.here() reads it, so a room that
-- looks empty makes the bashing loop believe it has already cleared the room and move
-- straight on. "Walks the area but never attacks anything" is this bug, not a bug in the
-- bashing loop.
--
-- So: clear, ask, and if nothing has arrived shortly afterwards, ask again a bounded
-- number of times. We never fall back to sending an actual game command (e.g. LOOK) to
-- force this -- see requestRoom() below for why that is both unnecessary and undesirable.

--- Which room the current `room` list belongs to, and whether we have confirmed a list
--- since the last room change.
M.roomNumber = nil
M.roomListVerified = false

--- True while requestRoom() has sent a Char.Items.Room poll for the CURRENT room that has
--- not yet been answered or exhausted. A "room" list that arrives while this is false was
--- not solicited by anything we asked for, so under Achaea's ordering guarantee (see
--- requestRoom()) it can only be the next room's contents, arriving ahead of that room's
--- Room.Info. roomListEarlyForNext remembers that until Room.Info consumes it.
M.roomPollOutstanding = false
M.roomListEarlyForNext = false

M.ROOM_RETRIES = 3
M.ROOM_RETRY_DELAY = 0.7

function cancelRoomRetry()
   emunah._persist = emunah._persist or {}
   if emunah._persist.itemsRoomTimer then
      killTimer(emunah._persist.itemsRoomTimer)
      emunah._persist.itemsRoomTimer = nil
   end
end

--- Ask for the room's contents, retrying while the list is still empty.
---
--- Confirmed in play: the GMCP request alone (Char.Items.Room) can go unanswered
--- indefinitely -- for a genuinely empty room, because Achaea simply does not push a list
--- when there is nothing to list, rather than pushing an explicit empty one; and, just as
--- importantly, for a room we already have the correct contents for, because there is
--- nothing new to tell us. Neither case is a dropped-packet race to retry around -- in both,
--- silence IS the server's answer. Without a way to read silence as "nothing to add", the
--- empty case surfaces as "even with no mobs, the walker refuses to move" and roomFresh()
--- never becomes true, which is exactly the bug bashing.lua's own comment warns about:
--- denizens.here() looks empty forever, but for the wrong reason, so the loop just sits
--- there instead of moving on.
---
--- This is only ever called when we do NOT already hold a list for the room we are in --
--- see the Room.Info handler below, which skips it entirely when the room's contents have
--- already arrived early. So by the time retries here are exhausted, no list arrived at
--- all, unsolicited or otherwise, and it is safe to read that as "empty".
---
--- We used to paper over the unanswered-poll case by sending a real LOOK command once
--- retries were exhausted, since that reliably forced a fresh (non-)list out of the server.
--- That meant injecting an unsolicited player command into the live session purely to coax
--- data out of a side-channel protocol -- visible in the scrollback, indistinguishable from
--- something the player typed, and liable to interact with anything else keyed off LOOK
--- output. Once silence itself is understood to mean "nothing to add", there is nothing
--- left for LOOK to fix.
local function requestRoom(attempt)
   attempt = attempt or 1
   cancelRoomRetry()

   if attempt > M.ROOM_RETRIES then
      log.debug("Char.Items.Room went unanswered after %d attempts -- treating the room " ..
         "as empty.", M.ROOM_RETRIES)
      M.roomPollOutstanding = false
      M.locations.room = {}
      touch()
      M.roomListVerified = true
      event.raise("items.list", "room", 0)
      return
   end

   M.roomPollOutstanding = true
   emunah.gmcp.request("Char.Items.Room")

   emunah._persist.itemsRoomTimer = tempTimer(M.ROOM_RETRY_DELAY, function()
      emunah._persist.itemsRoomTimer = nil
      -- Keep asking until a list arrives for this room.
      if not M.roomListVerified then
         log.debug("No room list yet after %.1fs -- asking again (%d).",
            M.ROOM_RETRY_DELAY, attempt + 1)
         requestRoom(attempt + 1)
      end
   end)
end

--- Does the room list we hold describe the room we are standing in?
---
--- False in exactly one situation: an unsolicited list has arrived and the Room.Info that
--- would confirm which room it belongs to has not. Achaea always sends a room's contents
--- ahead of its Room.Info, so during that window the tracked contents describe the room we
--- are walking INTO. Reading them then is what had the bashing loop attacking a creature it
--- had not reached yet.
---
--- DIAGNOSTIC, NOT A GATE, and deliberately so. Nothing guarantees a Room.Info follows every
--- unsolicited list, and a hard gate that never clears freezes the loop outright -- which
--- has already happened twice here, each time a worse failure than the bug being fixed.
--- Transit is gated on the walker, which knows whether it is moving; this reports when the
--- two views disagree so the disagreement is visible rather than inferred from behaviour.
function M.roomMatches()
   return not M.roomListEarlyForNext
end

--- Have we had a room list since the last room change?
---
--- Deliberately "since the last change" rather than "matching the current room number".
--- Achaea sends the new room's item list BEFORE Room.Info when you walk, so at the moment
--- the list arrives gmcp.Room.Info still names the room you just left -- a number
--- comparison would reject a list that is in fact correct, forever.
function M.roomFresh()
   return M.roomListVerified
end

event.gmcp("Room.Info", function()
   local num = gmcp.Room.Info and util.num(gmcp.Room.Info.num, nil)
   if num == M.roomNumber then
      -- Re-sent for the room we are already in -- a LOOK, or Achaea repeating itself. Any
      -- list waiting to be claimed belongs to THIS room after all, so claim it here too.
      -- Leaving it pending would strand roomMatches() false forever after a manual LOOK,
      -- and anything gating on that would never act again.
      M.roomListEarlyForNext = false
      return
   end

   -- DO NOT CLEAR THE LIST HERE.
   --
   -- This was the bug behind "room items never update when I enter a room, but do update
   -- when I LOOK". On movement Achaea sends Char.Items.List for the new room and THEN
   -- Room.Info; clearing on Room.Info therefore threw away the correct list microseconds
   -- after it arrived. LOOK worked only because it happens to send them the other way
   -- round. Keeping the last known list also means the panel shows something plausible
   -- rather than blanking on every step, and a genuinely empty room still clears it --
   -- an empty list is a list, and onList replaces wholesale.
   M.roomNumber = num

   if M.roomListEarlyForNext then
      -- The new room's list already arrived (see onList) before this Room.Info did, exactly
      -- as Achaea always orders it. We already hold the right data -- (re)requesting it
      -- would be asking a question we already know the answer to, and since nothing has
      -- changed since Achaea told us, that redundant poll can go unanswered. Regression:
      -- that unanswered-but-harmless poll was previously indistinguishable from a genuinely
      -- empty room, so requestRoom()'s retry-exhaustion would (wrongly) conclude "empty" a
      -- couple of seconds later and erase items that were showing correctly -- "items
      -- appear on entry, then vanish a few seconds later" was this, not a display bug.
      -- Arrived, and the list we already hold is this room's. onList() has already marked
      -- it current; restating it here keeps that true even if something cleared the flag
      -- between the two messages.
      M.roomListEarlyForNext = false
      M.roomListVerified = true
      return
   end

   M.roomListVerified = false
   requestRoom(1)
end, "gmcp.items")

event.register("sysDisconnectionEvent", cancelRoomRetry, "gmcp.items")

log.debug("Item tracking ready.")

return M

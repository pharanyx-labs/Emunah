--- Area walker -- visit every room in an area, raising an event at each one.
---
--- The shape: keep a list of remaining rooms, walk to the nearest one, raise an event on
--- arrival, wait to be told to move on. That "wait to be told" design is the load-bearing
--- part -- it makes the walker a transport layer that a bashing loop, a herb-picking
--- script or a room-scanner can each drive without any of them knowing about the others.
---
--- Four decisions worth keeping
--- ----------------------------
---
--- 1. NO MAPPER-SCRIPT DEPENDENCY. Reading `mmp.currentroom` and calling `mmp.gotoRoom()`
---    only works with the IRE mapper package installed. We already track the room number
---    from Room.Info (gmcp/room.lua), and Mudlet has built-in speedwalking, so the walker
---    works on a bare profile. mmp is used when present because its arrival events are
---    more reliable, but it is not required.
---
--- 2. REMOVAL CHECKS FIRST. The obvious one-liner is:
---        table.remove(targetTable, table.index_of(targetTable, item))
---    When the item is not in the table, index_of returns nil and table.remove(t, nil)
---    removes the LAST element instead. Every failed lookup would silently delete an
---    unrelated room and the walk would quietly skip rooms with no error. remove() below
---    checks first.
---
--- 3. PATHFINDING IS NOT O(n^2). Calling getPath() against every remaining room on every
---    move costs a 200-room area ~20,000 pathfinds per walk and stalls the client
---    noticeably. We pre-rank candidates by map coordinate distance (cheap) and only
---    pathfind the closest few (see CANDIDATES).
---
--- 4. Safety stops, an avoid list, and pause/resume, because an unattended walker that
---    cannot stop itself is how you feed a character to a denizen.

local M = {}

local util  = emunah.util
local log   = emunah.log
local event = emunah.event

--- How many coordinate-nearest rooms to actually pathfind before picking. Pathfinding is
--- the expensive operation; coordinate distance is a good enough pre-filter to make it
--- bounded. Raise it if your areas have unusual connectivity (lots of one-way exits or
--- portals), lower it for speed.
M.CANDIDATES = 8

M.enabled = false
M.paused  = false

M.remaining   = {}
M.visited     = {}
M.avoid       = {}
M.startRoom   = nil
M.nextRoom    = nil
M.area        = nil
M.stats       = { visited = 0, failed = 0, startedAt = 0 }

M.config = {
   returnToStart = true,
   -- Stop outright if health drops below this percentage. The walker cannot fight, so
   -- continuing to walk while something is killing you is never the right move.
   stopBelowHealth = 40,
   -- Stop if another player turns up. Usually what you want while bashing unattended.
   stopOnPlayer = false,

   -- DRIVE ITSELF.
   --
   -- The event contract below (arrive -> consumer acts -> consumer raises
   -- emunah.walker.move) is what lets a bashing loop pace the walk. But with no consumer
   -- registered, that contract means `emunah walk start` enumerates the area, announces
   -- the first room, and then waits forever for a message nobody sends -- which looks
   -- exactly like a walker that failed to start.
   --
   -- So auto-stepping is the default: the walk continues on its own, and the arrival
   -- event still fires for anything that wants to hook it. A consumer that needs to
   -- control pacing turns this off with `emunah walk auto off`.
   auto = true,
   -- Seconds of quiet after the last room change before stepping again. Because the timer
   -- is reset on every room change, this also means a multi-room speedwalk naturally
   -- finishes before the next step is chosen.
   stepDelay = 0.6,
   -- Give up on a destination the game will not let us reach in this long. Routes the
   -- mapper believes in but the game refuses -- water needing SWIM, closed doors, gates --
   -- otherwise loop forever.
   transitTimeout = 8.0,
}

--- Pending auto-step timer, so it can be cancelled rather than stacked.
M.stepTimer = nil

--- When the current goTo() was issued, so a walk that never arrives can be abandoned.
M.transitSince = nil

--- Who, if anyone, has taken over pacing.
---
--- Auto-stepping and a consumer are mutually exclusive drivers, and running both is worse
--- than either: the walker's timer fires on its own schedule while the consumer is still
--- working, so it speedwalks out of a room mid-fight and then marches through every
--- populated room afterwards, killing nothing. That is not a bashing bug -- bashing never
--- got the chance.
---
--- A consumer claims the walker and is then solely responsible for calling move(). This is
--- runtime state, not config: `emunah walk auto` stays whatever the user set it to, and
--- resumes the moment the claim is released.
M.claimedBy = nil

-- Forward declarations: claim/release are defined here for readability but call these,
-- which are defined below. Without the forward declaration they would resolve to nil
-- globals at call time rather than to these locals.
local scheduleNext, cancelStep

function M.claim(owner)
   M.claimedBy = owner or "consumer"
   cancelStep()
   return true
end

function M.release(owner)
   if owner and M.claimedBy and M.claimedBy ~= owner then return false end
   M.claimedBy = nil
   scheduleNext()
   return true
end

local function autoEnabled()
   if M.claimedBy then return false end
   local value = emunah.config.get("walker.auto", M.config.auto)
   return value ~= false
end

local function stepDelay()
   return tonumber(emunah.config.get("walker.stepDelay", M.config.stepDelay))
      or M.config.stepDelay
end

--- Queue the next step. Resetting an existing timer rather than adding one is what keeps
--- a speedwalk that crosses six rooms from queueing six steps.
function scheduleNext()
   if M.stepTimer then
      killTimer(M.stepTimer)
      M.stepTimer = nil
   end
   if not M.enabled or M.paused or not autoEnabled() then return end
   M.stepTimer = tempTimer(stepDelay(), function()
      M.stepTimer = nil
      if M.enabled and not M.paused then M.move() end
   end)
end

function cancelStep()
   if M.stepTimer then
      killTimer(M.stepTimer)
      M.stepTimer = nil
   end
end

-- ---------------------------------------------------------------------------
-- room helpers
-- ---------------------------------------------------------------------------

--- Where are we? Prefers our own GMCP tracking, falls back to the mapper.
function M.currentRoom()
   local room = emunah.gmcp.room
   if room and room.num then return tonumber(room.num) end
   if mmp and mmp.currentroom then return tonumber(mmp.currentroom) end
   if getPlayerRoom then
      local ok, id = pcall(getPlayerRoom)
      if ok and id then return tonumber(id) end
   end
   return nil
end

--- Remove a value from an array, safely.
---
--- The guard is the whole point -- see note 2 in the header. Without it a missing item
--- silently deletes the last element.
local function remove(list, value)
   for index, entry in ipairs(list) do
      if tonumber(entry) == tonumber(value) then
         table.remove(list, index)
         return true
      end
   end
   return false
end

--- Straight-line distance between two rooms on the map, or nil when either has no
--- coordinates. Cheap; used only to rank candidates before pathfinding.
local function coordDistance(from, to)
   if not getRoomCoordinates then return nil end
   local okA, ax, ay, az = pcall(getRoomCoordinates, from)
   local okB, bx, by, bz = pcall(getRoomCoordinates, to)
   if not (okA and okB and ax and bx) then return nil end
   local dx, dy, dz = (bx - ax), (by - ay), (bz - az)
   return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Number of steps to walk from `from` to `to`, or nil if unreachable.
local function pathLength(from, to)
   local ok, reachable = pcall(getPath, from, to)
   if not ok or not reachable then return nil end
   return table.size(speedWalkDir or {})
end

--- Nearest remaining room by actual path length.
---
--- Pathfinds only the CANDIDATES coordinate-closest rooms rather than all of them. On a
--- large area that is the difference between a walk that runs smoothly and one that
--- freezes Mudlet for a second between every room.
function M.closestRoom()
   local from = M.currentRoom()
   if not from or #M.remaining == 0 then return nil end

   -- Rank by coordinate distance first.
   local ranked = {}
   for _, id in ipairs(M.remaining) do
      ranked[#ranked + 1] = { id = id, distance = coordDistance(from, id) or math.huge }
   end
   table.sort(ranked, function(a, b) return a.distance < b.distance end)

   local best, bestLength
   local limit = math.min(#ranked, M.CANDIDATES)
   for index = 1, limit do
      local length = pathLength(from, ranked[index].id)
      if length and (not bestLength or length < bestLength) then
         best, bestLength = ranked[index].id, length
      end
   end

   -- Coordinates lied, or nothing in the shortlist was reachable. Fall back to a full
   -- scan rather than declaring the walk finished while rooms remain.
   if not best then
      for _, id in ipairs(M.remaining) do
         local length = pathLength(from, id)
         if length and (not bestLength or length < bestLength) then
            best, bestLength = id, length
         end
      end
   end

   return best
end

--- Walk to a room, using whichever mechanism is available.
--- The first room and direction on the path to `id`, or nil if we cannot work one out.
---
--- Used to take a SINGLE step instead of speedwalking a whole route -- see M.move() for
--- why that distinction decides whether a hunt kills anything at all.
local function firstStep(id)
   local from = M.currentRoom()
   if not from then return nil end
   local ok, reachable = pcall(getPath, from, id)
   if not (ok and reachable) then return nil end
   local direction = speedWalkDir and speedWalkDir[1]
   local room      = speedWalkPath and tonumber(speedWalkPath[1])
   if not direction then return nil end
   return room or tonumber(id), direction
end

local function goTo(id)
   if mmp and mmp.gotoRoom then
      mmp.gotoRoom(id)
      return true
   end
   local from = M.currentRoom()
   if not from then return false end
   local ok, reachable = pcall(getPath, from, id)
   if not (ok and reachable) then return false end
   -- Mudlet's built-in speedwalk consumes the getPath results.
   local walked = pcall(doSpeedWalk)
   return walked
end

-- ---------------------------------------------------------------------------
-- control
-- ---------------------------------------------------------------------------

--- Begin a walk.
--- @param rooms table|nil specific room ids; defaults to every room in the current area
function M.start(rooms)
   if M.enabled then
      log.warn("Walker is already running. 'emunah walk stop' first.")
      return false
   end

   local current = M.currentRoom()
   if not current then
      log.error("Cannot start: no current room. Is the mapper populated and GMCP Room.Info arriving?")
      return false
   end

   local area = getRoomArea and select(2, pcall(getRoomArea, current)) or nil

   if rooms and #rooms > 0 then
      M.remaining = util.copy(rooms)
      local first = tonumber(rooms[1])
      if first and getRoomArea then
         local ok, id = pcall(getRoomArea, first)
         if ok then area = id end
      end
   else
      if not getAreaRooms or not area then
         log.error("Cannot enumerate the current area. Pass explicit room ids instead.")
         return false
      end
      local ok, areaRooms = pcall(getAreaRooms, area)
      if not ok or not areaRooms then
         log.error("getAreaRooms failed for area %s.", tostring(area))
         return false
      end
      M.remaining = util.copy(areaRooms)
   end

   -- Never queue the room we are standing in, or anything on the avoid list.
   remove(M.remaining, current)
   for _, id in ipairs(M.avoid) do remove(M.remaining, id) end

   if #M.remaining == 0 then
      log.info("Nothing to walk to -- area already covered, or every room is avoided.")
      return false
   end

   M.enabled   = true
   M.paused    = false
   M.area      = area
   M.startRoom = current
   M.visited   = {}
   M.transitSince = nil
   M.lastStepAt = nil
   M.stats     = { visited = 0, failed = 0, startedAt = util.now() }

   -- Say who is actually driving. "auto off" is true but unhelpful when a consumer has
   -- claimed the walker: it reads like a misconfiguration rather than the normal
   -- arrangement during a hunt.
   local pacing = ""
   if M.claimedBy then
      pacing = (" -- paced by %s"):format(M.claimedBy)
   elseif not autoEnabled() then
      pacing = " (auto off -- raise emunah.walker.move to step)"
   end
   log.info("Walking %d room%s%s.", #M.remaining, #M.remaining == 1 and "" or "s", pacing)

   -- Treat the starting room as an arrival so a consumer gets a chance to act here too.
   event.raise("walker.arrived", current)

   -- ...then actually go, unless a consumer has taken over pacing.
   scheduleNext()
   return true
end

function M.stop(reason, emergency)
   if not M.enabled then return false end

   cancelStep()
   M.enabled = false
   M.paused  = false
   M.nextRoom = nil
   M.transitSince = nil
   M.lastStepAt = nil

   local elapsed = util.now() - (M.stats.startedAt or util.now())
   log.info("Walk finished: %d visited, %d unreachable, %s%s.",
      M.stats.visited, M.stats.failed, util.duration(elapsed),
      reason and (" (" .. reason .. ")") or "")

   event.raise("walker.finished", M.stats.visited, reason)

   -- Only walk back if we actually went somewhere, and NEVER after an emergency. Returning
   -- to start from the start produces a pointless "We're already at NNNN!" from the mapper;
   -- returning to start while something is killing you is far worse than pointless.
   -- Confirmed live: a safety stop at 44% health, bleeding 90 a tick, immediately
   -- speedwalked three rooms back across the area -- the stop had been the right call and
   -- the walk home undid it.
   if not emergency and M.config.returnToStart and M.startRoom and M.stats.visited > 0
      and M.currentRoom() ~= M.startRoom then
      goTo(M.startRoom)
   end
   return true
end

--- Advance to the next room. Consumers call this (or raise emunah.walker.move) when they
--- have finished whatever they came to the current room to do.
function M.move()
   if not M.enabled or M.paused then return false end

   -- Safety checks before committing to another room.
   local vitals = emunah.gmcp.vitals
   if vitals and M.config.stopBelowHealth > 0
      and vitals.percent.hp < M.config.stopBelowHealth then
      M.stop(("health below %d%%"):format(M.config.stopBelowHealth), true)
      return false
   end

   if M.config.stopOnPlayer and emunah.gmcp.room.playerCount() > 0 then
      M.stop("another player arrived", true)
      return false
   end

   if #M.remaining == 0 then
      M.stop("all rooms visited")
      return false
   end

   -- ALREADY TRAVELLING?
   --
   -- Re-issuing a speedwalk that is still in progress restarts it from scratch, and if the
   -- route cannot actually be walked the result is an unbounded loop: the mapper prints
   -- "Starting speedwalk from 2397 to 2396" on every prompt while the game answers
   -- "There's water ahead of you. You'll have to SWIM WEST" -- forever, because nothing
   -- ever arrives and nothing ever gives up. A route the mapper believes in but the game
   -- refuses (water, closed doors, locked gates, tolls) is common enough that the walker
   -- has to be able to abandon one.
   if M.nextRoom and M.transitSince then
      local elapsed = util.now() - M.transitSince
      local timeout = tonumber(emunah.config.get("walker.transitTimeout", M.config.transitTimeout))
         or M.config.transitTimeout

      if elapsed < timeout then
         return false      -- still on the way; leave it alone
      end

      log.warn("Could not reach room %s in %.0fs -- skipping it.", tostring(M.nextRoom), elapsed)
      remove(M.remaining, M.nextRoom)
      M.stats.failed = M.stats.failed + 1
      M.nextRoom = nil
      M.transitSince = nil
   end

   local target = M.closestRoom()
   if not target then
      M.stop("no reachable rooms remain")
      return false
   end

   -- ONE ROOM AT A TIME WHILE SOMETHING IS PACING US.
   --
   -- closestRoom() returns the nearest room still to be walked, which can be many steps
   -- away, and goTo() speedwalks the entire route. Rooms passed through en route are marked
   -- visited without ever raising walker.arrived, so a consumer never gets a look at them.
   -- Confirmed live from a GMCP trace: a seven-room speedwalk went straight through a room
   -- containing a guard pig -- "it's pathing but not attacking anything" was this. Bashing
   -- claims the walker precisely so it can act in each room; honouring that means stepping,
   -- not speedwalking. Unclaimed, a plain `emunah walk` still speedwalks, which is what you
   -- want when nothing is looking for a fight.
   if M.claimedBy then
      -- PACE THE STEPS OURSELVES.
      --
      -- scheduleNext() deliberately does nothing while claimed -- the consumer decides when
      -- to move -- and the mapper's own pacing is bypassed here because we are sending raw
      -- directions rather than asking it to speedwalk. That left nothing at all throttling
      -- movement: bashing clears a room and moves on the same prompt, so steps went out
      -- roughly one round trip apart and Achaea answered with "Now now, don't be so hasty!"
      -- Reuse the walker's own step delay rather than inventing a second knob; `emunah walk
      -- delay <s>` already tunes exactly this.
      if M.lastStepAt then
         local wait = stepDelay() - (util.now() - M.lastStepAt)
         if wait > 0 then
            cancelStep()
            M.stepTimer = tempTimer(wait, function()
               M.stepTimer = nil
               if M.enabled and not M.paused then M.move() end
            end)
            return true
         end
      end

      local room, direction = firstStep(target)
      if room then
         -- Movement costs BOTH balance and equilibrium -- confirmed by the player, and
         -- recorded in docs/game/balance.md so this does not get re-litigated. It makes
         -- stepping directly rivalrous with attacking: smite spends balance, so a step
         -- taken straight after a kill waits out the full recovery, and the log fills with
         -- `Held "s" -- no balance`. That pause is the game's rule, not a bug here, and the
         -- held lines are the walker reporting honestly rather than something to suppress.
         -- Retry rather than treat it as departed -- marking nextRoom on a step that never
         -- left would put the walker in transit having not moved, and bashing's transit
         -- gate would sit out the wait too.
         if not emunah.act.send(direction, { standing = true, bal = true, eq = true }) then
            cancelStep()
            M.stepTimer = tempTimer(stepDelay(), function()
               M.stepTimer = nil
               if M.enabled and not M.paused then M.move() end
            end)
            return true
         end
         M.nextRoom = room
         M.transitSince = util.now()
         M.lastStepAt = util.now()
         return true
      end
      -- No usable path step; fall through and let the mapper try the whole route.
   end

   M.nextRoom = tonumber(target)
   M.transitSince = util.now()
   if not goTo(M.nextRoom) then
      -- Could not even start walking there; drop it and try the next.
      remove(M.remaining, M.nextRoom)
      M.stats.failed = M.stats.failed + 1
      M.nextRoom = nil
      M.transitSince = nil
      M.move()
   end
   return true
end

function M.pause()
   if not M.enabled then return false end
   cancelStep()
   M.paused = true
   log.info("Walker paused. 'emunah walk resume' to continue.")
   return true
end

--- Turn self-driving on or off. Off hands pacing to whatever listens for
--- emunah.walker.arrived and raises emunah.walker.move.
function M.setAuto(enabled)
   emunah.config.set("walker.auto", enabled)
   emunah.config.save()
   if enabled then scheduleNext() else cancelStep() end
   log.info("Walker auto-step %s.",
      enabled and "<ansi_light_green>on<ansi_yellow>" or "<ansi_light_red>off<ansi_yellow>")
   return enabled
end

--- Seconds between steps.
function M.setDelay(seconds)
   seconds = tonumber(seconds)
   if not seconds or seconds < 0.1 or seconds > 30 then
      log.warn("Usage: emunah walk delay <seconds, 0.1-30>")
      return false
   end
   emunah.config.set("walker.stepDelay", seconds)
   emunah.config.save()
   log.info("Walker step delay %.1fs.", seconds)
   return seconds
end

function M.resume()
   if not M.enabled or not M.paused then return false end
   M.paused = false
   log.info("Walker resumed.")
   M.move()
   return true
end

function M.avoidRoom(id)
   id = tonumber(id)
   if not id then return false end
   if not util.contains(M.avoid, id) then
      table.insert(M.avoid, id)
   end
   remove(M.remaining, id)
   emunah.config.set("walker.avoid", M.avoid)
   emunah.config.save()
   return true
end

function M.unavoidRoom(id)
   id = tonumber(id)
   if not id then return false end
   local removed = remove(M.avoid, id)
   emunah.config.set("walker.avoid", M.avoid)
   emunah.config.save()
   return removed
end

--- Progress report.
function M.report()
   return {
      running   = M.enabled,
      paused    = M.paused,
      area      = M.area,
      remaining = #M.remaining,
      visited   = M.stats.visited,
      failed    = M.stats.failed,
      avoided   = #M.avoid,
      claimedBy = M.claimedBy,
      elapsed   = M.enabled and (util.now() - M.stats.startedAt) or 0,
   }
end

-- ---------------------------------------------------------------------------
-- arrival handling
-- ---------------------------------------------------------------------------

--- Called when the room changes.
---
--- Driven off our own Room.Info tracking rather than a mapper event, so it works with or
--- without mmp. genrun compared against mmp.currentroom and logged a debug line when they
--- disagreed; here a mismatch is normal (you can walk through intermediate rooms), so we
--- only count an arrival when we reach the room we actually asked for.
local function onRoom(_, roomNumber)
   if not M.enabled or M.paused then return end

   local current = tonumber(roomNumber) or M.currentRoom()
   if not current then return end

   -- Any remaining room we pass through counts as visited, even if it was not the target.
   if remove(M.remaining, current) then
      M.visited[current] = true
      M.stats.visited = M.stats.visited + 1
   end

   if M.nextRoom and current == M.nextRoom then
      M.nextRoom = nil
      M.transitSince = nil
      -- A consumer can act here and raise emunah.walker.move when finished.
      event.raise("walker.arrived", current)
   end

   -- Step again shortly. Rescheduling on EVERY room change (not just arrival at the
   -- target) is deliberate: a speedwalk crossing several rooms keeps pushing the timer
   -- out, so the next destination is chosen once the walk has actually settled rather
   -- than mid-route.
   scheduleNext()
end

--- The mapper failed to path somewhere. Drop that room and carry on rather than stalling.
local function onFailedPath()
   if not M.enabled then return end
   if M.nextRoom then
      remove(M.remaining, M.nextRoom)
      M.stats.failed = M.stats.failed + 1
      M.nextRoom = nil
      M.transitSince = nil
   end
   M.move()
end

event.register("emunah.room", onRoom, "walker")
event.register("emunah.walker.move", function() M.move() end, "walker")
event.register("emunah.walker.stop", function() M.stop("requested") end, "walker")

-- Honour the IRE mapper's failure event when that package is installed.
event.register("mmapper failed path", onFailedPath, "walker")

event.register("sysDisconnectionEvent", function()
   if M.enabled then M.stop("disconnected") end
end, "walker")

M.avoid = emunah.config.get("walker.avoid", {}) or {}

return M

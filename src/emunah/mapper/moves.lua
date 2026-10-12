--- When a step does not simply happen: water, doors, walls, rubble, a missing wormhole, a
--- move made too fast. The lines are mmp's, generated into mapper/lines.lua (M.MOVES, see
--- tools/build-mapper-lines.py); what each does for a walk is here.
---
--- Every response goes through the router (mapper/route.lua), so the commands it sends --
--- SWIM, OPEN DOOR, UNLOCK DOOR -- pass the same gate as a step and count as one. A line
--- is only acted on while a walk is going and a step of its went out in the last few
--- seconds: a door you open by hand is none of the walk's business.
---
--- WHERE THIS DIFFERS FROM mmp
---   refused   mmp ends the whole walk (mmp.failpath). Here the exit is locked until the
---             next map and the walk goes round it; with no way round, it stops then.
---   land      mmp only lands in Starmourn; for Achaea it does nothing and the walk stalls.
---             The landing command is not established here, so the walk pauses, keeping its
---             route, and says why: land, then `go`.
---
--- SHACKLE [mmp: Shackle handling]. mmp removes a shackle for a walk when the density
--- defence is up, and wears it again when the walk ends. Same here, for `goto` walks (not
--- the area walker's room-to-room hops, which would take it on and off every few seconds).

local M = {}

local log    = emunah.log
local event  = emunah.event
local config = emunah.config
local lines  = emunah.mapper.lines
local route  = emunah.mapper.route

local handle = {}

function handle.swim()
   local dir = route.stepDirection()
   if not dir then return end
   route.replaceStep({ { send = "swim " .. dir } })
end

function handle.open()
   local dir = route.stepDirection()
   if not dir then return end
   route.replaceStep({ { send = "open door " .. dir }, { send = route.walk.dirs[route.walk.i] } })
end

function handle.unlock()
   local dir = route.stepDirection()
   if not dir then return end
   -- [mmp] Unlock, then the step; a door still closed answers that with "in the way",
   -- which handle.open() takes from there.
   route.replaceStep({ { send = "unlock door " .. dir }, { send = route.walk.dirs[route.walk.i] } })
end

function handle.refused(entry)
   route.refuseExit(entry.key)
end

function handle.slow(entry)
   route.extendWait(entry.seconds or 2)
end

function handle.hasty()
   -- The line refuses whatever was sent last, which may not have been our step. If our
   -- step is still waiting for its arrival, look again just after act's backoff
   -- (patterns.lua) instead of resending now; if it was still to go out, the gate is
   -- already holding it.
   local walk = route.walk
   if walk and walk.sentAt then
      route.recheckSoon((emunah.act.BACKOFF or 1.5) + 0.3)
   end
end

function handle.noworm()
   local walk = route.walk
   if not walk then return end
   if (walk.dirs[walk.i] or ""):lower():find("worm warp", 1, true) then
      route.refuseExit("no wormhole")
   end
end

function handle.land()
   route.pauseFor("Flying, and the way on is indoors: land, then `go` carries on.")
end

-- ---------------------------------------------------------------------------
-- triggers
-- ---------------------------------------------------------------------------

emunah._persist.moves = emunah._persist.moves or {}
local persist = emunah._persist.moves
for _, id in ipairs(persist.triggers or {}) do killTrigger(id) end
persist.triggers = {}

for _, entry in ipairs(lines.MOVES) do
   local id = tempRegexTrigger(entry.pattern, function()
      if not route.stepping() then return end
      local ok, err = pcall(handle[entry.kind], entry)
      if not ok then log.debug("Movement line %s failed: %s", entry.key, tostring(err)) end
   end)
   persist.triggers[#persist.triggers + 1] = id
end

-- ---------------------------------------------------------------------------
-- the shackle
-- ---------------------------------------------------------------------------

--- Whether we took the shackle off for the walk under way, and so owe it back.
persist.shackleOff = persist.shackleOff or false

local function shackleWanted()
   return config.get("map.shackle", true) ~= false
end

event.register("emunah.map.walking", function()
   local walk = route.walk
   if not walk or walk.quiet or not shackleWanted() then return end
   local defences = emunah.gmcp.defences
   if defences and defences.has("density") and not persist.shackleOff then
      if emunah.act.send("remove shackle", route.NEEDS) then persist.shackleOff = true end
   end
end, "mapper-moves")

local function wearAgain()
   if not persist.shackleOff then return end
   if emunah.act.send("wear shackle", route.NEEDS) then persist.shackleOff = false end
end

event.register("emunah.map.arrived", wearAgain, "mapper-moves")
event.register("emunah.map.stopped", function(_, _, reason)
   if reason ~= "a new destination" then wearAgain() end
end, "mapper-moves")
-- Held at the end of a walk (no balance, say): put back on a later tick.
event.register("emunah.tick", function()
   if persist.shackleOff and not route.walk then wearAgain() end
end, "mapper-moves")

M.handle = handle

return M

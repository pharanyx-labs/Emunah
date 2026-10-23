--- Walking while something is trying to kill you. For `goto` walks only (the user,
--- 2026-10-12); the area walker and the hunt have their own safety stops.
---
---   A BIG HIT -- one Char.Vitals to the next losing more than map.bigHit percent of your
---   health -- raises a warning you cannot miss and walks you out of the area: back the way
---   you came to the first room in a different area, or, when everything behind you is
---   this area, to the nearest room over its border. One room inside the new area is enough.
---
---   AN AFFLICTION does not stop the walk: curing cures it, and a step it blocks
---   (paralysis, a web) is held by act.blocked until it is gone, then goes.
---
---   AN ENEMY in the room (namedb's enemy list) puts a red * in brackets on the end of the
---   prompt, for as long as they are there.
---
--- And the escape route: F12 walks to map.safeRoom (2096 by default, the user's), stopping a
--- hunt first so the two are not both moving you.

local M = {}

local util   = emunah.util
local log    = emunah.log
local event  = emunah.event
local config = emunah.config
local route  = emunah.mapper.route

local function guarded()
   local walk = route.walk
   return walk ~= nil and not walk.quiet
end

-- ---------------------------------------------------------------------------
-- a big hit
-- ---------------------------------------------------------------------------

--- Where to retreat to from `here`: back along the rooms walked, to the first in another
--- area; failing that, the nearest room just over this area's border.
function M.retreatTarget(here)
   here = tonumber(here)
   if not here then return nil end
   local area = getRoomArea(here)
   local trail = emunah.walker and emunah.walker.trail or {}
   for index = #trail, 1, -1 do
      local room = tonumber(trail[index])
      if room and room ~= here and roomExists(room) and getRoomArea(room) ~= area then
         return room
      end
   end
   local outside = {}
   for _, border in ipairs(route.borders(area)) do
      for _, to in pairs(getRoomExits(border) or {}) do
         if getRoomArea(to) ~= area then outside[#outside + 1] = tonumber(to) end
      end
      for _, to in pairs(getSpecialExitsSwap(border) or {}) do
         if getRoomArea(tonumber(to)) ~= area then outside[#outside + 1] = tonumber(to) end
      end
   end
   return (route.nearest(outside))
end

local lastHp = nil

function M.onVitals(_, vitals)
   vitals = vitals or emunah.gmcp.vitals
   local hp, maxhp = tonumber(vitals and vitals.hp), tonumber(vitals and vitals.maxhp)
   local previous = lastHp
   lastHp = hp
   if not (hp and maxhp and maxhp > 0 and previous) then return end
   local lost = (previous - hp) / maxhp * 100
   local limit = tonumber(config.get("map.bigHit", 33)) or 33
   if lost <= limit or not guarded() then return end
   -- Already running from one: keep running, do not turn round.
   if route.walk.retreat then return end

   local alert = emunah.ui.alert
   if alert then
      alert.show("bighit", ("BIG HIT: -%d%% HEALTH"):format(math.floor(lost + 0.5)), {
         { ("%d of %d health left."):format(hp, maxhp) },
         { "Walking out of the area." },
      }, { duration = 8 })
   end
   decho(("\n%s>>> BIG HIT: -%d%% health in one blow. Walking out of the area. <<<")
      :format(emunah.ui.theme.dc("danger"), math.floor(lost + 0.5)))

   local here = tonumber(emunah.gmcp.room.num)
   local target = M.retreatTarget(here)
   if not target then
      route.stop("a big hit, and no way out of the area")
      return
   end
   route.go(target, "out of the area", { retreat = true })
end

event.register("emunah.vitals", M.onVitals, "mapper-guard")

-- ---------------------------------------------------------------------------
-- an enemy in the room
-- ---------------------------------------------------------------------------

--- Is anyone the name database calls an enemy in the room? Ourselves excluded.
function M.enemyHere()
   local room = emunah.gmcp.room
   local namedb = emunah.namedb
   if not (room and namedb and namedb.isEnemy) then return false end
   local me = room.selfName and room.selfName()
   me = me and me:lower()
   for name in pairs(room.players or {}) do
      if name ~= me and namedb.isEnemy(room.playerShort[name] or name) then return true end
   end
   return false
end

event.register("emunah.prompt", function()
   if not guarded() or config.get("map.enemyMark", true) == false then return end
   if M.enemyHere() then
      local theme = emunah.ui.theme
      decho(" " .. theme.dc("textDim") .. "(" .. theme.dc("danger") .. "*" .. theme.dc("textDim") .. ")")
   end
end, "mapper-guard")

-- ---------------------------------------------------------------------------
-- the escape route
-- ---------------------------------------------------------------------------

--- F12: turn off whichever PvP mode is up, stop any hunt, then walk to the safe room.
function M.flee()
   local room = tonumber(config.get("map.safeRoom", 2096))
   if not room then log.warn("No safe room set: `emset map.safeRoom <room number>`.") return false end
   if emunah.pvp and emunah.pvp.enabled then emunah.pvp.stop("fleeing") end
   if emunah.bashing and emunah.bashing.enabled then emunah.bashing.stop("fleeing") end
   if emunah.walker and emunah.walker.enabled then emunah.walker.stop("fleeing", true) end
   return route.go(room, "safety (" .. room .. ")")
end

return M

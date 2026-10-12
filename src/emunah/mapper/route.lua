--- Going places: plan a route over the map, walk it one confirmed step at a time, and
--- recover when the game disagrees with the map.
---
--- Replaces mmp's speedwalking. Pathfinding is still Mudlet's getPath (C++, fast); what
--- changes is everything around it.
---
--- WHAT IS DIFFERENT FROM mmp, AND WHY
--- -----------------------------------
--- 1. EVERY STEP GOES THROUGH act.send. mmp polls GMCP vitals every 0.2s and send()s
---    directly, so it knows nothing of stun, sleep, paralysis or webbing, or of Emunah's
---    own halt and backoff. Here a step is held by the same rules as everything else, and
---    retried on the next tick -- the event that can unblock it -- not on a timer.
---    Movement needs standing, balance and equilibrium (docs/game/balance.md).
---
--- 2. A STEP GOES OUT WHEN THE LAST ONE ARRIVED, never more than one ahead. A step is
---    confirmed by Room.Info naming the room the map said it leads to. At most one step is
---    ever unconfirmed, so a refused exit costs one wasted command, not a queue of them.
---    Steps are spaced at least map.stepGap apart: steps about one round trip apart drew
---    "Now now, don't be so hasty!" (docs/game/balance.md, Rate limiting).
---
--- 3. SCRIPT EXITS ARE TRANSLATED, NEVER RUN. 58 special exits in the crowdmap are Lua:
---    `script: sendAll("pull vine", "e")`, `script: send("say Letum") mmp.customwalkdelay(4)`.
---    mmp runs them with loadstring, which needs mmp's functions and bypasses every gate.
---    M.plan() reads the few shapes they actually take into a list of sends and waits; an
---    exit in any other shape is locked out of routing and said so. The shapes, from the
---    map's own exits (2026-10-12): send(), sendAll(), mmp.customwalkdelay(n) and
---    tempTimer(n, [[cmd]]).
---
--- 4. THE PATH CACHE IS BOUNDED and cleared only when something routing depends on
---    changes: a new map, a lock, a weight. mmp's never shrinks.
---
--- 5. ROUTING POLICY IS mmp's DEFAULTS [mmp]: wormholes ("worm warp") and the enchanted
---    pebble's exits locked, water rooms weighted 3 when you cannot waterwalk. Applied after
---    every map load, because a load wipes them, and skipped when nothing changed.

local M = {}

local util   = emunah.util
local log    = emunah.log
local event  = emunah.event
local config = emunah.config
local timers = emunah.timers
local data   = emunah.mapper.data

--- What a step needs. Movement costs balance and equilibrium and needs you upright
--- (docs/game/balance.md). Special-exit commands (PULL VINE, SAY LETUM, ENTER PORTAL) are
--- held to the same: their own requirements are not known, and holding a command until
--- balance is back costs a moment, where sending one the game refuses costs the step.
M.NEEDS = { standing = true, bal = true, eq = true }

M.CACHE_SIZE = 128
--- How many times a walk may find itself off the route and re-plan before giving up.
M.REROUTES = 5
--- How many times one step is re-sent when no arrival follows, before giving up.
M.RESENDS = 2

-- ---------------------------------------------------------------------------
-- the path cache
-- ---------------------------------------------------------------------------

local cache, order = {}, {}

function M.invalidate()
   cache, order = {}, {}
end

--- A route from one room to another: dirs[i] is the command for step i, rooms[i] the room
--- it reaches. Fresh tables every call, so a caller may change them freely.
--- @return table|nil dirs, table|nil rooms
function M.path(from, to)
   from, to = tonumber(from), tonumber(to)
   if not from or not to then return nil end
   local key = from .. ">" .. to
   local hit = cache[key]
   if hit == nil then
      local ok, found = pcall(getPath, from, to)
      if ok and found then
         local dirs, rooms = {}, {}
         for i, dir in ipairs(speedWalkDir or {}) do dirs[i] = dir end
         for i, room in ipairs(speedWalkPath or {}) do rooms[i] = tonumber(room) end
         hit = { dirs = dirs, rooms = rooms }
      else
         hit = false
      end
      cache[key] = hit
      order[#order + 1] = key
      if #order > M.CACHE_SIZE then cache[table.remove(order, 1)] = nil end
   end
   if not hit then return nil end
   local dirs, rooms = {}, {}
   for i = 1, #hit.dirs do dirs[i], rooms[i] = hit.dirs[i], hit.rooms[i] end
   return dirs, rooms
end

--- How many routes are cached.
function M.cached() return #order end

--- Steps from one room to another, or nil when there is no way.
function M.distance(from, to)
   if tonumber(from) == tonumber(to) then return 0 end
   local dirs = M.path(from, to)
   return dirs and #dirs or nil
end

event.register("emunah.map.loaded", function() M.invalidate() end, "mapper-route")
event.register("emunah.map.changed", function() M.invalidate() end, "mapper-route")

-- ---------------------------------------------------------------------------
-- special exits
-- ---------------------------------------------------------------------------

--- Older crowdmaps prefix a special exit with "0" or "1", its lock state [mmp:
--- mmp.fixSpecialExits].
local function bare(command)
   return (tostring(command):gsub("^[01](script:)", "%1"))
end

local function strings(args)
   local out = {}
   for quote, text in args:gmatch("(['\"])(.-)%1") do out[#out + 1] = text end
   return out
end

--- What a special exit's command amounts to, as a list of { send = "cmd" } and
--- { wait = seconds }, or nil when it is a script in a shape we do not read.
function M.plan(command)
   command = bare(command)
   local script = command:match("^script:%s*(.*)$")
   if not script then return { { send = command } } end

   local steps, rest = {}, script
   while true do
      rest = rest:match("^%s*(.-)%s*$")
      if rest == "" then break end
      local args, after = rest:match("^sendAll(%b())%s*(.*)$")
      if args and not args:find("^%(%(") then
         local list = strings(args)
         if #list == 0 then return nil end
         for _, cmd in ipairs(list) do steps[#steps + 1] = { send = cmd } end
         rest = after
      else
         args, after = rest:match("^send(%b())%s*(.*)$")
         if args then
            local list = strings(args)
            if #list ~= 1 then return nil end
            steps[#steps + 1] = { send = list[1] }
            rest = after
         else
            local delay
            delay, after = rest:match("^mmp%.customwalkdelay%(%s*([%d%.]+)%s*%)%s*(.*)$")
            if delay then
               steps[#steps + 1] = { wait = tonumber(delay) }
               rest = after
            else
               local cmd
               delay, cmd, after = rest:match("^tempTimer%(%s*([%d%.]+)%s*,%s*%[%[(.-)%]%]%s*%)%s*(.*)$")
               if not delay then return nil end
               local inner = cmd:match("^%s*send%(%s*['\"](.-)['\"]%s*%)%s*$") or cmd:match("^%s*(.-)%s*$")
               if inner == "" or inner:find("[%(%)]") then return nil end
               -- The timer and any customwalkdelay before it start together, so the wait is
               -- the longer of the two, not their sum.
               local last = steps[#steps]
               if last and last.wait then
                  last.wait = math.max(last.wait, tonumber(delay))
               else
                  steps[#steps + 1] = { wait = tonumber(delay) }
               end
               steps[#steps + 1] = { send = inner }
               rest = after
            end
         end
      end
   end
   return #steps > 0 and steps or nil
end

--- Script exits we cannot read, locked this session: "from>to" -> command.
M.unreadable = {}

--- Plan a route, locking out any script exit on it we cannot read and planning again.
local function route(from, to)
   for _ = 1, 10 do
      local dirs, rooms = M.path(from, to)
      if not dirs then return nil end
      local blocked = false
      for i, dir in ipairs(dirs) do
         if not M.plan(dir) then
            local at = i == 1 and from or rooms[i - 1]
            lockSpecialExit(at, rooms[i], bare(dir), true)
            M.unreadable[at .. ">" .. rooms[i]] = bare(dir)
            log.warn("Room %s's special exit is a script Emunah does not run; it is locked "
               .. "out of routes: %s", tostring(at), bare(dir):sub(1, 60))
            M.invalidate()
            blocked = true
            break
         end
      end
      if not blocked then return dirs, rooms end
   end
   return nil
end

-- ---------------------------------------------------------------------------
-- routing policy [mmp]
-- ---------------------------------------------------------------------------

--- [mmp] Water, by the crowdmap's environment ids: Freshwater, Ocean, River, Deep Ocean,
--- Water, Reef, Ocean floor and Vast Ocean. River shares id 10 with Skies in the crowdmap
--- (see data.ENV), so sky rooms are weighted with it, as they are under mmp.
local function waterEnvs()
   local set = {}
   for _, name in ipairs({ "Freshwater", "Ocean", "River", "Deep Ocean", "Water", "Reef",
                           "Ocean floor", "Vast Ocean" }) do
      set[data.ENV[name]] = true
   end
   return set
end

--- [mmp] The enchanted pebble's exits (mmp.lockPebble).
M.PEBBLE = { ["touch 116998"] = true, ["touch 277930"] = true }

function M.policySignature()
   return table.concat({ tostring(data.store.version),
      config.get("map.wormholes", false) and "w" or "-",
      config.get("map.waterwalk", true) and "s" or "-" }, ":")
end

--- Put mmp's routing defaults on the map. Walks every room, so it only runs when the
--- map or the settings behind it changed (or when forced).
--- @return number exits locked, number water rooms weighted
function M.applyPolicy(force)
   local signature = M.policySignature()
   if not force and data.store.policy == signature then return 0, 0 end
   if not getRooms then return 0, 0 end
   local lockWorms = not config.get("map.wormholes", false)
   local heavyWater = not config.get("map.waterwalk", true)
   local water = waterEnvs()
   local overlayWeights = data.store.overlay.roomWeight
   local locked, weighted = 0, 0
   for id in pairs(getRooms() or {}) do
      for command, to in pairs(getSpecialExitsSwap(id) or {}) do
         local cmd = bare(command):lower()
         if cmd:find("worm warp", 1, true) then
            lockSpecialExit(id, to, command, lockWorms)
            if lockWorms then locked = locked + 1 end
         elseif M.PEBBLE[cmd] then
            lockSpecialExit(id, to, command, true)
            locked = locked + 1
         end
      end
      if water[getRoomEnv(id)] and overlayWeights[id] == nil then
         setRoomWeight(id, heavyWater and 3 or 1)
         if heavyWater then weighted = weighted + 1 end
      end
   end
   data.store.policy = signature
   data.save()
   M.invalidate()
   return locked, weighted
end

event.register("emunah.map.loaded", function() M.applyPolicy(true) end, "mapper-route")

-- ---------------------------------------------------------------------------
-- walking
-- ---------------------------------------------------------------------------

--- The walk in progress, or nil:
---   target, label   where to, and what to call it
---   dirs, rooms     the route; step i is dirs[i], arriving in rooms[i]
---   i               the step being taken
---   queue           what is left of step i's plan ({ send } / { wait })
---   sent            whether step i's last command went out, and when (sentAt)
---   resends, reroutes
M.walk = nil
M.paused = false
--- Where the last walk started, for `emset goto back`.
M.lastStart = nil

local function here()
   return emunah.gmcp.room and tonumber(emunah.gmcp.room.num) or nil
end

local function gap()
   return tonumber(config.get("map.stepGap", 0.5)) or 0.5
end

local function finish(reason, arrived)
   local walk = M.walk
   if not walk then return end
   M.walk = nil
   M.paused = false
   timers.stop("map.step")
   if arrived then
      log.info("Arrived at %s.", walk.label)
      event.raise("map.arrived", walk.target)
   else
      log.info("Stopped walking to %s: %s.", walk.label, reason)
      event.raise("map.stopped", walk.target, reason)
   end
end

local step   -- forward declaration: the timers below call it

local function after(seconds)
   timers.start("map.step", math.max(0.05, seconds), function() step() end)
end

local function stepsLeft(walk)
   return #walk.dirs - walk.i + 1
end

--- Send what is next in the current step's plan, as far as the gate and its waits allow.
function step()
   local walk = M.walk
   if not walk or M.paused then return end
   if timers.active("map.step") then return end
   while walk.queue[1] do
      local item = walk.queue[1]
      if item.wait then
         table.remove(walk.queue, 1)
         walk.extra = (walk.extra or 0) + item.wait
         after(item.wait)
         return
      end
      local since = walk.lastSentAt and (util.now() - walk.lastSentAt) or math.huge
      if since < gap() then after(gap() - since) return end
      if not emunah.act.send(item.send, M.NEEDS) then
         walk.held = true      -- retried on the next tick
         return
      end
      walk.held = false
      walk.lastSentAt = util.now()
      table.remove(walk.queue, 1)
      if config.get("map.showSteps", true) and not walk.queue[1] then
         decho(emunah.ui.theme.dc("textDim") .. (" (%d left)"):format(stepsLeft(walk) - 1))
      end
   end
   walk.sentAt = util.now()
end

local function begin(walk, i)
   walk.i = i
   walk.queue = M.plan(walk.dirs[i]) or {}
   walk.sentAt, walk.extra, walk.held = nil, 0, false
   walk.from = i == 1 and walk.origin or walk.rooms[i - 1]
   timers.stop("map.step")
   step()
end

--- Start walking to a room.
--- @param target number room id
--- @param label string|nil what to call it in messages ("the bank", "Ashtan")
--- @return boolean started
function M.go(target, label)
   target = tonumber(target)
   local from = here()
   if not target then return false end
   if not from then
      log.warn("Not walking: no current room yet. Room.Info has not arrived.")
      return false
   end
   if not roomExists(from) then
      log.warn("Not walking: you are in room %d, which is not on the map.", from)
      return false
   end
   label = label or ("room " .. target)
   M.applyPolicy(false)   -- a changed map.wormholes / map.waterwalk takes effect here
   if from == target then
      log.info("Already at %s.", label)
      return false
   end
   local dirs, rooms = route(from, target)
   if not dirs then
      log.warn("No route to %s from here.", label)
      event.raise("map.failed", target)
      return false
   end
   if M.walk then finish("a new destination") end
   M.lastStart = from
   M.walk = { target = target, label = label, dirs = dirs, rooms = rooms, origin = from,
              resends = 0, reroutes = 0, startedAt = util.now() }
   M.paused = false
   log.info("Walking to %s: %d step%s.", label, #dirs, #dirs == 1 and "" or "s")
   event.raise("map.walking", target, #dirs)
   begin(M.walk, 1)
   return true
end

function M.stop(reason)
   if not M.walk then return false end
   finish(reason or "stopped")
   return true
end

function M.pause()
   if not M.walk or M.paused then return false end
   M.paused = true
   timers.stop("map.step")
   log.info("Walk to %s paused.", M.walk.label)
   return true
end

function M.resume()
   if not M.walk or not M.paused then return false end
   M.paused = false
   log.info("Walk to %s resumed.", M.walk.label)
   -- Plan again from wherever we are now: anything may have moved us while paused, and a
   -- half-sent special exit is safer started over than finished from the middle.
   local walk, now = M.walk, here()
   if now == walk.target then finish(nil, true) return true end
   local dirs, rooms = now and route(now, walk.target)
   if not dirs then finish("no route from here any more") return true end
   walk.dirs, walk.rooms, walk.origin = dirs, rooms, now
   begin(walk, 1)
   return true
end

local function reroute(walk, now, why)
   walk.reroutes = walk.reroutes + 1
   if walk.reroutes > M.REROUTES then
      return finish(("left the route %d times"):format(walk.reroutes - 1))
   end
   local dirs, rooms = route(now, walk.target)
   if not dirs then return finish("no route from room " .. now) end
   log.debug("Re-planning from room %d (%s).", now, why)
   walk.dirs, walk.rooms, walk.origin = dirs, rooms, now
   walk.resends = 0
   begin(walk, 1)
end

local function onRoom(_, num)
   num = tonumber(num)
   local walk = M.walk
   if not walk or not num then return end
   if num == walk.from then return end   -- a LOOK, or Room.Info's duplicate
   if num == walk.target then return finish(nil, true) end
   for j = walk.i, #walk.rooms do
      if walk.rooms[j] == num then
         walk.resends = 0
         if M.paused then return end   -- resume() plans again from wherever this is
         return begin(walk, j + 1)
      end
   end
   if not M.paused then reroute(walk, num, "off the route") end
end

event.register("emunah.room", onRoom, "mapper-route")

--- A held step goes out on the tick that frees it; a lost one is sent again.
event.register("emunah.tick", function()
   local walk = M.walk
   if not walk or M.paused then return end
   if walk.held then return step() end
   if walk.sentAt and not walk.queue[1] then
      local wait = (tonumber(config.get("map.retryAfter", 3)) or 3) + (walk.extra or 0)
      if util.now() - walk.sentAt < wait then return end
      if walk.resends >= M.RESENDS then
         return finish(("no arrival after %s from room %s"):format(walk.dirs[walk.i],
            tostring(walk.from)))
      end
      walk.resends = walk.resends + 1
      begin(walk, walk.i)
   end
end, "mapper-route")

--- Room.WrongDir: the game says the exit we just took is not there. Lock it for this map
--- and plan around it. Only for the step we sent -- a typed wrong direction is not ours.
M.badExits = {}
event.register("emunah.room.wrongDirection", function(_, direction)
   local walk = M.walk
   if not walk or not walk.from then return end
   if bare(walk.dirs[walk.i]):lower() ~= tostring(direction):lower() then return end
   lockExit(walk.from, walk.dirs[walk.i], true)
   M.badExits[walk.from .. ":" .. walk.dirs[walk.i]] = true
   log.warn("The game has no %s exit in room %d; locked out of routes until the next map.",
      walk.dirs[walk.i], walk.from)
   M.invalidate()
   reroute(walk, walk.from, "wrong direction")
end, "mapper-route")

event.register("sysDisconnectionEvent", function() M.stop("disconnected") end, "mapper-route")
event.register("emunah.character.died", function() M.stop("died") end, "mapper-route")

-- ---------------------------------------------------------------------------
-- where is that? areas, features, nearest of many
-- ---------------------------------------------------------------------------

--- The closest of several rooms, by steps.
--- @return number|nil room, number|nil steps
function M.nearest(candidates)
   local from = here()
   if not from then return nil end
   local best, bestSteps
   for _, room in pairs(candidates) do
      local steps = M.distance(from, room)
      if steps and (not bestSteps or steps < bestSteps) then best, bestSteps = tonumber(room), steps end
   end
   return best, bestSteps
end

--- Areas whose name matches: an exact match alone if there is one, else every area
--- containing the text. Case-insensitive.
--- @return table list of { id, name }
function M.findAreas(query)
   query = util.trim(tostring(query or "")):lower()
   local exact, partial = {}, {}
   -- By id: two areas can share a name ("Delos, the Isle of" is two), and a table keyed by
   -- name would silently keep only one of them.
   for id, name in pairs(getAreaTableSwap() or {}) do
      local lower = name:lower()
      if lower == query then exact[#exact + 1] = { id = id, name = name }
      elseif lower:find(query, 1, true) then partial[#partial + 1] = { id = id, name = name } end
   end
   local list = #exact > 0 and exact or partial
   table.sort(list, function(a, b) return a.name < b.name end)
   return list
end

--- Rooms of an area with an exit out of it: the ways in. Cached per area until the map
--- changes, since walking every room of an area to find them is the costly part.
local borders = {}
event.register("emunah.map.loaded", function() borders = {} end, "mapper-route")

function M.borders(area)
   if borders[area] then return borders[area] end
   local list = {}
   for _, room in pairs(getAreaRooms(area) or {}) do
      local out = false
      for _, to in pairs(getRoomExits(room) or {}) do
         if getRoomArea(to) ~= area then out = true break end
      end
      if not out then
         for _, to in pairs(getSpecialExitsSwap(room) or {}) do
            if getRoomArea(tonumber(to)) ~= area then out = true break end
         end
      end
      if out then list[#list + 1] = room end
   end
   borders[area] = list
   return list
end

function M.goArea(area)
   local from = here()
   if from and getRoomArea(from) == area.id then
      log.info("Already in %s.", area.name)
      return false
   end
   local entry = M.nearest(M.borders(area.id))
   if not entry then
      log.warn("No way into %s from here.", area.name)
      return false
   end
   return M.go(entry, area.name)
end

-- Map features, in the map's own storage so the crowdmap's are found too [mmp]: the
-- map's user data "mapFeatures" holds name -> room character as JSON, and a room with
-- the feature has the user data "feature-<name>" = "true".

function M.features()
   local value = data.decode(getMapUserData and getMapUserData("mapFeatures"))
   return type(value) == "table" and value or {}
end

--- The feature a query names: exact, else the first containing it.
function M.findFeature(query)
   query = util.trim(tostring(query or "")):lower()
   local features = M.features()
   if features[query] then return query end
   local names = util.keys(features)
   table.sort(names)
   for _, name in ipairs(names) do
      if name:find(query, 1, true) then return name end
   end
   return nil
end

function M.featureRooms(name)
   local rooms = {}
   for _, room in pairs(searchRoomUserData("feature-" .. name, "true") or {}) do
      rooms[#rooms + 1] = tonumber(room)
   end
   return rooms
end

function M.goFeature(name)
   local rooms = M.featureRooms(name)
   local nearest = M.nearest(rooms)
   if not nearest then
      log.warn("None of the %d rooms with %s can be reached from here.", #rooms, name)
      return false
   end
   return M.go(nearest, "the nearest " .. name)
end

--- Rooms whose name matches, case-insensitively: { id = name }. `exact` wants the whole
--- name; otherwise any name containing the text. The crowdmap stores names without the
--- game's trailing period (data.cleanName), so a typed one is dropped.
function M.findRooms(query, exact)
   query = util.trim(tostring(query or "")):lower():gsub("%.$", "")
   local out = {}
   if query == "" then return out end
   for id, name in pairs(getRooms() or {}) do
      local lower = tostring(name):lower()
      if (exact and lower == query) or (not exact and lower:find(query, 1, true)) then
         out[tonumber(id)] = name
      end
   end
   return out
end

--- Walk to the nearest of the rooms named.
local function goNamed(rooms)
   local ids = util.keys(rooms)
   local nearest, steps = M.nearest(ids)
   if not nearest then
      log.warn("None of the %d rooms called that can be reached from here.", #ids)
      return false
   end
   local area = getRoomAreaName and getRoomAreaName(getRoomArea(nearest))
   local label = ("%s (%d%s)"):format(rooms[nearest], nearest, area and (", " .. area) or "")
   if #ids > 1 then label = "the nearest " .. label end
   return M.go(nearest, label)
end

--- `goto <where>`. A room number; else a whole name before a partial one, and among
--- whole names a feature, then an area, then a room -- so "goto bank" finds a bank, and
--- "goto fish street" the nearest of the four rooms called Fish Street. A partial name
--- tries an area (when only one matches), then a feature, then the nearest room whose name
--- contains it.
function M.travel(where)
   where = util.trim(tostring(where or ""))
   if where == "" then return false end
   if where:match("^%d+$") then return M.go(tonumber(where)) end
   local lower = where:lower()
   if lower == "back" then
      if not M.lastStart then log.info("No walk to go back from yet.") return false end
      return M.go(M.lastStart, "where the last walk started")
   end

   local features = M.features()
   if features[lower] then return M.goFeature(lower) end
   local areas = M.findAreas(where)
   if #areas >= 1 and areas[1].name:lower() == lower then return M.goArea(areas[1]) end
   local named = M.findRooms(where, true)
   if next(named) then return goNamed(named) end

   if #areas == 1 then return M.goArea(areas[1]) end
   local feature = M.findFeature(where)
   if feature then return M.goFeature(feature) end
   if #areas == 0 then
      named = M.findRooms(where, false)
      if next(named) then return goNamed(named) end
      log.warn("No room, feature or area called %q. `rf %s` searches room names.", where, where)
      return false
   end
   log.info("%d areas match %q:", #areas, where)
   for i = 1, math.min(#areas, 15) do
      local name = areas[i].name
      cechoLink("\n  " .. name, ([[emunah.mapper.route.goArea({ id = %d, name = %q })]])
         :format(areas[i].id, name), "Walk to " .. name, true)
   end
   return false
end

--- `rf <text>`: rooms whose name contains it, by area, each number a link that walks
--- there. [mmp: rf / room find]
M.FIND_SHOWN = 60

function M.find(query)
   local rooms = M.findRooms(query, false)
   local byArea, count = {}, 0
   for id, name in pairs(rooms) do
      count = count + 1
      local area = getRoomAreaName and getRoomAreaName(getRoomArea(id)) or "?"
      byArea[area] = byArea[area] or {}
      table.insert(byArea[area], { id = id, name = name })
   end
   if count == 0 then
      log.info("No room names contain %q.", tostring(query))
      return 0
   end
   local areas = util.keys(byArea)
   table.sort(areas)
   local theme = emunah.ui.theme
   decho(("\n%s%d room%s matching %q:"):format(theme.dc("text"), count, count == 1 and "" or "s",
      tostring(query)))
   local shown = 0
   for _, area in ipairs(areas) do
      if shown >= M.FIND_SHOWN then break end
      decho("\n  " .. theme.dc("textDim") .. area)
      table.sort(byArea[area], function(a, b) return a.id < b.id end)
      for _, room in ipairs(byArea[area]) do
         if shown >= M.FIND_SHOWN then break end
         shown = shown + 1
         decho("\n    ")
         dechoLink(theme.dc("balance") .. tostring(room.id),
            ("emunah.mapper.route.go(%d, %q)"):format(room.id, room.name),
            "Walk to " .. room.name, true)
         decho(theme.dc("text") .. "  " .. room.name)
      end
   end
   if shown < count then
      decho(("\n  %s...and %d more; narrow the search."):format(theme.dc("textDim"), count - shown))
   end
   return count
end

-- ---------------------------------------------------------------------------
-- clicking on the map
-- ---------------------------------------------------------------------------

--- Mudlet calls the global doSpeedWalk() when a room on the map is double-clicked, with
--- speedWalkPath already holding the route. mmp defines it; without mmp, nothing would.
--- Ours walks to the clicked room through this router. Left alone while mmp is running,
--- so the two never fight over the same click.
function M.installClickHandler()
   if data.mmpActive() then return false end
   _G.doSpeedWalk = function()
      local path = speedWalkPath or {}
      local target = tonumber(path[#path])
      if target then M.go(target) end
   end
   return true
end
M.installClickHandler()

-- ---------------------------------------------------------------------------
-- unmapped rooms
-- ---------------------------------------------------------------------------

M.unmapped = {}
event.register("emunah.room", function(_, num)
   num = tonumber(num)
   if not num or not roomExists or roomExists(num) or M.unmapped[num] then return end
   M.unmapped[num] = true
   log.warn("Room %d (%s) is not on the map; routes from here will fail until you leave it.",
      num, tostring(emunah.gmcp.room.name or "?"))
end, "mapper-route")

-- Put the policy on the map at startup if this map has not had it yet. Deferred a beat
-- so the rest of Emunah finishes loading first; it walks every room.
timers.start("map.policy", 1, function() M.applyPolicy(false) end)

return M

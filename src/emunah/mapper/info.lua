--- What the map knows: one room in detail, the areas, an area's rooms, and room numbers for
--- a room named in the game's text. Read-only; walking is mapper/route.lua's.
---
--- [mmp] The counterparts are `rl` (mmp.roomLook), `area list`, `room list` and
--- mmp.echonums. Every room number printed here is a link that walks there.

local M = {}

local util  = emunah.util
local log   = emunah.log
local data  = emunah.mapper.data
local route = emunah.mapper.route

local function theme() return emunah.ui.theme end
local function dc(key) return theme().dc(key) end

--- A room number as a link that walks there.
local function link(id, name)
   dechoLink(dc("balance") .. tostring(id), ("emunah.mapper.route.go(%d, %q)"):format(id,
      tostring(name or ("room " .. id))), "Walk to " .. tostring(name or id), true)
end

local function line(label, value)
   decho(("\n  %s%-12s%s %s"):format(dc("textDim"), label, dc("text"), tostring(value)))
end

local function areaName(id)
   return getRoomAreaName and getRoomAreaName(id) or tostring(id)
end

--- Environment names for an id. Several share one in the crowdmap (data.ENV's note), so
--- this can be more than one.
function M.envNames(env)
   local names = {}
   for name, id in pairs(data.ENV) do
      if id == env then names[#names + 1] = name end
   end
   table.sort(names)
   return names
end

--- Why an exit is out of routing, or nil: your lock, a refused exit, a script we do not run,
--- or the routing policy.
local function exitNote(room, exit, to)
   local overlay = data.store.overlay.lockExit[room] or {}
   local short = route.shortDir(exit)
   for locked in pairs(overlay) do
      if locked == exit or route.shortDir(locked) == short then return "locked by you" end
   end
   if route.badExits[room .. ":" .. exit] or route.badExits[room .. ":" .. short] then
      return "locked: the game refused it"
   end
   if route.unreadable[room .. ">" .. tostring(to)] then return "locked: a script Emunah does not run" end
   return nil
end

--- `emset room [number]`: everything the map holds about one room. [mmp: rl]
function M.room(num)
   num = tonumber(num) or tonumber(emunah.gmcp.room.num)
   if not num then log.warn("Which room? `emset room <number>`.") return false end
   if not roomExists(num) then log.warn("Room %d is not on the map.", num) return false end

   local name = getRoomName(num)
   local area = getRoomArea(num)
   decho(("\n%s%s %s(%d)"):format(dc("textBright"), tostring(name), dc("textDim"), num))
   local game = getRoomUserData(num, "Game Area")
   line("area", areaName(area) .. ((game ~= "" and game ~= areaName(area))
      and (dc("textDim") .. "  (the game calls it " .. game .. ")") or ""))
   local env = getRoomEnv(num)
   local envNames = M.envNames(env)
   local inside = getRoomUserData(num, "indoors") == "y" and "indoors"
      or getRoomUserData(num, "outdoors") == "y" and "outdoors" or "not recorded"
   line("environment", (#envNames > 0 and table.concat(envNames, " / ") or "?") .. " (" .. env
      .. "), " .. inside)
   local x, y, z = getRoomCoordinates(num)
   line("coordinates", ("%s, %s, %s"):format(tostring(x), tostring(y), tostring(z)))

   local locked = roomLocked(num)
   local why = data.store.overlay.lockRoom[num] and "locked by you" or locked and "locked" or "no"
   line("locked", why)
   local weight = getRoomWeight and getRoomWeight(num) or 1
   if weight and weight ~= 1 then line("weight", weight) end

   local here = tonumber(emunah.gmcp.room.num)
   if here and here ~= num then
      local steps = route.distance(here, num)
      line("from here", steps and (steps .. " step" .. (steps == 1 and "" or "s")) or "no route")
   end

   local features = {}
   for feature in pairs(route.features()) do
      if getRoomUserData(num, "feature-" .. feature) == "true" then features[#features + 1] = feature end
   end
   if #features > 0 then
      table.sort(features)
      line("features", table.concat(features, ", "))
   end

   local exits = getRoomExits(num) or {}
   local weights = getExitWeights and getExitWeights(num) or {}
   local dirs = util.keys(exits)
   table.sort(dirs)
   decho(("\n  %sexits (%d)"):format(dc("textDim"), #dirs))
   for _, dir in ipairs(dirs) do
      local to = exits[dir]
      decho(("\n    %s%-10s "):format(dc("text"), dir))
      link(to, getRoomName(to))
      local extra = {}
      if getRoomArea(to) ~= area then extra[#extra + 1] = "in " .. areaName(getRoomArea(to)) end
      if hasExitLock and hasExitLock(num, dir) then
         extra[#extra + 1] = exitNote(num, dir, to) or "locked"
      end
      local w = weights[dir] or weights[route.shortDir(dir)]
      if w and w > 1 then extra[#extra + 1] = "weight " .. w end
      decho(("%s  %s%s"):format(dc("text"), tostring(getRoomName(to)),
         #extra > 0 and (dc("textDim") .. "  (" .. table.concat(extra, ", ") .. ")") or ""))
   end

   local specials = getSpecialExitsSwap(num) or {}
   local commands = util.keys(specials)
   table.sort(commands)
   if #commands > 0 then
      decho(("\n  %sspecial exits (%d)"):format(dc("textDim"), #commands))
      for _, command in ipairs(commands) do
         local to = tonumber(specials[command])
         local plan = route.plan(command)
         local shown = command
         if command:find("script:", 1, true) then
            if plan then
               local parts = {}
               for _, step in ipairs(plan) do
                  parts[#parts + 1] = step.send or ("wait " .. step.wait .. "s")
               end
               shown = table.concat(parts, ", ")
            else
               shown = "a script Emunah does not run"
            end
         end
         decho("\n    ")
         link(to, getRoomName(to))
         local note = exitNote(num, command, to)
         decho(("%s  %s %s%s"):format(dc("text"), tostring(getRoomName(to)),
            dc("textDim") .. "by " .. dc("accent") .. shown,
            note and (dc("textDim") .. "  (" .. note .. ")") or ""))
      end
   end
   return true
end

--- `emset areas [text]`: every area (or those whose name contains the text), with room
--- counts, each a link to its room list. [mmp: area list]
function M.areas(filter)
   filter = filter and util.trim(filter):lower() or nil
   local rows, total = {}, 0
   for id, name in pairs(getAreaTableSwap() or {}) do
      if id ~= 0 and (not filter or filter == "" or name:lower():find(filter, 1, true)) then
         local count = 0
         -- getAreaRooms() is 0-indexed in Mudlet; pairs, never #.
         for _ in pairs(getAreaRooms(id) or {}) do count = count + 1 end
         rows[#rows + 1] = { id = id, name = name, count = count }
         total = total + count
      end
   end
   if #rows == 0 then log.info("No areas match %q.", tostring(filter)) return 0 end
   table.sort(rows, function(a, b) return a.name < b.name end)
   decho(("\n%s%d area%s, %s rooms (click one for its rooms):"):format(dc("text"), #rows,
      #rows == 1 and "" or "s", util.comma(total)))
   for _, row in ipairs(rows) do
      decho("\n  ")
      dechoLink(dc("text") .. row.name, ("emunah.mapper.info.rooms(%q)"):format(row.name),
         "The rooms in " .. row.name, true)
      decho(("%s  %d room%s"):format(dc("textDim"), row.count, row.count == 1 and "" or "s"))
   end
   return #rows
end

--- `emset rooms <area>`: an area's rooms, by number. [mmp: room list]
function M.rooms(query)
   local areas = route.findAreas(query or "")
   if #areas == 0 then log.warn("No area called %q. `emset areas` lists them.", tostring(query)) return 0 end
   if #areas > 1 then
      log.info("%d areas match %q; pick one:", #areas, tostring(query))
      for i = 1, math.min(#areas, 20) do
         decho("\n  ")
         dechoLink(dc("text") .. areas[i].name, ("emunah.mapper.info.rooms(%q)"):format(areas[i].name),
            "The rooms in " .. areas[i].name, true)
      end
      return 0
   end
   local area = areas[1]
   local ids = {}
   for _, id in pairs(getAreaRooms(area.id) or {}) do ids[#ids + 1] = tonumber(id) end
   table.sort(ids)
   decho(("\n%s%s: %d room%s"):format(dc("text"), area.name, #ids, #ids == 1 and "" or "s"))
   for _, id in ipairs(ids) do
      local name = getRoomName(id)
      decho("\n  ")
      link(id, name)
      decho(dc("text") .. "  " .. tostring(name))
   end
   return #ids
end

--- Rooms with exactly this name, nearest first. The name may carry the game's trailing
--- period. `area` narrows it to an area whose name contains that text.
function M.numbers(name, area)
   local rooms = route.findRooms(name, true)
   local ids = {}
   for id in pairs(rooms) do
      if not area or tostring(areaName(getRoomArea(id))):lower():find(area:lower(), 1, true) then
         ids[#ids + 1] = id
      end
   end
   local here = tonumber(emunah.gmcp.room.num)
   local steps = {}
   for _, id in ipairs(ids) do steps[id] = here and route.distance(here, id) or math.huge end
   table.sort(ids, function(a, b)
      local sa, sb = steps[a] or math.huge, steps[b] or math.huge
      if sa ~= sb then return sa < sb end
      return a < b
   end)
   return ids
end

--- Echo, at the cursor, the numbers of the rooms with this name: the nearest three as
--- links, then a count. For a line that names a room -- a locator, a shrine alert -- so
--- the place can be walked to with a click. [mmp: mmp.echonums]
--- @return number how many rooms have that name
function M.echoNumbers(name, area)
   local ids = M.numbers(name, area)
   if #ids == 0 then
      decho(dc("textDim") .. " (not on the map)")
      return 0
   end
   decho(dc("textDim") .. " (")
   for i = 1, math.min(3, #ids) do
      if i > 1 then decho(dc("textDim") .. ", ") end
      link(ids[i], getRoomName(ids[i]))
   end
   if #ids > 3 then decho(dc("textDim") .. (", +%d"):format(#ids - 3)) end
   decho(dc("textDim") .. ")")
   return #ids
end

return M

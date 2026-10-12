--- Where people are: locator lines turned into room numbers you can click, a last-known
--- location for everyone located, and their rooms lit on the map.
---
--- The lines are mmp's, verbatim, generated into mapper/lines.lua (see
--- tools/build-mapper-lines.py). What each match does is here. Only the groups switched on
--- in `map.locators` get a trigger, so a locator nobody uses costs nothing.
---
--- WHAT A MATCH ADDS TO THE LINE
--- -----------------------------
--- The rooms with that name, nearest first, three as links, and the nearest one's area:
---
---     Your guardian angel senses Erishka at Fish Street, on a health of ... (2098, 2097,
---     2171, +1) (Targossas, the City of)
---
--- That tail is what mmp added to these lines -- the user saw it there and was told it was
--- the mapper's (docs/game/help/who-listings.txt, 2026-10-03); this is our own. It is
--- appended, never parsed back: namedb/capture.lua and presences.lua read the same angel
--- line and stop at ", on a health", before anything a script adds.
---
--- THE ANGEL'S TWO SHAPES [mmp]
--- ----------------------------
--- After "You bid your guardian angel to seek out life presences nearby." and until the
--- prompt, each "Your guardian angel senses X at <room>," is one person in the scan. Outside
--- a scan the same opening is a sense of one place, and the lines after it, " is with X.",
--- name who is there. mmp switches its Angel sense trigger off for the scan; here the
--- window decides which reading applies.
---
--- WHO B [mmp]
--- -----------
--- mmp parses `Name (Room)` rows for ten seconds after it sends WHO B. A row that shape is
--- far too common to watch all the time, so the same window opens when YOU send WHO B --
--- Emunah never sends it.

local M = {}

local util   = emunah.util
local log    = emunah.log
local event  = emunah.event
local config = emunah.config
local timers = emunah.timers
local lines  = emunah.mapper.lines
local info   = emunah.mapper.info
local route  = emunah.mapper.route

--- [mmp] How long WHO B rows are read after it is sent.
M.WHO_WINDOW = 10

M.GROUPS = { "farsee", "view", "mindsense", "allsight", "alertness", "angel", "shrines",
             "shop", "who" }

emunah._persist.locate = emunah._persist.locate or {}
local persist = emunah._persist.locate

--- Last known locations: lower-case name -> { name, room, area, ids, at, via }.
persist.people = persist.people or {}
M.people = persist.people

local function dc(key) return emunah.ui.theme.dc(key) end

--- The groups switched on. The setting is a list, or a comma-separated string when typed
--- with `emset map.locators ...`; either way, an unknown name is ignored.
function M.enabledGroups()
   local value = config.get("map.locators", nil)
   local set = {}
   if value == nil then
      for _, group in ipairs(M.GROUPS) do set[group] = true end
   elseif type(value) == "table" then
      for _, group in ipairs(value) do set[tostring(group):lower()] = true end
   else
      for group in tostring(value):gmatch("[^,%s]+") do set[group:lower()] = true end
   end
   return set
end

-- ---------------------------------------------------------------------------
-- the people
-- ---------------------------------------------------------------------------

local function unlight(person)
   for _, id in ipairs(person.lit or {}) do unHighlightRoom(id) end
   person.lit = nil
end

--- Light a person's rooms on the map for map.trackFor minutes. Only when the name gives
--- three rooms or fewer: lighting a dozen "A forest path" rooms points nowhere.
local function light(key, person)
   unlight(person)
   local minutes = tonumber(config.get("map.trackFor", 5)) or 5
   if minutes <= 0 or #person.ids == 0 or #person.ids > 3 then return end
   person.lit = {}
   for _, id in ipairs(person.ids) do
      if highlightRoom(id, 255, 165, 0, 255, 165, 0, 0.6, 220, 0) then
         person.lit[#person.lit + 1] = id
      end
   end
   timers.start("map.track." .. key, minutes * 60, function() unlight(person) end)
end

--- Record where someone is. `ids` when the room is known exactly (alertness); otherwise
--- the rooms with that name.
--- @return table the rooms, nearest first
function M.record(name, roomName, via, area, ids)
   if not name or name == "" then return {} end
   ids = ids or info.numbers(roomName, area)
   local key = name:lower()
   local person = M.people[key] or {}
   person.name, person.room, person.area, person.ids = name, roomName, area, ids
   person.at, person.via = util.now(), via
   M.people[key] = person
   light(key, person)
   event.raise("map.located", name, ids[1], roomName)
   return ids
end

--- Someone's last known rooms, by name (any case), or nil.
function M.find(name)
   return M.people[tostring(name or ""):lower()]
end

--- After the line: the nearest rooms with that name as links, and the nearest one's area.
local function tail(roomName, area)
   local count = info.echoNumbers(roomName, area)
   if count > 0 then
      local ids = info.numbers(roomName, area)
      local areaName = getRoomAreaName and getRoomAreaName(getRoomArea(ids[1]))
      if areaName then decho(dc("textDim") .. " (" .. areaName .. ")") end
   end
end

-- ---------------------------------------------------------------------------
-- what each kind of line does
-- ---------------------------------------------------------------------------

local scanning, senseRoom, whoUntil = false, nil, 0

local function capture(entry, role)
   local index = entry[role]
   return index and matches[index + 1] or nil
end

local handle = {}

function handle.person(entry)
   local name, room = capture(entry, "person"), capture(entry, "room")
   M.record(name, room, entry.key, capture(entry, "area"))
   tail(room, capture(entry, "area"))
end

--- Alertness names the room next to you and the direction, so the room is known exactly:
--- the exit that way from here, or here itself "at your location".
function handle.near(entry)
   local name, room, dir = capture(entry, "person"), capture(entry, "room"), capture(entry, "dir")
   local here = tonumber(emunah.gmcp.room.num)
   local id
   if dir == "location" then
      id = here
   elseif here then
      local exits = getRoomExits(here) or {}
      id = exits[dir] or exits[route.shortDir(dir)]
   end
   if id then
      M.record(name, room, entry.key, nil, { tonumber(id) })
      decho(dc("textDim") .. " (")
      dechoLink(dc("balance") .. tostring(id), ("emunah.mapper.route.go(%d, %q)"):format(id, room),
         "Walk to " .. room, true)
      decho(dc("textDim") .. ")")
   else
      M.record(name, room, entry.key)
      tail(room)
   end
end

function handle.angel(entry)
   if entry.key == "angel.scan" then
      if not scanning then return end
      handle.person(entry)
   elseif not scanning then
      senseRoom = capture(entry, "room")
      tail(senseRoom)
   end
end

function handle.with(entry)
   if not senseRoom then return end
   M.record(capture(entry, "person"), senseRoom, entry.key)
end

function handle.place(entry)
   tail(capture(entry, "room"))
end

--- A shop directory row: the shop's room name starts at mmp's column. One room with that
--- name: the name becomes a link that walks there. Several, or none: left as it is.
function handle.shop(entry)
   local line = getCurrentLine() or ""
   local column = entry.column or 48
   local name = util.trim(line:sub(column + 1))
   if name == "" then return end
   local ids = info.numbers(name)
   if #ids ~= 1 then return end
   if not selectSection(column, #line - column) then return end
   replace("")
   dechoLink(dc("accent") .. name, ("emunah.mapper.route.go(%d, %q)"):format(ids[1], name),
      "Walk to " .. name, true)
end

function handle.who(entry)
   if util.now() > whoUntil then return end
   handle.person(entry)
end

-- ---------------------------------------------------------------------------
-- triggers
-- ---------------------------------------------------------------------------

-- Reload-safe: the previous generation's triggers go before this one's are made.
persist.triggers = persist.triggers or {}
for _, id in ipairs(persist.triggers) do killTrigger(id) end
persist.triggers = {}

--- Register a trigger for each line of each group switched on. Called again whenever the
--- setting changes (`emset map.locators ...` then `emset map locators` or a reload).
function M.build()
   for _, id in ipairs(persist.triggers) do killTrigger(id) end
   persist.triggers = {}
   local groups = M.enabledGroups()
   local count = 0
   for _, entry in ipairs(lines.LINES) do
      if groups[entry.group] then
         local id = tempRegexTrigger(entry.pattern, function()
            local ok, err = pcall(handle[entry.kind], entry)
            if not ok then log.debug("Locator %s failed: %s", entry.key, tostring(err)) end
         end)
         persist.triggers[#persist.triggers + 1] = id
         count = count + 1
      end
   end
   if groups.angel then
      for _, opener in ipairs(lines.SCAN_OPENERS) do
         local escaped = opener:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?%{%}|\\])", "\\%1")
         persist.triggers[#persist.triggers + 1] = tempRegexTrigger("^" .. escaped .. "$",
            function() scanning, senseRoom = true, nil end)
      end
   end
   return count
end

event.register("emunah.prompt", function()
   scanning, senseRoom = false, nil
end, "mapper-locate")

event.register("emunah.sent", function(_, command)
   if util.trim(tostring(command or "")):lower() == "who b" then
      whoUntil = util.now() + M.WHO_WINDOW
   end
end, "mapper-locate")

-- ---------------------------------------------------------------------------
-- emset where
-- ---------------------------------------------------------------------------

--- `emset where [person]`: who has been located, newest first, with their rooms as links.
function M.report(name)
   local list = {}
   for _, person in pairs(M.people) do
      if not name or person.name:lower():find(name:lower(), 1, true) then list[#list + 1] = person end
   end
   table.sort(list, function(a, b) return a.at > b.at end)
   if #list == 0 then
      log.info(name and ("Nobody called %s has been located.") or "Nobody has been located yet.",
         tostring(name))
      return 0
   end
   for _, person in ipairs(list) do
      local age = util.duration(math.max(0, util.now() - person.at))
      decho(("\n  %s%-14s%s %s"):format(dc("textBright"), person.name, dc("text"), tostring(person.room)))
      if person.ids[1] then
         decho(dc("textDim") .. " (")
         for i = 1, math.min(3, #person.ids) do
            if i > 1 then decho(dc("textDim") .. ", ") end
            dechoLink(dc("balance") .. person.ids[i], ("emunah.mapper.route.go(%d, %q)"):format(
               person.ids[i], person.name), "Walk to " .. person.name, true)
         end
         decho(dc("textDim") .. ")")
      end
      decho(("%s  %s ago, %s"):format(dc("textDim"), age, person.via or "?"))
   end
   return #list
end

--- For the suite: the handlers, by kind, so a line the mock cannot express as a Lua
--- pattern (the shop row's two non-capturing groups) can still be driven.
M.handle = handle

M.build()

return M

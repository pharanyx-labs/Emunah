--- Room.Info and the room player list.
---
--- Messages:
---   Room.Info          { num, name, area, environment, coords, map, details, exits }
---   Room.Players       array of { name, fullname }   -- replaces the list
---   Room.AddPlayer     { name, fullname }
---   Room.RemovePlayer  a bare NAME STRING (not an object)
---   Room.WrongDir      a direction string
---
--- A caveat that matters more than it looks: the player list is not complete. Anyone concealed -- shrouded, hiding, phased -- generates no Room.Players
--- entry at all. Treat this list as "players the game is willing to tell me about",
--- never as "players in the room". Anything safety-critical (deciding a room is empty
--- before doing something vulnerable) must not rely on it.

local M = {}

local util  = emunah.util
local event = emunah.event

--- Current room.
M.num, M.name, M.area, M.environment = nil, nil, nil, nil
M.coords, M.map = nil, nil
M.exits   = {}     -- direction -> room number
M.details = {}     -- array: "shop", "bank", ...

--- name (lower) -> fullname
M.players = {}

--- name (lower) -> true-case short name, e.g. "anzerloi" -> "Anzerloi". A parallel table
--- rather than a field on M.players' values: namedb.lua and namedb/capture.lua already
--- iterate `pairs(room.players)` expecting a plain fullname string, and changing that
--- shape would break both for the sake of a display-only need here.
M.playerShort = {}

local function onInfo()
   local info = gmcp.Room.Info
   if type(info) ~= "table" then return end

   local previous = M.num

   M.num         = util.num(info.num, nil)
   M.name        = info.name and tostring(info.name)
   M.area        = info.area and tostring(info.area)
   M.environment = info.environment and tostring(info.environment)
   M.coords      = info.coords and tostring(info.coords)
   M.map         = info.map and tostring(info.map)

   M.exits = {}
   for direction, target in pairs(info.exits or {}) do
      M.exits[tostring(direction)] = util.num(target, target)
   end

   M.details = {}
   for _, detail in ipairs(info.details or {}) do
      M.details[#M.details + 1] = tostring(detail)
   end

   -- Moving invalidates the player list; Room.Players follows but not always instantly,
   -- and showing the previous room's occupants for a beat is worse than showing none.
   if previous ~= M.num then
      M.players = {}
      M.playerShort = {}
   end

   event.raise("room", M.num, M.name)
end

--- Our own character name, from whichever source has it.
---
--- Char.Status is NOT dependable here. It arrives on login and on request, and a GMCP trace
--- of ordinary play shows room changes carrying Char.Vitals, Char.Items.List, Room.Info and
--- Room.Players with no Char.Status anywhere. Consulting it alone meant comparing every
--- player name against nil, so we never recognised ourselves -- and since Achaea's
--- Room.Players includes you, every room reported one occupant. That made
--- `bashing.stopOnPlayer` and the walker's equivalent unusable: switch either on and the
--- loop halts immediately, alone, reporting a player who is you.
---
--- Char.Name is the reliable one (sent once at connect, and retained in the raw gmcp table
--- across a reload), so it is checked first and Char.Status is the fallback.
function M.selfName()
   local name = emunah.gmcp and emunah.gmcp.character
   if name and name ~= "" then return tostring(name) end
   if gmcp and gmcp.Char and gmcp.Char.Name and gmcp.Char.Name.name then
      return tostring(gmcp.Char.Name.name)
   end
   local status = emunah.gmcp and emunah.gmcp.status
   name = status and status.name()
   if name and name ~= "" then return tostring(name) end
   return nil
end

--- Is this name us? Case-insensitive: nothing guarantees the casing matches between
--- Room.Players and whichever source named us.
function M.isSelf(name)
   local mine = M.selfName()
   if not (mine and name) then return false end
   return tostring(name):lower() == mine:lower()
end

local function onPlayers()
   local players = gmcp.Room.Players
   if type(players) ~= "table" then return end

   M.players = {}
   M.playerShort = {}
   for _, player in ipairs(players) do
      if player.name then
         local name = tostring(player.name)
         -- Exclude ourselves; every consumer wants "others here".
         if not M.isSelf(name) then
            M.players[name:lower()] = player.fullname and tostring(player.fullname) or name
            M.playerShort[name:lower()] = name
         end
      end
   end

   event.raise("room.players", M.playerNames())
end

local function onAddPlayer()
   local player = gmcp.Room.AddPlayer
   if type(player) ~= "table" or not player.name then return end
   local name = tostring(player.name)
   -- Same exclusion as the full list. Walking into a room can produce an AddPlayer for
   -- yourself, and one that slipped through would read as "another player arrived" -- which
   -- is a thing several consumers stop dead for.
   if M.isSelf(name) then return end
   M.players[name:lower()] = player.fullname and tostring(player.fullname) or name
   M.playerShort[name:lower()] = name
   event.raise("room.playerEntered", name)
end

local function onRemovePlayer()
   -- Arrives as a bare string, not an object.
   local raw = gmcp.Room.RemovePlayer
   local name = type(raw) == "table" and raw.name or raw
   if not name then return end
   name = tostring(name)
   M.players[name:lower()] = nil
   M.playerShort[name:lower()] = nil
   event.raise("room.playerLeft", name)
end

local function onWrongDir()
   local direction = gmcp.Room.WrongDir
   if not direction then return end
   -- Useful for mapper correction: the game is telling us an exit we believed in is not
   -- there. We surface it as an event rather than acting on it, so the mapper (or a
   -- walker script) can decide.
   event.raise("room.wrongDirection", tostring(direction))
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

--- Sorted names of other players the game has told us about.
function M.playerNames()
   local out = {}
   for _, fullname in pairs(M.players) do out[#out + 1] = fullname end
   table.sort(out)
   return out
end

--- Sorted true-case SHORT names (no honorific/title), for display where the full name is
--- too long to be useful -- e.g. the room panel, which has one line to work with.
function M.playerShortNames()
   local out = {}
   for _, name in pairs(M.playerShort) do out[#out + 1] = name end
   table.sort(out)
   return out
end

function M.playerCount()
   return util.count(M.players)
end

--- Is a specific player here (as far as the game will admit)?
function M.hasPlayer(name)
   return M.players[tostring(name or ""):lower()] ~= nil
end

--- Sorted exit directions.
function M.exitList()
   return util.keys(M.exits)
end

function M.hasExit(direction)
   return M.exits[tostring(direction or "")] ~= nil
end

--- Does the room have a given detail, e.g. "shop", "bank"?
function M.hasDetail(detail)
   return util.contains(M.details, tostring(detail or ""))
end

function M.current()
   return {
      num = M.num, name = M.name, area = M.area,
      environment = M.environment, coords = M.coords,
      exits = util.copy(M.exits), details = util.copy(M.details),
      players = M.playerNames(),
   }
end

event.gmcp("Room.Info",         onInfo,         "gmcp.room")
event.gmcp("Room.Players",      onPlayers,      "gmcp.room")
event.gmcp("Room.AddPlayer",    onAddPlayer,    "gmcp.room")
event.gmcp("Room.RemovePlayer", onRemovePlayer, "gmcp.room")
event.gmcp("Room.WrongDir",     onWrongDir,     "gmcp.room")

event.register("sysDisconnectionEvent", function()
   M.players = {}
end, "gmcp.room")

if gmcp and gmcp.Room and gmcp.Room.Info then
   onInfo()
   if gmcp.Room.Players then onPlayers() end
end

return M

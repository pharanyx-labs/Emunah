--- The map itself: keeping the crowdmap current, keeping your own changes on it across
--- updates, and correcting it from GMCP as you walk.
---
--- Replaces the map-data half of the IRE Mudlet Mapper (mmp). The map is still the
--- crowd-sourced Achaea map that mmp uses, loaded into Mudlet's own map store with
--- loadMap(), so getPath() and the map widget keep working unchanged. Everything here that
--- reproduces mmp behaviour was read from the mmp script installed in the profile
--- (`map downloads/mudlet-mapper.xml`) and is marked [mmp].
---
--- WHERE THE MAP COMES FROM [mmp]
--- ------------------------------
---   version.txt    one token, the published map's version ("486")
---   changelog.txt  `changelog = { [[entry]], [[entry]], ... }` -- Lua source
---   map            a binary Mudlet map, loaded with loadMap()
---
--- The changelog is Lua, and mmp runs it (in an empty environment). We never execute it:
--- the entries are long-bracket strings, and a pattern match reads them without handing a
--- downloaded file the interpreter. It also cannot be indexed by version -- the copy in the
--- profile has 483 entries for version 486 -- so "what changed" is the entries past the
--- count we saw last time, not a version range.
---
--- THE OVERLAY
--- -----------
--- loadMap() replaces the whole map, so anything set on the map in Mudlet -- a locked room,
--- a weight -- is gone after every update. mmp copies its private marks across by hand and
--- loses the rest. Ours keeps what you set in emunah-map.lua, outside the map, and applies
--- it again after every load. Each kind is applied here so a load can never come back
--- half-restored; the modules that set them write through M.remember / M.forget.
---
--- WHEN mmp IS STILL RUNNING
--- -------------------------
--- The user's plan keeps mmp installed but disabled until this replaces it. If its scripts
--- are running anyway, two checkers would download the map twice and load it twice, so we
--- stand back and say so. `mmp.checkforupdate` is the function its hourly timer calls; its
--- presence means mmp's scripts are live.

local M = {}

local util   = emunah.util
local log    = emunah.log
local event  = emunah.event
local config = emunah.config
local timers = emunah.timers

local HOME = getMudletHomeDir()
local PATH = HOME .. "/emunah-map.lua"

--- [mmp] The published Achaea crowdmap. mmp asks for these over http; GitHub Pages serves
--- the same files over https.
M.URL = {
   version   = "https://ire-mudlet-mapping.github.io/AchaeaCrowdmap/Map/version.txt",
   changelog = "https://ire-mudlet-mapping.github.io/AchaeaCrowdmap/Map/changelog.txt",
   map       = "https://ire-mudlet-mapping.github.io/AchaeaCrowdmap/Map/map",
}

--- Where each download lands. One fixed name per kind: a download that arrives after
--- another of the same kind replaced it is caught by `M.busy`, not by unique names.
M.FILE = {
   version   = HOME .. "/emunah-crowdmap-version.txt",
   changelog = HOME .. "/emunah-crowdmap-changelog.txt",
   map       = HOME .. "/emunah-crowdmap.dat",
}

--- mmp's record of the map it last loaded: `{"version":"486","identity":"published:achaea"}`,
--- or a bare version from older copies. Read once, so switching over does not download a
--- map that is already loaded.
M.MMP_MARKER = HOME .. "/map downloads/current"

--- How long a download may take before we stop waiting for it. The map is several
--- megabytes; the other two are a few kilobytes.
M.TIMEOUT = { version = 60, changelog = 60, map = 600 }

--- How many changelog entries to print at most after an update.
M.CHANGELOG_SHOWN = 10

--- [mmp] GMCP environment name -> the crowdmap's environment id, from
--- mmp.registerAchaeasEnvData, verbatim. Some ids are shared (Mountains and Catacombs are
--- both 14; River and Skies 10; Water and Deep Ocean floor 30). That is how the crowdmap is
--- coloured, so it is kept rather than "fixed" -- a different id here would recolour the
--- crowdmap's own rooms on the next visit.
M.ENV = {
   ["Constructed underground"] = 2, ["Crimson Sea"] = 45, ["Deep Ocean"] = 24,
   ["Deep Ocean floor"] = 30, ["Dwarven city"] = 18, ["Lava Fields"] = 39,
   ["Magma Caves"] = 31, ["Natural underground"] = 3, ["Ocean floor"] = 34,
   ["Planar Highway"] = 42, ["Sanguine River"] = 44, ["Tsol'aa city"] = 19,
   ["Vast Ocean"] = 40, Abstract = 37, Agrarian = 48, Ausafoss = 47, Beach = 5,
   Blighted = 29, Catacombs = 14, Chaos = 38, Desert = 6, Earthen = 43, Flames = 49,
   Forest = 4, Freshwater = 22, Garden = 21, Grasslands = 7, Hills = 9, Jungle = 17,
   Mountains = 14, Nothing = 0, Ocean = 20, Path = 11, Polar = 27, Reef = 25, River = 10,
   Road = 12, Ruins = 32, Sewer = 23, Skies = 10, Storm = 50, Swamp = 15, Trees = 28,
   Tundra = 16, Urban = 8, Valley = 13, Vessel = 36, Viscera = 46, Wastelands = 41,
   Water = 30,
}

-- ---------------------------------------------------------------------------
-- the store: map version, changelog position and the overlay
-- ---------------------------------------------------------------------------

--- The overlay's kinds, each keyed by room number (or area name for areas):
---   lockRoom    [room] = true                 keep the room out of every route
---   lockExit    [room] = { [exit] = true }    keep one exit out ("north", or a special
---                                             exit's command)
---   roomWeight  [room] = n                    prefer routes around the room
---   exitWeight  [room] = { [exit] = n }
---   lockArea    [area name] = true            lock every room in the area; by name, because
---                                             area ids are the map's and can change
---                                             between crowdmap versions, names do not
local KINDS = { lockRoom = true, lockExit = true, roomWeight = true, exitWeight = true,
                lockArea = true }

local function emptyStore()
   local overlay = {}
   for kind in pairs(KINDS) do overlay[kind] = {} end
   return { version = nil, changes = nil, checkedAt = nil, overlay = overlay }
end

-- Survives a reload: a reload mid-download must not forget the version it was fetching.
emunah._persist.mapper = emunah._persist.mapper or {}
local persist = emunah._persist.mapper

function M.save()
   local ok, err = pcall(table.save, PATH, M.store)
   if not ok then log.error("Could not save the map overlay: %s", tostring(err)) end
   return ok
end

--- mmp's version marker, if it describes the published crowdmap. A marker for the game's
--- own map or for the crowdmap service is a different map, and is not adopted.
function M.mmpVersion()
   local file = io.open(M.MMP_MARKER, "r")
   if not file then return nil end
   local text = util.trim(file:read("*a") or "")
   file:close()
   if text == "" then return nil end
   local version = text:match('"version"%s*:%s*"([^"]*)"')
   if not version then return text:match("^(%S+)$") end
   local identity = text:match('"identity"%s*:%s*"([^"]*)"')
   if identity and identity ~= "published:achaea" then return nil end
   return version ~= "" and version or nil
end

function M.load()
   local loaded = {}
   local file = io.open(PATH, "r")
   if file then
      file:close()
      local ok, err = pcall(table.load, PATH, loaded)
      if not ok then
         log.error("Could not read %s (%s); starting with an empty overlay.", PATH, tostring(err))
         loaded = {}
      end
   end
   M.store = emptyStore()
   for key, value in pairs(loaded) do
      if key ~= "overlay" then M.store[key] = value end
   end
   for kind in pairs(KINDS) do
      if type(loaded.overlay) == "table" and type(loaded.overlay[kind]) == "table" then
         M.store.overlay[kind] = loaded.overlay[kind]
      end
   end
   if not M.store.version then
      M.store.version = M.mmpVersion()
      if M.store.version then M.store.adopted = "mmp" end
   end
end

-- ---------------------------------------------------------------------------
-- the overlay
-- ---------------------------------------------------------------------------

local function areaRooms(name)
   local areas = getAreaTable and getAreaTable() or {}
   local id = areas[name]
   if not id then return nil end
   return getAreaRooms(id) or {}
end

--- Put one overlay entry on the map. `on` false takes it off again.
local function put(kind, key, sub, value, on)
   if kind == "lockRoom" then
      lockRoom(key, on)
   elseif kind == "lockExit" then
      -- A special exit's key is its command; an ordinary one is a direction. Mudlet locks
      -- them through different calls, and lockExit() on a special exit does nothing.
      local specials = getSpecialExitsSwap and getSpecialExitsSwap(key) or {}
      if specials[sub] then
         lockSpecialExit(key, specials[sub], sub, on)
      else
         lockExit(key, sub, on)
      end
   elseif kind == "roomWeight" then
      setRoomWeight(key, on and value or 1)
   elseif kind == "exitWeight" then
      setExitWeight(key, sub, on and value or 1)
   elseif kind == "lockArea" then
      -- getAreaRooms() is 0-indexed in Mudlet; pairs, never ipairs.
      for _, room in pairs(areaRooms(key) or {}) do lockRoom(room, on) end
   end
end

--- Apply the whole overlay to the map. Called after every map load, and at startup in
--- case the map was loaded by something else (Mudlet's own download button, mmp).
--- @return number entries applied, number skipped (room or area not on this map)
function M.apply()
   local applied, skipped = 0, 0
   local overlay = M.store.overlay
   local function exists(room) return roomExists(tonumber(room)) end
   for kind, entries in pairs(overlay) do
      for key, value in pairs(entries) do
         if kind == "lockArea" then
            if areaRooms(key) then put(kind, key, nil, nil, true) applied = applied + 1
            else skipped = skipped + 1 end
         elseif not exists(key) then
            skipped = skipped + 1
         elseif type(value) == "table" then
            for sub, v in pairs(value) do put(kind, tonumber(key), sub, v, true) applied = applied + 1 end
         else
            put(kind, tonumber(key), nil, value, true)
            applied = applied + 1
         end
      end
   end
   return applied, skipped
end

--- Record an overlay entry and put it on the map now.
--- remember("lockRoom", 1234)            remember("roomWeight", 1234, nil, 20)
--- remember("lockExit", 1234, "north")   remember("lockArea", "Mhaldor")
function M.remember(kind, key, sub, value)
   assert(KINDS[kind], "unknown overlay kind " .. tostring(kind))
   local entries = M.store.overlay[kind]
   if value == nil then value = true end
   if sub ~= nil then
      entries[key] = entries[key] or {}
      entries[key][sub] = value
   else
      entries[key] = value
   end
   put(kind, key, sub, value, true)
   M.save()
end

--- Remove an overlay entry and take it off the map.
function M.forget(kind, key, sub)
   assert(KINDS[kind], "unknown overlay kind " .. tostring(kind))
   local entries = M.store.overlay[kind]
   if entries[key] == nil then return false end
   if sub ~= nil then
      if type(entries[key]) ~= "table" or entries[key][sub] == nil then return false end
      entries[key][sub] = nil
      if next(entries[key]) == nil then entries[key] = nil end
   else
      entries[key] = nil
   end
   put(kind, key, sub, nil, false)
   -- Taking an entry off can take more than it owns: unlocking an area unlocks a room in it
   -- that is also locked on its own, and unlocking that room frees it inside a locked area.
   -- Putting the rest back settles both.
   M.apply()
   M.save()
   return true
end

--- Entries of each kind, for `emset map`.
function M.overlayCounts()
   local out = {}
   for kind, entries in pairs(M.store.overlay) do out[kind] = util.count(entries) end
   return out
end

-- ---------------------------------------------------------------------------
-- updates
-- ---------------------------------------------------------------------------

--- Which download we are waiting for: "version", "changelog", "map" or nil.
M.busy = persist.busy
--- The version being fetched, between version.txt and the map arriving.
M.incoming = persist.incoming
--- A downloaded map waiting for a walk to end before it is loaded.
M.pending = persist.pending
--- Whether the check in progress was asked for, so "already current" is worth saying.
local asked = persist.asked

local function remember(key, value)
   M[key] = value
   persist[key] = value
end

function M.mmpActive()
   return type(rawget(_G, "mmp")) == "table" and type(mmp.checkforupdate) == "function"
end

--- Is anything walking? Loading a map mid-walk swaps the rooms out from under the route.
function M.walking()
   local walker = emunah.walker
   return walker ~= nil and walker.enabled == true
end

local function readFile(path)
   local file = io.open(path, "r")
   if not file then return nil end
   local body = file:read("*a")
   file:close()
   return body
end

--- The changelog's entries, without running it.
function M.parseChangelog(text)
   local entries = {}
   for entry in tostring(text or ""):gmatch("%[%[(.-)%]%]") do
      entries[#entries + 1] = util.trim(entry)
   end
   return entries
end

local function finish()
   remember("busy", nil)
   remember("incoming", nil)
   asked = nil
   persist.asked = nil
   timers.stop("map.download")
   M.schedule()
end

local function fetch(kind)
   remember("busy", kind)
   os.remove(M.FILE[kind])
   timers.start("map.download", M.TIMEOUT[kind], function()
      log.warn("The crowdmap %s did not arrive within %ds; will try again at the next check.",
         kind, M.TIMEOUT[kind])
      finish()
   end)
   downloadFile(M.FILE[kind], M.URL[kind])
end

--- Load a downloaded map into Mudlet, re-apply the overlay and tell everyone.
--- @return boolean loaded
function M.loadPending()
   local path = M.pending
   if not path then return false end
   if M.walking() then
      log.info("The new crowdmap is downloaded; it loads when the walk ends.")
      return false
   end
   local ok, loaded = pcall(loadMap, path)
   if not ok or not loaded then
      -- [mmp] loadMap fails when the map widget has never been opened this session.
      log.warn("The crowdmap downloaded but would not load (%s). Open the map and try "
         .. "`emset map load`.", tostring(ok and "loadMap refused it" or loaded))
      return false
   end
   M.store.version = persist.pendingVersion or M.store.version
   M.store.adopted = nil
   M.save()
   os.remove(path)
   remember("pending", nil)
   persist.pendingVersion = nil
   local applied, skipped = M.apply()
   log.info("Crowdmap version %s loaded%s.", tostring(M.store.version),
      applied > 0 and (", your " .. applied .. " overlay entr" .. (applied == 1 and "y" or "ies")
         .. " put back") or "")
   if skipped > 0 then
      log.warn("%d overlay entr%s name rooms or areas this map does not have.", skipped,
         skipped == 1 and "y" or "ies")
   end
   event.raise("map.loaded", M.store.version)
   return true
end

local function showChanges(entries)
   local seen = M.store.changes
   local from = seen and (seen + 1) or #entries
   if from < #entries - M.CHANGELOG_SHOWN + 1 then from = #entries - M.CHANGELOG_SHOWN + 1 end
   if from > #entries then return end
   log.info("Crowdmap changes:")
   for i = math.max(from, 1), #entries do
      log.info("  %s", (entries[i]:gsub("%s+", " ")))
   end
end

local function onVersion(body)
   local version = util.trim(body or ""):match("^(%S+)$")
   if not version then
      log.warn("The crowdmap's version.txt was not a version: %q", tostring(body):sub(1, 40))
      return finish()
   end
   M.store.checkedAt = util.now()
   if version == tostring(M.store.version) then
      if asked then log.info("The crowdmap is current (version %s).", version) end
      M.save()
      return finish()
   end
   log.info("Crowdmap version %s is out (you have %s); downloading it.", version,
      tostring(M.store.version or "none"))
   remember("incoming", version)
   if config.get("map.changelog", true) then fetch("changelog") else fetch("map") end
end

local function onChangelog(body)
   local entries = M.parseChangelog(body)
   if #entries > 0 then
      showChanges(entries)
      M.store.changes = #entries
      M.save()
   end
   fetch("map")
end

local function onMap()
   persist.pendingVersion = M.incoming
   remember("pending", M.FILE.map)
   finish()
   M.loadPending()
end

--- Check for a new crowdmap now.
--- @param manual boolean asked for by the user: report "current", and ignore autoupdate
function M.check(manual)
   if M.mmpActive() then
      if manual then
         log.warn("mmp is running and updates the map itself. Disable its package and "
            .. "restart Mudlet to hand updates to Emunah.")
      end
      return false
   end
   if M.busy then
      if manual then log.info("Already fetching the crowdmap %s.", M.busy) end
      return false
   end
   asked = manual and true or nil
   persist.asked = asked
   fetch("version")
   return true
end

--- Arm the next automatic check, counting from the last one so a reload does not
--- re-check every time.
function M.schedule()
   timers.stop("map.check")
   if config.get("map.autoupdate", true) == false then return end
   local every = math.max(5, tonumber(config.get("map.checkEvery", 60)) or 60) * 60
   local since = M.store.checkedAt and (util.now() - M.store.checkedAt) or every
   local wait = math.max(5, every - since)
   timers.start("map.check", wait, function() M.check(false) end)
end

event.register("sysDownloadDone", function(_, path)
   if not M.busy or path ~= M.FILE[M.busy] then return end
   local kind = M.busy
   if kind == "map" then return onMap() end
   local body = readFile(path)
   os.remove(path)
   if kind == "version" then onVersion(body) else onChangelog(body) end
end, "mapper-data")

event.register("sysDownloadError", function(_, reason, path)
   if not M.busy or path ~= M.FILE[M.busy] then return end
   log.warn("Could not download the crowdmap %s: %s", M.busy, tostring(reason))
   finish()
end, "mapper-data")

-- A map that downloaded during a walk loads as soon as the walk is over.
event.register("emunah.walker.finished", function()
   if M.pending then M.loadPending() end
end, "mapper-data")

-- ---------------------------------------------------------------------------
-- correcting the map from GMCP [mmp: mmp.syncSafeRoomInfo]
-- ---------------------------------------------------------------------------

--- [mmp] How the crowdmap names rooms: Room.Info's name without the prefixes and suffixes
--- the game adds for where you are standing in it (mmp.cleanroomname, verbatim rules).
function M.cleanName(name)
   name = tostring(name or "")
   local prefixes = { "Flying above ", "In the trees above ", "The ruins of " }
   for _, prefix in ipairs(prefixes) do
      if name:sub(1, #prefix) == prefix then name = name:sub(#prefix + 1) end
   end
   if name:sub(-1) == "." then name = name:sub(1, -2) end
   for _, suffix in ipairs({ " (road)", " (indoors)", " (indoor road)" }) do
      if name:sub(-#suffix) == suffix then name = name:sub(1, -#suffix - 1) end
   end
   return name
end

--- Bring one mapped room in line with Room.Info. Only fields GMCP states outright: the
--- name, the environment, indoors or outdoors, the game's area name and the wilderness
--- mark. Exits are left alone -- a refused exit is a different question (loc.badexit).
--- @return table list of what changed, empty if nothing did
function M.sync(num, info)
   local changes = {}
   num = tonumber(num)
   if not num or type(info) ~= "table" or not roomExists(num) then return changes end

   if info.name then
      local name = M.cleanName(info.name)
      if name ~= "" and getRoomName(num) ~= name then
         setRoomName(num, name)
         changes[#changes + 1] = "name"
      end
   end

   local env = info.environment and M.ENV[info.environment]
   if env and getRoomEnv(num) ~= env then
      setRoomEnv(num, env)
      changes[#changes + 1] = "environment"
   end

   -- [mmp] Indoors is a `details` entry; its absence means outdoors. Stored the way the
   -- crowdmap stores it: "indoors"/"outdoors" user data set to "y", never both.
   if type(info.details) == "table" then
      local indoors = util.contains(info.details, "indoors")
      local isIndoors = getRoomUserData(num, "indoors") == "y"
      local isOutdoors = getRoomUserData(num, "outdoors") == "y"
      if indoors and (not isIndoors or isOutdoors) then
         setRoomUserData(num, "indoors", "y")
         clearRoomUserDataItem(num, "outdoors")
         changes[#changes + 1] = "indoors"
      elseif not indoors and (isIndoors or not isOutdoors) then
         clearRoomUserDataItem(num, "indoors")
         setRoomUserData(num, "outdoors", "y")
         changes[#changes + 1] = "outdoors"
      end
      if util.contains(info.details, "wilderness") and getRoomChar(num) ~= "W" then
         setRoomChar(num, "W")
         changes[#changes + 1] = "wilderness"
      end
   end

   if info.area and info.area ~= "" and getRoomUserData(num, "Game Area") ~= info.area then
      setRoomUserData(num, "Game Area", tostring(info.area))
      changes[#changes + 1] = "area"
   end

   return changes
end

event.register("emunah.room", function(_, num)
   if config.get("map.gmcpSync", true) == false then return end
   local info = gmcp and gmcp.Room and gmcp.Room.Info
   local changes = M.sync(num, info)
   if #changes > 0 then
      log.debug("Map room %s corrected from GMCP: %s", tostring(num), table.concat(changes, ", "))
   end
end, "mapper-data")

-- ---------------------------------------------------------------------------
-- startup
-- ---------------------------------------------------------------------------

M.load()
-- The map in Mudlet may have been loaded by anything since we last ran; put the overlay
-- on it. Idempotent, and cheap next to a load.
if roomExists then M.apply() end
M.schedule()

return M

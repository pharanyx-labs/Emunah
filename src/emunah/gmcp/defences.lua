--- Char.Defences -- active defences.
---
--- Same message shapes as Char.Afflictions:
---   Char.Defences.List     array of { name, desc }  -- replaces everything
---   Char.Defences.Add      a single { name, desc }
---   Char.Defences.Remove   an ARRAY OF NAMES
---
--- Unlike afflictions, this list is genuinely reliable: the game knows exactly which
--- defences you have and tells you about all of them. That makes defence keep-up a much
--- easier problem than curing, and it is why curing/defkeepup.lua can be driven straight
--- off this module with no trigger layer at all.
---
--- ONE EXCEPTION: parrying. GMCP does not send a Remove for the old "parrying (weapon)"
--- entry when a new one is granted (switching weapons, or re-parrying), so a naive Add-only
--- record would accumulate stale parry entries forever. onAdd() below clears every existing
--- "parrying (X)" entry before recording a new one.

local M = {}

local util  = emunah.util
local event = emunah.event

--- name -> { name, desc, since }
M.active = {}

--- Parrying defences are reported as "parrying (weapon name)". See the module header.
local PARRY_PATTERN = "^parrying %(.+%)$"

local function record(entry)
   if type(entry) ~= "table" or not entry.name then return nil end
   local name = tostring(entry.name):lower()
   local existing = M.active[name]
   M.active[name] = {
      name  = name,
      desc  = entry.desc and tostring(entry.desc) or (existing and existing.desc),
      since = existing and existing.since or emunah.util.now(),
   }
   return name
end

local function onList()
   local list = gmcp.Char.Defences.List
   if type(list) ~= "table" then return end

   local previous = M.active
   M.active = {}
   for _, entry in ipairs(list) do
      local name = record(entry)
      if name and previous[name] then
         M.active[name].since = previous[name].since
      end
   end
   event.raise("defences.list", M.names())
end

local function onAdd()
   local incoming = gmcp.Char.Defences.Add
   local incomingName = type(incoming) == "table" and incoming.name
      and tostring(incoming.name):lower() or nil

   -- Clear any stale parry entry first -- see the module header and PARRY_PATTERN above.
   if incomingName and incomingName:match(PARRY_PATTERN) then
      for existingName in pairs(M.active) do
         if existingName:match(PARRY_PATTERN) then M.active[existingName] = nil end
      end
   end

   local name = record(incoming)
   if not name then return end
   event.raise("defence.added", name, M.active[name])
end

local function onRemove()
   local removed = gmcp.Char.Defences.Remove
   if type(removed) ~= "table" then return end
   for _, entry in ipairs(removed) do
      local name = type(entry) == "table" and entry.name or entry
      name = name and tostring(name):lower()
      if name and M.active[name] then
         M.active[name] = nil
         -- defkeepup listens for this and re-raises the defence if it is on the list.
         event.raise("defence.lost", name)
      end
   end
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

function M.has(name)
   return M.active[tostring(name):lower()] ~= nil
end

function M.names()
   local out = {}
   for name in pairs(M.active) do out[#out + 1] = name end
   table.sort(out)
   return out
end

function M.list()
   local out = {}
   for _, record_ in pairs(M.active) do out[#out + 1] = record_ end
   table.sort(out, function(a, b) return a.name < b.name end)
   return out
end

function M.count()
   return util.count(M.active)
end

function M.set()
   local out = {}
   for name in pairs(M.active) do out[name] = true end
   return out
end

--- Which of the wanted defences are currently missing.
--- @param wanted table array of defence names
--- @return table array of missing names
function M.missingFrom(wanted)
   local out = {}
   for _, name in ipairs(wanted or {}) do
      if not M.has(name) then out[#out + 1] = tostring(name):lower() end
   end
   return out
end

--- Apply a DEFENCES listing: the names its lines were read as (deflist.DEF_LINES).
---
--- What a reload needs. The list is rebuilt from the last Char.Defences.List still in the
--- global gmcp table, and every Add and Remove since then is missing from it -- so a defence
--- raised after that list reads as down, and keep-up raises it again. DEFENCES is the whole
--- truth right now.
---
--- Conservative the way the reference system's process_defs is: a defence whose DEF line we know, and which
--- is not listed, is gone; one listed is up; one whose DEF line we do not know is left as it
--- was, because its absence from the lines we could read says nothing.
function M.applyDefListing(names)
   local listed = {}
   for _, name in ipairs(names) do listed[tostring(name):lower()] = true end
   local known = {}
   for _, name in pairs(emunah.curing.deflist.DEF_LINES or {}) do known[name] = true end

   for name in pairs(M.active) do
      if known[name] and not listed[name] then
         M.active[name] = nil
         event.raise("defence.lost", name)
      end
   end
   for name in pairs(listed) do
      if not M.active[name] then
         record({ name = name })
         event.raise("defence.added", name)
      end
   end
   event.raise("defences.list", M.names())
end

event.gmcp("Char.Defences.List",   onList,   "gmcp.defences")
event.gmcp("Char.Defences.Add",    onAdd,    "gmcp.defences")
event.gmcp("Char.Defences.Remove", onRemove, "gmcp.defences")

event.register("sysDisconnectionEvent", function()
   M.active = {}
end, "gmcp.defences")

if gmcp and gmcp.Char and gmcp.Char.Defences and gmcp.Char.Defences.List then
   onList()
end

return M

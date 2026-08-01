--- IRE.* -- the game-specific modules: Rift, Target, Time, Misc.
---
--- Messages:
---   IRE.Rift.List      array of { name, amount, desc }  -- full rift contents
---   IRE.Rift.Change    a single { name, amount, desc }  -- one commodity changed
---   IRE.Target.Set     target id (string), bidirectional
---   IRE.Target.Info    { id, short_desc, hpperc }
---   IRE.Time.List      { day, mon, month, year, hour, daynight }
---   IRE.Time.Update    partial time object
---
--- The Rift is why this module matters to curing. Achaea's rift is bottomless storage for
--- herbs and minerals, and OUTR pulls from it, so "do I have bloodroot" is really "do I
--- have bloodroot in inventory OR in the rift". emunah.have.cure() checks both, using the
--- counts tracked here.

local M = {}

local util  = emunah.util
local event = emunah.event

--- Rift: commodity name (lower) -> { name, amount, desc }
M.rift = {}

--- Current target.
M.target = { id = nil, description = nil, health = nil }

--- Game time.
M.time = {}

-- ---------------------------------------------------------------------------
-- Rift
-- ---------------------------------------------------------------------------

--- THE KEY IS NOT JUST `name`. Confirmed from a GMCP trace at 11:42:02, pulling irid moss:
---
---     IRE.Rift.Change {amount="493" desc="irid" name="moss"}
---
--- `name` is the generic commodity ("moss") and `desc` is the qualifier -- and it is the
--- QUALIFIER that OUTR takes (`outr 5 irid`) and that the cure tables name. Keying on
--- `name` alone meant `riftCount("irid")` answered 0 for a rift holding 493 of it, so the
--- restocker would never pull, and nothing would say why.
---
--- Qualified entries are keyed "<desc> <name>" so two mosses cannot overwrite each other;
--- find() below is what resolves a caller's plain "irid".
local function riftKey(name, desc)
   if desc and desc ~= "" and desc ~= name then return desc .. " " .. name end
   return name
end

local function riftRecord(entry)
   if type(entry) ~= "table" or not entry.name then return nil end
   local name = tostring(entry.name):lower()
   local desc = entry.desc and tostring(entry.desc):lower() or nil
   local key  = riftKey(name, desc)
   M.rift[key] = {
      name   = name,
      desc   = desc,
      key    = key,
      amount = util.num(entry.amount, 0),
   }
   return key
end

local function onRiftList()
   local list = gmcp.IRE.Rift.List
   if type(list) ~= "table" then return end
   M.rift = {}
   for _, entry in ipairs(list) do riftRecord(entry) end
   event.raise("rift.list", util.count(M.rift))
end

local function onRiftChange()
   local key = riftRecord(gmcp.IRE.Rift.Change)
   if not key then return end
   event.raise("rift.change", key, M.rift[key].amount)
end

--- The rift entry a caller means, by whichever word they have.
---
--- Callers hold the word the game's own commands use -- "irid", "bloodroot" -- which is
--- sometimes the entry's `name` and sometimes its `desc`. Both are tried before giving up,
--- exact matches only: a substring fallback would let "moss" claim the irid.
function M.riftFind(query)
   query = tostring(query or ""):lower()
   if query == "" then return nil end

   local direct = M.rift[query]
   if direct then return direct end

   for _, entry in pairs(M.rift) do
      if entry.desc == query or entry.name == query then return entry end
   end
   return nil
end

--- How many of a commodity are in the rift.
function M.riftCount(name)
   local entry = M.riftFind(name)
   return entry and entry.amount or 0
end

function M.requestRift()
   sendGMCP("IRE.Rift.Request")
end

-- ---------------------------------------------------------------------------
-- Target
-- ---------------------------------------------------------------------------

local function onTargetSet()
   local id = gmcp.IRE.Target.Set
   -- Sent as a bare string; an empty string means the target was cleared.
   id = (id ~= nil and tostring(id) ~= "") and tostring(id) or nil
   if M.target.id == id then return end
   M.target = { id = id, description = nil, health = nil }
   event.raise("target", id)
end

local function onTargetInfo()
   local info = gmcp.IRE.Target.Info
   if type(info) ~= "table" then return end
   M.target.id          = info.id and tostring(info.id) or M.target.id
   M.target.description = info.short_desc and tostring(info.short_desc) or M.target.description
   M.target.health      = util.num(info.hpperc, M.target.health)
   event.raise("target.info", M.target.id, M.target.health)
end

--- Set the server-side target. Achaea accepts this both ways, so the client can drive
--- targeting and stay in sync with anything else reading IRE.Target.
function M.setTarget(id)
   if not id then return false end
   sendGMCP("IRE.Target.Set " .. yajl.to_string(tostring(id)))
   return true
end

--- Target health as a percentage, or nil if unknown.
function M.targetHealth()
   return M.target.health
end

function M.hasTarget()
   return M.target.id ~= nil
end

-- ---------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------

local function applyTime(payload)
   if type(payload) ~= "table" then return end
   for key, value in pairs(payload) do
      M.time[key] = value
   end
   event.raise("time", M.time)
end

local function onTimeList()   applyTime(gmcp.IRE.Time.List) end
local function onTimeUpdate() applyTime(gmcp.IRE.Time.Update) end

--- Is it currently night? Relevant to a lot of Achaea mechanics, and the reason we track
--- time at all.
function M.isNight()
   local daynight = util.num(M.time.daynight, nil)
   if not daynight then return nil end
   -- IRE reports daynight as a 0-based clock position; night runs at the extremes.
   return daynight < 4 or daynight > 20
end

function M.requestTime()
   sendGMCP("IRE.Time.Request")
end

-- ---------------------------------------------------------------------------

event.gmcp("IRE.Rift.List",    onRiftList,    "gmcp.ire")
event.gmcp("IRE.Rift.Change",  onRiftChange,  "gmcp.ire")
event.gmcp("IRE.Target.Set",   onTargetSet,   "gmcp.ire")
event.gmcp("IRE.Target.Info",  onTargetInfo,  "gmcp.ire")
event.gmcp("IRE.Time.List",    onTimeList,    "gmcp.ire")
event.gmcp("IRE.Time.Update",  onTimeUpdate,  "gmcp.ire")

event.register("sysDisconnectionEvent", function()
   M.target = { id = nil, description = nil, health = nil }
end, "gmcp.ire")

if gmcp and gmcp.IRE then
   if gmcp.IRE.Rift and gmcp.IRE.Rift.List then onRiftList() end
   if gmcp.IRE.Time and gmcp.IRE.Time.List then onTimeList() end
end

return M

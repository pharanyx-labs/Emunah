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

--- Have we actually SEEN a rift list, as opposed to not having asked yet?
---
--- Same distinction gmcp/items.lua's M.inventoryListed draws, and for the same reason: an
--- empty M.rift means both "confirmed empty" and "the reply has not arrived", and a caller
--- that cannot tell them apart acts on the wrong one. Live at login 2026-08-03 16:29:25.58,
--- already paralysed: `have.cure()` read zero in both inventory and rift (neither had
--- landed yet) and warned "Out of bloodroot" -- wrong, and worse, that warning is
--- once-per-item and nothing at that call site ever clears it, so a real "out of bloodroot"
--- later in the same session would have stayed silent. Three seconds later, once
--- IRE.Rift.List actually arrived, the exact same refusal correctly became "bloodroot is in
--- the rift, not in hand".
M.riftListed = false

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

--- Every word that resolves to an entry -- its key, its `desc`, and its `name` -- pointing
--- at the entry itself.
---
--- riftFind() used to fall back to a linear `pairs` scan of the whole rift whenever the
--- caller's word was not a key, which is the COMMON case and not the rare one: qualified
--- entries are keyed "irid moss" and every caller asks for "irid". have.inRift() is called
--- fifteen times per prompt by the restock pass, so that was fifteen full scans of the rift
--- per prompt.
---
--- Built at the same six sites that write M.rift, so it cannot drift from it.
local riftAlias = {}

local function riftIndex(record)
   riftAlias[record.key] = record
   -- The qualifier is what OUTR takes and what the cure tables name, so it is the alias
   -- that actually gets used. It wins over the bare commodity name deliberately: two mosses
   -- share a `name` and only the `desc` tells them apart.
   if record.name and riftAlias[record.name] == nil then riftAlias[record.name] = record end
   if record.desc then riftAlias[record.desc] = record end
end

local function riftRecord(entry)
   if type(entry) ~= "table" or not entry.name then return nil end
   local name = tostring(entry.name):lower()
   local desc = entry.desc and tostring(entry.desc):lower() or nil
   local key  = riftKey(name, desc)
   local record = {
      name   = name,
      desc   = desc,
      key    = key,
      amount = util.num(entry.amount, 0),
   }
   M.rift[key] = record
   riftIndex(record)
   return key
end

local function onRiftList()
   local list = gmcp.IRE.Rift.List
   if type(list) ~= "table" then return end
   M.rift = {}
   -- Rebuilt wholesale with the table it indexes. A surgical update here would be a stale
   -- alias pointing at a commodity the rift no longer holds, which reads as "we have it"
   -- and has the restocker pull something that is not there.
   riftAlias = {}
   for _, entry in ipairs(list) do riftRecord(entry) end
   M.riftListed = true
   event.raise("rift.list", util.count(M.rift))
end

--- True once the rift has actually been listed, as opposed to just starting empty.
function M.riftKnown()
   return M.riftListed
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
   -- The bare word first: callers on the hot path already hold a lowercase commodity name,
   -- and the index answers them in one lookup with no allocation.
   local hit = riftAlias[query]
   if hit then return hit end

   query = tostring(query or ""):lower()
   if query == "" then return nil end
   return riftAlias[query]
end

--- How many of a commodity are in the rift.
function M.riftCount(name)
   local entry = M.riftFind(name)
   return entry and entry.amount or 0
end

function M.requestRift()
   emunah.gmcp.request("IRE.Rift.Request")
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
   emunah.gmcp.request("IRE.Time.Request")
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
   M.rift = {}
   M.riftListed = false
end, "gmcp.ire")

if gmcp and gmcp.IRE then
   if gmcp.IRE.Rift and gmcp.IRE.Rift.List then onRiftList() end
   if gmcp.IRE.Time and gmcp.IRE.Time.List then onTimeList() end
end

return M

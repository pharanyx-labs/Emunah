--- Char.Afflictions -- the server's view of what is wrong with you.
---
--- Message shapes (note the asymmetry, which is a common source of bugs):
---   Char.Afflictions.List    array of { name, cure, desc }   -- replaces everything
---   Char.Afflictions.Add     a single   { name, cure, desc } -- one object, not an array
---   Char.Afflictions.Remove  an ARRAY OF NAMES (strings), not objects
---
--- Scope of this module
--- --------------------
--- This is the *server's* affliction list, and it is deliberately kept separate from the
--- curing engine's own tracked state (curing/engine.lua). The two disagree constantly and
--- that is expected: Achaea only reports afflictions it has told you about, so in real
--- combat an opponent can have several afflictions on you that never appear here. Using
--- this list as the sole input to curing is the single biggest reason naive systems lose
--- fights they should win.
---
--- So: triggers are the primary detector, and this module is the reconciler. It is
--- authoritative for *removal* (if the server says it is gone, it is gone) and
--- corroborating for addition.
---
--- STACKING AFFLICTIONS
--- ---------------------
--- A handful of afflictions (the tempered-humour states, some Weaving effects, and a few
--- others) report with a live stack count baked directly into the name string, e.g.
--- "temperedsanguine (2)" rather than a separate field. Left alone, that string never
--- matches afflist.lua's plain "temperedsanguine" key under any spelling, so the engine
--- would track-but-never-cure every one of them silently -- exactly the failure mode
--- flagged as an open risk in docs/afflictions.md's Phase 1 cross-check, since resolved
--- against an independent implementation's own GMCP-name handling. splitStack() below
--- strips the suffix before anything downstream (afflist.known(), engine.tracked) ever
--- sees the name, and keeps the count for anything that wants it.

local M = {}

local util  = emunah.util
local event = emunah.event

--- name -> { name, cure, desc, since, stacks }
M.active = {}

--- "temperedsanguine (2)" -> "temperedsanguine", 2. Anything without the suffix is
--- returned unchanged with a nil count.
local function splitStack(name)
   local base, stacks = name:match("^(.-)%s*%((%d+)%)$")
   if base and base ~= "" then return base, tonumber(stacks) end
   return name, nil
end

local function record(entry)
   if type(entry) ~= "table" or not entry.name then return nil end
   local rawName = tostring(entry.name):lower()
   local name, stacks = splitStack(rawName)
   local existing = M.active[name]
   M.active[name] = {
      name   = name,
      stacks = stacks or (existing and existing.stacks) or 1,
      cure   = entry.cure and tostring(entry.cure) or (existing and existing.cure),
      desc   = entry.desc and tostring(entry.desc) or (existing and existing.desc),
      -- Preserve the original onset time across updates so the UI's age column is honest.
      since  = existing and existing.since or emunah.util.now(),
   }
   return name
end

local function onList()
   local list = gmcp.Char.Afflictions.List
   if type(list) ~= "table" then return end

   local previous = M.active
   M.active = {}
   for _, entry in ipairs(list) do
      local name = record(entry)
      -- Carry the onset time over from the previous generation where we had one.
      if name and previous[name] then
         M.active[name].since = previous[name].since
      end
   end

   event.raise("afflictions.list", M.names())
end

local function onAdd()
   local name = record(gmcp.Char.Afflictions.Add)
   if not name then return end
   event.raise("affliction.added", name, M.active[name])
end

local function onRemove()
   -- Remove carries an array of bare names.
   local removed = gmcp.Char.Afflictions.Remove
   if type(removed) ~= "table" then return end
   for _, entry in ipairs(removed) do
      -- Tolerate an object here as well as a string: some IRE games have been
      -- inconsistent about this and the cost of accepting both is one line.
      local raw = type(entry) == "table" and entry.name or entry
      raw = raw and tostring(raw):lower()
      if raw then
         local name = splitStack(raw)
         if M.active[name] then
            M.active[name] = nil
            event.raise("affliction.removed", name)
         end
      end
   end
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

--- Does the server currently report this affliction?
function M.has(name)
   return M.active[util.lower(name)] ~= nil
end

--- Sorted array of affliction names.
function M.names()
   local out = {}
   for name in pairs(M.active) do out[#out + 1] = name end
   table.sort(out)
   return out
end

--- Full records, sorted by onset (oldest first) -- the order the affliction panel wants.
function M.list()
   local out = {}
   for _, record_ in pairs(M.active) do out[#out + 1] = record_ end
   table.sort(out, function(a, b) return a.since < b.since end)
   return out
end

--- Seconds since an affliction was first seen.
function M.age(name)
   local entry = M.active[util.lower(name)]
   if not entry then return 0 end
   return emunah.util.now() - entry.since
end

--- The cure the server suggests for an affliction, when it has told us one.
function M.cureFor(name)
   local entry = M.active[util.lower(name)]
   return entry and entry.cure
end

--- Current stack count, for the handful of afflictions that carry one. 1 for anything
--- else that's simply present, 0 when not tracked at all.
function M.stacks(name)
   local entry = M.active[util.lower(name)]
   return entry and entry.stacks or 0
end

function M.count()
   return util.count(M.active)
end

--- Set-shaped view for cheap diffing against the curing engine's tracked state.
function M.set()
   local out = {}
   for name in pairs(M.active) do out[name] = true end
   return out
end

event.gmcp("Char.Afflictions.List",   onList,   "gmcp.afflictions")
event.gmcp("Char.Afflictions.Add",    onAdd,    "gmcp.afflictions")
event.gmcp("Char.Afflictions.Remove", onRemove, "gmcp.afflictions")

event.register("sysDisconnectionEvent", function()
   M.active = {}
end, "gmcp.afflictions")

if gmcp and gmcp.Char and gmcp.Char.Afflictions and gmcp.Char.Afflictions.List then
   onList()
end

return M

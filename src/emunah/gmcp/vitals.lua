--- Char.Vitals -- health, resources, balance, equilibrium, and class stats.
---
--- Achaea sends Char.Vitals with essentially every prompt, which makes it the natural
--- heartbeat for the whole system: the curing engine ticks on it, the UI redraws on it,
--- and balance transitions are detected from it.
---
--- Fields, as Achaea sends them:
---   hp maxhp mp maxmp ep maxep wp maxwp   numeric, arriving as strings
---   nl                                    percent progress to next level
---   string                                all of the above as "H:x/y M:x/y ..."
---   bal eq                                "1" / "0"
---   charstats                             array of "Key: Value" strings, class-specific
---
--- Two traps worth knowing about, both handled below:
---
---   1. bal/eq are the STRINGS "1" and "0". `if gmcp.Char.Vitals.bal then` is true when
---      you have no balance, because "0" is truthy in Lua.
---
---   2. Char.Vitals messages are not always complete. A partial update omitting `bal`
---      must not be read as "balance lost" -- we only transition on fields that are
---      actually present.

local M = {}

local util  = emunah.util
local event = emunah.event

-- Current values.
M.hp, M.maxhp = 0, 0
M.mp, M.maxmp = 0, 0
M.ep, M.maxep = 0, 0
M.wp, M.maxwp = 0, 0
M.nl          = 0

M.bal = true
M.eq  = true

--- Percentages, precomputed because the UI and the curing thresholds both want them.
M.percent = { hp = 100, mp = 100, ep = 100, wp = 100 }

--- Class-specific values parsed out of charstats: { Bleed = 0, Kai = 0, Stance = "None" }
--- Raw string forms are kept in M.statsText for anything we cannot parse to a number.
M.stats     = {}
M.statsText = {}

--- Previous snapshot, for damage calculation and change detection.
M.last = {}

--- Ticks seen this session. The curing engine uses this to schedule periodic
--- reconciliation without needing its own timer.
M.ticks = 0

local RESOURCES = { "hp", "mp", "ep", "wp" }

--- Parse the charstats array into typed values.
---
--- Entries look like "Bleed: 0", "Kai: 0%", "Stance: None", "Devotion: 100%". The set
--- varies by class, so we parse generically rather than against a fixed list -- this is
--- what lets the same code serve Monk (Kai/Stance) and Priest (Devotion) without change.
local function parseCharstats(list)
   local stats, text = {}, {}
   for _, entry in ipairs(list or {}) do
      local key, value = tostring(entry):match("^%s*([^:]+):%s*(.*)$")
      if key then
         key   = util.trim(key)
         value = util.trim(value)
         text[key] = value
         -- "0%" -> 0, "None" -> kept as a string in M.stats too so callers can compare.
         local numeric = tonumber((value:gsub("%%", "")))
         stats[key] = numeric or value
      else
         -- No colon: a bare flag such as "Insomnia". Record it as present.
         local flag = util.trim(tostring(entry))
         if flag ~= "" then
            stats[flag] = true
            text[flag]  = flag
         end
      end
   end
   return stats, text
end

--- Handle an incoming Char.Vitals.
local function onVitals()
   local v = gmcp.Char.Vitals
   if type(v) ~= "table" then return end

   -- Snapshot before mutating, so damage taken this tick is derivable.
   M.last = {
      hp = M.hp, mp = M.mp, ep = M.ep, wp = M.wp,
      bal = M.bal, eq = M.eq,
   }

   for _, key in ipairs(RESOURCES) do
      local maxKey = "max" .. key
      if v[key]    ~= nil then M[key]    = util.num(v[key], M[key]) end
      if v[maxKey] ~= nil then M[maxKey] = util.num(v[maxKey], M[maxKey]) end
      M.percent[key] = util.percent(M[key], M[maxKey])
   end

   if v.nl ~= nil then M.nl = util.num(v.nl, M.nl) end

   -- Balance and equilibrium. Only act on fields that are actually present: a partial
   -- Char.Vitals must not be mistaken for a balance loss.
   local balChanged, eqChanged = false, false
   if v.bal ~= nil then
      local bal = util.bool(v.bal)
      balChanged = (bal ~= M.bal)
      M.bal = bal
   end
   if v.eq ~= nil then
      local eq = util.bool(v.eq)
      eqChanged = (eq ~= M.eq)
      M.eq = eq
   end

   if v.charstats then
      M.stats, M.statsText = parseCharstats(v.charstats)
   end

   M.ticks = M.ticks + 1

   -- Balance transitions drive the action queue, so raise them before the generic tick.
   if balChanged then
      event.raise(M.bal and "balance.gained" or "balance.lost")
   end
   if eqChanged then
      event.raise(M.eq and "equilibrium.gained" or "equilibrium.lost")
   end

   event.raise("vitals", M)

   -- The system heartbeat. Curing, defence keep-up and the queue all hang off this.
   event.raise("tick", M.ticks)
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

--- Optimistically mark bal/eq as spent, for something that consumes it by sending a command
--- rather than by a GMCP push telling us so.
---
--- Char.Vitals omits bal/eq when they have not changed (see the file header), so after
--- sending an attack the very next Char.Vitals push -- triggered by something unrelated,
--- like the damage the same round dealt us -- can still read the pre-spend value and fire
--- another attempt before the server's own bal=0 arrives. Confirmed in play: this is what
--- was sending an attack command on every prompt for several prompts in a row, each one
--- rejected with "You must regain balance first." Only ever sets false; the server's own
--- push is still what brings it back true, so a spend can be over-eager but never stuck.
function M.spend(field)
   if field == "bal" then M.bal = false
   elseif field == "eq" then M.eq = false end
end

--- Damage taken since the previous tick (positive means health was lost).
function M.damageTaken()
   if not M.last.hp then return 0 end
   local delta = M.last.hp - M.hp
   return delta > 0 and delta or 0
end

--- Health below a percentage -- the standard guard for fleeing and for emergency cures.
function M.below(resource, pct)
   return (M.percent[resource] or 100) < (pct or 0)
end

--- A charstat by name, with a fallback. Case-sensitive because the game's own casing is
--- stable: `vitals.stat("Kai")`, `vitals.stat("Bleed", 0)`.
function M.stat(name, fallback)
   local value = M.stats[name]
   if value == nil then return fallback end
   return value
end

--- Bleeding is common to every class and worth a named accessor.
function M.bleeding()
   return util.num(M.stats.Bleed, 0)
end

function M.snapshot()
   return {
      hp = M.hp, maxhp = M.maxhp, mp = M.mp, maxmp = M.maxmp,
      ep = M.ep, maxep = M.maxep, wp = M.wp, maxwp = M.maxwp,
      nl = M.nl, bal = M.bal, eq = M.eq,
      percent = util.copy(M.percent),
      stats   = util.copy(M.stats),
      ticks   = M.ticks,
   }
end

event.gmcp("Char.Vitals", onVitals, "gmcp.vitals")

-- Adopt whatever is already in the feed, so a mid-session reload does not sit at zero
-- until the next prompt.
if gmcp and gmcp.Char and gmcp.Char.Vitals then
   onVitals()
end

return M

--- Cure vectors and the commands that drive them.
---
--- A "vector" is a resource that gates a cure. Achaea has several that run independently:
--- eating a herb, applying a salve and smoking a pipe all happen on separate balances, so
--- all three can be in flight at once. core/queue.lua models that as one slot per vector;
--- this module says what each vector costs and how to phrase the command.
---
--- Timings
--- -------
--- The `recovery` figures below are FALLBACKS, not the mechanism. A cure's balance is
--- normally cleared by the trigger that confirms the cure landed (see curing/detect/);
--- the timer only fires when that confirmation is lost. They are therefore deliberately
--- set a little long -- an over-long fallback costs one wasted tick, an over-short one
--- sends a second cure while the first is still on balance, which is worse. All are
--- tunable via `emunah set curing.recovery.<vector> <seconds>`.
---
--- Herbs vs minerals
--- -----------------
--- Alchemists transmute minerals instead of eating herbs, and the two sets are
--- one-for-one equivalent (bloodroot/magnesium, kelp/aurum, ginseng/ferrum, ...). Each
--- cure option in afflist.lua carries both as `item` and `alt`, so the mapping lives in
--- exactly one place and this module just picks the side the config asks for.

local M = {}

--- Vector definitions.
M.vectors = {
   -- Herb and smoke are ANNOUNCED ("You may eat another plant or mineral.", "Your lungs have
   -- recovered enough to smoke..."), so like the elixir these are nets for a lost line, not
   -- estimates. At 1.8 the herb net lapsed before the real line: bloodroot sent 14:26:03.27,
   -- eaten 04.11, balance announced 05.65 -- 2.4s send to balance -- and since a lapsing
   -- timer ticks the engine, `eat ash` went out at ~05.1 inside it. The balance line then
   -- freed the ash's slot as if it were its own, and `eat bloodroot` followed straight into
   -- the ash's balance: "The plant has no effect." (14:26:06.05), still paralysed.
   herb    = { recovery = 3.5, command = "eat %s",          needsItem = true  },
   salve   = { recovery = 1.8, command = "apply %s to %s",  needsItem = true  },
   -- Elixir recovery is deliberately LONG. Achaea announces sip balance returning
   -- ("You may drink another health or mana elixir."), and curing/detect/patterns.lua
   -- clears the vector the instant it does -- so this number is only ever the safety net
   -- for a missed message. An under-estimate here re-sends `drink health` mid-sip and
   -- wastes the vial; an over-estimate costs at most one late sip.
   elixir  = { recovery = 6.0, command = "drink %s",        needsItem = true  },
   -- The AFFLICTION-HEALING elixirs -- immunity, frost, venom, speed, levitation -- run on
   -- a balance of their own, not the health/mana sip balance [svof: bals.purgative, gated
   -- by check_purgative independently of check_sip]. Announced like the sip ("You may drink
   -- another affliction-healing elixir."), so this is a net for a missed line, sized like
   -- the elixir's for the same reason.
   purgative = { recovery = 6.0, command = "drink %s",      needsItem = true  },
   smoke   = { recovery = 3.5, command = "smoke %s",        needsItem = true  },
   -- Irid moss. Its own balance, with herb balance untouched. MEASURED at 5.94s: eaten
   -- 12:41:01.61, "You may eat another bit of irid moss or potash." at 12:41:07.55. The
   -- first estimate of ~2.75s came from reading a transcript where the announcement's
   -- position was ambiguous, and 5.0 was short enough that the fallback lapsed before the
   -- real message arrived -- so the vector reopened while the balance was still out. Same
   -- reasoning as the elixir: the announcement is authoritative and this is only the net
   -- for a missed one, so it errs long.
   moss    = { recovery = 8.0, command = "eat %s",          needsItem = true  },
   -- Not a balance. OUTR is free; this is only the re-send guard covering the gap between
   -- the pull and the game confirming it, and the confirmation clears it long before this
   -- elapses -- measured at 0.23s (`outr 3 irid` 11:48:26.14, "You remove 3 irid" at
   -- 11:48:26.37). It is deliberately short because it is what paces restocking: a whole
   -- cure list has to be pulled one item at a time.
   rift    = { recovery = 1.0, command = "outr %s",         needsItem = false },
   focus   = { recovery = 4.5, command = "focus",           needsItem = false },
   tree    = { recovery = 15.0, command = "touch tree",     needsItem = false },
   writhe  = { recovery = 1.0, command = "writhe",          needsItem = false },
   special = { recovery = 2.0, command = "%s",              needsItem = false },
}

--- Herbs that are smoked rather than eaten. Smoking needs a lit pipe with that herb in
--- it, which is a second resource the engine has to care about beyond the herb itself --
--- see hasPipe() in have/capabilities.lua.
M.smoked = {
   elm      = true,   cinnabar  = true,
   valerian = true,   realgar   = true,
   skullcap = true,   malachite = true,   -- skullcap is dual-purpose: eaten and smoked
   linseed  = true,
}

--- Fallback body location for APPLY when an affliction does not name one. Achaea's APPLY
--- syntax needs a target part, and applying to the wrong one burns the balance without
--- curing anything, so afflist.lua carries the correct location per affliction and this
--- is only the safety net.
M.salveLocations = {
   mending        = "body",  renewal        = "body",
   restoration    = "torso", reconstructive = "torso",
   epidermal      = "body",  sensory        = "body",
   caloric        = "body",  exothermic     = "body",
   mass           = "body",  density        = "body",
   sileris        = "body",  quicksilver    = "body",
   health         = "torso",
}

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------

--- Resolve the item a cure actually consumes, honouring the herbs/minerals setting.
--- Every cure option carries both forms, so this is a straight pick between them.
--- @param option table a cure option from afflist ({ item, alt, ... })
--- @return string|nil
function M.resolveItem(option)
   if type(option) ~= "table" then return nil end
   local method = emunah.config.get("curing.method", "herbs")
   if method == "minerals" and option.alt then return option.alt end
   return option.item
end

--- Every consumable the cure tables can call for, in the form this character actually uses
--- (herbs or their mineral equivalents). This is the restocking list: the things that live
--- in the rift and have to be pulled out before they can be eaten or smoked.
---
--- Three sources, all drawing from the same rift: affliction cures (afflist.afflictions),
--- defence cures (afflist.defenceCures -- echinacea for thirdeye,
--- skullcap for deathsight/rebounding, myrrh), and deflist.lua's bare-command defences that
--- carry an explicit `item` (bayberry for blind, hawthorn for deaf). Before defence cures
--- were included here, keep-up would raise a defence like insomnia until the rift ran dry
--- and then just sit there refused, because nothing kept its herb topped up the way an
--- affliction cure's herb was.
---
--- Elixirs are deliberately absent -- they are vials, refilled with FILL rather than pulled
--- with OUTR, and a vial is not something you carry three of. Salves used to be excluded for
--- the same reason, but that turned out to be wrong about the mechanism, not just the
--- bookkeeping -- see M.restockableSalves() below.
local restockCache = {}

function M.restockables()
   -- Memoised per method: this walks every affliction in the table, and with restocking on
   -- every tick that is a scan of a few hundred entries per prompt for a list that only
   -- changes when the character does.
   local method = tostring(emunah.config.get("curing.method", "herbs"))
   if restockCache[method] then return restockCache[method] end

   local seen, out = {}, {}
   local function collect(item, vector)
      if (vector == "herb" or vector == "smoke") and item and not seen[item] then
         seen[item] = true
         out[#out + 1] = item
      end
   end

   for _, definition in pairs(emunah.curing.afflist.afflictions) do
      for _, option in ipairs(definition.cures or {}) do
         collect(M.resolveItem(option), option.vector)
      end
   end
   for _, option in pairs(emunah.curing.afflist.defenceCures) do
      collect(M.resolveItem(option), option.vector)
   end
   local deflist = emunah.curing.deflist
   if deflist then
      for _, entry in pairs(deflist.commands) do
         collect(entry.item, entry.vector)
      end
   end

   table.sort(out)   -- stable order, so the pull sequence is predictable and testable
   restockCache[method] = out
   return out
end

--- Memoised alongside restockCache and keyed the same way; see M.restockablesWithIrid().
local restockIridCache = {}

--- M.restockables() plus irid moss, which is what the engine's restock pass actually wants.
---
--- The engine used to build this per tick, by hand:
---
---     local wanted = {}
---     for _, item in ipairs(curelist.restockables()) do wanted[#wanted + 1] = item end
---     wanted[#wanted + 1] = "irid"
---
--- The copy was load-bearing and the comment there explained why: appending "irid" straight
--- onto restockables() grew the MEMOISED list by one every tick, forever, so each pass got
--- an iteration slower than the last. Copying fixed the bug and left a nineteen-slot table
--- allocated on every prompt to show for it.
---
--- Memoising the combined list keeps the fix and drops the allocation: the answer changes
--- only when `curing.method` does, exactly like the list it is built from, and the caller
--- gets a shared list it must not mutate -- which is the rule for every list this module
--- hands out.
function M.restockablesWithIrid()
   local method = tostring(emunah.config.get("curing.method", "herbs"))
   local hit = restockIridCache[method]
   if hit then return hit end

   local out = {}
   for _, item in ipairs(M.restockables()) do out[#out + 1] = item end
   -- Irid moss is not in the cure tables -- it treats no affliction, it refills health and
   -- mana -- but it is eaten from inventory like everything else here, so it stocks alike.
   out[#out + 1] = "irid"

   restockIridCache[method] = out
   return out
end

--- Every salve the cure tables call for, refilled with FILL rather than pulled with OUTR.
---
--- Confirmed live for epidermal only: `FILL EMPTY WITH EPIDERMAL FROM RIFT`. Reported in
--- play as "epidermal is in the rift, not in hand" going uncured for the whole fight,
--- because nothing ever tried to get it into a tin -- unlike herbs, no salve was ever
--- restocked at all, so `have.cure()`'s "in the rift" answer was structurally permanent
--- rather than a round trip away.
---
--- The other salves (mending, restoration, caloric, mass, sileris) are extended the same
--- command on the strength of the pattern rather than individual confirmation -- Achaea
--- already uses `FILL <container> WITH <fluid> FROM RIFT` for elixir vials (see
--- engine.elixirMissing()'s warning text), and "EMPTY" reads as the generic empty-container
--- word rather than something epidermal-specific. If any of them turns out to need
--- different phrasing, the generic "You do not have that/any of those/the" backstop in
--- detect/patterns.lua resyncs inventory and says so rather than looping silently.
local restockSalveCache = {}

function M.restockableSalves()
   local method = tostring(emunah.config.get("curing.method", "herbs"))
   if restockSalveCache[method] then return restockSalveCache[method] end

   local seen, out = {}, {}
   local function collect(item, vector)
      if vector == "salve" and item and not seen[item] then
         seen[item] = true
         out[#out + 1] = item
      end
   end

   for _, definition in pairs(emunah.curing.afflist.afflictions) do
      for _, option in ipairs(definition.cures or {}) do
         collect(M.resolveItem(option), option.vector)
      end
   end
   for _, option in pairs(emunah.curing.afflist.defenceCures) do
      collect(M.resolveItem(option), option.vector)
   end

   table.sort(out)
   restockSalveCache[method] = out
   return out
end

--- Build the command for a cure option.
--- @param option table { vector = "herb", item = "bloodroot", location = ..., command = ... }
--- @return string|nil command, string|nil item actually required
function M.command(option)
   if type(option) ~= "table" or not option.vector then return nil, nil end
   local vector = M.vectors[option.vector]
   if not vector then return nil, nil end

   -- An explicit command on the option wins; this is how `special` cures and any
   -- class-specific removal are expressed.
   if option.command then return option.command, option.item end

   if not vector.needsItem then
      return vector.command, nil
   end

   local item = M.resolveItem(option)
   if not item then return nil, nil end

   if option.vector == "salve" then
      local location = option.location or M.salveLocations[item] or "body"
      return string.format(vector.command, item, location), item
   end

   return string.format(vector.command, item), item
end

--- Config paths for the per-vector recovery override, built once.
---
--- `"curing.recovery." .. vector` is a string concatenation, and this is called from
--- have.spend() on every cure that goes out. The set of vectors is fixed, so the paths are
--- too; building them on demand and keeping them is one allocation per vector, ever, instead
--- of one per cure.
local recoveryPaths = setmetatable({}, {
   __index = function(self, vector)
      local path = "curing.recovery." .. tostring(vector)
      self[vector] = path
      return path
   end,
})

--- Fallback recovery time for a vector, honouring any config override.
function M.recovery(vector)
   local configured = emunah.config.get(recoveryPaths[vector])
   if configured then return tonumber(configured) or 2.0 end
   local definition = M.vectors[vector]
   return definition and definition.recovery or 2.0
end

--- Is this a vector we know how to drive?
function M.knownVector(vector)
   -- Bare key first: every caller on the hot path holds one of M.VECTORS already, and
   -- tostring() on a string still costs a call.
   if M.vectors[vector] ~= nil then return true end
   return M.vectors[tostring(vector or "")] ~= nil
end

return M

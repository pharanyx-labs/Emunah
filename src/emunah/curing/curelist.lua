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
   herb    = { recovery = 1.8, command = "eat %s",          needsItem = true  },
   salve   = { recovery = 1.8, command = "apply %s to %s",  needsItem = true  },
   -- Elixir recovery is deliberately LONG. Achaea announces sip balance returning
   -- ("You may drink another health or mana elixir."), and curing/detect/patterns.lua
   -- clears the vector the instant it does -- so this number is only ever the safety net
   -- for a missed message. An under-estimate here re-sends `drink health` mid-sip and
   -- wastes the vial; an over-estimate costs at most one late sip.
   elixir  = { recovery = 6.0, command = "drink %s",        needsItem = true  },
   smoke   = { recovery = 2.0, command = "smoke %s",        needsItem = true  },
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
--- Salves and elixirs are deliberately absent -- they are vials, refilled with FILL rather
--- than pulled with OUTR, and a vial is not something you carry three of.
local restockCache = {}

function M.restockables()
   -- Memoised per method: this walks every affliction in the table, and with restocking on
   -- every tick that is a scan of a few hundred entries per prompt for a list that only
   -- changes when the character does.
   local method = tostring(emunah.config.get("curing.method", "herbs"))
   if restockCache[method] then return restockCache[method] end

   local seen, out = {}, {}
   for _, definition in pairs(emunah.curing.afflist.afflictions) do
      for _, option in ipairs(definition.cures or {}) do
         if option.vector == "herb" or option.vector == "smoke" then
            local item = M.resolveItem(option)
            if item and not seen[item] then
               seen[item] = true
               out[#out + 1] = item
            end
         end
      end
   end
   table.sort(out)   -- stable order, so the pull sequence is predictable and testable
   restockCache[method] = out
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

--- Fallback recovery time for a vector, honouring any config override.
function M.recovery(vector)
   local configured = emunah.config.get("curing.recovery." .. tostring(vector))
   if configured then return tonumber(configured) or 2.0 end
   local definition = M.vectors[vector]
   return definition and definition.recovery or 2.0
end

--- Is this a vector we know how to drive?
function M.knownVector(vector)
   return M.vectors[tostring(vector or "")] ~= nil
end

return M

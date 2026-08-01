--- "Can I actually do this?" -- the capability gate.
---
--- Everything in this module answers a question about the character's current ability to
--- perform an action, using only tracked GMCP state. Nothing here sends a command or
--- guesses; if the data has not arrived yet the answer is a conservative one.
---
--- Why it exists
--- -------------
--- A curing engine that does not check first fails in a specific, maddening way: it picks
--- the correct cure, sends `eat kelp`, the game replies "You do not have that item", the
--- affliction stays, and the engine sends it again on the next tick -- forever, while you
--- die. Checking possession, skill and balance before queueing turns that infinite loop
--- into "no kelp, fall through to the next option, warn once".
---
--- The four questions, and where each is answered from:
---
---   have.skill(name)     Char.Skills index          -- do I know this ability?
---   have.item(name)      Char.Items inventory       -- is it in my hands?
---   have.cure(aff, vec)  the above + IRE.Rift       -- can I perform this cure?
---   have.balance(vec)    Char.Vitals + core/timers  -- is the vector free right now?

local M = {}

local util = emunah.util
local log  = emunah.log

--- Warn at most once per missing thing, so a depleted herb does not spam the console
--- every tick for the rest of the fight.
local warned = {}

local function warnOnce(key, fmt, ...)
   if warned[key] then return end
   warned[key] = true
   log.warn(fmt, ...)
end

--- Clear the warn-once memory. Called when inventory changes, so restocking silences the
--- warning without needing a reload.
function M.resetWarnings()
   warned = {}
end

-- ---------------------------------------------------------------------------
-- skills
-- ---------------------------------------------------------------------------

--- Abilities the game has explicitly told us we do not have -- see M.denySkill(). Checked
--- ahead of the index itself because the index's own "not built yet" default below is
--- permissive, and a rejection is unambiguous: e.g. right after an emreload, Char.Skills
--- has to make a fresh round trip before `skills.complete` is true again, and anything
--- gated only on the index would spend that whole window re-sending a command the game has
--- already refused once.
---
--- Cleared on the next "emunah.skills.complete" (see below) rather than re-checked on every
--- M.skill() call: re-checking "does the index say yes RIGHT NOW" on every call would let a
--- stale, unchanged index immediately undo the very denial it was just told about, since
--- nothing about the index actually changed between the rejection and the next query. A
--- fresh index round trip is real new evidence; the index just sitting there is not.
local denied = {}

--- Does the character know this ability?
---
--- Returns true when the skill index has not been built yet: refusing to act because we
--- have not finished asking the game what we know would break the system on every login,
--- and an unknown-ability rejection is cheap and self-correcting.
function M.skill(name)
   local key = tostring(name or ""):lower()
   if denied[key] then return false end
   local skills = emunah.gmcp.skills
   if not skills or not skills.complete then return true end
   return skills.has(name)
end

--- Record that the game itself has told us this ability is not available -- e.g. "Clot is
--- not a valid command." Overrides the index's permissive default for the rest of the
--- session, or until the index completes a fresh round trip (see the
--- "emunah.skills.complete" listener below); see the "clot" trigger in
--- curing/detect/patterns.lua for the confirmed case this exists for.
function M.denySkill(name)
   denied[tostring(name or ""):lower()] = true
end

-- A completed skill index is real new evidence -- e.g. the ability got trained since the
-- last denial -- so let it clear the slate rather than have a stale denial outlive it.
emunah.event.register("emunah.skills.complete", function()
   denied = {}
end, "have")

--- Does the character have a whole skillset? Cheap class inference.
function M.skillset(name)
   local skills = emunah.gmcp.skills
   if not skills then return false end
   return skills.hasGroup(name)
end

-- ---------------------------------------------------------------------------
-- items
-- ---------------------------------------------------------------------------

--- How many of an item are in inventory.
function M.item(name)
   local items = emunah.gmcp.items
   if not items then return 0 end
   return items.count(name)
end

--- How many we are carrying, counting a grouped stack by its stated number rather than as
--- one entry. M.item() answers "is there an entry for this"; this answers "how many".
function M.quantity(name)
   local items = emunah.gmcp.items
   if not items then return 0 end
   return items.quantity(name)
end

--- How many are in the Rift. Herbs are normally kept there and pulled with OUTR, so a
--- zero inventory count does not mean you are out.
function M.inRift(name)
   local ire = emunah.gmcp.ire
   if not ire then return 0 end
   return ire.riftCount(name)
end

--- Total available: inventory plus rift.
function M.supply(name)
   return M.item(name) + M.inRift(name)
end

--- Is a lit pipe with this herb available? Smoking needs one, and "I have valerian" is
--- not the same question as "I have a pipe with valerian in it".
---
--- Achaea names pipes descriptively ("a pipe filled with valerian"), so we match on the
--- herb name appearing in a pipe's description.
function M.pipe(herb)
   local items = emunah.gmcp.items
   if not items then return false end
   for _, item in ipairs(items.at("inv")) do
      local name = (item.name or ""):lower()
      if name:find("pipe", 1, true) and name:find(tostring(herb):lower(), 1, true) then
         return true
      end
   end
   -- No pipe matched by description. Rather than block smoking entirely -- descriptions
   -- vary, and many players keep several pipes -- allow it but say so once.
   warnOnce("pipe:" .. tostring(herb),
      "No pipe of %s found in inventory; smoking may fail.", tostring(herb))
   return true
end

-- ---------------------------------------------------------------------------
-- defences and afflictions
-- ---------------------------------------------------------------------------

function M.def(name)
   local defences = emunah.gmcp.defences
   return defences and defences.has(name) or false
end

function M.affliction(name)
   local afflictions = emunah.gmcp.afflictions
   return afflictions and afflictions.has(name) or false
end

-- ---------------------------------------------------------------------------
-- balances
-- ---------------------------------------------------------------------------

--- Is a vector free to use right now?
---
--- Two different mechanisms, deliberately kept separate:
---
---   balance / equilibrium come from Char.Vitals and are authoritative. The game tells us
---     directly, so there is nothing to estimate.
---
---   herb / salve / elixir / smoke / focus / tree are timed. Achaea does not report these
---     over GMCP, so core/timers.lua runs a fallback countdown that the confirmation
---     triggers cut short. `ready` therefore means "our timer has lapsed", which is
---     correct but can lag reality by a fraction of a second when a confirmation is lost.
---
--- @param vector string
--- @return boolean
function M.balance(vector)
   local vitals = emunah.gmcp.vitals
   if not vitals then return false end

   if vector == "free" then return true end
   if vector == "balance" then return vitals.bal end
   -- Equilibrium needs its timer as well as the flag, for the same reason an attack does:
   -- `perform hands` costs 3 seconds of it, and Char.Vitals cannot report the loss until
   -- the game has actually run the command. The flag alone would let a second one go out
   -- into the gap.
   if vector == "equilibrium" then
      return vitals.eq and emunah.timers.ready("cure.equilibrium")
   end

   -- Writhing needs no resource; it is gated by the affliction itself.
   if vector == "writhe" then return true end

   return emunah.timers.ready("cure." .. tostring(vector))
end

--- Mark a vector as spent, starting its fallback recovery timer.
function M.spend(vector)
   local recovery = emunah.curing.curelist.recovery(vector)
   emunah.timers.start("cure." .. tostring(vector), recovery)
end

--- Mark a vector as recovered ahead of its timer, on trigger confirmation.
function M.recover(vector)
   emunah.timers.stop("cure." .. tostring(vector))
end

-- ---------------------------------------------------------------------------
-- cures
-- ---------------------------------------------------------------------------

--- Is a vector currently blocked by an affliction?
--- Returns the blocking affliction's name, or nil.
---
--- Reads the curing engine's tracked afflictions when it is running, and falls back to
--- the server's list otherwise, so this is meaningful even with curing switched off.
function M.blockedBy(vector)
   local afflist = emunah.curing.afflist
   local engine  = emunah.curing.engine
   for affliction, blocked in pairs(afflist.blocks) do
      for _, shut in ipairs(blocked) do
         if shut == vector then
            local present = engine and engine.has and engine.has(affliction)
               or M.affliction(affliction)
            if present then return affliction end
         end
      end
   end
   return nil
end

--- Can we perform this specific cure option right now?
---
--- @param option table a cure option from afflist ({ vector, item, alt, location })
--- @return boolean usable
--- @return string|nil reason when not usable
function M.cure(option)
   if type(option) ~= "table" or not option.vector then
      return false, "malformed cure option"
   end

   local curelist = emunah.curing.curelist
   local vector = option.vector

   if not curelist.knownVector(vector) then
      return false, "unknown vector " .. tostring(vector)
   end

   local blocker = M.blockedBy(vector)
   if blocker then
      return false, ("%s is blocked by %s"):format(vector, blocker)
   end

   local definition = curelist.vectors[vector]
   if definition and definition.needsItem then
      local item = curelist.resolveItem(option)
      if not item then return false, "no item resolved" end

      if vector == "smoke" then
         if not M.pipe(item) then
            return false, ("no pipe of %s"):format(item)
         end
      elseif M.supply(item) <= 0 then
         warnOnce("item:" .. item, "Out of %s -- falling through to the next cure.", item)
         return false, ("out of %s"):format(item)
      end
   end

   -- FOCUS costs mana; attempting it at empty is a wasted balance.
   if vector == "focus" then
      local vitals = emunah.gmcp.vitals
      if vitals and vitals.mp < 250 then
         return false, "not enough mana to focus"
      end
      if not M.skill("focus") then
         return false, "focus not known"
      end

      -- GUILT MAKES FOCUSING A BAD TRADE, AND ANOREXIA MAKES IT THE ONLY TRADE.
      --
      -- Reported in play: "a good rule is NOT to focus when you have guilt, UNLESS you also
      -- have anorexia." Both halves matter and they pull opposite ways.
      --
      -- Focusing under guilt costs more than the affliction it clears, so ordinarily it is
      -- the wrong move. But anorexia shuts the herb vector, and the herb vector is where
      -- guilt's own cure lives -- so with both up, refusing to focus means refusing to act
      -- at all, and the lock simply stays shut. The exception is not a softening of the
      -- rule; it is the case the rule would otherwise make fatal.
      --
      -- Tactical rather than mechanical, so it is a setting: `emunah set curing.focusGuilt
      -- true` focuses regardless.
      if emunah.config.get("curing.focusGuilt", false) ~= true then
         local engine = emunah.curing.engine
         local function afflicted(name)
            if engine and engine.has and engine.has(name) then return true end
            return M.affliction(name)
         end
         if afflicted("guilt") and not afflicted("anorexia") then
            return false, "guilt -- not focusing while the herb vector is still open"
         end
      end
   end

   if vector == "tree" and not M.def("tree") then
      -- The Tree of Life tattoo has to be inked before it can be touched.
      return false, "no tree tattoo"
   end

   return true
end

--- Full readiness check: is the vector free AND is the cure performable?
function M.canCure(option)
   local usable, reason = M.cure(option)
   if not usable then return false, reason end
   if not M.balance(option.vector) then
      return false, ("%s balance not ready"):format(option.vector)
   end
   return true
end

-- ---------------------------------------------------------------------------
-- reporting
-- ---------------------------------------------------------------------------

--- Human-readable summary, for `emunah have`.
function M.report()
   local out = {
      skillsIndexed = emunah.gmcp.skills and emunah.gmcp.skills.complete or false,
      inventory     = emunah.gmcp.items and emunah.gmcp.items.count("inv") or 0,
      riftEntries   = emunah.gmcp.ire and util.count(emunah.gmcp.ire.rift) or 0,
      balances      = {},
      blocked       = {},
   }
   for _, vector in ipairs({ "balance", "equilibrium", "herb", "salve", "elixir", "smoke", "focus", "tree" }) do
      out.balances[vector] = M.balance(vector)
      local blocker = M.blockedBy(vector)
      if blocker then out.blocked[vector] = blocker end
   end
   return out
end

-- Restocking should clear "out of X" warnings without a reload.
emunah.event.register("emunah.items.added", function()
   M.resetWarnings()
end, "have")
emunah.event.register("emunah.rift.change", function()
   M.resetWarnings()
end, "have")

return M

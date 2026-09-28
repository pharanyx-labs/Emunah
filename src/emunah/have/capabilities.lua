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
--- PIPELIST ANSWERS THIS PROPERLY; the inventory scan below does not, and never did.
---
--- The fallback assumes Achaea names pipes descriptively ("a pipe filled with valerian").
--- Real ones are not: three pipes holding skullcap, elm and valerian are all called
--- "a white stone pipe", so the herb never appears in the description and this always fell
--- through to the permissive branch at the bottom. Every smoke cure was therefore allowed
--- unconditionally, which is right often enough to hide the problem and wrong exactly when
--- the pipe has gone out or run dry.
---
--- emunah.pipes tracks Status and Contents from PIPELIST, so when it has seen one it can say
--- what the description cannot. It has to be LIT as well as loaded -- a pipe that has gone
--- cold holds the herb and cannot be smoked.
function M.pipe(herb)
   local pipes = emunah.pipes
   if pipes and next(pipes.pipes) ~= nil then
      for _, pipe in ipairs(pipes.list()) do
         if pipe.herb == tostring(herb):lower() and pipe.status == "lit" and pipe.puffs > 0 then
            return true
         end
      end
      -- PIPELIST has been seen and does not show a lit pipe of this herb. That is a real
      -- answer rather than an absence of one, so it is not softened the way the fallback is.
      return false
   end

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

   -- Writhing needs no resource, but it must not be repeated while one is under way --
   -- a second WRITHE prolongs the first (HELP ENTANGLEMENT). See engine.onWritheStart.
   if vector == "writhe" then return emunah.timers.ready("writhe.busy") end

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
--- vector -> the afflictions that shut it, inverted from afflist.blocks on first use.
---
--- blockedBy() used to walk the whole of afflist.blocks and each entry's vector list looking
--- for one vector. That is a nested scan answering a question with a fixed answer: the table
--- is written at load and never mutated, so the inversion cannot go stale. It matters
--- because this is asked eleven times per prompt by have.cure(), and five more times per
--- repaint by ui/vitals.lua's vector lights.
local blockedByVector = nil

local function shutBy(vector)
   if not blockedByVector then
      blockedByVector = {}
      for affliction, blocked in pairs(emunah.curing.afflist.blocks) do
         for _, shut in ipairs(blocked) do
            local list = blockedByVector[shut]
            if not list then
               list = {}
               blockedByVector[shut] = list
            end
            list[#list + 1] = affliction
         end
      end
      -- Stable order, so which affliction is named as the blocker does not depend on hash
      -- iteration order -- two afflictions can shut the same vector, and a report that
      -- changes its mind between prompts reads as a bug.
      for _, list in pairs(blockedByVector) do table.sort(list) end
   end
   return blockedByVector[vector]
end

--- Is a vector currently blocked by an affliction?
--- Returns the blocking affliction's name, or nil.
---
--- Reads the curing engine's tracked afflictions when it is running, and falls back to
--- the server's list otherwise, so this is meaningful even with curing switched off.
function M.blockedBy(vector)
   local candidates = shutBy(vector)
   if not candidates then return nil end

   local engine = emunah.curing.engine
   local has = engine and engine.has
   for index = 1, #candidates do
      local affliction = candidates[index]
      local present = (has and has(affliction)) or M.affliction(affliction)
      if present then return affliction end
   end
   return nil
end

--- FOCUS is refused below this much willpower. The reference system's check_focus holds focus at
--- `stats.currentwillpower <= 75`; willpower is the resource mental abilities draw on
--- (HELP WILLPOWER), so a focus sent without it is a refusal, not a cure.
M.FOCUS_MIN_WILLPOWER = 75

--- Percent of maximum mana at or below which FOCUS is held. The reference system's default `manause`.
M.FOCUS_MIN_MANA = 35

--- Why a vector cannot be used right now, beyond its own balance -- or nil.
---
--- The queue asks this AT SEND TIME, not only when a cure is chosen. A cure queued while
--- the vector was open waits there for its balance, and anorexia (or slickness, asthma...)
--- can land in that gap. Checking only at resolve time put the queued `eat` on the wire
--- into "You are afflicted with anorexia and cannot eat anything." -- an action sent
--- without the state to perform it, which is the one thing this layer exists to prevent.
function M.vectorBlocked(vector)
   local blocker = M.blockedBy(vector)
   if blocker then return blocker end
   if vector == "tree" and M.bothArmsBroken() then return "both arms disabled" end
   if vector == "focus" then
      local vitals = emunah.gmcp.vitals
      if vitals and vitals.maxwp > 0 and vitals.wp <= M.FOCUS_MIN_WILLPOWER then
         return "low willpower"
      end
      -- The reference system's check_focus also needs can_usemana(): mana above `conf.manause`, the share of
      -- maximum mana below which it stops spending mana on skills (default 35%). Mana is
      -- what an enemy Priest's kill route drains (docs/game/priest-abilities.md).
      local floor = tonumber(emunah.config.get("curing.focusMinMana", M.FOCUS_MIN_MANA))
         or M.FOCUS_MIN_MANA
      if vitals and vitals.maxmp > 0 and (vitals.percent.mp or 100) <= floor then
         return "mana below " .. floor .. "%"
      end
   end
   return nil
end

--- Is this whole arm disabled, at any severity tier?
local function armDisabled(side)
   local afflist = emunah.curing.afflist
   local engine  = emunah.curing.engine
   for _, name in ipairs(afflist.armAfflictions[side] or {}) do
      local present = (engine and engine.has and engine.has(name)) or M.affliction(name)
      if present then return true end
   end
   return false
end

--- Both arms disabled at once -- touching a tattoo needs a working hand, and is refused the
--- same way paralysis refuses it. See afflist.armAfflictions for provenance.
function M.bothArmsBroken()
   return armDisabled("left") and armDisabled("right")
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

   -- Blockers of ONE cure rather than a whole vector: confusion stops CONCENTRATE (HELP
   -- COMPOSE) without stopping COMPOSE or CLOT on the same slot.
   -- And the reference system's per-cure conditions (afflist.CONDITIONS).
   if option.unless then
      for _, name in ipairs(option.unless) do
         if emunah.act.afflicted(name) then
            return false, ("%s is prevented by %s"):format(option.command or vector, name)
         end
      end
   end
   if option.unlessInFlight then
      for _, other in ipairs(option.unlessInFlight) do
         if emunah.queue.awaiting(other) then
            return false, ("%s waits for the %s in flight"):format(option.command or vector, other)
         end
      end
   end

   local definition = curelist.vectors[vector]
   if definition and definition.needsItem then
      local item = curelist.resolveItem(option)
      if not item then return false, "no item resolved" end

      -- EPIDERMAL CURES BLIND, DEAF AND ANOREXIA ALIKE, and reported in play: applying it
      -- for one can cure the others too, regardless of which affliction actually queued it
      -- or which location it is applied to. `blindness`/`deafness` themselves are already
      -- guarded (deflist.deliberate() in engine.resolve()'s loop skips ranking them at all
      -- while held on purpose) -- but that guard is keyed to the affliction BEING cured,
      -- and says nothing about a DIFFERENT affliction, like anorexia, that also wants
      -- epidermal. Refusing the item outright while either defence is deliberately up is
      -- the safe direction: anorexia stays uncured a little longer and falls through to
      -- focus, rather than risk stripping a defence raised on purpose mid-fight.
      if item == "epidermal" then
         local deflist = emunah.curing.deflist
         if deflist and (deflist.deliberate("blindness") or deflist.deliberate("deafness")) then
            return false, "epidermal would also cure blind/deaf, which are held on purpose"
         end
      end

      if vector == "smoke" then
         if not M.pipe(item) then
            return false, ("no pipe of %s"):format(item)
         end
      elseif M.item(item) <= 0 then
         -- NEITHER LIST HAS ARRIVED YET is a third state, distinct from "confirmed empty" in
         -- both places -- and it is not rare: it is every login and reload, for as long as
         -- Char.Items.Inv and IRE.Rift.List take to answer. Live at login 2026-08-03
         -- 16:29:25.58, already paralysed: this branch read zero in both inventory and rift
         -- (neither had actually landed) and warned "Out of bloodroot" -- wrong, and the
         -- warning is once-per-item with nothing at this call site to ever clear it, so a
         -- REAL "out of bloodroot" later in the same session would have stayed silent behind
         -- it. Three seconds later, once IRE.Rift.List actually arrived, the identical
         -- refusal correctly became "bloodroot is in the rift, not in hand". Distinguishing
         -- this here means the loud, once-only warning is reserved for when it is true.
         local items = emunah.gmcp.items
         local ire   = emunah.gmcp.ire
         if not ((items and items.inventoryKnown()) and (ire and ire.riftKnown())) then
            return false, "inventory/rift not loaded yet"
         end

         -- IN HAND, NOT IN THE RIFT. supply() counts both, and that is the right question
         -- for "can I get this" -- it is the wrong one for "can I eat this now". A death
         -- drops the pack while the rift keeps its 750 bloodroot, so the cure read as
         -- performable and `eat bloodroot` went out every two seconds against "What do you
         -- want to eat?", indefinitely, with paralysis never clearing.
         --
         -- The rift is still the answer, just not this instant: the restocker pulls it and
         -- the cure becomes possible a round trip later. Saying which of the two is the
         -- case matters, because "out of bloodroot" and "bloodroot is in the rift" call for
         -- completely different responses from whoever reads the log.
         local inRift = M.inRift(item)
         if inRift > 0 then
            return false, ("%s is in the rift, not in hand"):format(item)
         end
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

      -- GUILT MAKES FOCUSING A BAD TRADE, UNLESS NOTHING ELSE CAN CLEAR THE GUILT.
      --
      -- Reported in play: "a good rule is NOT to focus when you have guilt, UNLESS you also
      -- have anorexia." Focusing under guilt costs more than the affliction it clears, so
      -- ordinarily it is the wrong move -- but guilt's own cure is a herb, and if that route
      -- is shut then refusing to focus means refusing to act at all.
      --
      -- THE TEST IS WHETHER GUILT CAN ACTUALLY BE EATEN AWAY RIGHT NOW, not whether
      -- anorexia specifically is up. Anorexia was only ever the example: being out of
      -- lobelia shuts the same door, and in a real fight that is the commoner way to lose
      -- it. Checking the affliction rather than the capability left the engine refusing to
      -- focus while it also had nothing to eat, which is the one state where focusing is
      -- unambiguously right.
      --
      -- Herb BALANCE deliberately does not enter into it. Focus runs on its own balance, so
      -- being mid-herb-cooldown says nothing about whether focusing is a good idea -- it is
      -- a question about supply and blocks, both of which have.cure() answers.
      if emunah.config.get("curing.focusGuilt", false) ~= true then
         local engine = emunah.curing.engine
         local guilty = (engine and engine.has and engine.has("guilt")) or M.affliction("guilt")
         if guilty then
            local afflist = emunah.curing.afflist
            local canEatItAway = false
            for _, herbOption in ipairs(afflist.curesVia("guilt", "herb")) do
               if M.cure(herbOption) then canEatItAway = true end
            end
            if canEatItAway then
               return false, "guilt -- eating it away first, which costs less than focusing"
            end
         end
      end
   end

   if vector == "tree" then
      if not M.def("tree") then
         -- The Tree of Life tattoo has to be inked before it can be touched.
         return false, "no tree tattoo"
      end
      if M.bothArmsBroken() then
         return false, "both arms are broken"
      end
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

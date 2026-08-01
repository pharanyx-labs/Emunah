--- The curing engine.
---
--- Runs once per tick (per Char.Vitals, which Achaea sends with every prompt). Each tick:
---
---   1. reconcile tracked afflictions against the server's list, periodically
---   2. for each vector independently, pick the most urgent affliction that vector can
---      cure, check we are actually able to perform it, and queue the command
---   3. flush the queue, which sends at most one command per free vector
---
--- Per-vector resolution is the important design choice. A single global priority list
--- would mean the most urgent affliction hogs the tick even when it is waiting on salve
--- balance and three herb cures could have gone out for free. Achaea combat is won on
--- exactly that kind of throughput.
---
--- DETECTION: read this before trusting the engine in PvP
--- ------------------------------------------------------
--- Affliction state comes from two sources:
---
---   Char.Afflictions (GMCP) -- reliable, but only reports afflictions Achaea chooses to
---     announce. Complete enough for bashing; incomplete in PvP, where much of the point
---     is afflicting you with things you have not been told about.
---
---   Triggers (curing/detect) -- how that gap gets closed, and where most of the work in
---     a mature system goes. The framework is here and is data-driven, but the shipped
---     pattern set is a seed, not a complete corpus: Achaea's affliction messages are not
---     published in a form that could be transcribed reliably, and a wrong pattern is
---     worse than a missing one because it silently corrupts state. Run `emunah learn on` to log
---     unrecognised lines while you fight, then add patterns from what you actually see.
---
--- So: this engine is production-ready for PvE today, and is the correct scaffolding for
--- PvP once the pattern set is filled in against real combat logs.

local M = {}

local util     = emunah.util
local log      = emunah.log
local event    = emunah.event
local queue    = emunah.queue
local have     = emunah.have
local afflist  = emunah.curing.afflist
local curelist = emunah.curing.curelist

--- affliction name -> { since, source }
M.tracked = {}

--- Vectors we resolve cures on, in the order we consider them. Order only affects which
--- vector gets first refusal on a shared resource; they are otherwise independent.
M.VECTORS = { "salve", "herb", "smoke", "elixir", "focus", "tree" }

M.enabled = false

-- ---------------------------------------------------------------------------
-- affliction state
-- ---------------------------------------------------------------------------

--- Record an affliction.
--- @param source string "gmcp" | "trigger" | "manual"
function M.add(name, source)
   name = tostring(name or ""):lower()
   if name == "" then return false end
   if M.tracked[name] then return false end

   M.tracked[name] = { since = emunah.util.now(), source = source or "manual" }

   if not afflist.known(name) and not afflist.isWrithe(name)
      and not afflist.isState(name) then
      -- Worth saying out loud: an affliction we cannot cure will sit in state forever.
      log.debug("Tracking unknown affliction %q (no cure defined).", name)
   end

   event.raise("affliction.tracked", name, source)
   return true
end

function M.remove(name)
   name = tostring(name or ""):lower()
   if not M.tracked[name] then return false end
   M.tracked[name] = nil
   event.raise("affliction.cured", name)
   return true
end

function M.has(name)
   return M.tracked[tostring(name or ""):lower()] ~= nil
end

function M.clear()
   M.tracked = {}
end

function M.count()
   return util.count(M.tracked)
end

--- Tracked afflictions sorted by onset, oldest first.
function M.list()
   local out = {}
   for name, record in pairs(M.tracked) do
      out[#out + 1] = { name = name, since = record.since, source = record.source }
   end
   table.sort(out, function(a, b) return a.since < b.since end)
   return out
end

--- Reconcile against the server's view.
---
--- Removal is authoritative: if Char.Afflictions no longer lists something, it is gone,
--- whatever our triggers think. Addition is only corroborating -- we adopt afflictions
--- the server reports that we missed, but we do NOT drop trigger-detected afflictions
--- merely because the server has not mentioned them, because in PvP it frequently will
--- not.
function M.reconcile()
   local server = emunah.gmcp.afflictions
   if not server then return end

   local reported = server.set()

   -- Adopt anything the server knows about that we do not.
   for name in pairs(reported) do
      if not M.tracked[name] then
         M.add(name, "gmcp")
      end
   end

   -- Drop anything the server explicitly says is gone, but only if we learned it from
   -- GMCP in the first place. Trigger-detected afflictions survive.
   for name, record in pairs(M.tracked) do
      if record.source == "gmcp" and not reported[name] then
         M.remove(name)
      end
   end
end

-- ---------------------------------------------------------------------------
-- cure resolution
-- ---------------------------------------------------------------------------

--- Best cure to perform on one vector right now.
--- @return table|nil option, string|nil affliction
local function resolve(vector)
   local bestOption, bestAffliction, bestRank

   for name in pairs(M.tracked) do
      local rank = afflist.priority(name, vector)
      if rank and (not bestRank or rank < bestRank) then
         for _, option in ipairs(afflist.curesVia(name, vector)) do
            local usable = have.cure(option)
            if usable then
               bestOption, bestAffliction, bestRank = option, name, rank
               break
            end
         end
      end
   end

   return bestOption, bestAffliction, bestRank
end

--- Writhes are not priority-ranked; if you are bound you writhe, and nothing else on that
--- vector matters.
local function resolveWrithe()
   for name in pairs(M.tracked) do
      if afflist.isWrithe(name) then return name end
   end
   return nil
end

--- Emergency healing. Not an affliction, but it competes for the elixir vector and has to
--- outrank everything on it -- there is no point curing stupidity at 8% health.
--- What `perform hands` costs, in seconds of equilibrium.
M.HANDS_EQUILIBRIUM = 3.0

--- How long to wait for the game to confirm an elixir before re-arming.
---
--- "You may drink another health or mana elixir." arrives around five seconds after the
--- sip, so the generic two-second wait lapsed every single time and logged a re-arm for a
--- cure that had worked perfectly. The real confirmation is the one that matters; this is
--- only the backstop for when it is missed.
M.ELIXIR_CONFIRM = 7.0

--- How long to stop asking for a fluid the game says we are not carrying.
---
--- Long enough that a fight is not spent re-sending a command that cannot work; short
--- enough that filling a vial takes effect without a reload.
M.MISSING_RETRY = 120

--- Achaea could not resolve `drink <fluid>`: no vial on us holds it.
---
--- Live at 11:10:14.06 -- `drink mana` answered with "What is it that you wish to drink?",
--- fourteen vials held, 2000 sips of mana in the rift and none of it in a vial. Retrying
--- that on a loop is not merely useless, it is actively harmful: see the trigger in
--- detect/patterns.lua for why it stops health sipping too.
function M.elixirMissing(fluid)
   if not fluid then return end
   emunah.timers.start("elixir.missing." .. fluid, M.MISSING_RETRY)
   emunah.log.warn("No vial of %s to drink -- FILL <vial> WITH %s FROM RIFT. "
      .. "Not asking again for %ds.", fluid, fluid, M.MISSING_RETRY)
end

--- Is it worth asking for this fluid at all?
local function elixirAvailable(fluid)
   return emunah.timers.ready("elixir.missing." .. fluid)
end

local function queueHealing()
   local vitals = emunah.gmcp.vitals
   if not vitals then return end

   local healthAt = tonumber(emunah.config.get("curing.healthThreshold", 80)) or 80
   local manaAt   = tonumber(emunah.config.get("curing.manaThreshold", 85)) or 85

   -- PERFORM HANDS -- a second, independent source of healing.
   --
   -- Worth having alongside the elixir precisely because it does not compete with it: the
   -- elixir spends sip balance, this spends equilibrium, so both can be in flight at once
   -- and the two together heal roughly twice as fast as either alone. That matters most in
   -- exactly the situation this threshold describes.
   --
   -- Deliberately a lower threshold than the elixir's: this is the emergency, not the
   -- routine top-up. Costs 3 seconds of equilibrium, so it is queued on that vector and
   -- marks it spent on send -- equilibrium comes from Char.Vitals, which will not report
   -- the loss until the game has actually run the command.
   local handsAt = tonumber(emunah.config.get("curing.handsThreshold", 50)) or 50
   -- No have.skill() gate. The ability's exact name in the skill index has never been
   -- observed, and guessing it wrong would silently disable healing the moment the index
   -- finished loading -- the same failure the CLOT gate produced in the other direction.
   -- If the ability turns out to be unavailable the game says so, and that rejection can
   -- be handled like every other capability here.
   if vitals.percent.hp < handsAt then
      queue.push("equilibrium", "perform hands", {
         priority = 0, tag = "healhands",
         confirm  = emunah.config.get("curing.confirmWait", 2.0),
         onSent   = function()
            emunah.gmcp.vitals.spend("eq")
            emunah.timers.start("cure.equilibrium", M.HANDS_EQUILIBRIUM)
         end,
      })
   end

   -- The availability check is part of the condition, not a wrapper around the push, so a
   -- fluid we cannot drink falls through to the next branch rather than blocking it. Health
   -- and mana share one vector; a missing health vial must not also stop mana.
   if vitals.percent.hp < healthAt and elixirAvailable("health") then
      queue.push("elixir", "drink health", {
         priority = 0, tag = "healhealth",
         confirm  = emunah.config.get("curing.elixirConfirm", M.ELIXIR_CONFIRM),
         onSent   = function() have.spend("elixir") end,
      })
   elseif vitals.percent.mp < manaAt and elixirAvailable("mana") then
      queue.push("elixir", "drink mana", {
         priority = 0, tag = "healmana",
         confirm  = emunah.config.get("curing.elixirConfirm", M.ELIXIR_CONFIRM),
         onSent   = function() have.spend("elixir") end,
      })
   end
end

--- IRID MOSS -- a third healing source, on a balance nothing else touches.
---
--- Restores health and mana together ("You feel your health and mana replenished.", mana
--- 80% -> 88% at 11:28:31.95), and announces its own recovery, so it stacks with both the
--- elixir and `perform hands` rather than competing with either.
---
--- Deliberately a lower threshold than the elixir's. The moss is finite -- 498 in the rift
--- and no way to make more in a fight -- while elixirs refill from a tun. So this is the
--- second line, not the routine top-up. `emunah config curing.iridThreshold` moves it.
M.IRID_THRESHOLD = 68

local function queueIrid()
   if emunah.config.get("curing.irid", true) == false then return end
   local vitals = emunah.gmcp.vitals
   if not vitals then return end

   local at = tonumber(emunah.config.get("curing.iridThreshold", M.IRID_THRESHOLD))
      or M.IRID_THRESHOLD
   -- Either bar: it refills both, so either being low is reason enough.
   if vitals.percent.hp >= at and vitals.percent.mp >= at then return end

   -- `alive` on both, because both are refused while dead. Neither needs `standing`:
   -- eating works flat on your back, and refusing to heal while knocked down is how an
   -- automated system kills you.
   if have.item("irid") > 0 then
      -- Anorexia shuts the eat but not the pull, so it is checked HERE rather than in
      -- have.balance() -- the vector itself is free, we just cannot use it yet.
      if not have.blockedBy("moss") then
         queue.push("moss", "eat irid", {
            priority = 0, tag = "irid",
            needs    = { alive = true },
            -- Longer than the 5.94s the balance actually takes. At 5.0 this timed out
            -- every single time ("No confirmation for [moss] eat irid -- re-arming." at
            -- 12:41:06.17, with the real confirmation arriving at 12:41:07.55) and the
            -- log line was pure noise about a command that had worked.
            confirm  = emunah.config.get("curing.mossConfirm", 9.0),
            onSent   = function() have.spend("moss") end,
         })
      end
   elseif have.inRift("irid") > 0 then
      queue.push("rift", "outr irid", {
         priority = 0, tag = "irid",
         needs    = { alive = true },
         confirm  = emunah.config.get("curing.riftConfirm", 1.5),
         onSent   = function() have.spend("rift") end,
      })
   end
end

-- ---------------------------------------------------------------------------
-- Restocking from the rift
-- ---------------------------------------------------------------------------
--
-- Everything lives in the rift, and OUTR has a round trip. Pulling a herb at the moment
-- the affliction lands is a cure that arrives a second late, which against a lock is a
-- cure that did not happen. So carry a few of each ahead of time.
--
-- THE CEILING IS THE POINT. Inventory is lost on death and the rift is not, so this is not
-- "carry as many as possible" -- three of each covers a lock without turning a death into
-- a shopping trip. Raise it with `emunah config curing.stockTarget` if you would rather
-- risk the loss.

M.STOCK_TARGET = 3

--- How many pulls of one item are allowed without the held count moving, before we stop.
---
--- The guard against a counting mistake becoming an unbounded pull: if a stack arrives in
--- a wording have.quantity() cannot read, it counts as 1 and the target can never be met.
--- The honest response to "my model of this is wrong" is to stop and say so; the
--- alternative is emptying the rift into a pack that the next death drops on the floor.
---
--- Three survives running every tick because only ONE pull is in flight at a time and the
--- inventory update lands first: in the trace at 11:48:26 the Char.Items.Add for the moss
--- arrived before "You remove 3 irid...", which is what frees the vector. So the count has
--- already moved by the time another pull is possible, and the budget resets.
M.STOCK_ATTEMPTS = 3

local stockPulls, stockSeen, stockWarned = {}, {}, {}

--- Reset the restocking ledger. Used on reload and when the rift is re-listed.
function M.forgetStock()
   stockPulls, stockSeen, stockWarned = {}, {}, {}
end

local function queueRestock()
   if emunah.config.get("curing.restock", true) == false then return end
   -- One pull at a time, and never in competition with the emergency pull in queueIrid():
   -- if the rift vector is busy there is nothing to decide.
   if queue.pending("rift") or queue.awaiting("rift") then return end

   -- NOT KNOWING what we carry is not the same as carrying nothing, and acting on the
   -- second when it is the first is what put 9 ash and 6 bloodroot in the pack: a reload
   -- empties this module's inventory while the character still holds everything, so every
   -- item read as 0 and got pulled again. Three reloads, three pulls of three.
   local items = emunah.gmcp.items
   if not (items and items.inventoryKnown()) then return end

   local target = tonumber(emunah.config.get("curing.stockTarget", M.STOCK_TARGET))
      or M.STOCK_TARGET

   local wanted = curelist.restockables()
   -- Irid moss is not in the cure tables -- it treats no affliction, it refills health and
   -- mana -- but it is eaten from inventory like everything else here, so it stocks alike.
   wanted[#wanted + 1] = "irid"

   for _, item in ipairs(wanted) do
      local held = have.quantity(item)
      -- Any increase means the count is moving, so the previous pulls worked and the
      -- attempt budget resets. Consumption lowers `seen` too, which is what lets a
      -- long-lived session keep topping up after every fight.
      if held > (stockSeen[item] or -1) then stockPulls[item] = 0 end
      stockSeen[item] = held

      if held < target then
         local spent = stockPulls[item] or 0
         if spent >= M.STOCK_ATTEMPTS then
            if not stockWarned[item] then
               stockWarned[item] = true
               log.warn("Pulled %s %d times and still count %d in inventory -- "
                  .. "not pulling more. Check what INV calls a stack.", item, spent, held)
            end
         elseif have.inRift(item) > 0 then
            local want = math.min(target - held, have.inRift(item))
            queue.push("rift", string.format("outr %d %s", want, item), {
               priority = 50,       -- a top-up loses the slot to a pull we need right now
               tag      = "restock",
               needs    = { alive = true },
               confirm  = emunah.config.get("curing.riftConfirm", 1.5),
               onSent   = function()
                  have.spend("rift")
                  stockPulls[item] = (stockPulls[item] or 0) + 1
               end,
            })
            return
         end

      elseif held > target then
         -- OVER the target, so put the difference back. Inventory is what a death drops;
         -- the rift is not. Anything above the line is risk carried for no benefit, and
         -- keeping the number exact is the only way "three of each" stays true after a
         -- manual pull, a reload that over-pulled, or picking up a corpse's herbs.
         --
         -- INR is the inverse of OUTR and confirms the same way ("You store 9 ash,
         -- bringing the total in the rift to 100.") -- syntax from HELP RIFT.
         queue.push("rift", string.format("inr %d %s", held - target, item), {
            priority = 60,          -- lower than a pull: being short matters more
            tag      = "restock",
            needs    = { alive = true },
            confirm  = emunah.config.get("curing.riftConfirm", 1.5),
            onSent   = function() have.spend("rift") end,
         })
         return
      end
   end
end

--- Check stock and act on it now, without waiting for a prompt.
---
--- The engine is prompt-driven, which is right for curing -- nothing changes between
--- prompts -- but wrong for restocking, because the two moments stock is most likely to be
--- wrong are a reload and a fresh inventory listing, and neither produces a prompt. Idle in
--- a shop after `emreload` at 12:05:52, the first pull did not go out until a manual LOOK
--- at 12:07:28: ninety-six seconds of standing there unstocked.
function M.restockNow()
   if not M.enabled then return end
   queueRestock()
   queue.flush()
end

--- One pass of the engine.
function M.tick()
   if not M.enabled then return end

   -- Periodic reconciliation. Cheap, but not free, so not every tick.
   local every = tonumber(emunah.config.get("curing.reconcileEvery", 20)) or 20
   local vitals = emunah.gmcp.vitals
   if vitals and every > 0 and (vitals.ticks % every) == 0 then
      M.reconcile()
   end

   -- Writhes first: while bound, most other actions will be refused anyway.
   local writhe = resolveWrithe()
   if writhe then
      queue.push("writhe", "writhe", {
         priority = 0, tag = writhe,
         confirm  = emunah.config.get("curing.confirmWait", 2.0),
      })
   end

   queueHealing()
   queueIrid()

   -- Every tick by default. It was every tenth, which meant one item pulled per ten
   -- prompts: `outr 3 valerian` at 11:47:32 and `outr 3 irid` at 11:48:26, nearly a minute
   -- apart, while most of the cure list was still not carried. Only one pull can be in
   -- flight regardless, so the tick interval was pure delay on top of the round trip.
   local restockEvery = tonumber(emunah.config.get("curing.restockEvery", 1)) or 1
   if vitals and restockEvery > 0 and (vitals.ticks % restockEvery) == 0 then
      queueRestock()
   end

   for _, vector in ipairs(M.VECTORS) do
      local option, affliction, rank = resolve(vector)
      if option then
         local command, item = curelist.command(option)
         if command then
            queue.push(vector, command, {
               priority = rank,
               tag      = affliction,
               confirm  = emunah.config.get("curing.confirmWait", 2.0),
               onSent   = function()
                  -- Start the fallback recovery timer. A confirmation trigger or the
                  -- GMCP removal will normally cut this short.
                  have.spend(vector)
               end,
               onTimeout = function()
                  log.debug("Cure for %s via %s went unconfirmed.", affliction, vector)
               end,
            })
            log.debug("Resolved %s -> %s (%s, p%s)", affliction, command, item or "-", tostring(rank))
         end
      end
   end

   queue.flush()
end

-- ---------------------------------------------------------------------------
-- control
-- ---------------------------------------------------------------------------

function M.start()
   M.enabled = true
   emunah.config.set("curing.enabled", true)
   M.reconcile()
   log.info("Curing <ansi_light_green>on<ansi_yellow>.")
   event.raise("curing.enabled")
end

function M.stop()
   M.enabled = false
   emunah.config.set("curing.enabled", false)
   -- Clear in-flight entries too: leaving them would block those vectors when curing is
   -- switched back on, which looks exactly like the system having hung.
   queue.reset()
   log.info("Curing <ansi_light_red>off<ansi_yellow>.")
   event.raise("curing.disabled")
end

function M.toggle()
   if M.enabled then M.stop() else M.start() end
   return M.enabled
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

-- The heartbeat.
event.register("emunah.tick", function()
   M.tick()
end, "curing.engine")

-- Server-confirmed removal is our most reliable cure confirmation: free the vector that
-- was waiting on it so the next cure can go out immediately rather than after the
-- fallback timer.
event.register("emunah.affliction.removed", function(_, name)
   name = tostring(name or ""):lower()
   M.remove(name)
   for _, vector in ipairs(queue.VECTORS) do
      local action = queue.awaiting(vector)
      if action and action.tag == name then
         queue.confirm(vector)
         have.recover(vector)
         break
      end
   end
end, "curing.engine")

event.register("emunah.affliction.added", function(_, name)
   M.add(name, "gmcp")
end, "curing.engine")

event.register("emunah.afflictions.list", function()
   M.reconcile()
end, "curing.engine")

-- Restock the moment we learn what we are carrying, or what the rift holds. On a reload
-- these are the first true facts we get, and both arrive well before the next prompt.
event.register("emunah.items.list", function(_, location)
   if location == "inv" then M.restockNow() end
end, "curing.engine")

event.register("emunah.rift.list", function() M.restockNow() end, "curing.engine")

event.register("sysDisconnectionEvent", function()
   M.clear()
   queue.reset()
   -- Inventory and rift counts are both re-listed on connect, and a death may have emptied
   -- the pack in between, so the restocking ledger from the last session means nothing.
   M.forgetStock()
end, "curing.engine")

-- Restore the previous on/off state, but never auto-enable on a fresh install.
M.enabled = emunah.config.get("curing.enabled", false) == true

return M

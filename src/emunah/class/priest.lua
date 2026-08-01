--- Priest.
---
--- Implements the interface in class/adapter.lua. The adapter auto-loads this file when
--- Char.Status.class (or the Devotion/Spirituality skillsets) identify you as a Priest, so
--- nothing else has to know the class exists.
---
--- COSTS, AS VERIFIED IN PLAY
--- --------------------------
--- The attack command is `smite`. It spends BALANCE and requires EQUILIBRIUM to be
--- present, without consuming it -- a distinction that stays invisible until something
--- else takes equilibrium, at which point every attack sent into that window is refused.
--- See docs/game/mechanics.md.
---
--- Kept as a setting rather than hardcoded, since a second attack is likely to differ:
---
---     emunah bash balance eq|bal|both

local M = {}

--- Skillsets that identify a Priest, for adapter.detect().
M.SKILLSETS = { "devotion", "spirituality" }

--- The charstat carrying this class's own resource. watch.lua reads it generically, so a
--- new class declares the name and needs no code there.
M.RESOURCE = "Devotion"

--- What the attack costs. Overridden by `emunah bash balance`.
---
--- BOTH, confirmed live. Smite announces "Balance used: 3.2s." so balance was obvious, but
--- after `perform hands` took equilibrium the prompt read "x-" (balance, no equilibrium) and
--- three smites in a row came back "You must regain equilibrium first." at 09:09:41.70,
--- :42.80 and :43.93. Requiring only balance meant every attack during an equilibrium
--- cooldown was thrown away -- and `perform hands` creates exactly that window, so the two
--- were fighting each other.
local function requirement()
   return emunah.config.get("bashing.balance", "both")
end

--- Send the attack at a specific target.
---
--- `target` is a REPLICA NUMBER, not a name -- see denizens.lua for why that distinction
--- is load-bearing. Passing "pixie" here would let Achaea pick which pixie, and its choice
--- shifts as they move and die.
function M.attack(target)
   if not target then return false end
   local command = emunah.config.get("bashing.attack", "smite")
   local needs = requirement()

   local sent = emunah.act.send(string.format("%s %s", command, target), {
      standing = true,
      bal      = (needs == "bal" or needs == "both"),
      eq       = (needs == "eq" or needs == "both"),
   })
   if not sent then return false end

   -- SENT IS NOT EXECUTED, AND THAT DISTINCTION IS THE WHOLE BUG.
   --
   -- Achaea processes our command some time after it arrives -- behind whatever else is
   -- already queued, and behind its own combat resolution. Until it does, Char.Vitals goes
   -- on reporting the balance we are about to spend as available, because it genuinely
   -- still is. Confirmed live with timestamps: smites went out at 00:17:22.40 and
   -- 00:17:23.06, both while the prompt truthfully read "ex-", and the second was rejected
   -- with "You must regain balance first." once the first finally resolved. Marking the
   -- balance spent locally (vitals.spend, below) cannot survive that on its own -- the very
   -- next Char.Vitals push overwrites it with the game's own still-accurate "you have
   -- balance".
   --
   -- So the guard cannot be a flag that GMCP is entitled to overwrite. It is a timer, armed
   -- pessimistically the moment the command leaves, and re-armed precisely when the game
   -- confirms execution with its exact cost ("Balance used: 3.2s." -- see below). One
   -- command in flight at a time is the actual game mechanic being modelled here.
   emunah.timers.start("attack.balance", M.inflightGuard())

   -- REQUIRING a resource and SPENDING it are different things, and smite is the case that
   -- separates them: at 12:39:14.49 it announced "Balance used: 2.9s." and the prompt read
   -- "e-" -- balance gone, equilibrium still there. So it needs equilibrium present to go
   -- out and does not consume it. Marking equilibrium spent here would suppress the next
   -- attack over a resource the game never took.
   local vitals = emunah.gmcp.vitals
   if vitals and (needs == "bal" or needs == "both") then vitals.spend("bal") end

   return true
end

--- Is an attack possible right now?
function M.canAttack()
   local vitals = emunah.gmcp.vitals
   if not vitals then return false end

   local needs = requirement()
   if not emunah.act.can({ standing = true }) then return false end

   -- The in-flight/cooldown timer is required alongside the GMCP flag, never instead of it:
   -- the flag alone is too slow to reflect a command we have sent but the game has not run
   -- yet (see M.attack), and the timer alone would ignore balance lost to anything other
   -- than our own attack.
   -- Equilibrium gets the same treatment as balance: the GMCP flag AND the cooldown the
   -- game announced. Penitence and `perform hands` both spend equilibrium and both announce
   -- their cost ("Equilibrium used: 1.25s."), so the timer is authoritative for the window
   -- where the flag has not caught up yet.
   local eqReady  = vitals.eq and emunah.timers.ready("cure.equilibrium")
   local balReady = vitals.bal and emunah.timers.ready("attack.balance")

   if needs == "eq" then return eqReady end
   if needs == "both" then return balReady and eqReady end
   return balReady
end

-- ---------------------------------------------------------------------------
-- Penitence
-- ---------------------------------------------------------------------------
--
--   PERFORM PENITENCE <target>
--   Cooldown: 1.00s of equilibrium (slightly more against denizens)
--   Resource: 300 devotion and 100 mana (devotion cost reduced against denizens)
--   Against denizens: the target takes 10% more damage from SPIRITUALITY SMITE.
--
-- Worth using only when the fight lasts long enough for 10% to repay what it cost. It is
-- not free in three separate currencies -- devotion, mana, and the equilibrium that SMITE
-- also needs -- so casting it on something that dies in two hits is a straight loss.
--
-- The decision is made from evidence rather than a guess: after the first smite lands,
-- bashing.killIn() knows how much of the target's health one attack actually removes, and
-- therefore roughly how many more are needed. Below PENITENCE_MIN_HITS it is not worth it.
-- A target whose health is not moving reports no estimate at all, and correctly gets no
-- penitence either -- 10% more of nothing is nothing.

--- Minimum estimated remaining attacks before penitence pays for itself.
M.PENITENCE_MIN_HITS = 5

--- Devotion floor, as a percentage. The exact cost against denizens is "reduced" from 300
--- by an unstated amount, and charstats reports devotion only as a percentage, so there is
--- no honest way to compute affordability -- this is a deliberately cautious floor rather
--- than a calculation. Running out of devotion mid-hunt costs far more than a few missed
--- amplifications.
M.PENITENCE_DEVOTION = 50

--- Mana floor, absolute. Costs 100; the margin leaves room for curing.
M.PENITENCE_MANA = 400

local function penitenceSetting(key, fallback)
   local value = emunah.config.get("bashing." .. key)
   if value == nil then return fallback end
   return tonumber(value) or fallback
end

--- Is penitence worth sending at this target right now?
--- @param remaining number|nil estimated attacks still needed, from bashing.killIn()
function M.shouldPenitence(remaining)
   if emunah.config.get("bashing.penitence", true) == false then return false end
   if type(remaining) ~= "number" then return false end
   if remaining < penitenceSetting("penitenceMinHits", M.PENITENCE_MIN_HITS) then
      return false
   end

   local vitals = emunah.gmcp.vitals
   if not vitals then return false end

   local devotion = vitals.stat("Devotion")
   if type(devotion) ~= "number"
      or devotion < penitenceSetting("penitenceDevotion", M.PENITENCE_DEVOTION) then
      return false
   end
   if vitals.mp < penitenceSetting("penitenceMana", M.PENITENCE_MANA) then return false end

   return true
end

--- Brand a denizen so it takes more damage from smite. Costs equilibrium, which smite also
--- needs -- so this deliberately spends a turn that would otherwise have been an attack.
function M.penitence(target)
   if not target then return false end
   if not emunah.act.send("perform penitence " .. target, { standing = true, eq = true }) then
      return false
   end
   -- Spend locally, exactly as the attack does. Char.Vitals cannot report the loss until
   -- the game has run the command, and two smites went out into that gap live -- both
   -- rejected with "You must regain equilibrium first." while the prompt read "x-". The
   -- "Equilibrium used:" trigger replaces this with the real figure the moment it arrives.
   --
   -- The local spend alone is not enough, for the reason set out at length in M.attack: a
   -- Char.Vitals push arriving before the game has run the command truthfully reports the
   -- equilibrium as still available and overwrites the flag. Live at 10:32:28.35, one tick
   -- after penitence went out and before "Equilibrium used: 1.25s." arrived, that is exactly
   -- what let a smite through -- rejected, and a wasted turn. So arm the same pessimistic
   -- in-flight guard the attack uses, covering send -> announcement rather than the whole
   -- cooldown; `perform hands` already does this on the same timer.
   local vitals = emunah.gmcp.vitals
   if vitals then vitals.spend("eq") end
   emunah.timers.start("cure.equilibrium", M.inflightGuard())
   return true
end

--- Priest has no generic shield-break, so this stays unimplemented rather than guessing.
--- The bashing loop treats `false` as "cannot handle it" and stops rather than flailing.
function M.handleShield(target)
   return false
end

--- Devotion, and anything else Achaea reports for the class, straight from charstats.
function M.stats()
   local vitals = emunah.gmcp.vitals
   return vitals and vitals.stats or {}
end

--- Current devotion, when the game reports it.
function M.devotion()
   local vitals = emunah.gmcp.vitals
   if not vitals then return nil end
   return vitals.stats.Devotion or vitals.stats.devotion
end

-- ---------------------------------------------------------------------------
-- balance: a game-confirmed cooldown, not the raw GMCP flag
-- ---------------------------------------------------------------------------
--
-- How long to refuse to attack after sending one, before the game has confirmed anything.
-- Covers only the send -> execute gap (see M.attack); the real figure replaces it the moment
-- Achaea announces the actual cost, so this has to be longer than a round trip, not longer
-- than a balance. Too short reintroduces the double-send; too long costs tempo.
--
-- "Longer than a round trip" is measurable rather than guessable: Mudlet's
-- getNetworkLatency() reports exactly the send -> response time this is covering. A fixed
-- guess is wrong in both directions -- on a fast local connection 2s throws away most of a
-- balance, and on a bad one it is not enough. So size it from the real figure, with slack
-- for jitter, and clamp it so a wild reading cannot either wedge the loop or disable the
-- guard entirely.
M.GUARD_MIN, M.GUARD_MAX = 0.5, 3.0
M.GUARD_SLACK = 2.5

function M.inflightGuard()
   local latency
   if type(getNetworkLatency) == "function" then
      local ok, value = pcall(getNetworkLatency)
      if ok then latency = tonumber(value) end
   end
   if not latency or latency <= 0 then return M.GUARD_MIN end
   local guard = latency * M.GUARD_SLACK
   if guard < M.GUARD_MIN then return M.GUARD_MIN end
   if guard > M.GUARD_MAX then return M.GUARD_MAX end
   return guard
end

-- Achaea states the exact recovery time every single time it takes balance, so past this
-- point there is nothing to estimate. This replaces the pessimistic guard above with the
-- real figure, timed from the moment of execution rather than the moment of sending.
local function installTriggers()
   emunah._persist = emunah._persist or {}
   for _, id in ipairs(emunah._persist.priestTriggers or {}) do killTrigger(id) end
   emunah._persist.priestTriggers = {}

   local function keep(id)
      if id then table.insert(emunah._persist.priestTriggers, id) end
   end

   keep(tempRegexTrigger([[^Balance used: ([\d.]+)s\.$]], function()
      local seconds = tonumber(matches[2])
      if seconds then emunah.timers.start("attack.balance", seconds) end
   end))

   -- A rejected command never executed, so it never cost balance -- holding the guard for
   -- its full duration would stall the retry for no reason. "You must be standing first."
   -- is the common one while bashing: prone gates the attack anyway, so clearing here just
   -- means the first tick after standing can act immediately.
   keep(tempRegexTrigger([[^You must be standing first\.$]], function()
      emunah.timers.stop("attack.balance")
   end))

   -- SOMEONE ELSE BRANDED IT.
   --
   -- Verbatim, from another Priest hunting in the same room:
   --
   --     Anzerloi calls down holy fire upon a young rat, condemning him to serve penance
   --     in a righteous blaze of light.
   --
   -- The brand is on the creature, not on the caster, so a second one achieves nothing.
   -- Re-branding is cheap rather than free -- an already-branded target refuses without
   -- taking balance or equilibrium -- but it still costs a turn that could have been an
   -- attack, and it counts against the rate limiter.
   --
   -- Deliberately NOT anchored with `$`: Achaea wraps this sentence at the client's width,
   -- so the tail lands on the next line and an anchored pattern would never fire. Matching
   -- through "condemning" is enough to be unambiguous.
   --
   -- The message names the creature by description, so it has to be resolved back to a
   -- replica number against the room. An ambiguous answer is left alone on purpose: with
   -- two young rats present the description identifies neither, and the costs are not
   -- symmetric. Marking the wrong one loses a real amplification on a fight that wanted it;
   -- marking neither costs at worst one refused command that spends nothing.
   keep(tempRegexTrigger(
      [[^(\w+) calls down holy fire upon ([^,]+), condemning ]],
      function()
         local caster, description = matches[2], matches[3]
         if not (caster and description) then return end

         local denizens = emunah.denizens
         local bashing  = emunah.bashing
         if not (denizens and bashing) then return end

         local found = denizens.findByName(description)
         if #found ~= 1 then
            emunah.log.debug("%s branded %q -- %d matches in the room, so not recorded.",
               caster, description, #found)
            return
         end

         bashing.markPenitent(found[1].id)
         emunah.log.debug("%s branded %s (%s) -- not re-branding it.",
            caster, description, found[1].id)
      end))
end
installTriggers()

return M

--- Priest.
---
--- Implements the interface in class/adapter.lua. The adapter auto-loads this file when
--- Char.Status.class (or the Devotion/Spirituality skillsets) identify you as a Priest, so
--- nothing else has to know the class exists.
---
--- COSTS, AS VERIFIED IN PLAY
--- --------------------------
--- The attack command is configurable. Two have been confirmed so far, and both need BOTH
--- balance and equilibrium PRESENT to go out -- but each only ever CONSUMES one of the two,
--- and it is not the same one:
---
---   smite       (old default) spends BALANCE. "Balance used: 3.2s." announced it while the
---               prompt read "e-" -- equilibrium still in hand. See docs/game/mechanics.md.
---   angel sear  (shipped default) spends EQUILIBRIUM instead. HELP SEAR states its cooldown
---               as "2.50 seconds of equilibrium"; the balance requirement on top of that was
---               confirmed by the user rather than guessed at, 2026-08-04 -- the mirror image
---               of smite is not something to assume just because it rhymes. Against a
---               denizen it also does not touch Angel power at all (HELP SEAR again), which
---               is why nothing here gates on that resource: bashing never targets anything
---               else.
---
--- Which one is required lives in `bashing.balance`; which one is actually spent lives in
--- `bashing.consumes` -- see requirement() and consumption() below, and the DEFAULTS comment
--- in core/config.lua for why switching attacks does not get a schema migration.
---
---     emunah bash attack "angel sear"
---     emunah bash balance eq|bal|both
---     emunah bash consumes eq|bal

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

--- Which single resource the attack actually CONSUMES, as opposed to merely requiring --
--- "bal" | "eq". Both confirmed attacks need both present (requirement() above) but only
--- ever take one; the other is left for whatever else needs it (penitence, `perform hands`,
--- both of which want equilibrium). Defaults to "eq" for the shipped attack, Angel Sear; an
--- unrecognised value falls back the same way rather than silently guarding nothing.
local function consumption()
   local value = emunah.config.get("bashing.consumes", "eq")
   if value ~= "bal" and value ~= "eq" then return "eq" end
   return value
end

--- Send the attack at a specific target.
---
--- `target` is a REPLICA NUMBER, not a name -- see denizens.lua for why that distinction
--- is load-bearing. Passing "pixie" here would let Achaea pick which pixie, and its choice
--- shifts as they move and die.
function M.attack(target)
   if not target then return false end
   local command = emunah.config.get("bashing.attack", "angel sear")
   local needs = requirement()
   local consumes = consumption()

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
   -- on reporting the resource we are about to spend as available, because it genuinely
   -- still is. Confirmed live with timestamps: smites went out at 00:17:22.40 and
   -- 00:17:23.06, both while the prompt truthfully read "ex-", and the second was rejected
   -- with "You must regain balance first." once the first finally resolved. Marking the
   -- resource spent locally (vitals.spend, below) cannot survive that on its own -- the very
   -- next Char.Vitals push overwrites it with the game's own still-accurate "you have it".
   --
   -- So the guard cannot be a flag that GMCP is entitled to overwrite. It is a timer, armed
   -- pessimistically the moment the command leaves, and re-armed precisely when the game
   -- confirms execution with its exact cost ("Balance used: 3.2s." / "Equilibrium used:
   -- 2.50s." -- see below and the global trigger in curing/detect/patterns.lua). One command
   -- in flight at a time is the actual game mechanic being modelled here.
   --
   -- WHICH TIMER gets the guard has to follow what this attack actually spends, not just
   -- default to balance: smite guards attack.balance, but an attack that spends equilibrium
   -- instead has to guard cure.equilibrium -- the same timer penitence and `perform hands`
   -- arm -- or canAttack()'s eq check never sees the in-flight window at all and the
   -- double-send comes right back, just on the other resource.
   if consumes == "bal" then
      emunah.timers.start("attack.balance", M.inflightGuard())
   else
      emunah.timers.start("cure.equilibrium", M.inflightGuard())
   end

   -- REQUIRING a resource and SPENDING it are different things, and smite was the case that
   -- first separated them: at 12:39:14.49 it announced "Balance used: 2.9s." and the prompt
   -- read "e-" -- balance gone, equilibrium still there, despite equilibrium being required
   -- to send it at all. Marking the un-consumed resource spent here would suppress the next
   -- attack over something the game never actually took.
   local vitals = emunah.gmcp.vitals
   if vitals then vitals.spend(consumes) end

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
   -- game announced. Penitence, `perform hands`, and now the attack itself (when configured
   -- to consume equilibrium -- see M.attack's consumption()) all spend equilibrium and all
   -- announce their cost ("Equilibrium used: 1.25s."), so the timer is authoritative for the
   -- window where the flag has not caught up yet.
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

-- ---------------------------------------------------------------------------
-- Rite of Desolation (Battlerage)
-- ---------------------------------------------------------------------------
--
--   PERFORM RITE OF DESOLATION ON <target>
--   Works on/against: Denizens
--   Cooldown: 23.00 seconds
--   Resource: 36 rage
--
-- HELP DESOLATION, pasted by the user 2026-08-04. Unlike penitence, the cooldown is not
-- stated as balance or equilibrium -- just a flat 23 seconds -- so this is gated on its own
-- timer rather than attack.balance or cure.equilibrium. It IS confirmed by the game, though,
-- just not with a "X used: N.NNs." cost line -- see installTriggers() below for the two
-- lines Achaea sends, unprompted, the moment the cooldown actually elapses.
--
-- Rage is read the same generic way as devotion, confirmed live via `lua
-- display(gmcp.Char.Vitals)` at 06:38:36.52 (2026-08-04): charstats carried
-- "Rage: 0" alongside "Angelpower: 1500" and "Devotion: 98%", so `vitals.stat("Rage")` is
-- the exact key Achaea sends -- not "Battlerage", which is the skillset's name rather than
-- the stat's.
--
-- Sequenced the same way as penitence -- checked, and sent, before the attack itself -- but
-- for a different reason: penitence competes with the attack for the SAME equilibrium
-- smite/sear need, so it only makes sense when the fight can repay the lost swing.
-- Desolation costs neither balance nor equilibrium at all, so there is nothing to repay; it
-- only needs to wait its own 23s and find 36 rage, and firing it a beat before the attack
-- rather than a beat after costs nothing extra.

--- Rage needed per cast, and the ability's own fixed cooldown.
M.DESOLATION_RAGE     = 36
M.DESOLATION_COOLDOWN = 23.00

--- Current battlerage, when the game reports it.
function M.rage()
   local vitals = emunah.gmcp.vitals
   if not vitals then return nil end
   return vitals.stat("Rage")
end

--- Is Desolation worth sending at this target right now? Bashing-only by design -- the
--- caller is expected to have already checked denizens.isDenizen(target), the same guard
--- penitence uses, since HELP DESOLATION states it works only against denizens.
function M.shouldDesolation(target)
   if not target then return false end
   if emunah.config.get("bashing.desolation", true) == false then return false end
   if not emunah.timers.ready("bashing.desolation") then return false end

   local rage = M.rage()
   if type(rage) ~= "number" or rage < M.DESOLATION_RAGE then return false end

   return true
end

--- Send Rite of Desolation at a denizen target.
function M.desolation(target)
   if not target then return false end
   if not emunah.act.send("perform rite of desolation on " .. target, { standing = true }) then
      return false
   end
   -- Pessimistic guess at the HELP-stated 23.00s, same shape as inflightGuard() elsewhere:
   -- armed on send, then cleared early (or confirmed, if the real figure differs) the moment
   -- Achaea's own "You can use Desolation again." / "...you lack the necessary Rage." lines
   -- arrive -- see installTriggers(). Clearing early can only help; shouldDesolation() still
   -- requires the rage floor separately before anything is actually sent.
   emunah.timers.start("bashing.desolation", M.DESOLATION_COOLDOWN)
   return true
end

-- ---------------------------------------------------------------------------
-- Zeal verses (PvP affliction offense)
-- ---------------------------------------------------------------------------
--
--   RECITE GUILT <target>          1.60s of PRAYER balance (Zeal)
--   RECITE CONDEMNATION <target>   1.60s of PRAYER balance (Zeal). Works on/against:
--                                  Adventurers. HELP CONDEMNATION states directly: "striking
--                                  them down with the justice affliction."
--
-- Requires ANOINT ASH first (a one-time, non-repeatable prerequisite -- travel to Anost in
-- the Ruins of the Dawnspear). Refused otherwise with an unmistakable line, confirmed live
-- 2026-08-05: "You have not anointed yourself with holy ash; see AB ZEAL ANOINT for the path
-- you must walk." That is not a balance rejection -- nothing was spent -- so the trigger
-- below clears the guard rather than waiting it out.
--
-- PRAYER BALANCE IS ITS OWN RESOURCE, separate from both attack balance and equilibrium.
-- Confirmed live: `recite guilt` and `recite condemnation` both went out and were accepted
-- with Angel Sear's equilibrium still on cooldown from an earlier attack, no rejection either
-- time. A Priest with Zeal can attack AND recite on the same tick; neither competes with the
-- other for anything.
--
-- NOT a "Balance used: N.NNs." announcement, unlike smite/Angel Sear/penitence. Confirmed
-- live: neither cast produced that line. The only confirmation is "You may speak another
-- holy verse." -- the same shape as the herb/elixir readiness lines ("You may eat another
-- plant or mineral.") rather than the attack-cost lines. HELP states the cost as 1.60s; that
-- is the pessimistic guess armed on send, replaced the instant the real line arrives (see
-- installTriggers() below) -- the same shape as inflightGuard() elsewhere in this file.
--
-- Guilt's own HELP text never names the affliction it causes. Confirmed instead by two
-- independent pieces of evidence from the same live cast, 2026-08-05: the target immediately
-- ate a lobelia seed, and afflist.lua already has a `guilt` entry whose one and only cure is
-- `{ vector = "herb", item = "lobelia" }` -- added earlier from an unrelated cross-check, so
-- this is not circular. Condemnation's target (`justice`) is not inferred at all; HELP states
-- it outright, and afflist.lua's `justice` entry (cured by bellwort) matches what the second
-- test target ate.
--
-- ONSET IS NOT DETECTED. Neither cast produced a message (to the caster) confirming the
-- affliction actually landed rather than being resisted or shielded -- only that the verse
-- was successfully SPOKEN. curing/detect/opponent.lua has no entry for guilt or justice
-- landing yet; opponent_patterns.lua has only the one CURE message this test happened to
-- show (guilt's). Do not add a landing pattern without seeing the real onset text first.

--- Pessimistic guess at prayer balance's cost, per HELP GUILT / HELP CONDEMNATION. Replaced
--- by the real confirmation the instant it arrives -- see installTriggers().
M.RECITE_BALANCE_GUESS = 1.60

--- Verses confirmed live to cause an affliction on a player target, 2026-08-05. Keyed by the
--- word RECITE takes; value is the ability name have.skill() checks against Char.Skills, so
--- an unlearned verse (everything past Unflinching, at last check) is refused before it is
--- ever sent rather than bouncing off the game.
M.VERSES = {
   guilt        = "guilt",
   condemnation = "condemnation",
}

--- Is this verse known, and is prayer balance free?
function M.canRecite(verse)
   if not (verse and M.VERSES[verse]) then return false end
   if not emunah.have.skill(M.VERSES[verse]) then return false end
   if not emunah.act.can({ standing = true }) then return false end
   return emunah.timers.ready("pvp.prayer")
end

--- Recite a verse at a player target.
---
--- `target` is a NAME, not a replica number -- HELP CONDEMNATION states "Works on/against:
--- Adventurers", so unlike bashing's M.attack() there is no denizen case to support, and
--- pvp.lua's own targeting is already name-based (see pvp.lua's M.setTarget).
function M.recite(verse, target)
   if not (target and M.VERSES[verse]) then return false end
   if not emunah.act.send("recite " .. verse .. " " .. target, { standing = true }) then
      return false
   end
   emunah.timers.start("pvp.prayer", M.RECITE_BALANCE_GUESS)
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

   -- DESOLATION'S COOLDOWN IS ANNOUNCED, NOT JUST STATED IN HELP. Confirmed live,
   -- 2026-08-04: Achaea says one of two things, unprompted, the moment the ability's own
   -- 23s cooldown actually elapses --
   --
   --   "You can use Desolation again."
   --   "Your Desolation ability could be used again but you lack the necessary Rage."
   --
   -- -- the same shape as "Balance used: N.NNs." replacing a guessed recovery with the real
   -- one, except here there is no duration to parse: the event itself is the confirmation.
   -- Both lines mean the cooldown this guards is over; the second just adds that rage, not
   -- cooldown, is what is actually holding it back, and shouldDesolation()'s own
   -- vitals.stat("Rage") check already covers that independently. So both clear the same
   -- guard rather than needing two different states -- and clearing early (or catching a
   -- cooldown shorter than the flat 23.00s HELP states) can only help, never double-send:
   -- shouldDesolation() still requires the rage floor separately before anything is sent.
   -- The real prayer-balance confirmation, replacing the pessimistic RECITE_BALANCE_GUESS
   -- the moment it arrives -- same shape as "Balance used: N.NNs." above, except this is a
   -- flat "ready" line rather than one carrying its own duration. Confirmed live 2026-08-05,
   -- verbatim, after both `recite guilt` and `recite condemnation`.
   keep(tempRegexTrigger([[^You may speak another holy verse\.$]], function()
      emunah.timers.stop("pvp.prayer")
   end))

   -- ANOINT ASH IS A PREREQUISITE, NOT A BALANCE COST. Confirmed live 2026-08-05: this refusal
   -- fired for both `recite guilt` and `recite condemnation` before the one-time Anoint ritual
   -- was done, and neither cast spent anything -- no "You may speak another holy verse."
   -- followed either time. Clear the guard rather than waiting out a cost that was never
   -- taken, and say so once rather than let every recite attempt fail silently forever.
   keep(tempRegexTrigger(
      [[^You have not anointed yourself with holy ash; see AB ZEAL ANOINT]],
      function()
         emunah.timers.stop("pvp.prayer")
         emunah.log.warn("Zeal verses refused -- not anointed yet (AB ZEAL ANOINT).")
      end))

   keep(tempRegexTrigger([[^You can use Desolation again\.$]], function()
      emunah.timers.stop("bashing.desolation")
   end))
   keep(tempRegexTrigger(
      [[^Your Desolation ability could be used again but you lack the necessary Rage\.$]],
      function()
         emunah.timers.stop("bashing.desolation")
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

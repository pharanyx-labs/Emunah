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
---               prompt read "e-" -- equilibrium still in hand. See docs/game/priest-abilities.md.
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

--- Send the hunt's attack at a target. PvP never comes here: its moves are its own
--- (class/priest_pvp.lua).
local function sendAttack(command, target, needs, consumes)
   if not target then return false end
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

--- Is an attack needing `needs` ("eq" | "bal" | "both") possible right now?
local function attackReady(needs)
   local vitals = emunah.gmcp.vitals
   if not vitals then return false end

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

--- The hunt's attack, at a denizen.
---
--- `target` is a REPLICA NUMBER, not a name -- see denizens.lua for why that distinction
--- is load-bearing. Passing "pixie" here would let Achaea pick which pixie, and its choice
--- shifts as they move and die.
function M.attack(target)
   return sendAttack(emunah.config.get("bashing.attack", "angel sear"), target,
      requirement(), consumption())
end

function M.canAttack()
   return attackReady(requirement())
end

--- HELP CHASTEN's two pools, and the capstone each gives a target that already has all of
--- it (Anzerloi, 2026-10-23 14:39:26: "Addiction for body, impat for mind"). `chasten body`
--- or `chasten mind` gives one of the pool the target does not have -- "smart afflicting"
--- (14:36:51) -- and the capstone once there is none.
M.CHASTEN_POOLS = {
   body = { "paralysis", "healthleech", "clumsiness", "nausea", "asthma", capstone = "addiction" },
   mind = { "epilepsy", "dizziness", "confusion", "recklessness", capstone = "impatience" },
}

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

--- What a verse needs: both balances, though it spends neither (2026-10-23, every recite
--- sent with one down was refused; docs/game/priest-abilities.md).
M.RECITE_NEEDS = { bal = true, eq = true, standing = true }

--- Is this verse known, and is prayer balance free?
function M.canRecite(verse)
   if not (verse and M.VERSES[verse]) then return false end
   if not emunah.have.skill(M.VERSES[verse]) then return false end
   if M.ONCE_PER_PRAYER[verse] and M.prayerSpent[verse] then return false end
   if not M.prayerAllows(verse) then return false end
   if not emunah.act.can(M.RECITE_NEEDS) then return false end
   return emunah.timers.ready("pvp.prayer")
end

--- Recite a verse at a player target.
---
--- `target` is a NAME, not a replica number -- HELP CONDEMNATION states "Works on/against:
--- Adventurers", so unlike bashing's M.attack() there is no denizen case to support, and
--- pvp.lua's own targeting is already name-based (see pvp.lua's M.setTarget).
function M.recite(verse, target)
   if not (target and M.VERSES[verse]) then return false end
   if not emunah.act.send("recite " .. verse .. " " .. target, M.RECITE_NEEDS) then
      return false
   end
   emunah.timers.start("pvp.prayer", M.RECITE_BALANCE_GUESS)
   if M.ONCE_PER_PRAYER[verse] then M.prayerSpent[verse] = true end
   return true
end

-- ---------------------------------------------------------------------------
-- the prayer: length, conviction, and verses spent until it ends
-- ---------------------------------------------------------------------------
--
-- AB PRAYER: verses recited close together chain into a prayer; "certain verses can only be
-- utilised once per prayer, and others may require a prayer of a certain length". The game
-- reports the chain as `prayer_length` and `conviction` in charstats (Char.Vitals,
-- 2026-08-04), parsed to numbers by gmcp/vitals.lua.
--
-- Tracking the once-per-prayer verses is Anzerloi's method, in party chat 2026-10-15
-- 12:49:38-12:49:55: mark one unusable when you recite it; free them all "on a successful
-- rebuke, any of them, or upon prayer length resetting to 0 for any other reason".
--
-- Marked ON SEND, so the next tick cannot recite it again before the game has answered.
-- Freed on the TRANSITION to 0, not on reading 0: the prompt between sending a prayer's
-- first verse and the game executing it still says 0, and clearing there would forget the
-- verse just sent.
--
-- VERSES (docs/game/help/verses.txt, 2026-10-15) gives each limited verse's needs: a
-- conviction percentage and a prayer length, and all seven are once per prayer. Guilt and
-- Condemnation are not in it, so neither needs nor is limited by anything here.
--
-- Heresy's rebuke prints "You decree that <name> will pay for her crimes against Creation."
-- whether or not inquisition lands (2026-10-24 14:09:36, 14:10:12): it ends the prayer, and
-- says nothing of what it gave. The other rebukes' lines, and whether reciting one of these
-- spends conviction, are not yet known.

--- verse -> { conviction = %, length = verses }, from VERSES.
M.VERSE_NEEDS = {
   glory       = { conviction = 0,  length = 2 },
   light       = { conviction = 0,  length = 0 },
   purge       = { conviction = 5,  length = 0 },
   reflection  = { conviction = 5,  length = 2 },
   revelations = { conviction = 10, length = 3 },
   salvation   = { conviction = 10, length = 0 },
   wrath       = { conviction = 20, length = 1 },
}

--- verse -> true, for verses limited to once per prayer. VERSES says Yes for all seven.
M.ONCE_PER_PRAYER = {}
for verse in pairs(M.VERSE_NEEDS) do M.ONCE_PER_PRAYER[verse] = true end

--- rebuke sin -> the prayer length it needs, and what it gives (AB ZEAL REBUKE). Heresy's
--- inquisition only lands on a target with both guilt and spiritburn. A rebuke ends the
--- prayer, so the drop to 0 that follows frees the once-per-prayer verses on its own.
M.REBUKES = {
   darkness = { length = 2, gives = "paranoia" },
   chaos    = { length = 3, gives = "hallucinations" },
   evil     = { length = 3, gives = "masochism" },
   heresy   = { length = 4, gives = "inquisition" },
}

--- Does the current prayer meet this verse's (or rebuke's) needs? True for anything with
--- none listed.
---
--- A REBUKE COUNTS THE VERSE IT RIDES ON. Anzerloi, 2026-10-15 13:24:48: "if your prayer
--- length is 1, you can, for instance, recite guilt rebuke darkness. The guilt before it IS
--- the prayer length 2 achieved, and then it is immediately reset by the rebuke." So a
--- rebuke needs one less than its stated length already in the prayer. A verse's own
--- length (VERSES) is what the prayer must already be, as in his "if prayer length >= 3 ...
--- you can recite revelations".
function M.prayerAllows(verse)
   local prayer = M.prayer()
   local rebuke = M.REBUKES[verse]
   if rebuke then return prayer.length + 1 >= rebuke.length end
   local needs = M.VERSE_NEEDS[verse]
   if not needs then return true end
   return prayer.length >= needs.length and prayer.conviction >= needs.conviction
end

--- verse -> true, once-per-prayer verses recited in the current prayer.
M.prayerSpent = {}

--- The current prayer, from charstats. Absent stats read as 0: no prayer.
function M.prayer()
   local vitals = emunah.gmcp.vitals
   local stat = vitals and vitals.stat
   return {
      length     = tonumber(stat and stat("prayer_length", 0)) or 0,
      conviction = tonumber(stat and stat("conviction", 0)) or 0,
   }
end

--- The prayer is over: every once-per-prayer verse is usable again. The offence's route
--- (class/priest_pvp.lua) hears it to choose its next prayer.
function M.prayerReset()
   M.prayerSpent = {}
   emunah.event.raise("priest.prayerEnded")
end

local lastPrayerLength = 0
-- The adapter can load this file again without a full reload (a class re-detected), so the
-- previous generation's handler goes first.
emunah.event.kill("priest")
emunah.event.register("emunah.vitals", function()
   local length = M.prayer().length
   if length == 0 and lastPrayerLength > 0 then M.prayerReset() end
   lastPrayerLength = length
end, "priest")

-- ---------------------------------------------------------------------------
-- sapping: how much mana a sap takes, from what the target carries
-- ---------------------------------------------------------------------------
--
-- Absolve kills when the target's mana is below 50% as it lands; exactly 50 fails. A sap
-- is what drives it there, and its size depends on the target's afflictions. These figures
-- are Anzerloi's, in party chat 2026-10-15 12:30:55-12:39:26 -- an informant, not HELP; see
-- docs/game/priest-abilities.md (Priest: absolve). Each is a share of the target's MAXIMUM
-- mana, added together:
--
--   guilt, spiritburn, tenderskin, burning   3.5 each
--   each level of a limb break               3
--   each mental affliction (focus cures it)  2
--   prone                                    2
--   any other affliction                     1
--
-- and inquisition multiplies an ANGEL sap, not `recite wrath`. Anzerloi's "half again" is
-- measured as about double: the user's, on him uncured, 2026-10-24 -- the lobelia trail
-- alone took 11.05% (14:31:23-27; his figures give 10.5), and the trail with justice and
-- inquisition took 24.4% or more (14:10:25-54; 12.5 before the multiplier). Wrath on the
-- trail took 11.2% (14:23:10-14), his 11.5 with inquisition unmultiplied.
--
-- Whether a sap does anything with none of these present is not stated, so `base` is a
-- parameter defaulting to 0 rather than a figure. NOTHING SENDS A SAP YET: the syntax,
-- cost and replies of ANGEL SAP, RECITE WRATH and ABSOLVE are not captured. This is the
-- calculation the offence will decide with once they are.

M.ABSOLVE_BELOW = 50

M.SAP = {
   heavy  = 3.5,
   level  = 3,
   mental = 2,
   prone  = 2,
   other  = 1,
   inquisition = 2.0,
}

M.SAP_HEAVY = { guilt = true, spiritburn = true, tenderskin = true, burning = true, ablaze = true }

-- Tier of each break name. Arms and legs go broken, damaged, mangled; head and torso have
-- no "broken" and go damaged, mangled (the same informant, 2026-08-05 -- see Limb breaks in
-- priest-abilities.md). `crippled`/`mutilated` are left out: whether they are the same scale
-- is unresolved, so they count as ordinary afflictions.
local LIMB_TIERS = { broken = 1, damaged = 2, mangled = 3 }
local CORE_TIERS = { damaged = 1, mangled = 2 }
local CORE = { head = true, torso = true }

local function breakTier(name)
   for prefix in pairs(LIMB_TIERS) do
      if name:sub(1, #prefix) == prefix then
         local limb = name:sub(#prefix + 1)
         if CORE[limb] then
            if CORE_TIERS[prefix] then return limb, CORE_TIERS[prefix] end
            return nil
         end
         if limb:find("arm$") or limb:find("leg$") then return limb, LIMB_TIERS[prefix] end
      end
   end
   return nil
end

--- How much of the target's maximum mana one sap takes, as a percentage.
---
--- A set may give each affliction a CHANCE (name -> 0..1) in place of true, and each then
--- counts for that share of its value: "Each of these relative to that aff's probability"
--- (Anzerloi, 2026-10-24 15:21:30). Inquisition's multiplier scales the same way.
---
--- @param afflictions table a list of names, or a set (name -> true or a chance)
--- @param opts table|nil { via = "angel"|"wrath" (default angel), base = number }
--- @return number percent
--- @return table breakdown { heavy, levels, mental, prone, other, inquisition }
function M.sapPercent(afflictions, opts)
   opts = opts or {}
   local afflist = emunah.curing.afflist
   local names, weight = {}, {}
   for key, value in pairs(afflictions or {}) do
      local name = type(key) == "number" and value or key
      if value and type(name) == "string" then
         name = name:lower()
         local chance = type(value) == "number" and type(key) == "string" and value or 1
         if chance > 0 then
            names[#names + 1] = name
            weight[name] = math.min(chance, 1)
         end
      end
   end

   local tally = { heavy = 0, levels = 0, mental = 0, prone = 0, other = 0, inquisition = false }
   local limbs, inquisition = {}, 0
   for _, name in ipairs(names) do
      local limb, tier = breakTier(name)
      local w = weight[name]
      if M.SAP_HEAVY[name] then
         tally.heavy = tally.heavy + w
      elseif limb then
         -- A higher tier sits on top of the lower ones, so a limb is worth its worst tier
         -- once, however many of its tiers are listed.
         local worth = tier * w
         if worth > (limbs[limb] or 0) then limbs[limb] = worth end
      elseif name == "prone" then
         tally.prone = math.max(tally.prone, w)
      elseif #afflist.curesVia(name, "focus") > 0 then
         tally.mental = tally.mental + w
      else
         -- Inquisition too: it is an affliction like any other here, and its multiplier
         -- below is separate.
         tally.other = tally.other + w
      end
      if name == "inquisition" then
         tally.inquisition = true
         inquisition = w
      end
   end
   for _, worth in pairs(limbs) do tally.levels = tally.levels + worth end

   local percent = (tonumber(opts.base) or 0)
      + tally.heavy  * M.SAP.heavy
      + tally.levels * M.SAP.level
      + tally.mental * M.SAP.mental
      + tally.prone  * M.SAP.prone
      + tally.other  * M.SAP.other
   if tally.inquisition and (opts.via or "angel") == "angel" then
      percent = percent * (1 + (M.SAP.inquisition - 1) * inquisition)
   end
   return percent, tally
end

--- The target's mana, as a percentage of maximum, after one sap. Never below 0.
function M.sapAfter(manaPercent, afflictions, opts)
   local after = (tonumber(manaPercent) or 100) - M.sapPercent(afflictions, opts)
   return after > 0 and after or 0
end

-- ---------------------------------------------------------------------------
-- contemplate: the target's real mana
-- ---------------------------------------------------------------------------
--
-- Captured 2026-10-15 against Anzerloi, verbatim:
--
--   13:31:27  contemplate Anzerloi
--             Anzerloi's mana stands at 5337/5405 [98%].
--             Equilibrium used: 1.00s.
--   13:31:45  angel sap Anzerloi
--             Your guardian angel casts a piercing glance at Anzerloi.
--             Equilibrium used: 2.75s.
--
-- The sap reports no figure to the caster, so the only measure of what it took is the next
-- contemplate. A sap therefore marks the reading it follows as stale rather than guessing
-- a new number. Both are read whoever sent them, by hand or not; nothing sends either yet.

--- name (lower) -> { current, max, percent, at, sappedAt }
M.targetMana = {}

--- The last contemplate reading for a target, or nil. `stale` when a sap has landed since.
function M.mana(name)
   local reading = M.targetMana[tostring(name or ""):lower()]
   if not reading then return nil end
   reading.stale = reading.sappedAt ~= nil and reading.sappedAt >= reading.at
   return reading
end

-- ---------------------------------------------------------------------------
-- limb damage: what our own blows report
-- ---------------------------------------------------------------------------
--
-- A mace blow on a limb says how much it dealt. Seen from the target's end, Anzerloi on
-- Maelgor, 2026-10-13 (docs/game/pvp-locks.md, Anzerloi's route):
--
--   As Anzerloi's blow crunches into you, you perceive that he has dealt 16.6% damage to
--   your right leg.
--
-- and from ours, the one capture a rebound gave (2026-10-15 13:58:03):
--
--   As your blow lands with a crunch, you perceive that you have dealt 13.9% damage to
--   yourself's head.
--
-- So the caster's line names the target and the limb. It is summed per limb here and read
-- by the offence to spread its blows across the legs. A blow the game did not report
-- (missed, parried, or a break with no figure) adds nothing. When the target's own healing
-- resets a limb is not known, so a total only clears with a new fight or target.

--- name (lower) -> limb ("left leg", "head", ...) -> percent dealt so far
M.targetLimbs = {}

--- The damage our blows have reported on each of a target's limbs, as a table (empty when
--- none).
function M.limbs(name)
   return M.targetLimbs[tostring(name or ""):lower()] or {}
end

--- Would absolve kill at this mana? Strictly below the threshold.
function M.absolveKills(manaPercent)
   manaPercent = tonumber(manaPercent)
   return manaPercent ~= nil and manaPercent < M.ABSOLVE_BELOW
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
      if seconds then
         emunah.timers.start("attack.balance", seconds)
         emunah.timers.confirm("attack.balance")
      end
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

   -- CONTEMPLATE and ANGEL SAP: see M.targetMana for the captures.
   keep(tempRegexTrigger([[^(\w+)'s mana stands at (\d+)/(\d+) \[(\d+)%\]\.$]], function()
      local name = matches[2]:lower()
      M.targetMana[name] = {
         current = tonumber(matches[3]),
         max     = tonumber(matches[4]),
         percent = tonumber(matches[5]),
         at      = emunah.util.now(),
      }
      emunah.event.raise("priest.contemplated", name, M.targetMana[name])
   end))
   keep(tempRegexTrigger([[^Your guardian angel casts a piercing glance at (\w+)\.$]], function()
      local name = matches[2]:lower()
      local reading = M.targetMana[name]
      if reading then reading.sappedAt = emunah.util.now() end
      emunah.event.raise("priest.sapped", name)
   end))

   -- CHASTEN SAYS WHAT LANDED. Captured 2026-10-15 13:58:03, `smite anzerloi head chasten
   -- asthma` (the smite rebounded; the chasten still landed):
   --
   --   You direct a dark bolt of energy through your mace towards Anzerloi. The curse of
   --   asthma is brought down on to your victim.
   --
   -- The game naming the affliction it gave is a statement, not an inference from the move,
   -- so it goes to the opponent tracker the way a symptom line does. The name is in the
   -- first sentence and the affliction in the second; unanchored, so the line wrapping
   -- between them does not matter. A multi-word affliction would not match (\w+) and is
   -- left untracked rather than guessed.
   --
   -- THE CAPSTONE NAMES A WHOLE POOL. Chastening a pool the target already has all of gives
   -- its capstone instead: addiction for body, impatience for mind (Anzerloi, 2026-10-23
   -- 14:39:08-14:40:37: "If you just chastened addiction, target must have had all of the
   -- body chasten affs at the point of afflicting"). So the capstone landing confirms the
   -- pool with it.
   local chastened
   keep(tempRegexTrigger([[dark bolt of energy through your mace towards (\w+)\.]], function()
      chastened = matches[2]:lower()
   end))
   keep(tempRegexTrigger([[The curse of (\w+) is brought]], function()
      local opponent = emunah.curing.detect.opponent
      local given = matches[2]:lower()
      if chastened and opponent then
         opponent.assert(chastened, given)
         for _, pool in pairs(M.CHASTEN_POOLS) do
            if pool.capstone == given then
               for _, aff in ipairs(pool) do opponent.assert(chastened, aff) end
            end
         end
      end
      chastened = nil
   end))

   -- LIMB DAMAGE: see M.targetLimbs. Unanchored at the start, for the same reason as the
   -- chasten line; a rebound names "yourself", which is no one's limb.
   keep(tempRegexTrigger(
      [[you perceive that you have dealt ([\d.]+)% damage to (\w+)'s ((?:left leg|right leg|left arm|right arm|head|torso))]],
      function()
         local percent, name, limb = tonumber(matches[2]), matches[3]:lower(), matches[4]
         if not percent or name == "yourself" then return end
         M.targetLimbs[name] = M.targetLimbs[name] or {}
         M.targetLimbs[name][limb] = (M.targetLimbs[name][limb] or 0) + percent
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

-- PvP: its moves and modes, in their own file (class/priest_pvp.lua), which installs
-- pvpPlan()/pvpSend() on this module for pvp.lua to drive.
do
   local path = (emunah._root or ".") .. "/src/emunah/class/priest_pvp.lua"
   local ok, install = pcall(dofile, path)
   if ok and type(install) == "function" then
      install(M)
   else
      emunah.log.error("Priest PvP failed to load: %s", tostring(install))
   end
end

return M

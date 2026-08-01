--- Affliction detection patterns.
---
--- READ THIS BEFORE ADDING TO IT
--- -----------------------------
--- This file is intentionally small. It contains only patterns that are structurally
--- certain -- ones keyed off Achaea's own rejection messages, which are stable, generic,
--- and say exactly what is wrong. It does NOT contain the ~200 affliction onset messages,
--- because those could not be sourced reliably, and a plausible-but-wrong pattern is the
--- worst possible outcome here: it asserts an affliction you do not have, the engine burns
--- a balance curing it, and you lose the fight for a reason that is invisible in the logs.
---
--- The right way to grow this file is from evidence:
---
---   1. `emunah learn on`
---   2. fight, or have someone afflict you in the arena
---   3. `emunah learn off`, then read ~/.config/mudlet/profiles/<you>/emunah-learn.txt
---   4. add the messages you actually saw, using the shape below
---
--- Shape:
---
---   detect.define("paralysis", {
---      gain = { [[^Your muscles seize up completely\.$]] },
---      cure = { [[^Your muscles unlock and you can move again\.$]] },
---   })
---
--- Patterns are PCRE (Mudlet's regex triggers). Anchor them with ^ and $ wherever you can:
--- an unanchored pattern will match the same words quoted back at you in a tell, and you
--- will spend an evening wondering why you keep curing afflictions you do not have.

local detect = emunah.curing.detect

-- ---------------------------------------------------------------------------
-- Vector-blocking afflictions, detected from the game's own refusal messages.
--
-- These are the highest-value patterns in the system and the safest to assert, because
-- Achaea tells you *precisely* why an action failed. They also close the most damaging
-- gap in GMCP-only detection: the asthma/anorexia/slickness lock is exactly what an
-- opponent uses when they do not want you to know what you have.
--
-- Each one is a "gain" assertion triggered by a failed cure attempt, which means the
-- engine learns about the block the first time it tries to act through it and then routes
-- around it -- see afflist.blocks and have.blockedBy().
-- ---------------------------------------------------------------------------

detect.define("anorexia", {
   gain = {
      [[^You are afflicted with anorexia and cannot eat anything\.$]],
      [[^You cannot afford to eat that in your condition\.$]],
   },
})

detect.define("asthma", {
   gain = {
      [[^You are having difficulty breathing and cannot smoke\.$]],
      [[^Your lungs are too constricted to smoke\.$]],
   },
})

detect.define("slickness", {
   gain = {
      [[^Your body is too slick with oil for the salve to have any effect\.$]],
      [[^The salve slides off your slick skin\.$]],
   },
})

detect.define("paralysis", {
   gain = {
      [[^You are paralysed and cannot move\.$]],
   },
})

-- ---------------------------------------------------------------------------
-- Elixir (sip) balance, tracked from the game's own messages.
--
-- These two lines are verbatim from a live transcript, which is why they are here and the
-- affliction onset messages are not -- see the note at the top of this file. Achaea
-- announces sip balance returning explicitly, so there is no reason to estimate it.
--
-- This matters more than it looks. The fallback timer was 1.8s against a real sip balance
-- several times that, so the queue re-sent `drink health` while the previous sip was still
-- in flight: elixirs drunk "without effect", a vial wasted per attempt, and health not
-- actually rising. Off-balance sipping is not a cosmetic problem, it is the difference
-- between healing and dying while appearing to heal.
-- ---------------------------------------------------------------------------

detect.balance("elixir", {
   spend = {
      [[^You take a drink from ]],
   },
   gain = {
      [[^You may drink another health or mana elixir\.$]],
   },
})

-- ---------------------------------------------------------------------------
-- Herb balance, announced by the game.
--
-- "You may eat another plant or mineral." is the herb balance returning, and nothing was
-- listening to it. Every herb cure therefore ran on the 1.8s fallback timer and held its
-- queue slot for the full 2s confirmation wait, which is why a real fight logged "No
-- confirmation for [herb] eat kelp -- re-arming" after every single cure. The cures worked;
-- the system just never heard the game say so.
--
-- No spend pattern here. "You eat ..." also matches irid moss, which is a different balance
-- entirely, and spending the herb vector on a moss eat would stall herb curing for no
-- reason. The send arms the fallback; this is what cuts it short.
-- ---------------------------------------------------------------------------

detect.balance("herb", {
   gain = {
      [[^You may eat another plant or mineral\.$]],
   },
})

-- ---------------------------------------------------------------------------
-- Irid moss: a balance of its own, and a trip to the rift first.
--
-- Verbatim from a live transcript at 11:28:29.20 onwards. The moss restores health AND
-- mana ("You feel your health and mana replenished."), and announces its own recovery --
-- so it competes with nothing: not sip balance, not herb balance, not the equilibrium
-- `perform hands` needs. Three healing sources can be in flight at once.
--
-- The pull is a separate vector from the eat because anorexia blocks only the eating.
-- OUTR works while anorexic, so the two must not share a slot -- otherwise being anorexic
-- would also stop us stocking up for the moment it lifts.
-- ---------------------------------------------------------------------------

detect.balance("moss", {
   spend = {
      [[^You eat some irid moss\.$]],
   },
   gain = {
      [[^You may eat another bit of irid moss or potash\.$]],
   },
})

detect.balance("rift", {
   -- No spend pattern: the guard is armed on send (there is no game message for asking),
   -- and this is the confirmation that clears it. Written for any OUTR, not just moss --
   -- one pull at a time is the rule, whatever is being pulled.
   gain = {
      -- Both directions confirm the same way, and both are ours: OUTR to stock up, INR to
      -- put back what is over the target. `[^,]+` rather than `\w+` because the item can be
      -- two words -- "You store 10 green ink, bringing the total in the rift to 10."
      [[^You remove \d+ [^,]+, bringing the total in the rift to \d+\.$]],
      [[^You store \d+ [^,]+, bringing the total in the rift to \d+\.$]],
   },
})

-- ---------------------------------------------------------------------------
-- A drink with nothing to drink.
--
-- "What is it that you wish to drink?" is Achaea failing to resolve the noun in `drink
-- mana`: no vial we are carrying holds that fluid. Verbatim from a live transcript at
-- 11:10:14.06 -- fourteen vials in hand, 2000 sips of mana in the rift, none of it in a
-- vial. It is NOT a balance rejection, so it belongs here rather than in the table below:
-- nothing was drunk, so nothing was spent, and re-arming the recovery timer is the exact
-- wrong response.
--
-- Two things go wrong when it is unhandled, and the second is the expensive one:
--
--   1. The send armed the 6s fallback timer and the 7s confirmation wait, and the
--      confirmation ("You may drink another health or mana elixir.") is never coming --
--      because no sip happened.
--   2. Health and mana share ONE elixir vector. So a mana sip that CANNOT succeed holds
--      that vector for the full confirmation wait, every time the engine retries it, and
--      `drink health` cannot go out in any of those windows. Sitting below the mana
--      threshold with no mana vial therefore stops health sipping during a fight, in
--      bursts, for reasons nothing in the log explains. That is the "sipping randomly
--      stops" report.
--
-- So: free the vector immediately, and stop asking for a fluid we do not have.
-- ---------------------------------------------------------------------------

do
   local id = tempRegexTrigger([[^What is it that you wish to drink\?$]], function()
      -- Read the in-flight action before confirming it away -- it is the only record of
      -- which fluid was asked for. The game's reply does not name it.
      local action = emunah.queue.awaiting("elixir")
      emunah.queue.confirm("elixir")
      emunah.have.recover("elixir")

      local engine = emunah.curing and emunah.curing.engine
      local fluid = action and action.command and action.command:match("^drink%s+(%S+)$")
      if engine and engine.elixirMissing then engine.elixirMissing(fluid) end
   end)
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
   end
end

-- ---------------------------------------------------------------------------
-- A cure that cured nothing.
--
-- "The plant has no effect." means the herb was eaten and did not treat anything -- so our
-- tracked state and the game disagree about what is actually wrong. The herb is spent
-- either way; what must not continue is acting on the belief that produced it.
--
-- Char.Afflictions is authoritative here, so the response is to reconcile against it rather
-- than to guess which entry was wrong. Seen repeatedly in the arena while an opponent
-- re-applied afflictions faster than the list could settle.
-- ---------------------------------------------------------------------------

do
   local id = tempRegexTrigger([[^The plant has no effect\.$]], function()
      local engine = emunah.curing and emunah.curing.engine
      if not engine then return end

      -- WHICH cure failed is the part that matters. The in-flight action on the herb
      -- vector is the only record of it -- the game's reply names neither the herb nor the
      -- affliction -- so read it before the vector is freed.
      local action = emunah.queue.awaiting("herb")
      if action and action.tag and action.command then
         -- The tag carries the affliction, sometimes with a suffix for a server-suggested
         -- cure; the affliction is the part before any space.
         local affliction = tostring(action.tag):match("^(%S+)")
         engine.cureFailed(affliction, action.command)
      end

      emunah.queue.confirm("herb")
      emunah.have.recover("herb")

      if engine.reconcile then engine.reconcile() end
   end)
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
   end
end

-- ---------------------------------------------------------------------------
-- An eat with nothing to eat.
--
-- "What do you want to eat?" is the herb counterpart of the drink case above: the noun did
-- not resolve because the herb is not in inventory. Observed at 18:26:51.05, immediately
-- after a death dropped everything.
--
-- Same reasoning as the drink: nothing was eaten, so no herb balance was spent, and
-- re-arming the recovery timer would be exactly wrong. Free the vector so the next cure --
-- possibly for a different affliction, with a herb we do have -- is not stuck behind it.
-- ---------------------------------------------------------------------------

do
   local id = tempRegexTrigger([[^What do you want to eat\?$]], function()
      emunah.queue.confirm("herb")
      emunah.have.recover("herb")
      emunah.log.debug("An eat did not resolve -- the herb is not in inventory.")
   end)
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
   end
end

-- ---------------------------------------------------------------------------
-- Balance rejections.
--
-- Not afflictions, but the same principle: the game telling us our model is wrong. If we
-- believed a balance was available and Achaea refuses the command, our timer has drifted
-- and the honest response is to re-arm it rather than keep firing into a closed vector.
-- ---------------------------------------------------------------------------

local function rearm(vector)
   return function()
      emunah.have.spend(vector)
      emunah.log.debug("Rejected on %s balance -- re-arming the recovery timer.", vector)
   end
end

local REJECTIONS = {
   { vector = "herb",   pattern = [[^You must regain balance first\.$]] },
   { vector = "salve",  pattern = [[^You have not yet regained balance for applying salves\.$]] },
   { vector = "elixir", pattern = [[^You may not drink another elixir yet\.$]] },
   { vector = "smoke",  pattern = [[^You have not yet recovered balance for smoking\.$]] },
   { vector = "focus",  pattern = [[^You have not yet regained your mental balance\.$]] },
}

for _, rejection in ipairs(REJECTIONS) do
   local id = tempRegexTrigger(rejection.pattern, rearm(rejection.vector))
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
   end
end

-- ---------------------------------------------------------------------------
-- Missing-item detection.
--
-- The failure mode described at the top of have/capabilities.lua: the engine sends a cure
-- for something it does not have. have.cure() prevents this when inventory tracking is
-- accurate, and this is the backstop for when it is not.
-- ---------------------------------------------------------------------------

do
   local id = tempRegexTrigger([[^You do not have (?:that|any of those|the) ]], function()
      emunah.log.warn("The game says an item is missing -- resyncing inventory.")
      if emunah.gmcp.items then emunah.gmcp.items.refresh() end
   end)
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
   end
end

-- ---------------------------------------------------------------------------
-- Knocked down.
--
-- "You must be standing first." is what Achaea says when an action -- attacking, curing,
-- anything -- is refused because you are lying down (a denizen knockback, or PvP). From a
-- real bashing transcript against guard pigs: their charge attack stuns and knocks down,
-- and every attack sent while down was silently wasted until the character stood back up
-- manually -- three "You must be standing first." / "stand" round trips in a row, because
-- nothing was tracking that we were already down and trying to get up. Standing is the
-- only sensible response regardless of what we were trying to do, so this reacts
-- unconditionally rather than being scoped to curing or bashing. detect.prone is the flag
-- other modules (bashing.lua) check before sending anything that needs you upright, so
-- being down stops looking like a balance race and starts being a known, gated state.
--
-- ONSET MESSAGES, AND WHY THIS LIST IS SHORT
-- -----------------------------------------
-- Learning we are down from "You must be standing first." is circular, exactly as it was
-- for stun: the flag can only become true after a command has already been thrown away.
-- Confirmed live -- a wildcat knocked us flat at 06:53:53.41 and the smite sent at
-- 06:53:55.44 was refused, because the knockdown line itself matched nothing:
--
--     Springing forward, a wildcat soldier launches forward into you, sending you sprawling.
--
-- ONSET is what stops the wasted command. But there is one such message per attack per
-- denizen, and exactly one has been observed, so this list is a seed and the rejection
-- above remains the backstop for everything not yet in it. `emunah learn on` while bashing
-- captures more. Patterns anchor on the tail (the actor and verb vary) with a closing "."
-- so a quotation of the same words in a tell -- which would end in ." -- does not match.
-- ---------------------------------------------------------------------------

do
   local function onProne()
      if not detect.prone then
         emunah.log.debug("Knocked down -- standing up.")
         detect.standUp()
      end
      detect.prone = true
      -- Backstop, for the same reason the stun guard exists: this flag gates sending, so a
      -- missed "You stand up." would leave the bot refusing to act indefinitely.
      emunah.timers.start("prone.guard", detect.PRONE_GUARD, function()
         if detect.prone then
            emunah.log.debug("No stand confirmation after %.1fs -- assuming upright.",
               detect.PRONE_GUARD)
            detect.prone = false
            emunah.event.raise("recovered")
         end
      end)
   end

   for _, pattern in ipairs({
      [[^You must be standing first\.$]],           -- the rejection: backstop
      [[sending you sprawling\.$]],                 -- observed: wildcat soldier
   }) do
      local id = tempRegexTrigger(pattern, onProne)
      if id then
         emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
         table.insert(emunah._persist.detectTriggers, id)
      end
   end

   -- "You are already standing." is the other way this resolves: something else stood us up
   -- (a cure, a manual command) between the rejection and our own STAND arriving.
   -- "You are not fallen or kneeling." is what Achaea actually says when you STAND while
   -- already up -- confirmed live at 09:09:28.43. The guessed "You are already standing."
   -- is kept in case it exists too; it has never been observed.
   for _, pattern in ipairs({
      [[^You stand up\.$]],
      [[^You are not fallen or kneeling\.$]],
      [[^You are already standing\.$]],
   }) do
      local upId = tempRegexTrigger(pattern, function()
         emunah.timers.stop("prone.guard")
         detect.prone = false
         emunah.event.raise("recovered")
      end)
      if upId then
         emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
         table.insert(emunah._persist.detectTriggers, upId)
      end
   end
end

-- ---------------------------------------------------------------------------
-- Bleeding.
--
-- Achaea's own help (afflictions-and-what-cures-them) gives bleeding's cure as the bare
-- CLOT command, not an item -- curelist.lua's `special` vector already exists for exactly
-- this shape (a fixed command, no item). But this is NOT registered as a tracked
-- affliction via detect.define(): a real transcript shows only the repeating per-tick
-- damage line ("You bleed N health."), never a distinct onset or "you stop bleeding"
-- message. Asserting it into engine.tracked with no way to retract it would leave it
-- stuck forever, queuing `clot` every tick long after the bleeding has actually stopped --
-- exactly the failure mode this file's header warns about, just shaped as a stuck TRUE
-- instead of a false one. So this acts directly on the queue, the same way the
-- balance-rejection triggers above act straight on have./queue. rather than going through
-- the tracked-affliction machinery: each observed bleed tick queues at most one `clot`,
-- and there is no persistent state to leak if it turns out to be wrong.
--
-- CLOT is the Survival ability "clotting", not a command everyone can send -- confirmed
-- live: without it, Achaea replies "Clot is not a valid command.", one wasted round trip
-- per bleed tick for as long as curing stays on.
--
-- This deliberately does NOT use the ordinary have.skill() gate that curing/engine.lua uses
-- for every other cure. That gate defaults PERMISSIVE (assume yes) while the skill index is
-- still loading, which is right for a cure you might have: refusing to act on every login
-- until the round trip finishes would break curing generally. It is wrong here, confirmed
-- live twice over, because we have stronger evidence than "unknown" -- the character does
-- not have this lesson, full stop -- and permissive-by-default means every fresh reload or
-- reconnect re-sends `clot` into the same rejection once more before the index (or the
-- rejection itself, via have.denySkill() -- see below) catches up. So this waits for
-- POSITIVE confirmation instead: skills.complete AND skills.has("clotting"), both true. The
-- cost of being wrong here is a few points of unclotted bleed for a moment, which is not
-- remotely comparable to sending a command the game has already told us does not exist.
--
-- have.denySkill() is still worth keeping as a backstop for the reverse mistake: if the
-- index ever says yes but the game disagrees, one rejection is enough to override it for
-- the rest of the session, the same as any other capability the game corrects us on.
-- ---------------------------------------------------------------------------

do
   local id = tempRegexTrigger([[^You bleed \d+ health\.$]], function()
      local engine = emunah.curing.engine
      if not (engine and engine.enabled) then return end
      local skills = emunah.gmcp.skills
      if not (skills and skills.complete) then return end   -- unknown -- do not guess
      if not emunah.have.skill("clotting") then return end
      emunah.queue.push("special", "clot", {
         priority = 50, tag = "bleeding",
         confirm  = emunah.config.get("curing.confirmWait", 2.0),
         onSent   = function() emunah.have.spend("special") end,
      })
   end)
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
   end

   local deniedId = tempRegexTrigger([[^Clot is not a valid command\.$]], function()
      emunah.log.debug("No clotting lesson -- will not try CLOT again this session.")
      emunah.have.denySkill("clotting")
   end)
   if deniedId then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, deniedId)
   end
end

-- ---------------------------------------------------------------------------
-- Damage dealt.
--
-- Achaea reports it per hit. Paired with damage taken (from Char.Vitals) it is what makes
-- a threshold like "stop below 50% health" tunable from evidence instead of taste.
-- ---------------------------------------------------------------------------

do
   local id = tempRegexTrigger([[^Damage dealt: (\d+) ]], function()
      local amount = tonumber(matches[2])
      if amount then emunah.event.raise("damage.dealt", amount) end
   end)
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
   end
end

-- ---------------------------------------------------------------------------
-- Equilibrium cost.
--
-- Achaea states it the same way it states balance -- "Equilibrium used: 3.00s." after
-- `perform hands` -- so there is nothing to estimate. Arms the same timer have.balance()
-- checks for the equilibrium vector, which is what stops a second one going out into the
-- window before Char.Vitals reports the loss.
-- ---------------------------------------------------------------------------

do
   local id = tempRegexTrigger([[^Equilibrium used: ([\d.]+)s\.$]], function()
      local seconds = tonumber(matches[2])
      if seconds then emunah.timers.start("cure.equilibrium", seconds) end
   end)
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
   end
end

-- ---------------------------------------------------------------------------
-- Rate limiting.
--
-- "Now now, don't be so hasty!" is Achaea refusing to keep up. It is not about any one
-- balance, so it is handled globally in core/act.lua rather than by whichever subsystem
-- happened to send last -- each of them paces itself against its own resource and cannot
-- see the others, so all of them can be individually reasonable while the total is too
-- fast. The game is complaining about the sum.
-- ---------------------------------------------------------------------------

do
   local id = tempRegexTrigger([[^Now now, don't be so hasty!$]], function()
      emunah.act.rateLimited()
   end)
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
   end
end

-- ---------------------------------------------------------------------------
-- Stunned.
--
-- Stunned is a DIFFERENT state from being knocked down (above) -- confirmed live from a
-- guard-pig charge that produces both: stun clears first ("You are no longer stunned."),
-- and only the next action after that reveals you are ALSO still down ("You must be
-- standing first."). Nothing fixes stunned by sending a command; it just wears off. So
-- unlike knockdown this only tracks it -- callers check detect.isStunned() (via
-- core/act.lua, which refuses EVERY command while it is true) rather than acting on it.
--
-- TWO MESSAGES, AND THE ONSET IS THE IMPORTANT ONE
-- -----------------------------------------------
-- This originally matched only "You are too stunned to be able to do anything.", which is
-- the REJECTION -- the game telling us a command we already sent was thrown away. Detecting
-- the state from its own rejection message is circular: it can only ever become true after
-- we have already spammed at least one command into it, which is the exact thing the flag
-- exists to prevent. Confirmed live, with timestamps: a smite went out at 00:17:21.14 while
-- stunned, because the onset line two seconds earlier --
--
--     You are momentarily stunned as the massive bulk of a guard pig smashes into you.
--
-- -- matched nothing at all. The onset is anchored loosely after "momentarily stunned"
-- because the tail names whatever hit you and varies per denizen and attack.
-- ---------------------------------------------------------------------------

do
   local function onStunned()
      if not detect.stunned then
         emunah.log.debug("Stunned -- holding every command until it passes.")
      end
      detect.stunned = true
      -- Backstop. detect.stunned blocks EVERYTHING, so a missed "You are no longer
      -- stunned." would not degrade the bot, it would freeze it outright. A stun is
      -- momentary by definition, so an upper bound costs nothing when the clear arrives
      -- normally (it just cancels this) and rescues the session when it does not.
      emunah.timers.start("stun.guard", detect.STUN_GUARD, function()
         if detect.stunned then
            emunah.log.debug("No stun-clear message after %.1fs -- assuming it passed.",
               detect.STUN_GUARD)
            detect.stunned = false
            emunah.event.raise("recovered")
         end
      end)
   end

   for _, pattern in ipairs({
      [[^You are momentarily stunned]],
      [[^You are too stunned to be able to do anything\.$]],
   }) do
      local id = tempRegexTrigger(pattern, onStunned)
      if id then
         emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
         table.insert(emunah._persist.detectTriggers, id)
      end
   end

   local clearId = tempRegexTrigger([[^You are no longer stunned\.$]], function()
      emunah.timers.stop("stun.guard")
      detect.stunned = false
      -- A knockdown and a stun routinely arrive on the same hit, and while stunned the
      -- STAND above is refused like everything else. Stun lifting is therefore the moment
      -- to actually get up -- otherwise nothing retries it and we sit prone until the
      -- prone guard lapses.
      if detect.prone then detect.standUp() end
      emunah.event.raise("recovered")
   end)
   if clearId then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, clearId)
   end
end

return true

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
      -- Confirmed live 2026-08-05, verbatim, blocking a salve applied to arms mid-fight:
      -- "oily skin", not "slick skin" -- a real wording this repo had never seen before,
      -- so the block went undetected and afflist.blocks/have.blockedBy() never routed
      -- around it.
      [[^The salve slides off your oily skin\.$]],
   },
})

-- All four are the game refusing an action because of paralysis, and they are worth
-- asserting from: they arrive the instant the refusal happens, ahead of any GMCP push, and
-- they are unambiguous. Verbatim from the arena -- the first for `drink health`, the second
-- also for `drink health`, the third for `perform hands`.
detect.define("paralysis", {
   gain = {
      [[^You are paralysed and cannot move\.$]],
      [[^Your state of paralysis prevents you from doing that\.$]],
      [[^You are paralysed and cannot do that\.$]],
      [[^Frustratingly, your body won't respond to your call to action\.$]],
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

      -- NO ATTRIBUTION. It is tempting to blame the in-flight herb action and record that
      -- cure as useless, and that was tried: it blacklisted `eat bloodroot` for paralysis,
      -- `eat lobelia` for guilt and `eat kelp` for clumsiness within twelve seconds -- all
      -- three correct cures that had worked minutes earlier -- and left the character
      -- curing nothing at all.
      --
      -- The reason is that the reply cannot be matched to the command that caused it. The
      -- herb balance now returns on the game's own announcement, so by the time "no effect"
      -- prints, the vector has been freed and a DIFFERENT cure is already in flight. The
      -- failure lands on whichever action happens to be queued, which is usually not the
      -- one that failed.
      --
      -- THE HERB WAS EATEN. That is what this message means -- it was consumed and treated
      -- nothing, because it went down inside the herb balance. So the balance is NOT free:
      -- it has just been spent again, on nothing.
      --
      -- Recovering it here (which this did) is the same mistake that caused the message in
      -- the first place, one layer further on: it frees a balance the game has not returned,
      -- the next eat goes out inside it too, and paralysis is never cured because every
      -- bloodroot lands off balance. Spend, do not recover.
      emunah.queue.confirm("herb")
      emunah.have.spend("herb")

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

      -- Our view of inventory is wrong, by definition: we believed we held something we do
      -- not. Ask for the real list rather than waiting for whatever would have corrected it
      -- eventually -- after a death this is the difference between resuming and repeating
      -- the same failed eat until someone notices.
      --
      -- INVENTORY ONLY, not the full M.refresh(). This question is "what do I hold", which
      -- has nothing to do with the room -- and a full refresh also polls Char.Items.Room and
      -- triggers a Char.Items.Contents round trip per container in the pack. Live 2026-08-03
      -- 15:52:18-23: that chain ran for five seconds of real time, mid-fight, taking only
      -- bleed damage, before the next cure went out. See M.refreshInventory() in
      -- gmcp/items.lua.
      emunah.log.debug("An eat did not resolve -- re-reading inventory.")
      if emunah.gmcp.items and emunah.gmcp.items.refreshInventory then
         emunah.gmcp.items.refreshInventory()
      end
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

--- "You must regain balance first." is GENERIC, and attributing it to the herb vector
--- unconditionally was wrong in a way that made things worse under load.
---
--- The message belongs to whichever command needed the physical balance. Observed at
--- 12:01:19.03: `perform hands` and `eat irid` went out together, the refusal came back,
--- and the very next line was "You eat some irid moss." -- the eat had worked, and the
--- refusal was the hands. It was logged as "Rejected on herb balance" and re-armed the herb
--- recovery timer anyway. Again at 12:01:24.47 and 12:01:28.17 with no herb or moss action
--- in flight at all, the last eat having resolved five seconds earlier.
---
--- So failing to heal via equilibrium was delaying healing via herbs, at exactly the moment
--- both were needed. What the message unambiguously states is that BALANCE is not there;
--- that much is always safe to record. The herb reading is kept -- mechanics.md has it as
--- what a herb eaten too soon gets -- but only when there is a herb or moss action actually
--- in flight to have earned it.
local function onBalanceRefused()
   local vitals = emunah.gmcp and emunah.gmcp.vitals
   if vitals and vitals.spend then vitals.spend("bal") end

   for _, vector in ipairs({ "herb", "moss" }) do
      if emunah.queue.awaiting(vector) then
         emunah.have.spend(vector)
         emunah.log.debug("Rejected on %s balance -- re-arming the recovery timer.", vector)
         return
      end
   end

   emunah.log.debug("Refused for balance, with nothing eaten in flight -- "
      .. "balance marked spent, herb timer untouched.")
end

local REJECTIONS = {
   { handler = onBalanceRefused, pattern = [[^You must regain balance first\.$]] },
   { vector = "salve",  pattern = [[^You have not yet regained balance for applying salves\.$]] },
   { vector = "elixir", pattern = [[^You may not drink another elixir yet\.$]] },
   { vector = "smoke",  pattern = [[^You have not yet recovered balance for smoking\.$]] },
   { vector = "focus",  pattern = [[^You have not yet regained your mental balance\.$]] },
}

for _, rejection in ipairs(REJECTIONS) do
   local id = tempRegexTrigger(rejection.pattern,
      rejection.handler or rearm(rejection.vector))
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
      -- Inventory only, not M.refresh() -- see the comment on the eat-failure handler above
      -- for why a full refresh (room plus a Char.Items.Contents round trip per container) is
      -- the wrong amount of work for "what do I actually hold".
      if emunah.gmcp.items and emunah.gmcp.items.refreshInventory then
         emunah.gmcp.items.refreshInventory()
      end
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
-- Guardian angel.
--
-- Unlike prone/stunned/asleep, there is no GMCP backstop here at all: `emunah debug gmcp`
-- across both `angel summon` (07:44:53-07:44:59) and `angel fade` (07:45:01-07:45:28) showed
-- only the ordinary Char.Vitals equilibrium update, nothing Char.Defences- or Char.Status-
-- shaped. These two lines are the ONLY mechanism, not a backstop for one -- so unlike prone's
-- rejection-text fallback, there is nothing else to fall back to if one is ever missed.
-- Confirmed exact wording from that same capture.
-- ---------------------------------------------------------------------------

do
   local function onAngelUp()
      if not detect.angel then
         detect.angel = true
         emunah.event.raise("defence.added", "trackangel")
      end
      -- NOTHING ELSE CONFIRMS THE EQUILIBRIUM VECTOR for this command -- same gap
      -- documented below at "perform hands landed": "Equilibrium used: N.NNs." arms the
      -- fallback timer but never calls queue.confirm(), so without this the vector sits
      -- inFlight for the full 2s confirm window (queue.lua's vectorReady() refuses it
      -- outright while inFlight is set) even though the game already answered. Harmless on
      -- its own -- the 2s timeout re-arms it either way -- but it is the same wasted-wait
      -- shape that command was fixed for, and ANGEL SUMMON is unconditionally the only
      -- thing that can be in flight on this vector when either of these lines lands.
      emunah.queue.confirm("equilibrium")
   end

   -- REGRESSION: a cold summon and a redundant one answer with DIFFERENT text, and only the
   -- first was covered. Confirmed live 08:32:09.28-08:32:16.27: `angel summon` sent while
   -- already summoned answered "You feel confusion radiate from your guardian, who hovers
   -- already at your side." -- which never touched detect.angel, so isUp("trackangel") stayed
   -- false forever and keep-up resent ANGEL SUMMON every equilibrium cycle indefinitely,
   -- stopped only by the user pausing keep-up by hand (`pp`). Both mean the same thing --
   -- the angel is up -- and both have to set the flag.
   for _, pattern in ipairs({
      [[^A flower of white light blooms in the air beside you, and your guardian is by your side\.$]],
      [[^You feel confusion radiate from your guardian, who hovers already at your side\.$]],
   }) do
      local id = tempRegexTrigger(pattern, onAngelUp)
      if id then
         emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
         table.insert(emunah._persist.detectTriggers, id)
      end
   end
end

do
   local id = tempRegexTrigger([[^Your guardian angel shimmers silently away\.$]], function()
      if detect.angel then
         detect.angel = false
         emunah.event.raise("defence.lost", "trackangel")
      end
   end)
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
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
-- THE CHARACTER NOW HAS THE LESSON, and that changes the gate rather than merely satisfying
-- it. This used to demand POSITIVE confirmation -- skills.complete AND skills.has()
-- -- refusing to send while the index was still loading, unlike every other cure. That was
-- right at the time and for a specific reason: we had evidence stronger than "unknown",
-- namely two live rejections saying the lesson was absent, so permissive-by-default would
-- have re-sent `clot` into the same rejection after every reload and reconnect.
--
-- That evidence is now void, and a rule kept past its reason is just a rule that is wrong.
-- So this is back to the ordinary have.skill() gate the rest of curing uses, which is
-- permissive while the index loads. The trade has inverted with the premise: the cost of
-- being wrong is now one wasted CLOT after a reload -- and CLOT costs no balance, so it is
-- close to free -- while the cost of the strict rule is unclotted bleeding through every
-- post-reload window, which at the 90-a-tick rates seen while hunting is not nothing.
--
-- have.denySkill() is what makes that safe, and it is worth keeping for the reverse mistake
-- in either direction: if the index ever says yes but the game disagrees, one rejection
-- overrides it for the rest of the session, the same as any other capability the game
-- corrects us on. It also self-clears when a fresh index completes, so a lesson trained
-- mid-session is picked up without a reload.
--
-- CLOT COSTS NO BALANCE AND NO EQUILIBRIUM -- it can be sent freely, and takes a little mana
-- instead. So nothing here spends a vector: an earlier version called have.spend("special"),
-- which armed a two-second recovery timer for a balance that does not exist. The pacing that
-- remains is the queue's own `confirm` slot, which holds one CLOT in flight at a time -- that
-- is a statement about waiting for the game to answer, which is true, rather than about a
-- balance, which is not.
-- ---------------------------------------------------------------------------

do
   local id = tempRegexTrigger([[^You bleed \d+ health\.$]], function()
      local engine = emunah.curing.engine
      if not (engine and engine.enabled) then return end
      if not emunah.have.skill("clotting") then return end

      -- ONLY ABOVE A THRESHOLD. The bleed level comes from the `Bleed` charstat rather than
      -- the number this very line carries -- see detect.CLOT_THRESHOLD, and the same choice
      -- already made in watch.lua. The line says what one tick cost, which is not the same
      -- question as how hard we are bleeding.
      local function bleeding()
         local vitals = emunah.gmcp.vitals
         return vitals and vitals.bleeding() or 0
      end
      local at = tonumber(emunah.config.get("curing.clotThreshold", detect.CLOT_THRESHOLD))
         or detect.CLOT_THRESHOLD
      if bleeding() <= at then return end

      emunah.queue.push("special", "clot", {
         priority = 50, tag = "bleeding",
         confirm  = emunah.config.get("curing.confirmWait", 2.0),
         -- Re-checked at send time, like every other queued action whose reason can stop
         -- being true while it waits. A clot queued at 45 that is still pending once the
         -- bleed has clotted down past the threshold would spend mana on a problem that has
         -- already gone.
         valid    = function() return bleeding() > at end,
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

   -- "You do not bleed, my friend." -- CLOT answered when there was nothing to clot.
   --
   -- Handled for the QUEUE, not for the state, and the distinction is the whole reason this
   -- section keeps no bleeding flag (see above). The line says we are not bleeding *now*,
   -- which is a fact with no future in it -- the next tick can start us bleeding again and
   -- nothing would retract a flag set from this. Storing it would recreate exactly the stuck
   -- TRUE the header warns about, in the opposite direction.
   --
   -- What it does settle is this command. A CLOT sent just as the bleeding stopped would
   -- otherwise hold the special slot for the full confirm timeout, and any clot still pending
   -- behind it would go out into the same reply afterwards. The game has answered: free the
   -- slot, and drop the queued one. Checked by tag because `special` is a general-purpose
   -- vector and this reply is only ever about a CLOT.
   local idleId = tempRegexTrigger([[^You do not bleed, my friend\.$]], function()
      local flight = emunah.queue.awaiting("special")
      if flight and flight.tag == "bleeding" then emunah.queue.confirm("special") end
      local pending = emunah.queue.pending("special")
      if pending and pending.tag == "bleeding" then emunah.queue.clear("special") end
   end)
   if idleId then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, idleId)
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
-- An elixir that did nothing.
--
-- "The elixir flows down your throat without effect." is Achaea saying the sip was real and
-- achieved nothing -- almost always because the defence it grants is already up.
--
-- That matters because of what it looked like without this. Watched live at 13:47:44.97:
-- `drink venom` had worked at 13:47:33 ("your resistance to damage by poison increases",
-- and DEF listed it), but Char.Defences never reported it under the name `venom`, so
-- keep-up kept raising it -- three sips, each one answered with this line, each one a
-- wasted elixir and a wasted balance, before the attempt budget stopped it.
--
-- The line is unambiguous, so the honest response is to stop rather than to spend the rest
-- of the budget learning the same thing twice. Only a DEFENCE raise is abandoned: a healing
-- sip that reports no effect means something quite different (full health), and that path
-- has its own handling.
-- ---------------------------------------------------------------------------

do
   local id = tempRegexTrigger([[^The elixir flows down your throat without effect\.$]], function()
      local flight = emunah.queue.awaiting("elixir")
      local tag = flight and flight.tag
      local defence = tag and tostring(tag):match("^def:(.+)$")
      if not defence then return end

      emunah.queue.confirm("elixir")
      emunah.curing.defkeepup.abandon(defence,
         "the sip had no effect, so it is already up under a different Char.Defences name")
   end)
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
   end
end

-- ---------------------------------------------------------------------------
-- `perform hands` landed.
--
-- NOTHING confirmed the equilibrium vector. Every other vector has a line that closes the
-- loop -- "You eat some irid moss." for moss, "You may drink another..." for the elixir --
-- and equilibrium had none, so queue.confirm("equilibrium") was never once called and every
-- single `perform hands` timed out instead:
--
--   12:01:31.34  You lay your hands on yourself.          <- it worked
--   12:01:31.83  No confirmation for [equilibrium] perform hands -- re-arming.
--
-- The heal itself was fine; the bookkeeping said otherwise, which is how a working ability
-- ends up looking broken in the log and being re-queued on top of itself.
-- ---------------------------------------------------------------------------

do
   local id = tempRegexTrigger([[^You lay your hands on yourself\.$]], function()
      emunah.queue.confirm("equilibrium")
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

-- ---------------------------------------------------------------------------
-- Asleep.
--
-- GMCP IS THE MECHANISM HERE, NOT THE FALLBACK. Achaea names it `sleeping` in
-- Char.Afflictions and reported both edges cleanly in the 06:03 capture, so unlike prone --
-- where the onset text is per attack per denizen and the corpus is necessarily partial --
-- there is nothing for these patterns to cover that GMCP does not already. They exist for
-- the window before the next push, and because the rejection is free to match.
--
-- WHAT IS DELIBERATELY MISSING
-- ---------------------------
-- The onset below is the one for a SLEEP you typed yourself. What an opponent's sleep
-- prints, and what a successful WAKE prints, have never been observed -- and the wake
-- message that HAS been seen is specifically the rested one at the end of a full night:
--
--     06:03:15.10  You open your eyes and stretch languidly, feeling deliciously well-rested.
--
-- Guessing the other two would be the failure this file's header warns about, and there is
-- no cost to leaving them out: Char.Afflictions.Remove carried the wake in the same capture,
-- and detect.SLEEP_GUARD bounds an involuntary sleep even if both were lost.
-- ---------------------------------------------------------------------------

do
   for _, pattern in ipairs({
      -- The onset of a self-inflicted sleep. Observed 06:03:03.06.
      [[^You close your eyes, curl up in a ball, and fall asleep\.$]],
      -- The REJECTION, and circular in the same way stun's is: it can only make the flag
      -- true after a command has already been thrown away. Kept anyway because it is what
      -- re-asserts the state if SLEEP_GUARD expires early on a long sleep -- see the note
      -- on that constant for why being wrong there is cheap.
      [[^You are asleep and can do nothing\. WAKE will attempt to wake you\.$]],
   }) do
      local id = tempRegexTrigger(pattern, function() detect.onSleep() end)
      if id then
         emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
         table.insert(emunah._persist.detectTriggers, id)
      end
   end

   local wokeId = tempRegexTrigger(
      [[^You open your eyes and stretch languidly, feeling deliciously well-rested\.$]],
      function() detect.onWake() end)
   if wokeId then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, wokeId)
   end
end

return true

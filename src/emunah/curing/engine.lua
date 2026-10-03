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
--- DETECTION
--- ---------
--- Char.Afflictions can be relied on for every affliction, in player combat as well as
--- against denizens, with exactly two exceptions:
---
---   blackout -- afflictions applied during it produce no update at all. There is no way
---     to see through it, so the response is to stop reconciling against a frozen feed and
---     catch up the moment it lifts. See M.BLINDING.
---
---   loki -- the list cannot be trusted while it is up. Unlike blackout there IS an answer:
---     DIAG reports the ground truth, at the cost of a second of equilibrium. See
---     M.SUSPECT and queueDiag().
---
--- This is the opposite of the assumption the engine was built under, and it moves the
--- trigger corpus from "the thing standing between this and PvP" to a refinement. Triggers
--- in curing/detect still earn their place -- they see an affliction the instant its message
--- prints, ahead of the next Char.Afflictions push -- but they are no longer load-bearing.
---
--- Char.Vitals is a separate question and has its own liar: recklessness reports hp and mp
--- at maximum regardless of the truth. See gmcp/vitals.lua's M.LIARS.

local M = {}

local util     = emunah.util
local log      = emunah.log
local event    = emunah.event
local queue    = emunah.queue
local have     = emunah.have
local afflist  = emunah.curing.afflist
local deflist  = emunah.curing.deflist
local curelist = emunah.curing.curelist

--- affliction name -> { since, source }
M.tracked = {}

--- Why a tracked affliction is not being cured: affliction -> reason.
---
--- have.cure() returns a precise reason for every refusal -- "out of bloodroot", "herb is
--- blocked by anorexia", "not enough mana to focus" -- and resolve() used to discard it.
--- That made every cure failure look identical from outside: an affliction sitting in the
--- panel with nothing happening, and nothing anywhere saying why. Kept so `emunah affs` can
--- answer the question directly.
M.refusals = {}

--- Reasons already logged, so a refusal is reported when it changes rather than per tick.
local reported = {}

--- How long to wait after sending a cure before sending another for the SAME affliction.
---
--- This is what stops a cure being sent twice, and it replaces an attempt at something
--- cleverer that failed badly. "The plant has no effect." cannot be attributed to the
--- command that caused it -- the herb balance returns on the game's own announcement, so by
--- the time the reply prints, a different cure is already in flight -- and recording the
--- failure against the wrong pair blacklisted `eat bloodroot` for paralysis and `eat
--- lobelia` for guilt inside twelve seconds. Correct cures, disabled, mid-fight.
---
--- The guard needs no attribution. A cure was sent for this affliction; until the game says
--- the affliction is gone, or this long passes, sending a second one can only be a
--- duplicate -- the first has not been answered yet.
M.CURE_GUARD = 1.5

--- affliction -> time until which another cure for it is a duplicate.
local curing = {}

--- Forget the in-flight cure guards.
function M.forgetIneffective()
   curing = {}
end

--- Is a cure for this affliction already on its way?
local function cureInFlight(name)
   local until_ = curing[name]
   if not until_ then return false end
   if util.now() >= until_ then
      curing[name] = nil
      return false
   end
   return true
end

--- Has DIAG already gone out for this bout of loki?
---
--- Once per occurrence, not once per tick. It costs a second of equilibrium -- the same
--- resource attacking needs -- so sending it repeatedly while the illusion persists would
--- cost more than the uncertainty it resolves.
local diagSent = false

--- Vectors we resolve cures on, in the order we consider them. Order only affects which
--- vector gets first refusal on a shared resource; they are otherwise independent.
-- `special` carries the cures that cost no curing balance: COMPOSE for fear, CONCENTRATE
-- for disrupted equilibrium (the reference system's misc actions). CLOT uses the same slot.
M.VECTORS = { "salve", "herb", "smoke", "elixir", "focus", "tree", "special" }

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

--- ONE LINE OF TEXT IS NOT PROOF. Afflictions reported by the imported trigger package
--- (EmunahTriggers.xml, generated from the reference system's trigger set) are held on probation: if the
--- server has not reported the same name within M.TEXT_CONFIRM, the report is dropped.
---
--- Char.Afflictions is reliable for everything except loki and blackout (docs/game/gmcp.md),
--- and it arrives with the same prompt as the text, so a real affliction is confirmed long
--- before this lapses. What does NOT get confirmed is an illusion -- the reference system guards its own
--- triggers against those with a whole subsystem (lifevision) that these triggers do not
--- carry -- and before this, anything a trigger asserted survived every reconcile, so one
--- faked line had the engine curing a phantom for the rest of the fight. While the feed is
--- blinded the text is all there is, so the clock does not run.
M.TEXT_CONFIRM = 2.0

local pendingText = {}

--- Record an affliction from an imported trigger. See M.TEXT_CONFIRM.
function M.addText(name)
   name = tostring(name or ""):lower()
   if M.add(name, "text") then pendingText[name] = emunah.util.now() end
end

local function confirmText()
   if next(pendingText) == nil then return end
   local server = emunah.gmcp.afflictions
   local now = emunah.util.now()
   local blinded = M.blinded()
   local grace = tonumber(emunah.config.get("curing.textConfirm", M.TEXT_CONFIRM))
      or M.TEXT_CONFIRM
   for name, since in pairs(pendingText) do
      local record = M.tracked[name]
      if not record then
         pendingText[name] = nil
      elseif server and server.has(name) then
         record.source = "gmcp"
         pendingText[name] = nil
      elseif blinded then
         pendingText[name] = now
      elseif now - since >= grace then
         pendingText[name] = nil
         log.debug("Dropping %s -- reported by text, never confirmed by the server.", name)
         M.remove(name)
      end
   end
end

function M.remove(name)
   name = tostring(name or ""):lower()
   if not M.tracked[name] then return false end
   M.tracked[name] = nil
   M.refusals[name] = nil
   reported[name] = nil
   curing[name] = nil
   -- The server-cure resend pace (M.SERVER_CURE_RETRY) is for a cure the game keeps
   -- refusing, and a refused affliction stays tracked. One that has gone was answered, and
   -- the next one of the same name is a new affliction: at 14:18:45.68 SMOKE ELM cured
   -- earworm, a second earworm landed at 14:18:49.10 with smoke balance back since 47.21,
   -- and the elm waited until 50.78 for the first cure's throttle to lapse.
   emunah.timers.stop("cure.servercure." .. name)
   event.raise("affliction.cured", name)

   -- A blinding affliction leaving is handled as a state edge in M.tick() rather than here,
   -- because it can also leave via a reconcile or a trigger, and the catch-up has to happen
   -- whichever route it took.
   return true
end

function M.has(name)
   return M.tracked[tostring(name or ""):lower()] ~= nil
end

function M.clear()
   M.tracked = {}
   pendingText = {}
   -- Refusals describe afflictions that no longer exist, and the log debounce keyed to them
   -- would otherwise suppress the first report of the same reason next time round.
   M.refusals = {}
   reported = {}
   -- Clearing tracked state ends the bout: a loki tracked after this is a new one.
   diagSent = false
   curing = {}
end

function M.count()
   return util.count(M.tracked)
end

--- Tracked afflictions that are not a defence held on purpose.
---
--- defkeepup.lua uses a nonzero count to mean "curing is fighting for a vector, stand down
--- until it is not" -- but `blind`/`deaf` kept up deliberately never leave M.tracked once
--- the character holds them, so gating on M.count() there would starve keep-up, including
--- mindseye, the one defence that makes holding them survivable, forever. See the guard in
--- defkeepup.lua's M.tick().
function M.curableCount()
   local n = 0
   for name in pairs(M.tracked) do
      if not deflist.deliberate(name) then n = n + 1 end
   end
   return n
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

--- Afflictions during which Char.Afflictions stops updating.
---
--- Blackout is the known one: afflictions applied while it is up produce no GMCP update at
--- all. This is not the feed lying -- it is the feed frozen -- and the two need different
--- handling. A frozen feed must not be reconciled against, because `reported` is a snapshot
--- from before the blackout began and reconciling would drop every GMCP-sourced affliction
--- that has landed since.
M.BLINDING = { blackout = true }

--- CONCENTRATE once a blackout has lasted this long without lifting. The game's own advice,
--- from an NPC on 2026-09-28: "I've been told it's wise to CONCENTRATE after 3 seconds of
--- blackout have passed without it wearing off." The reason is disrupted equilibrium, which
--- blackout brings and hides: the reference system's dict.blackout assumes `disrupt` a few
--- seconds in (`tempTimer(4.5, ... addaff(dict.disrupt))`), and CONCENTRATE is its cure
--- (HELP COMPOSE). Nothing can confirm it while blind, so the equilibrium never shows as
--- disrupted, and waiting for it to would mean waiting out the whole blackout.
M.BLACKOUT_CONCENTRATE = 3.0

--- Afflictions that make the list untrustworthy rather than absent.
---
--- `loki` is illusion: while it is up, what Char.Afflictions reports cannot be taken at
--- face value. Unlike blackout there is an answer -- DIAG reports the ground truth -- so
--- this is not a state to wait out, it is one to resolve.
M.SUSPECT = { loki = true }

--- What DIAG costs. Requires balance AND equilibrium; consumes 1s of equilibrium only.
--- Same require-versus-consume split as smite: balance has to be there, and is not spent.
M.DIAG_EQUILIBRIUM = 1.0

--- Is affliction state currently unobservable?
---
--- Either source counts. Our own tracked set may not have adopted it yet -- adoption
--- happens in reconcile(), which this function gates -- so asking only ourselves would
--- mean the first reconcile after a blackout lands runs against the frozen snapshot it is
--- supposed to be protected from.
function M.blinded()
   local server = emunah.gmcp.afflictions
   for affliction in pairs(M.BLINDING) do
      if M.tracked[affliction] then return true end
      if server and server.has(affliction) then return true end
   end
   return false
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

   -- Nothing to reconcile against while the feed is frozen; see M.BLINDING. The catch-up
   -- happens in M.remove() the moment it lifts.
   if M.blinded() then return end

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

-- WHY THE TRACKED LIST IS SORTED ONCE PER TICK AND NOT ONCE PER VECTOR
-- --------------------------------------------------------------------
-- resolve() below runs for each of the six vectors, and it used to walk the whole of
-- M.tracked every time -- asking deflist.deliberate(), afflist.known() and afflist.isState()
-- about the same eight afflictions six times over, plus a second full pass per idle vector
-- for the server-cure fallback. With eight afflictions up that is 53 deliberate() calls per
-- prompt for eight afflictions' worth of answer.
--
-- None of those three questions depends on the vector. So they are asked once, here, and the
-- vector loop reads the result. What IS per-vector -- priority and whether a cure is
-- performable -- stays in resolve().

--- Tracked afflictions worth resolving a cure for, and tracked afflictions afflist has never
--- heard of. Plain arrays with an explicit count, reused across ticks: this runs on every
--- prompt, and a fresh table per tick is exactly the kind of garbage that gets collected on
--- the UI thread mid-lock.
local curable, curableCount = {}, 0
local unknown, unknownCount = {}, 0

--- Split M.tracked into those two sets. Call once per tick, after anything that can change
--- what is tracked and before the vector loop reads them.
local function classify()
   curableCount, unknownCount = 0, 0

   for name in pairs(M.tracked) do
      -- NEVER CURE A DEFENCE THE CHARACTER IS HOLDING ON PURPOSE.
      --
      -- `blind` and `deaf` are defences, and the game reports the resulting state as an
      -- affliction too. Char.Defences says `blindness`; the darkness trigger and svof's
      -- gamename say `blind`. Watched at 13:55:02: "Cannot cure blindness: epidermal is in
      -- the rift, not in hand". Watched again at 17:31:33.81, once the text name was what
      -- got tracked: "Cannot cure blind: epidermal would also cure blind/deaf, which are
      -- held on purpose." Either name, while the defence is up or keep-up intends it, is
      -- skipped here so the salve is never applied for it.
      --
      -- It lapses the instant the defence does, and the instant keep-up stops intending it:
      -- a real blinding, with no `blind` defence up, cures normally. The epidermal refusal
      -- in have.cure() stays for a DIFFERENT affliction (anorexia) that would strip the
      -- defence as a side effect. This skip is what stops the warning for blind itself.
      if not deflist.deliberate(name) then
         if afflist.known(name) then
            curableCount = curableCount + 1
            curable[curableCount] = name
         -- afflist.isState() excludes `prone`, `stunned`, `sleeping`: those already have a
         -- dedicated response in curing/detect (STAND, wait, WAKE), driven off the same GMCP
         -- flag through emunah.affliction.added, not off this loop at all. Without this
         -- check, `prone` fell into the "afflist has never heard of it" branch just like a
         -- real unknown affliction, M.serverCure() saw Char.Afflictions' "STAND" suggestion,
         -- and since STAND is a body-position command rather than a vector verb
         -- (M.CURE_VERBS), logged "not acting on it" -- true of THIS loop, false of the
         -- character, which was already standing back up via curing/detect.
         elseif not afflist.isState(name) then
            unknownCount = unknownCount + 1
            unknown[unknownCount] = name
         end
      end
   end
end

--- Best cure to perform on one vector right now.
--- @return table|nil option, string|nil affliction
local function resolve(vector)
   local bestOption, bestAffliction, bestRank

   for index = 1, curableCount do
      local name = curable[index]
      local rank = afflist.priority(name, vector)
      if rank and (not bestRank or rank < bestRank) then
         for _, option in ipairs(afflist.curesVia(name, vector)) do
            local usable, reason = have.cure(option)
            if usable and cureInFlight(name) then
               usable, reason = false, nil   -- not a refusal: a cure is already on its way
            end
            if usable then
               bestOption, bestAffliction, bestRank = option, name, rank
               M.refusals[name] = nil
               reported[name] = nil
               break
            elseif reason then
               M.refusals[name] = reason
               -- Once per distinct reason, not once per tick: this runs on every prompt,
               -- and an affliction nothing can cure would otherwise fill the log with the
               -- same line several times a second.
               if reported[name] ~= reason then
                  reported[name] = reason
                  log.warn("Cannot cure %s: %s.", name, reason)
               end
            end
         end
      end
   end

   return bestOption, bestAffliction, bestRank
end

-- ---------------------------------------------------------------------------
-- The cure the server itself suggests
-- ---------------------------------------------------------------------------
--
-- Char.Afflictions.Add carries a `cure` field, and it has been ignored since the module was
-- written:
--
--     {cure="EAT KELP" desc="Weariness increases the rate at which you use endurance..."
--      name="weariness"}
--
-- Meanwhile the engine logged "Tracking unknown affliction \"weariness\" (no cure defined)"
-- and did nothing about it -- with the answer sitting in the same payload.
--
-- This does not replace afflist.lua. That table carries PRIORITY, which the server does not
-- send and which decides what to cure first when several things are wrong at once; and it
-- carries the mineral equivalents. What this adds is a floor: an affliction the table has
-- never heard of is no longer untreatable, it is simply treated last.
--
-- The verb maps to a vector because the verb IS the command we would have built anyway.
-- EAT is the only form observed so far; the rest are mapped because they name vectors that
-- already exist, and anything unrecognised is skipped and said out loud rather than guessed
-- into a command.

M.CURE_VERBS = {
   EAT   = "herb",
   SMOKE = "smoke",
   APPLY = "salve",
   DRINK = "elixir",
   FOCUS = "focus",
   TOUCH = "tree",
}

--- Rank for a server-suggested cure. Above every real priority, so a cure from afflist --
--- which knows what is urgent -- always wins the vector.
M.GMCP_CURE_PRIORITY = 500

--- How long to wait between resends of the server's own suggested cure for one affliction.
---
--- Not "this cannot work" -- the suggestion is often exactly right, and unlike a normal
--- afflist cure there is no have.cure() check gating it first, so nothing here can tell in
--- advance whether it will succeed. This is purely "the game already answered this tick,
--- stop asking again next tick regardless of what the answer was" -- the same shape as
--- M.CURE_GUARD, but keyed by name rather than left to the queue's own confirm window,
--- because a live rejection clears that window almost immediately and the resend follows
--- right behind it.
---
--- Confirmed live 2026-08-05: "apply mending to arms" (the server's own suggestion for two
--- simultaneously broken arms, tracked under a name afflist did not recognise) went back out
--- on essentially every prompt for close to 30 seconds, each time rejected outright ("Your
--- left arm is too severely damaged to permit that." / "Both your arms must be free and
--- functioning to do that.") -- a real, mechanically-blocked case (see armAfflictions) that
--- no retry cadence, however patient, would ever resolve on its own.
M.SERVER_CURE_RETRY = 5.0

local warnedVerb = {}

--- The cure Char.Afflictions suggests for an affliction, as a vector and a command.
--- @return string|nil vector, string|nil command
function M.serverCure(name)
   local afflictions = emunah.gmcp.afflictions
   if not (afflictions and afflictions.cureFor) then return nil end

   local suggestion = afflictions.cureFor(name)
   if not suggestion or suggestion == "" then return nil end

   local verb = tostring(suggestion):match("^(%a+)")
   local vector = verb and M.CURE_VERBS[verb:upper()]
   if not vector then
      if verb and not warnedVerb[verb] then
         warnedVerb[verb] = true
         log.warn("Char.Afflictions suggests %q for %s and the verb is not one this "
            .. "system maps to a vector -- not acting on it.", suggestion, name)
      end
      return nil
   end
   return vector, tostring(suggestion):lower()
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

--- How often to repeat "wanted to heal, no vial available" while it stays true.
---
--- M.elixirMissing() already warns once, at the moment the fluid is first found missing --
--- but that is the only place it says so, and MISSING_RETRY holds the suppression for 120s.
--- A fight that starts after the one-time warning has scrolled off sees nothing at all: the
--- elixir vector just stops being used, with no line anywhere connecting that to a missing
--- vial rather than a bug. Throttled rather than logged every tick for the same reason every
--- other repeated-cause warning in this file is.
M.ELIXIR_GAP_REMIND = 15

--- Say why the elixir vector is idle while it is actually wanted.
local function warnElixirGap(fluid, percent)
   local key = "elixir.gapwarn." .. fluid
   if not emunah.timers.ready(key) then return end
   emunah.timers.start(key, M.ELIXIR_GAP_REMIND)
   log.warn("Wanted to drink %s at %d%% but no %s vial is available -- this vector stays "
      .. "idle until the missing-fluid window clears.", fluid, percent, fluid)
end

--- Health and mana as a percentage, for a threshold decision.
---
--- Returns 0 for a resource Char.Vitals is lying about, which makes every threshold below
--- fire. Recklessness reports hp and mp at maximum (see vitals.LIARS), so the alternative
--- is a character that reads 100% while it dies -- the affliction exists precisely to
--- produce that. Over-healing costs consumables; under-healing costs the character, and the
--- window is short because recklessness is itself a high-priority cure.
local function healthPercent(vitals, resource)
   if not vitals.trusted(resource) then return 0 end
   return vitals.percent[resource]
end

local warnedUntrusted = false

local function queueHealing()
   local vitals = emunah.gmcp.vitals
   if not vitals then return end

   if not vitals.trusted() then
      if not warnedUntrusted then
         warnedUntrusted = true
         log.warn("Char.Vitals cannot be trusted right now -- healing on every source "
            .. "until it clears.")
      end
   else
      warnedUntrusted = false
   end

   local hp = healthPercent(vitals, "hp")
   local mp = healthPercent(vitals, "mp")

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
   if hp < handsAt then
      queue.push("equilibrium", "perform hands", {
         priority = 0, tag = "healhands",
         -- IT NEEDS BALANCE TOO, not just equilibrium.
         --
         -- Live at 12:01:18.64, 12:01:22.98 and 12:01:27.70: `perform hands` sent with the
         -- prompt reading "e-" (equilibrium up, balance down, because smite had just taken
         -- it) came back "You must regain balance first." every time. The two sent with
         -- "ex-" at 12:01:30.94 and 12:01:34.31 both landed. Five for five.
         --
         -- Without this the loop is pathological rather than merely wasteful: smite takes
         -- balance for 2.8s, which is most of the time during a fight, so nearly every
         -- attempt is refused -- and each refusal was ALSO re-arming the herb timer (see
         -- detect/patterns.lua), so failing to heal one way delayed healing the other way.
         -- Declared as a `needs` rather than folded into have.balance("equilibrium")
         -- because it is a fact about this COMMAND: `diag` shares the vector and has never
         -- been observed to need balance.
         needs    = { bal = true },
         -- Equilibrium is the most contested vector there is -- attacking and penitence
         -- both want it -- so this can wait seconds, and health recovers in that time.
         valid    = function() return healthPercent(vitals, "hp") < handsAt end,
         -- Longer than the generic wait, for the reason ELIXIR_CONFIRM is: the equilibrium
         -- it costs is 3s, so a 2s confirm window lapsed before the ability had finished
         -- even when it worked perfectly, logging a re-arm for every successful heal.
         confirm  = M.HANDS_EQUILIBRIUM + 1.0,
         onSent   = function()
            emunah.gmcp.vitals.spend("eq")
            emunah.timers.start("cure.equilibrium", M.HANDS_EQUILIBRIUM)
         end,
      })
   end

   -- The availability check is part of the condition, not a wrapper around the push, so a
   -- fluid we cannot drink falls through to the next branch rather than blocking it. Health
   -- and mana share one vector; a missing health vial must not also stop mana.
   --
   -- elixirAvailable() being false is silent everywhere else -- M.elixirMissing() logs once,
   -- when the fluid is first found missing, and MISSING_RETRY holds that suppression for a
   -- full 120s. Watched in an arena death 2026-08-03 15:52: health fell from 74% to 0% over
   -- the second half of the fight with no further "Sent [elixir]" anywhere in the log and no
   -- explanation for the gap -- the one-time warning, if it happened at all, was minutes
   -- earlier and long since scrolled away. Re-announcing here, throttled, means a fight lost
   -- to "no vial in hand" says so in the log instead of just going quiet.
   if hp < healthAt then
      if elixirAvailable("health") then
         queue.push("elixir", "drink health", {
            priority = 0, tag = "healhealth",
            valid    = function() return healthPercent(vitals, "hp") < healthAt end,
            confirm  = emunah.config.get("curing.elixirConfirm", M.ELIXIR_CONFIRM),
            onSent   = function() have.spend("elixir") end,
         })
      else
         warnElixirGap("health", hp)
      end
   elseif mp < manaAt then
      if elixirAvailable("mana") then
         queue.push("elixir", "drink mana", {
            priority = 0, tag = "healmana",
            valid    = function() return healthPercent(vitals, "mp") < manaAt end,
            confirm  = emunah.config.get("curing.elixirConfirm", M.ELIXIR_CONFIRM),
            onSent   = function() have.spend("elixir") end,
         })
      else
         warnElixirGap("mana", mp)
      end
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
   -- Either bar: it refills both, so either being low is reason enough. Both read 0 while
   -- Char.Vitals is lying about them, which engages this the same as any other source.
   if healthPercent(vitals, "hp") >= at and healthPercent(vitals, "mp") >= at then return end

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
            valid    = function()
               return healthPercent(vitals, "hp") < at or healthPercent(vitals, "mp") < at
            end,
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
-- "carry as many as possible". Set to 1 on request -- carrying only one of each trades away
-- the buffer that covered a lock (a herb used mid-fight now waits on a fresh OUTR round
-- trip before the same cure can fire again) in exchange for minimising what a death drops.
-- Raise it with `emunah set curing.stockTarget <n>` if that trade stops being worth it.

M.STOCK_TARGET = 1

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

--- How long to leave an item alone after sending a rift command for it.
---
--- THE COUNT LAGS THE COMMAND, and deciding on a stale one oscillates. Observed after a
--- death dropped everything: `outr 3 ash` went out, the count still read 0 because
--- Char.Items had not caught up, so a second `outr 3 ash` followed -- then the count read 6,
--- which is over target, so `inr 3 ash` went out twice, and the count read 0 again. It ran
--- at four commands a second until the fight ended.
---
--- The rift vector alone cannot prevent it: the game's own "You remove 3 ash" confirmation
--- frees the vector, and that arrives before the inventory update it describes. So the
--- guard has to be per item and has to outlive the vector -- no further decision about an
--- item until its count actually moves, or this long has passed.
M.RESTOCK_SETTLE = 2.0

local stockPulls, stockSeen, stockWarned = {}, {}, {}

--- item -> { held = count when the command was sent, until_ = when to give up waiting }
local settling = {}

--- Reset the restocking ledger. Used on reload and when the rift is re-listed.
function M.forgetStock()
   stockPulls, stockSeen, stockWarned, settling = {}, {}, {}, {}
end

--- Is this item waiting for the count to reflect a command already sent?
local function unsettled(item, held)
   local pending = settling[item]
   if not pending then return false end
   -- The count moved: whatever we sent has landed, and the new number is real.
   if held ~= pending.held then
      settling[item] = nil
      return false
   end
   if util.now() < pending.until_ then return true end
   -- Waited long enough. Either the command did nothing or the update was lost; either way
   -- the attempt budget is what stops this becoming a loop.
   settling[item] = nil
   return false
end

local function markSettling(item, held)
   settling[item] = { held = held, until_ = util.now() + M.RESTOCK_SETTLE }
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

   -- Shared and read-only. This used to be copied here per tick, because appending "irid"
   -- to curelist.restockables() grew the memoised list itself; curelist now memoises the
   -- combined answer, so the copy is neither needed nor paid for. See
   -- curelist.restockablesWithIrid() for the whole story -- nothing below may mutate it.
   local wanted = curelist.restockablesWithIrid()

   for _, item in ipairs(wanted) do
      local held = have.quantity(item)
      -- Any increase means the count is moving, so the previous pulls worked and the
      -- attempt budget resets. Consumption lowers `seen` too, which is what lets a
      -- long-lived session keep topping up after every fight.
      if held > (stockSeen[item] or -1) then stockPulls[item] = 0 end
      stockSeen[item] = held

      if unsettled(item, held) then
         -- Deliberately not `return`: another item can still be dealt with this pass.

      elseif held < target then
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
                  markSettling(item, held)
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
            onSent   = function()
               have.spend("rift")
               markSettling(item, held)
            end,
         })
         return
      end
   end
end

--- FILLING A SALVE TIN -- confirmed live for epidermal only:
--- `FILL EMPTY WITH EPIDERMAL FROM RIFT`. See curelist.restockableSalves() for how far that
--- is extended to the rest of the salve list, and why.
---
--- Simpler than queueRestock(): a tin is either usable right now or it is not, so this asks
--- presence, not a target count, and shares the rift vector -- one pull or one fill in
--- flight at a time, same as herbs. The bounded-attempts guard is the same shape as
--- queueRestock()'s, for the same reason: a FILL that silently resolves the wrong tin, or
--- produces an item name have.item()'s substring match does not recognise, must stop asking
--- rather than retry forever.
local salvePulls, salveWarned = {}, {}

--- Reset the salve-restocking ledger. Same triggers as M.forgetStock(): a death or reload
--- makes the previous attempt counts meaningless.
function M.forgetSalveStock()
   salvePulls, salveWarned = {}, {}
end

local function queueSalveRestock()
   -- OFF BY DEFAULT, and not on a whim: confirmed live 2026-08-03 16:43 that `have.item()`
   -- never recognises a filled vial as holding the salve it now holds -- ELIST shows the
   -- vial's own name ("Oaken vial418713") and its fluid ("a caloric salve") as separate
   -- columns, so a filled vial almost certainly never carries the substance name in the
   -- Char.Items `name` field the way a loose herb stack does. That means the "is it in hand
   -- yet" check this loop's stopping condition depends on can never turn true, so it never
   -- stops -- three consecutive `fill empty with caloric from rift` went out a few seconds
   -- apart, each one draining 200 sips from the rift (1000 -> 800 -> 600 -> 400) and eating
   -- another empty vial, until the user manually paused curing to stop it. Left here,
   -- disabled, until there is a confirmed way to read a vial's contents back from GMCP --
   -- turning this on without that fix reproduces the drain.
   if emunah.config.get("curing.restockSalves", false) ~= true then return end
   -- Shares the rift vector with herb pulls: never in competition with a pull that is
   -- actually needed right now.
   if queue.pending("rift") or queue.awaiting("rift") then return end

   local items = emunah.gmcp.items
   if not (items and items.inventoryKnown()) then return end
   local ire = emunah.gmcp.ire
   if not (ire and ire.riftKnown()) then return end

   for _, item in ipairs(curelist.restockableSalves()) do
      if have.item(item) > 0 then
         -- In hand again: whatever was filled worked, so the budget resets for next time.
         salvePulls[item] = 0
      elseif have.inRift(item) > 0 then
         local spent = salvePulls[item] or 0
         if spent >= M.STOCK_ATTEMPTS then
            if not salveWarned[item] then
               salveWarned[item] = true
               log.warn("Filled towards %s %d times and still none in hand -- not trying "
                  .. "again. Check FILL's wording against what this expects.", item, spent)
            end
         else
            queue.push("rift", string.format("fill empty with %s from rift", item), {
               priority = 55,
               tag      = "restock-salve",
               needs    = { alive = true },
               confirm  = emunah.config.get("curing.riftConfirm", 1.5),
               onSent   = function()
                  have.spend("rift")
                  salvePulls[item] = (salvePulls[item] or 0) + 1
               end,
            })
            return
         end
      end
   end
end

-- ---------------------------------------------------------------------------
-- TOUCH TREE -- the last resort
-- ---------------------------------------------------------------------------
--
-- The Tree of Life tattoo costs no balance and no equilibrium, only its own tree balance,
-- which is why it still works when everything else has been taken. That is also the only
-- situation it is worth spending: the balance is long, and burning it on an affliction the
-- herb vector would have cleared a moment later wastes the one cure a lock cannot block.
--
-- WHICH afflictions it clears is not recorded here, and deliberately so -- no entry in
-- afflist.lua names `tree` as a vector, because the mapping has never been verified. So
-- this does not claim to cure a particular affliction. It fires on the *state* the tattoo
-- exists for: something is afflicting us and every cure we know for it has been refused.
--
-- engine.refusals is what makes that state observable. It records why each tracked
-- affliction could not be cured on this pass -- a blocked vector, a missing item, an
-- untrained skill -- all of which are structural rather than a balance ticking down.

--- Seconds an affliction must have been uncurable before the tattoo is spent on it.
---
--- Refusals are structural, but not all are durable: "out of bloodroot" clears the moment
--- restocking lands. A short dwell keeps the long balance for a genuine lock rather than a
--- gap of a second and a half.
M.TREE_DWELL = 2.0

local function queueTree()
   if emunah.config.get("curing.tree", true) == false then return end
   if queue.pending("tree") or queue.awaiting("tree") then return end

   -- The tattoo has to be inked, and its own balance has to be back. Both are checked by
   -- have.cure() for an ordinary cure; this path builds its own command, so it asks here.
   if not have.def("tree") then return end
   if not have.balance("tree") then return end
   -- BOTH ARMS BROKEN, and touching a tattoo needs a working hand. Reported in play: this
   -- is refused the same way paralysis is (see queue.WHILE_PARALYSED). No entry in
   -- afflist.lua calls out `tree` as a vector, so have.cure() never sees this option --
   -- queueTree() builds the command itself and has to ask the same question have.cure()
   -- would have for any other vector.
   if have.bothArmsBroken and have.bothArmsBroken() then return end

   local now = util.now()
   for name, record in pairs(M.tracked) do
      if M.refusals[name] and (now - record.since) >= M.TREE_DWELL then
         queue.push("tree", "touch tree", {
            priority = 0,
            tag      = "tree:" .. name,
            confirm  = emunah.config.get("curing.confirmWait", 2.0),
            onSent   = function() have.spend("tree") end,
         })
         log.info("Nothing can cure %s (%s) -- touching the tree.", name, M.refusals[name])
         return
      end
   end
end

--- LOKI: ask the game what is actually afflicting us.
---
--- Char.Afflictions is reliable in player combat for everything except loki and blackout.
--- Blackout has no answer and is waited out; loki has one, and it is DIAG.
---
--- Queued on the equilibrium vector because that is what it spends, while declaring a
--- balance requirement it does not spend -- act.blocked() enforces both, so this waits for
--- the "next balance" rather than being refused into a rejection message.
local function queueDiag()
   if not M.tracked["loki"] then
      diagSent = false
      return
   end
   if diagSent then return end
   if emunah.config.get("curing.diag", true) == false then return end

   queue.push("equilibrium", "diag", {
      priority = 0,
      tag      = "diag:loki",
      needs    = { bal = true, eq = true },
      confirm  = emunah.config.get("curing.confirmWait", 2.0),
      -- Still wanted only while the illusion is up: loki cured by anything else in the
      -- meantime makes this a second of equilibrium spent on a resolved question.
      valid    = function() return M.tracked["loki"] ~= nil end,
      onSent   = function()
         diagSent = true
         -- Marks the equilibrium spent immediately, for the same reason every other
         -- equilibrium cost does: Char.Vitals goes on reporting it as available until the
         -- game runs the command. The game's own "Equilibrium used:" line replaces this
         -- with the exact figure when it arrives.
         emunah.timers.start("cure.equilibrium", M.DIAG_EQUILIBRIUM)
         log.info("Loki is up -- DIAG for what is actually afflicting us.")
      end,
   })
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
   queueSalveRestock()
   queue.flush()
end

--- Were we blind on the previous pass? See the thaw check in M.tick().
local wasBlinded = false

--- This blackout's CONCENTRATE: due once M.BLACKOUT_CONCENTRATE has passed, and sent at most
--- once. Once, not per tick like a tracked affliction's cure: nothing can confirm it while
--- blind, so a cure loop would CONCENTRATE every couple of seconds for the whole blackout
--- on nothing but a guess. A `disrupted` the server does report is cured the usual way.
local blackoutConcentrate = { due = false, sent = false }

local function queueBlackoutConcentrate()
   if not blackoutConcentrate.due or blackoutConcentrate.sent then return end
   if M.tracked.disrupted then return end
   queue.push("special", "concentrate", {
      priority = 2, tag = "blackout",
      confirm  = emunah.config.get("curing.confirmWait", 2.0),
      -- Confusion prevents concentrating (HELP COMPOSE), the same condition afflist puts on
      -- the `disrupted` cure. Left due, so it goes out once the confusion is cured.
      valid    = function()
         return M.blinded() and not M.tracked.confusion and not M.tracked.disrupted
      end,
      onSent   = function() blackoutConcentrate.sent = true end,
   })
end

--- One pass of the engine.
function M.tick()
   if not M.enabled then return end

   -- THE FEED JUST THAWED. Checked as a state edge rather than hooked onto one code path,
   -- because blackout can leave through any of three: a GMCP removal, a trigger, or a
   -- reconcile. Everything applied while it was up is unknown to us, and the periodic
   -- reconcile below can be twenty ticks away -- a whole fight, at prompt speed.
   local blinded = M.blinded()
   if wasBlinded and not blinded then
      log.warn("Affliction state was unobservable -- reconciling now.")
      M.reconcile()
   end
   -- The blackout clock runs on a timer, not on prompts: whether prompts keep arriving
   -- while blind is exactly what cannot be relied on, so the timer ticks the engine itself.
   if blinded and not wasBlinded then
      blackoutConcentrate.due, blackoutConcentrate.sent = false, false
      emunah.timers.start("blackout.concentrate", M.BLACKOUT_CONCENTRATE, function()
         blackoutConcentrate.due = true
         M.tick()
      end)
   elseif not blinded and wasBlinded then
      emunah.timers.stop("blackout.concentrate")
      blackoutConcentrate.due, blackoutConcentrate.sent = false, false
   end
   wasBlinded = blinded

   confirmText()

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
         -- Held by have.balance("writhe") while a writhe is under way. See M.onWritheStart.
         valid    = function() return resolveWrithe() ~= nil end,
      })
   end

   queueHealing()
   queueIrid()

   -- Before resolving any cure: under loki the list we would resolve against is the thing
   -- in doubt, so establishing what is real comes first.
   queueDiag()
   queueBlackoutConcentrate()

   -- Every tick by default. It was every tenth, which meant one item pulled per ten
   -- prompts: `outr 3 valerian` at 11:47:32 and `outr 3 irid` at 11:48:26, nearly a minute
   -- apart, while most of the cure list was still not carried. Only one pull can be in
   -- flight regardless, so the tick interval was pure delay on top of the round trip.
   local restockEvery = tonumber(emunah.config.get("curing.restockEvery", 1)) or 1
   if vitals and restockEvery > 0 and (vitals.ticks % restockEvery) == 0 then
      queueRestock()
      queueSalveRestock()
   end

   -- One pass over what is tracked, feeding both loops below. See classify().
   classify()

   for _, vector in ipairs(M.VECTORS) do
      local option, affliction, rank = resolve(vector)

      -- Nothing in the cure table wanted this vector. Before leaving it idle, see whether
      -- the server has suggested a cure for something we are tracking but do not know how
      -- to treat -- the case afflist has simply never heard of.
      if not option then
         for index = 1, unknownCount do
            local name = unknown[index]
            -- `unknown` has already excluded defences held on purpose, and for the same
            -- reason resolve() does: the server's own "cure" suggestion undoes a defence
            -- exactly as readily as afflist's table does. `insomnia` has no afflist entry at
            -- all, so this loop was the only thing that ever tried to cure it -- and did,
            -- straight through the guard that stops every other vector. See
            -- deflist.M.DELIBERATE.
            --
            -- timers.ready() is the resend pace, not a success/failure check -- see
            -- M.SERVER_CURE_RETRY. It is armed unconditionally on send, so a genuine
            -- success and a live rejection are throttled exactly alike; the difference is
            -- that a success also removes the tracked affliction, which is what actually
            -- stops this loop from reaching it again.
            if emunah.timers.ready("cure.servercure." .. name) then
               local suggestedVector, suggestedCommand = M.serverCure(name)
               if suggestedVector == vector and suggestedCommand then
                  emunah.timers.start("cure.servercure." .. name, M.SERVER_CURE_RETRY)
                  queue.push(vector, suggestedCommand, {
                     priority = M.GMCP_CURE_PRIORITY,
                     tag      = name .. " (server-suggested)",
                     confirm  = emunah.config.get("curing.confirmWait", 2.0),
                     valid    = function() return M.tracked[name] ~= nil end,
                     onSent   = function() have.spend(vector) end,
                  })
                  log.info("No cure defined for %s -- using the server's own suggestion: %s.",
                     name, suggestedCommand)
                  break
               end
            end
         end
      end

      if option then
         local command, item = curelist.command(option)
         if command then
            queue.push(vector, command, {
               priority = rank,
               tag      = affliction,
               confirm  = emunah.config.get("curing.confirmWait", 2.0),
               -- Another vector may have cured it while this one waited: anorexia goes to
               -- salve or focus, and whichever lands first makes the other a wasted
               -- balance at the moment the next affliction needs it.
               valid    = function() return M.tracked[affliction] ~= nil end,
               onSent   = function()
                  -- Start the fallback recovery timer. A confirmation trigger or the
                  -- GMCP removal will normally cut this short.
                  have.spend(vector)
                  -- And do not send another cure for this same affliction until the game
                  -- has had a chance to answer this one.
                  curing[affliction] = util.now() + M.CURE_GUARD
               end,
               onTimeout = function()
                  log.debug("Cure for %s via %s went unconfirmed.", affliction, vector)
               end,
            })
            log.debug("Resolved %s -> %s (%s, p%s)", affliction, command, item or "-", tostring(rank))
         end
      end
   end

   -- After the vector loop: this pass's refusals are what it reads.
   queueTree()

   queue.flush()
end

-- ---------------------------------------------------------------------------
-- control
-- ---------------------------------------------------------------------------

--- @param silent boolean|nil skip the "Curing on." line -- for a caller (`pp`) that is
---   about to print its own summary covering this and another module together
function M.start(silent)
   M.enabled = true
   emunah.config.set("curing.enabled", true)
   M.reconcile()
   if not silent then log.info("Curing <ansi_light_green>on<ansi_yellow>.") end
   event.raise("curing.enabled")
end

--- @param silent boolean|nil see M.start()
function M.stop(silent)
   M.enabled = false
   emunah.config.set("curing.enabled", false)
   -- Clear in-flight entries too: leaving them would block those vectors when curing is
   -- switched back on, which looks exactly like the system having hung.
   queue.reset()
   if not silent then log.info("Curing <ansi_light_red>off<ansi_yellow>.") end
   event.raise("curing.disabled")
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

-- The heartbeat.
event.register("emunah.tick", function()
   M.tick()
end, "curing.engine")

--- WRITHE ONCE, THEN WAIT.
---
--- HELP ENTANGLEMENT: "if you WRITHE again while you are already writhing, it will take
--- even longer! Just WRITHE once, then wait until you are free of that entanglement." The
--- engine used to push WRITHE every tick and let the confirm timeout re-arm it every two
--- seconds -- extending every web and bind it was trying to escape.
---
--- The game announces the start and the finish, and those lines (the reference system's `started
--- writhe`, `writhe transfixed`, `writhe impale` and `writhed *` triggers,
--- verbatim in curing/detect/patterns.lua) drive this. After the start, the vector is held
--- for M.WRITHE_WAIT -- the reference system's `customwait = 6` on every curing<entanglement> -- or until
--- a finish line or the affliction's removal frees it for the NEXT entanglement, which the
--- same HELP says needs a writhe of its own.
M.WRITHE_WAIT = 6.0

function M.onWritheStart()
   queue.confirm("writhe")
   emunah.timers.start("writhe.busy", M.WRITHE_WAIT)
end

function M.onWritheFree()
   emunah.timers.stop("writhe.busy")
end

--- "You begin to writhe helplessly, throwing your body off balance." -- a WRITHE with
--- nothing to writhe from. Whatever entanglement we are tracking is not real (the reference system's
--- writhe_helpless clears them all the same way), and the balance is gone for nothing.
function M.onWritheHelpless()
   queue.confirm("writhe")
   emunah.timers.stop("writhe.busy")
   for name in pairs(M.tracked) do
      if afflist.isWrithe(name) then M.remove(name) end
   end
end

-- Server-confirmed removal is our most reliable cure confirmation, and it frees the QUEUE
-- SLOT that was waiting on it -- but NOT the balance.
--
-- THE AFFLICTION BEING CURED IS NOT THE BALANCE COMING BACK. This freed both, and it is the
-- cause of every "The plant has no effect." in a night of arena logs: eating bloodroot
-- cures paralysis instantly and also puts you off herb balance for a second and a half.
-- Treating the cure as proof the balance had returned sent the next eat 0.22s later, inside
-- the real balance, where Achaea consumes the herb and does nothing. Which then looked like
-- the cure table being wrong, and cost an attempt at "fixing" that by disabling correct
-- cures.
--
-- The balance has its own authority and does not need inferring: the game announces it
-- ("You may eat another plant or mineral.", "You may drink another health or mana
-- elixir."), and where it does not, the fallback timer in curelist.lua is the estimate.
event.register("emunah.affliction.removed", function(_, name)
   name = tostring(name or ""):lower()
   if afflist.isWrithe(name) then M.onWritheFree() end
   M.remove(name)
   for _, vector in ipairs(queue.VECTORS) do
      local action = queue.awaiting(vector)
      if action and action.tag == name then
         queue.confirm(vector)
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

-- CHAIN THE PULLS. Restocking is driven by the engine tick, and the engine ticks on
-- Char.Vitals -- which Achaea sends with a prompt, and an idle character produces no
-- prompts. Standing still after login, `outr 3 bloodroot` at 18:14:50 was followed by
-- `outr 3 pear` at 18:15:05: fifteen seconds of nothing, waiting for something to happen
-- that would produce the tick that issued the next pull.
--
-- The game confirming one pull is the natural moment to send the next, and it arrives in
-- about a fifth of a second. That turns restocking from "one item per prompt" into a chain
-- that drains at the speed of the round trip.
--- How long after a confirmed pull before the next one goes out.
---
--- Not zero. The confirmation arrives inside a trigger, and sending the next command from
--- there would re-enter the queue while it is still finishing the previous one. A short
--- timer keeps the chain fast while leaving each pull a complete, separate transaction.
M.RESTOCK_CHAIN = 0.05

-- Death drops the pack. Every count in the ledger now describes inventory that is on the
-- floor of wherever you died, and the settle windows describe commands about it.
event.register("emunah.character.died", function()
   M.forgetStock()
   M.forgetSalveStock()
end, "curing.engine")

-- A CURING TIMER LAPSING IS A BALANCE COMING BACK, and nothing else will say so. The engine
-- ticks on prompts, and a balance recovered on its fallback timer (or a server-cure pace
-- running out) produces none: the cure it frees waits for whatever unrelated line brings the
-- next one. bashing.lua found the same stall for its own timers on 2026-08-04; curing had it
-- too. Only `cure.*` timers: they are the ones M.tick() reads.
event.register("emunah.timer.expired", function(_, name)
   if not M.enabled then return end
   if type(name) == "string" and name:sub(1, 5) == "cure." then M.tick() end
end, "curing.engine")

event.register("emunah.balance.recovered", function(_, vector)
   if vector ~= "rift" then return end
   emunah.timers.start("restock.chain", M.RESTOCK_CHAIN, function() M.restockNow() end)
end, "curing.engine")

event.register("sysDisconnectionEvent", function()
   M.clear()
   queue.reset()
   -- Inventory and rift counts are both re-listed on connect, and a death may have emptied
   -- the pack in between, so the restocking ledger from the last session means nothing.
   M.forgetStock()
   M.forgetSalveStock()
end, "curing.engine")

-- Restore the previous on/off state, but never auto-enable on a fresh install.
M.enabled = emunah.config.get("curing.enabled", false) == true

return M

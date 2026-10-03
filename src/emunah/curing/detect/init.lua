--- Trigger-based affliction detection.
---
--- WHAT THIS IS, AND WHAT IT IS NOT
--- -------------------------------
--- This is the framework for detecting afflictions from game text rather than from GMCP.
--- It is complete and working. The *pattern corpus* it drives, in patterns.lua, is a seed
--- rather than a full set, and that distinction matters:
---
---   * Achaea's affliction messages are not published anywhere transcribable. Writing
---     ~200 patterns from memory would produce a table that looks complete and is quietly
---     wrong, which is strictly worse than one that is visibly partial -- a bad pattern
---     asserts an affliction you do not have and the engine then burns balance curing it.
---
---   * So: GMCP is the working detector today (see curing/engine.lua), this layer adds
---     precision where a pattern is known to be right, and learn mode (`detect.startLearning()`) captures
---     what you actually see in combat so the corpus can be grown from evidence.
---
--- Learn mode writes unmatched candidate lines to a file. After a fight, read it, and add
--- the real messages with `detect.add(...)` or by editing patterns.lua.
---
--- PATTERN SHAPE
--- -------------
---   detect.add("paralysis", "gain", [[^Your muscles seize up completely\.$]])
---   detect.add("paralysis", "cure", [[^Your muscles unlock and you can move again\.$]])
---
--- `gain` asserts the affliction; `cure` retracts it and confirms the vector that was
--- waiting on it, which is what lets the next cure go out without waiting for the
--- fallback timer.

local M = {}

local log   = emunah.log
local event = emunah.event

--- affliction -> { gain = { patterns }, cure = { patterns } }
M.patterns = {}

M.learning = false

--- True while the character is known to be down (a denizen knockback, a shove, PvP...).
--- Set and cleared by the "Knocked down" trigger in patterns.lua, from the game's own
--- "You must be standing first." / "You stand up." text -- there is no GMCP field for this.
--- Anything that sends a command requiring you to be upright should check M.isProne()
--- first: sending into a known-down state is not a race to retry around, every attempt is
--- rejected until you actually stand, so retrying blind is pure spam.
M.prone = false

function M.isProne()
   return M.prone
end

--- True while stunned -- see the "Stunned" trigger in patterns.lua. A separate state from
--- M.prone: the two are often caused by the same hit, but clear independently, and stunned
--- has no command to send in response, unlike prone's "stand".
M.stunned = false

function M.isStunned()
   return M.stunned
end

--- True while unconscious. Blocks every command, like stun: every one of the reference system's gates
--- (check_herb, check_salve, check_sip, check_balanceful_acts ...) refuses on
--- `affs.unconsciousness` alongside stun and sleep. Text-driven -- the GMCP name is not
--- confirmed, so it is not guessed into STATE_FLAGS below. See patterns.lua.
M.unconscious = false

function M.isUnconscious()
   return M.unconscious
end

--- Backstop for a missed "You regain consciousness with a start.": The reference system's
--- `unconsciousness.waitingfor` uses customwait = 7 and clears it on timeout.
M.UNCONSCIOUS_GUARD = 7.0

-- ---------------------------------------------------------------------------
-- State edges. Shared by the built-in patterns (patterns.lua) and the imported trigger
-- package (EmunahTriggers.xml, see M.textState), so a line reaches the same code whichever
-- trigger matched it.
-- ---------------------------------------------------------------------------

--- Knocked down. Stand, and bound the belief: this flag gates sending, so a missed "You
--- stand up." would otherwise leave the bot refusing to act indefinitely.
function M.onProne()
   if not M.prone then
      log.debug("Knocked down -- standing up.")
      M.standUp()
   end
   M.prone = true
   emunah.timers.start("prone.guard", M.PRONE_GUARD, function()
      if M.prone then
         log.debug("No stand confirmation after %.1fs -- assuming upright.", M.PRONE_GUARD)
         M.prone = false
         event.raise("recovered")
      end
   end)
end

function M.onStood()
   emunah.timers.stop("prone.guard")
   M.prone = false
   event.raise("recovered")
end

--- Stunned. Blocks EVERYTHING, so a missed "You are no longer stunned." would freeze the
--- bot outright; a stun is momentary by definition, so the guard costs nothing when the
--- clear arrives normally and rescues the session when it does not.
function M.onStunned()
   if not M.stunned then log.debug("Stunned -- holding every command until it passes.") end
   M.stunned = true
   emunah.timers.start("stun.guard", M.STUN_GUARD, function()
      if M.stunned then
         log.debug("No stun-clear message after %.1fs -- assuming it passed.", M.STUN_GUARD)
         M.stunned = false
         event.raise("recovered")
      end
   end)
end

--- A knockdown and a stun routinely arrive on the same hit, and while stunned STAND is
--- refused like everything else -- so stun lifting is the moment to actually get up.
function M.onUnstunned()
   emunah.timers.stop("stun.guard")
   M.stunned = false
   if M.prone then M.standUp() end
   event.raise("recovered")
end

function M.onUnconscious()
   if not M.unconscious then log.debug("Unconscious -- holding every command.") end
   M.unconscious = true
   emunah.timers.start("unconscious.guard", M.UNCONSCIOUS_GUARD, function()
      if M.unconscious then
         M.unconscious = false
         event.raise("recovered")
      end
   end)
end

function M.onConscious()
   emunah.timers.stop("unconscious.guard")
   M.unconscious = false
   if M.prone then M.standUp() end
   event.raise("recovered")
end

-- ---------------------------------------------------------------------------
-- The imported trigger package's entry points, and its ANTI-ILLUSION.
--
-- EmunahTriggers.xml (tools/build-trigger-package.py) calls only these, with the server's
-- name for each affliction. What it reports is text, and text can be faked: an opponent can
-- send you any line they like. The reference system defends against that in layers, and these are them:
--
--   1. NOTHING COUNTS UNTIL THE PROMPT. The reference system's lifevision collects what a block of output
--      reports and applies it at the prompt. Here the block is everything since the last
--      Char.Vitals (Achaea sends one per prompt), committed on the `vitals` event -- which
--      is raised before `tick`, so the engine sees the committed state the same prompt.
--   2. ONE ILLUSION SPOILS THE BLOCK. The reference system's ignore_illusion() discards everything in the
--      paragraph. M.textIllusion() is its equivalent, called by the package's copy of the reference system's
--      "Generic illusions" triggers -- pairs of lines that cannot really arrive together.
--   3. A CURE LINE NEEDS A CURE IN PROGRESS. The reference system's herb_cured_*/focus_cured_*/... accept a
--      cure line only while that balance's action is in flight, never sooner than half the
--      ping after sending it, and -- for an affliction other than the one being cured --
--      only if it is actually tracked. M.textCure(name, via) checks the same.
--   4. THE SERVER HAS THE LAST WORD. A gained affliction is dropped unless Char.Afflictions
--      confirms it (engine.TEXT_CONFIRM). The reference system: "serverside curing is completely immune" to
--      illusions -- which is exactly what GMCP is.
--
-- `emunah set curing.antiIllusion false` applies reports the moment they arrive instead
-- (the reference system's `vconfig aillusion`); layers 3 and 4 still apply.
-- ---------------------------------------------------------------------------

local paragraph = {}
local illusion = nil

local function antiIllusion()
   return emunah.config.get("curing.antiIllusion", true) ~= false
end

local TEXT_STATES = {
   stunned     = { on = "onStunned",     off = "onUnstunned" },
   prone       = { on = "onProne",       off = "onStood" },
   sleeping    = { on = "onSleep",       off = "onWake" },
   unconscious = { on = "onUnconscious", off = "onConscious" },
}

--- Is this cure line believable? See layer 3 above. `via` is one balance, or a list of the
--- balances the same line can come from (a tree touch and an eaten herb print the same
--- "cured" line) -- any one of them in flight will do.
local function cureBelievable(name, via)
   if not via then return true end            -- a wear-off or general cure: no action to match
   local engine = emunah.curing.engine
   local action
   if type(via) == "table" then
      for _, vector in ipairs(via) do
         action = emunah.queue.awaiting(vector)
         if action then via = vector break end
      end
      if not action then via = table.concat(via, "/") end
   else
      action = emunah.queue.awaiting(via)
   end
   if not action then
      return false, ("a %s cure for %s, but nothing is being cured on %s"):format(via, name, via)
   end
   if action.tag ~= name and not (engine and engine.has(name)) then
      return false, ("a %s cure for %s, which we do not have"):format(via, name)
   end
   local latency = 0
   if type(getNetworkLatency) == "function" then
      local ok, value = pcall(getNetworkLatency)
      if ok and tonumber(value) then latency = tonumber(value) end
   end
   local elapsed = emunah.util.now() - (action.sentAt or 0)
   if elapsed < latency / 2 then
      return false, ("a %s cure %.2fs after sending, faster than half the ping (%.2fs)")
         :format(via, elapsed, latency)
   end
   return true
end

local function apply(report)
   local kind, name = report[1], report[2]
   if kind == "gain" then
      local engine = emunah.curing.engine
      if engine then engine.addText(name) end
      -- The login/LOOK line for real blindness. Committed here, with the rest of the
      -- paragraph, so an illusion that spoils the block never spends the equilibrium.
      -- Mindseye is what lets prerift and the room be read while blind is held on purpose.
      if name == "blind" or name == "blindness" then
         local defkeepup = emunah.curing.defkeepup
         if defkeepup and defkeepup.noteTrueBlind then defkeepup.noteTrueBlind() end
      end
   elseif kind == "cure" then
      local believable, why = cureBelievable(name, report[3])
      if believable then
         M.onCure(name)
      else
         log.info("Illusion ignored -- %s.", why)
      end
   elseif kind == "state" then
      local handlers = TEXT_STATES[name]
      if handlers then M[report[3] and handlers.on or handlers.off]() end
   end
end

local function report(entry)
   if antiIllusion() then
      paragraph[#paragraph + 1] = entry
   else
      apply(entry)
   end
end

--- An affliction gained, on probation until the server confirms it (engine.TEXT_CONFIRM).
function M.textGain(name)
   report({ "gain", tostring(name or ""):lower() })
end

--- An affliction cured. `via` is the curing balance the line belongs to (herb, salve, focus,
--- smoke, tree), or nil for a wear-off or a general cure. Frees the queue slot waiting on it,
--- as a native cure line does; if the server still reports it, the next reconcile adopts it.
function M.textCure(name, via)
   report({ "cure", tostring(name or ""):lower(), via })
end

--- A state entered or left.
function M.textState(state, on)
   report({ "state", state, on and true or false })
end

--- This block of output contains an illusion: throw away everything it reported.
function M.textIllusion(reason)
   illusion = illusion or reason or "a line that cannot be real"
end

--- Apply, or discard, what the block reported. Runs on every prompt.
function M.commitText()
   if illusion then
      if #paragraph > 0 then
         log.info("Illusion ignored -- %s; discarded %d report(s) with it.", illusion, #paragraph)
      end
      paragraph, illusion = {}, nil
      return
   end
   if #paragraph == 0 then return end
   local pending = paragraph
   paragraph = {}
   for index = 1, #pending do apply(pending[index]) end
end

--- Lines since the last Char.Vitals. See M.textPrompt().
M.linesSinceVitals = 0

event.register("emunah.vitals", function()
   M.linesSinceVitals = 0
   M.commitText()
end, "curing.detect")

--- Lines since the last prompt: The reference system's `paragraph_length`, kept by the same trigger.
M.paragraphLength = 0

--- A non-prompt line. Called by the package's prompt trigger for every line that is not a
--- prompt, exactly as the reference system's `Prompt` trigger counts them.
function M.textLine()
   M.paragraphLength = M.paragraphLength + 1
   M.linesSinceVitals = M.linesSinceVitals + 1
end

--- The prompt. Closes the block: its reports are applied (or discarded, on an illusion)
--- whether or not a Char.Vitals came with it, and if none did, the prompt runs the
--- heartbeat instead (gmcp.vitals.onPrompt).
---
--- So does a block whose Char.Vitals came BEFORE some of its lines. The heartbeat ran on
--- Char.Vitals, and whatever those later lines did -- a balance announced, an affliction
--- committed here -- was then sat on until the NEXT prompt: in test/latency.lua, a herb
--- balance announced after Char.Vitals sent nothing at all that block. svof runs everything
--- off the prompt line for exactly this reason: it is the one thing guaranteed to come last.
--- Whether Achaea ever orders a block that way is not established; when it does not, this
--- costs nothing, because no line has arrived since Char.Vitals.
function M.textPrompt()
   M.commitText()
   M.paragraphLength = 0
   local after = M.linesSinceVitals > 0
   M.linesSinceVitals = 0
   local vitals = emunah.gmcp and emunah.gmcp.vitals
   if vitals and vitals.onPrompt then vitals.onPrompt(after) end
end

--- Arm balance. The reference system holds every balance-taking action until BOTH arms have it
--- (check_balanceful_acts: `not bals.rightarm or not bals.leftarm`). It is lost by
--- arm-specific attacks and announced back per arm -- see patterns.lua for the lines.
M.armBalance = { left = true, right = true }

--- Backstop for a missed arm-recovery line, which would otherwise hold every bal/eq action
--- for the rest of the session. Generous, like the prone guard: it should only fire when
--- the real line was genuinely lost.
M.ARM_GUARD = 10.0

function M.armsBalanced()
   return M.armBalance.left and M.armBalance.right
end

function M.loseArmBalance(side)
   M.armBalance[side] = false
   emunah.timers.start("arm.guard." .. side, M.ARM_GUARD, function()
      if not M.armBalance[side] then
         log.debug("No %s arm balance line after %.1fs -- assuming it returned.",
            side, M.ARM_GUARD)
         M.armBalance[side] = true
      end
   end)
end

function M.gainArmBalance(side)
   M.armBalance[side] = true
   emunah.timers.stop("arm.guard." .. side)
end

--- True while asleep -- put there by an opponent, or by your own SLEEP.
---
--- Blocks every command bar WAKE (see core/act.lua). A third state alongside prone and
--- stunned rather than a flavour of either: Achaea applies `prone` at the same time, so the
--- two coincide and clear separately, and unlike stunned there IS a command that ends it.
M.asleep = false
--- A WAKE has been accepted and the struggle is under way. See wakeUp().
M.waking = false

function M.isAsleep()
   return M.asleep
end

--- True while the guardian angel is summoned. Set and cleared by the two lines in
--- patterns.lua -- there is no GMCP field for this at all, unlike prone/stunned/asleep.
--- Confirmed live via `emunah debug gmcp` 07:44:45-07:45:32: `angel summon` and `angel fade`
--- produced only the ordinary Char.Vitals equilibrium update, no Char.Defences and no
--- Char.Status naming the angel. curing/deflist.lua's M.SYNTHETIC reads this directly, the
--- same way it reads a wielded item straight off Char.Items for the mace -- neither has a
--- Char.Defences entry to be "up" in.
M.angel = false

function M.isAngelSummoned()
   return M.angel
end

--- True when this sleep is one the character asked for.
---
--- The character has to SLEEP from time to time, and an automation that WAKEs them out of
--- it immediately is worse than no automation at all. So a SLEEP typed by hand suppresses
--- the auto-wake for the whole of that sleep; everything else stays blocked, which is the
--- point -- the system goes quiet until you are up.
M.voluntary = false

--- Deadline by which a sleep must arrive for it to count as ours. See M.intendSleep().
M.sleepIntent = nil

--- How long a hand-typed SLEEP explains an incoming `sleeping`.
---
--- Measured at ~3.1s from the command to the affliction in the 06:02:59 capture, which is
--- one prompt; this is generous on top of that. It has to LAPSE, though, and that is the
--- whole reason it is a window rather than a flag: a SLEEP the game refuses (wrong room,
--- in combat) would otherwise leave the auto-wake suppressed indefinitely, and the next
--- sleep to land would be one an opponent put there.
M.SLEEP_INTENT = 8.0

--- Record that the character asked to sleep. Called by the SLEEP alias in commands.lua.
function M.intendSleep()
   M.sleepIntent = emunah.util.now() + M.SLEEP_INTENT
end

--- Get up.
---
--- STAND COSTS BALANCE. Confirmed live: knocked down at 08:12:57.54 with the prompt reading
--- "e-", the stand went out immediately and came back "You must regain balance first." A
--- knockdown almost always lands right after our own attack, so balance is precisely what we
--- do not have at the moment we need to stand -- declaring the cost is what stops the
--- attempt being wasted.
---
--- No standing requirement, obviously; the stun check comes free with act.send(), since
--- STAND is refused while stunned like everything else.
---
--- Retried from the tick below rather than sent once. A single refused attempt left the
--- character flat for twelve seconds in that same fight, until an unrelated rejection
--- happened to trigger another one.
--- How long to refuse a second STAND after sending one.
---
--- Sized like every other in-flight guard here: long enough to cover the round trip, short
--- enough that a stand which was genuinely refused is retried promptly.
M.STAND_GUARD = 1.0

--- Legs too damaged to stand on. The reference system's prone isadvisable refuses STAND on any of these
--- (a merely BROKEN leg does not stop it), as well as while entangled or paralysed.
M.STAND_BLOCKING_LEGS = {
   "crippledleftleg",  "crippledrightleg",
   "mangledleftleg",   "mangledrightleg",
   "mutilatedleftleg", "mutilatedrightleg",
}

--- Get up, at most once per round trip.
---
--- SENT IS NOT EXECUTED, and prone is re-evaluated on every tick. Without a guard, a single
--- knockdown produced a STAND on every Char.Vitals until the game caught up -- observed as
--- two in a row for one `sit`, answered with "You are not fallen or kneeling." That reply
--- is harmless; the balance the second one would have spent if it HAD been needed is not.
function M.standUp()
   if not emunah.timers.ready("stand.inflight") then return false end
   for _, leg in ipairs(M.STAND_BLOCKING_LEGS) do
      if emunah.act.afflicted(leg) then return false end
   end
   -- Equilibrium as well as balance: The reference system will not stand without both (prone isadvisable),
   -- which is also HELP EQUILIBRIUM's default -- "not having balance prevents you from
   -- using an ability that requires equilibrium, and vice versa". `unbound` holds it while
   -- entangled; paralysis comes with `bal`.
   local sent = emunah.act.send("stand", { bal = true, eq = true, unbound = true })
   if sent then emunah.timers.start("stand.inflight", M.STAND_GUARD) end
   return sent
end

--- Upper bound on how long either state is believed without a clearing message. Both flags
--- gate sending, so a clear that never arrives is not a degraded bot but a frozen one --
--- these bound the damage. Generous on purpose: they should only ever fire when a message
--- was genuinely missed, never in place of the real one.
M.STUN_GUARD  = 6.0
M.PRONE_GUARD = 10.0

--- Bleed level at or below which CLOT is not worth sending.
---
--- CLOT costs no balance and no equilibrium, so the only price is mana -- but mana is the
--- resource an enemy Priest's kill route drains, and `perform hands` spends it too. A trickle
--- bleed clots itself off in a few ticks and does not justify paying for it every one.
---
--- READ FROM THE `Bleed` CHARSTAT, not from the number in "You bleed N health.". That is the
--- same call watch.lua already made, for the reason given there: the damage message only
--- appears when you actually lose health to it, so it says nothing about how hard you are
--- bleeding, while the charstat arrives with every prompt. Override with
--- `emunah set curing.clotThreshold <n>`.
M.CLOT_THRESHOLD = 30

--- How long to refuse a second WAKE after sending one.
---
--- WAKE costs neither balance nor equilibrium, so a wasted one costs only the round trip --
--- but the game says it will "attempt" to wake you, which reads as something that can fail,
--- so it is worth repeating rather than sending once and hoping. Sized like STAND_GUARD for
--- the same reason: one attempt per round trip, not one per prompt.
M.WAKE_GUARD = 1.0

--- Backstop for an INVOLUNTARY sleep whose end is never reported.
---
--- Sleep runs a variable length, up to about ten seconds, so this is roughly double the
--- longest expected. Deliberately NOT armed for a voluntary sleep: that one ends when the
--- character decides it does, and a timer that unblocked the system mid-nap would be the
--- automation interfering, which is exactly what M.voluntary exists to prevent.
---
--- Being wrong here is cheap and self-correcting, unlike the prone and stun guards. If this
--- fires while still asleep, the next command draws "You are asleep and can do nothing.",
--- and that line re-asserts the flag -- so the cost is one wasted round trip rather than a
--- system that has quietly stopped believing in a state it is still in.
M.SLEEP_GUARD = 20.0

--- Wake up, at most once per round trip.
---
--- Declares `whileAsleep` because it is the one command that works from here -- the game's
--- own rejection names it. No balance or equilibrium requirement: confirmed that WAKE
--- neither requires nor consumes either.
---
--- ONCE IT HAS STARTED, NEVER AGAIN. HELP SLEEPING: "when you type WAKE, you will begin
--- to struggle your way out of sleep ... Typing WAKE repeatedly will only delay this
--- process, so just do it once, and wait." The start is announced -- "You begin your
--- struggle to escape from the dreamworld." (the reference system's `start waking` trigger) -- and
--- from then until the sleep ends M.waking holds every further WAKE, the same way the reference system
--- parks in `curingsleep` with no retry. Before that line, a WAKE that went unanswered is
--- still retried once per round trip: it may simply have been lost.
function M.wakeUp()
   if not M.asleep then return false end
   -- The character asked for this sleep. Waking them out of it is the interference.
   if M.voluntary then return false end
   if M.waking then return false end
   if not emunah.timers.ready("wake.inflight") then return false end
   local sent = emunah.act.send("wake", { whileAsleep = true })
   if sent then emunah.timers.start("wake.inflight", M.WAKE_GUARD) end
   return sent
end

--- Enter the asleep state. Safe to call again while already asleep.
---
--- The one place the voluntary/involuntary decision is made, because it can only be made on
--- the edge: once asleep, nothing in the game text or GMCP distinguishes a nap from a
--- Somnolence, and the only evidence either way is whether we sent SLEEP a moment ago.
function M.onSleep()
   if M.asleep then return end
   M.asleep = true

   M.voluntary = M.sleepIntent ~= nil and emunah.util.now() < M.sleepIntent
   M.sleepIntent = nil

   if M.voluntary then
      log.info("Asleep by your own SLEEP -- holding everything until you wake.")
      return
   end

   log.debug("Asleep -- waking.")
   emunah.timers.start("sleep.guard", M.SLEEP_GUARD, function()
      if M.asleep then
         log.debug("No wake confirmation after %.1fs -- assuming awake.", M.SLEEP_GUARD)
         M.onWake()
      end
   end)
   M.wakeUp()
end

--- The game has started waking us. See wakeUp() for why nothing is resent after this.
function M.onWakeStart()
   if not M.asleep then return end
   M.waking = true
   emunah.timers.stop("wake.inflight")
   log.debug("Waking -- not sending WAKE again until it finishes.")
end

--- Leave it. Clears the voluntary flag too: the next sleep is a new question, and one nap
--- must not buy an opponent a free Somnolence afterwards.
function M.onWake()
   M.waking = false
   if not M.asleep then return end
   M.asleep = false
   M.voluntary = false
   emunah.timers.stop("sleep.guard")
   emunah.timers.stop("wake.inflight")
   event.raise("recovered")
end

local LEARN_PATH = getMudletHomeDir() .. "/emunah-learn.txt"

--- Trigger ids live on _persist so a reload can kill the previous generation. Same
--- problem, and same fix, as the event handlers in core/event.lua: Mudlet keeps temp
--- triggers alive independently of the Lua state that created them.
local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
   return emunah._persist.detectTriggers
end

--- Remove every trigger this module owns.
function M.killAll()
   local reg = registry()
   local n = 0
   for _, id in ipairs(reg) do
      if killTrigger(id) then n = n + 1 end
   end
   emunah._persist.detectTriggers = {}
   return n
end

-- ---------------------------------------------------------------------------
-- registration
-- ---------------------------------------------------------------------------

--- Register a detection pattern.
--- @param affliction string
--- @param kind string "gain" | "cure"
--- @param pattern string a Mudlet-flavoured (PCRE) regex
--- @return boolean
function M.add(affliction, kind, pattern)
   affliction = tostring(affliction or ""):lower()
   if affliction == "" or type(pattern) ~= "string" then return false end
   if kind ~= "gain" and kind ~= "cure" then
      log.warn("Detection kind must be 'gain' or 'cure', got %q.", tostring(kind))
      return false
   end

   M.patterns[affliction] = M.patterns[affliction] or { gain = {}, cure = {} }
   table.insert(M.patterns[affliction][kind], pattern)

   local id = tempRegexTrigger(pattern, function()
      if kind == "gain" then
         M.onGain(affliction)
      else
         M.onCure(affliction)
      end
   end)

   if not id then
      log.error("Could not create a %s trigger for %s.", kind, affliction)
      return false
   end

   table.insert(registry(), id)
   return true
end

--- Convenience: register several patterns for one affliction.
function M.define(affliction, spec)
   for _, pattern in ipairs(spec.gain or {}) do M.add(affliction, "gain", pattern) end
   for _, pattern in ipairs(spec.cure or {}) do M.add(affliction, "cure", pattern) end
end

--- Track a cure balance from the game's own messages rather than from a timer.
---
--- The timers in curelist.lua are FALLBACKS for when a confirmation is missed. Where
--- Achaea actually announces a balance -- and for elixirs it does, precisely -- the
--- announcement is authoritative and the estimate is not. Guessing short is expensive:
--- the queue re-sends as soon as its timer lapses, so an under-estimate means drinking
--- again before the sip has landed, which wastes the elixir ("The elixir flows down your
--- throat without effect") and can burn a vial per second.
---
--- @param vector string a cure vector, e.g. "elixir"
--- @param spec table { spend = { patterns }, gain = { patterns } }
function M.balance(vector, spec)
   for _, pattern in ipairs(spec.spend or {}) do
      local id = tempRegexTrigger(pattern, function()
         emunah.have.spend(vector)
      end)
      if id then table.insert(registry(), id) end
   end

   for _, pattern in ipairs(spec.gain or {}) do
      local id = tempRegexTrigger(pattern, function()
         -- Free the QUEUE SLOT as well as the balance. queue.flush() refuses a vector while
         -- something is in flight on it, and only the confirm timeout was clearing that --
         -- so the announcement that the balance is back left the slot held anyway, and no
         -- further cure went out on that vector until the timeout lapsed. Raising the
         -- elixir confirm to 7s (because the real confirmation arrives late) turned a two
         -- second stall into a seven second one: health sipping simply stopped for stretches
         -- of a fight. The game telling us the balance is back IS the confirmation.
         emunah.queue.confirm(vector)
         emunah.have.recover(vector)
         emunah.event.raise("balance.recovered", vector)
      end)
      if id then table.insert(registry(), id) end
   end
end

-- ---------------------------------------------------------------------------
-- handlers
-- ---------------------------------------------------------------------------

function M.onGain(affliction)
   local engine = emunah.curing.engine
   if not engine then return end
   if engine.add(affliction, "trigger") then
      log.debug("Detected %s.", affliction)
   end
end

function M.onCure(affliction)
   local engine = emunah.curing.engine
   local queue  = emunah.queue
   if not engine then return end

   engine.remove(affliction)

   -- Free the QUEUE SLOT that was waiting on this cure, and only that. The balance is a
   -- separate thing and is not back merely because the affliction is gone -- eating a herb
   -- cures instantly and still costs the full herb balance, so recovering it here sent the
   -- next eat inside the balance, where the game consumes the herb and answers "The plant
   -- has no effect." See the same note in curing/engine.lua.
   for _, vector in ipairs(queue.VECTORS) do
      local action = queue.awaiting(vector)
      if action and action.tag == affliction then
         queue.confirm(vector)
         break
      end
   end
end

-- ---------------------------------------------------------------------------
-- learn mode
-- ---------------------------------------------------------------------------

--- Lines that look like they could be affliction messages: second person, present tense,
--- short. Deliberately loose -- the point is to over-capture and let you filter.
local CANDIDATE = [[^(You|Your) .{4,90}[.!]$]]

local function logCandidate(line)
   local file = io.open(LEARN_PATH, "a")
   if not file then return end
   file:write(os.date("%H:%M:%S "), line, "\n")
   file:close()
end

function M.startLearning()
   if M.learning then return false end
   M.learning = true

   local id = tempRegexTrigger(CANDIDATE, function()
      local line = matches and matches[1]
      if type(line) ~= "string" then return end
      logCandidate(line)
   end)

   if id then
      emunah._persist.learnTrigger = id
      log.toggled("Learn mode", true,
         (" Candidate lines -> <ansi_cyan>%s<ansi_yellow>"):format(LEARN_PATH))
      log.info("Fight normally, then read that file and add the real messages.")
   end
   return true
end

function M.stopLearning()
   if not M.learning then return false end
   M.learning = false
   if emunah._persist.learnTrigger then
      killTrigger(emunah._persist.learnTrigger)
      emunah._persist.learnTrigger = nil
   end
   log.toggled("Learn mode", false, (" Captured lines are in %s"):format(LEARN_PATH))
   return true
end

function M.toggleLearning()
   if M.learning then M.stopLearning() else M.startLearning() end
   return M.learning
end

M.learnPath = LEARN_PATH

-- ---------------------------------------------------------------------------
-- affliction corpus walk ("affpop")
-- ---------------------------------------------------------------------------
--
-- `learn` mode above catches affliction MESSAGES seen in combat. This drives the game's
-- own reference commands instead -- `AFFLICTION LIST` (every name Achaea knows) and
-- `AFFLICTION SHOW <name>` (that name's Diagnose/Cure(s)/Description block), both real
-- commands, confirmed live 21:02-21:03 -- and captures every answer. Existing afflist.lua
-- entries were built from memory and the published help pages; this walks the game itself
-- instead, which is the higher-authority source per docs/afflictions.md.
--
-- WHY RAW CAPTURE, NOT A PARSER: one sample of AFFLICTION SHOW is not enough to know the
-- field set is fixed (whether every affliction has exactly the same boolean flags at the
-- end, for instance), and guessing a parser onto an unverified shape is exactly the mistake
-- this file's own header warns about for pattern data. Dump verbatim, review by hand, and
-- write a parser once several real blocks are on hand to check it against.
--
-- THE SHAPE OF THE WALK, confirmed live: AFFLICTION LIST prints a page of bare names ending
-- either in `[Type MORE if you wish to continue reading. (NN% shown)]` -- answer MORE and
-- another page follows -- or, on the last page, nothing of the kind at all; output just
-- stops. There is no distinct "100%" or "end of list" line, so completion is read from
-- silence: if nothing relevant has arrived for AFFPOP_SETTLE seconds, the list is done.
-- Once it is, AFFLICTION SHOW <name> is sent for every name collected, one at a time, paced
-- by AFFPOP_SHOW_INTERVAL -- answers run several lines and interleaving two of them would
-- leave nothing in the file to tell them apart.
--
-- DELIBERATELY LOOSE PATTERNS, same reasoning as CANDIDATE above, and separate triggers
-- rather than one combined regex for the same reason `pipes on|off` is three aliases, not
-- one: tempAlias/tempRegexTrigger take a PCRE regex, but test/mock_mudlet.lua translates
-- that to a Lua pattern to match it in tests, and Lua patterns have no alternation.
local AFFPOP_PATH = getMudletHomeDir() .. "/emunah-affliction-corpus.txt"

--- A bare capitalised word alone on its line -- one entry from `AFFLICTION LIST`.
local AFFPOP_LISTED = [[^[A-Z][A-Za-z]*$]]

--- `Label:   value` -- one field from `AFFLICTION SHOW <name>`, e.g. "Cure(s):  Apply
--- Health To Arms" or "Diagnose:  suffering from...".
local AFFPOP_FIELD = [[^[A-Za-z()' ]+:\s+.+$]]

--- Section markers worth keeping so the file reads as blocks rather than a word-salad:
--- the "All afflictions" header, its rule, and `[File continued via MORE]`.
local AFFPOP_MARKER = [[^(All afflictions|-{5,}|\[.+\])$]]

--- The MORE prompt itself, answered automatically while listing. Seen verbatim on more than
--- just AFFLICTION LIST (ability descriptions page the same way), so this is Achaea's
--- general pagination prompt, not something specific to this one command.
local AFFPOP_MORE = [[^\[Type MORE if you wish to continue reading\..*\]$]]

--- Gap between successive AFFLICTION SHOW sends. Paced the same way gmcp/init.lua paces
--- GMCP requests: one command out, then a cooldown, rather than a burst.
local AFFPOP_SHOW_INTERVAL = 1.5

--- Silence, in seconds, after which a page with no MORE prompt is read as the last one.
local AFFPOP_SETTLE = 2.5

M.capturing = false   -- true while the corpus triggers are armed
M.walking   = false   -- true from AFFLICTION LIST until the last AFFLICTION SHOW is sent

--- True only while collecting names off AFFLICTION LIST -- a bare capitalised word can
--- appear plenty of other places, and outside the list this must not add a phantom name to
--- the walk.
local listing = false

local walkNames, walkIndex = {}, 0

--- Names collected from the current or most recent walk. Exposed for `emunah affpop` and
--- for tests -- a copy, so nothing outside this module can mutate the walk mid-flight.
function M.affpopNames()
   local copy = {}
   for i, name in ipairs(walkNames) do copy[i] = name end
   return copy
end

local function logCapture(line)
   local file = io.open(AFFPOP_PATH, "a")
   if not file then return end
   file:write(os.date("%H:%M:%S "), line, "\n")
   file:close()
end

--- Send AFFLICTION SHOW for the next collected name, then re-arm for the one after it.
function M.walkNext()
   walkIndex = walkIndex + 1
   local name = walkNames[walkIndex]
   if not name then
      M.walking = false
      log.info("Affliction walk complete: %d entries -- see %s", #walkNames, AFFPOP_PATH)
      return
   end
   if not emunah.act.send("affliction show " .. name, {}) then
      -- Blocked (stunned, asleep...) -- retry the same name next tick rather than skip it.
      walkIndex = walkIndex - 1
   end
   emunah.timers.start("affpop.walk", AFFPOP_SHOW_INTERVAL, M.walkNext)
end

local function armSettle()
   emunah.timers.start("affpop.settle", AFFPOP_SETTLE, function()
      if not listing then return end
      listing = false
      log.info("AFFLICTION LIST complete: %d names -- walking AFFLICTION SHOW now.",
         #walkNames)
      M.walkNext()
   end)
end

function M.startCapture()
   if M.capturing then return false end
   M.capturing = true

   local ids = {}
   for _, pattern in ipairs({ AFFPOP_FIELD, AFFPOP_MARKER }) do
      local id = tempRegexTrigger(pattern, function()
         local line = matches and matches[1]
         if type(line) == "string" then logCapture(line) end
      end)
      if id then ids[#ids + 1] = id end
   end

   local listedId = tempRegexTrigger(AFFPOP_LISTED, function()
      local line = matches and matches[1]
      if type(line) ~= "string" then return end
      logCapture(line)
      if listing then
         walkNames[#walkNames + 1] = line
         armSettle()
      end
   end)
   if listedId then ids[#ids + 1] = listedId end

   local moreId = tempRegexTrigger(AFFPOP_MORE, function()
      local line = matches and matches[1]
      if type(line) == "string" then logCapture(line) end
      if listing then
         emunah.act.send("more", {})
         armSettle()
      end
   end)
   if moreId then ids[#ids + 1] = moreId end

   emunah._persist.affpopTriggers = ids
   log.toggled("Affliction capture", true,
      (" Captured lines -> <ansi_cyan>%s<ansi_yellow>"):format(AFFPOP_PATH))
   return true
end

function M.stopCapture()
   if not M.capturing then return false end
   M.capturing, listing, M.walking = false, false, false
   emunah.timers.stop("affpop.settle")
   emunah.timers.stop("affpop.walk")
   for _, id in ipairs(emunah._persist.affpopTriggers or {}) do
      killTrigger(id)
   end
   emunah._persist.affpopTriggers = nil
   log.toggled("Affliction capture", false, (" Captured lines are in %s"):format(AFFPOP_PATH))
   return true
end

--- Start the full walk: AFFLICTION LIST, MORE answered automatically until the list runs
--- out, then AFFLICTION SHOW <name> for every name it named, one at a time.
function M.startWalk()
   if M.walking then return false end
   if not M.capturing then M.startCapture() end

   M.walking, listing = true, true
   walkNames, walkIndex = {}, 0

   if not emunah.act.send("affliction list", {}) then
      M.walking, listing = false, false
      log.warn("Could not send AFFLICTION LIST -- try again in a moment.")
      return false
   end
   armSettle()
   log.info("Walking AFFLICTION LIST -- MORE is answered automatically.")
   return true
end

function M.toggleWalk()
   if M.walking or M.capturing then M.stopCapture() else M.startWalk() end
   return M.walking
end

M.affpopPath = AFFPOP_PATH

-- ---------------------------------------------------------------------------
-- load
-- ---------------------------------------------------------------------------

-- Drop the previous generation before installing this one.
M.killAll()

--- How many afflictions have at least one pattern. Reported by `emunah detect`.
function M.coverage()
   local withGain, withCure = 0, 0
   for _, spec in pairs(M.patterns) do
      if #spec.gain > 0 then withGain = withGain + 1 end
      if #spec.cure > 0 then withCure = withCure + 1 end
   end
   return {
      afflictions   = emunah.util.count(M.patterns),
      withGain      = withGain,
      withCure      = withCure,
      totalKnown    = emunah.curing.afflist.count(),
   }
end

-- Publish before loading the pattern file.
--
-- patterns.lua reaches back through `emunah.curing.detect` to call define(). The loader
-- only performs that assignment once this module *returns*, so without publishing here
-- the pattern file would see nil. It is also not in the loader's manifest, so its
-- package.loaded entry has to be cleared by hand or a reload would silently skip it and
-- leave you with no triggers at all.
emunah.curing = emunah.curing or {}
emunah.curing.detect = M

package.loaded["emunah.curing.detect.patterns"] = nil
local ok, err = pcall(require, "emunah.curing.detect.patterns")
if not ok then
   log.warn("No detection patterns loaded: %s", tostring(err))
end

event.register("sysDisconnectionEvent", function()
   M.stopLearning()
   -- A voluntary sleep arms no guard, by design -- so it is the one state here that can
   -- outlive the session that created it, and it blocks every command. Reconnecting awake
   -- with the flag still set would look exactly like the system having hung.
   M.onWake()
   M.sleepIntent = nil
end, "curing.detect")

-- GMCP IS THE AUTHORITY FOR THESE, NOT OUR PATTERNS.
--
-- Achaea reports `prone` (and `stunned`) by name through Char.Afflictions. We had been
-- inferring knockdown from per-denizen text -- one onset message per attack per creature,
-- of which exactly one was ever observed -- while the game was saying it plainly all along.
-- The text patterns stay as a backstop for the window before GMCP catches up, but a named
-- affliction is complete where a hand-built corpus cannot be.
--
-- Adding another state is one line in afflist.STATES plus one here.
--
-- `sleeping` is the GMCP name and `asleep` is our flag; they differ because the affliction
-- names the state and the flag reads as a predicate at the call sites. Sleep is GMCP-driven
-- by preference and not merely by fallback -- the wake message observed
-- ("You open your eyes and stretch languidly...") is the one for a natural, rested wake,
-- and what a WAKE out of an enemy Somnolence prints has never been seen. Char.Afflictions
-- reported both edges cleanly in the 06:03 capture, so the patterns in patterns.lua are the
-- backstop here and not the mechanism.
local STATE_FLAGS = { prone = "prone", stunned = "stunned", sleeping = "asleep" }

local GUARD_TIMER = { prone = "prone.guard", stunned = "stun.guard", asleep = "sleep.guard" }

event.register("emunah.affliction.added", function(_, name)
   name = tostring(name or ""):lower()
   local flag = STATE_FLAGS[name]
   if not flag then return end

   -- Sleep owns its own edge: the flag, the voluntary decision and the first WAKE are one
   -- transaction, and splitting them across the generic path would run the decision after
   -- the flag was already set.
   if flag == "asleep" then
      if not M.asleep then log.debug("GMCP reports %s.", name) end
      M.onSleep()
      return
   end

   if not M[flag] then
      log.debug("GMCP reports %s.", name)
      M[flag] = true
      if flag == "prone" then M.standUp() end
   end
end, "curing.detect")

event.register("emunah.affliction.removed", function(_, name)
   local flag = STATE_FLAGS[tostring(name or ""):lower()]
   if not flag or not M[flag] then return end

   if flag == "asleep" then
      M.onWake()
      return
   end

   M[flag] = false
   emunah.timers.stop(GUARD_TIMER[flag])
   event.raise("recovered")
end, "curing.detect")

-- Keep trying while we are down. Self-limiting: standing spends the balance it requires, so
-- a successful attempt blocks the next tick's, and "You stand up." clears the flag anyway.
--
-- Not while asleep. Achaea applies `prone` WITH `sleeping`, so without that clause this is
-- the exact line that produced three refused STANDs in the 06:03 capture. act.blocked()
-- would hold them anyway, but the two flags coinciding is the normal case rather than an
-- edge, and it is worth reading here that we know it.
local function retryStandAndWake()
   if M.prone and not M.stunned and not M.asleep then M.standUp() end
   -- Retried per tick rather than sent once: WAKE "will attempt" to wake you, and it costs
   -- nothing, so the guard rather than the send is what paces it.
   if M.asleep then M.wakeUp() end
end

event.register("emunah.tick", retryStandAndWake, "curing.detect")

-- ...and the moment a guard that was pacing them lapses, not at whichever prompt follows.
-- A refused STAND left the character flat until the next unrelated event; the guard exists
-- to space retries a round trip apart, not to wait for the room to say something.
local RETRY_ON_EXPIRY = {
   ["stand.inflight"] = true, ["wake.inflight"] = true,
   ["stun.guard"] = true, ["unconscious.guard"] = true,
}

event.register("emunah.timer.expired", function(_, name)
   if RETRY_ON_EXPIRY[name] then retryStandAndWake() end
end, "curing.detect")

return M

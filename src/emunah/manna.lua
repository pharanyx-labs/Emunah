--- The manna rite, as one command.
---
--- Three commands with real waits between them, which is the only reason this is a module
--- and not an alias that sends three lines:
---
---     perform rite of sustenance      places a bowl and fills it -- costs 3s equilibrium
---     get bowl                        needs balance AND equilibrium, so it must wait
---     drink bowl                      drains it
---
--- Transcribed from one live run at 07:07:08 -- see docs/game/sustenance.md. The player typed
--- each command by hand with several seconds between them; the pauses in that transcript are
--- a human waiting, not a required delay, and the actual constraint is narrower and exactly
--- knowable: the rite announces "Equilibrium used: 3.00s." and GET needs equilibrium back.
---
--- CHAINED ON THE GAME'S OWN LINES, NOT ON TIMERS
--- ----------------------------------------------
--- Each step advances when Achaea confirms the previous one, the same way cures do. A timer
--- would have to encode the 3 seconds, and that number is already announced -- the trigger in
--- curing/detect/patterns.lua arms `cure.equilibrium` from the announcement itself, so asking
--- have.balance("equilibrium") is exact where a hardcoded sleep is an estimate that goes
--- stale the moment a trait or an affliction changes it.
---
--- Everything goes through core/act.lua rather than the queue. The queue is only flushed by
--- the curing engine, so a queued action does nothing at all while curing is off -- and this
--- is a command the player typed, which must work regardless of what else is switched on.

local M = {}

local log   = emunah.log
local event = emunah.event

--- The sequence. `done` is the game line that means this step has actually happened.
---
--- WHAT EACH STEP DECLARES IS NOT GUESSED, WITH ONE GAP SAID OUT LOUD:
---
---   The rite consumes 3.00s of equilibrium -- announced, and observed as the prompt going
---   from "ex-" to "x-". Whether it also REQUIRES balance is not established; the prompt
---   read "ex-" beforehand, so the transcript cannot distinguish "needs balance" from
---   "happened to have it". Nothing is declared, and a refusal would be visible.
---
---   GET costs balance and equilibrium and needs you upright -- already established, and
---   loot.lua declares the same three.
---
---   What DRINK BOWL costs has never been observed. It is not an elixir, so the sip balance
---   the elixir vector models may not apply at all. Nothing is declared rather than guessing
---   a requirement that would either hold it back for no reason or send it into a refusal;
---   M.ATTEMPTS is what stops a wrong guess here becoming a loop.
M.STEPS = {
   {
      command = "perform rite of sustenance",
      needs   = { eq = true },
      -- The plea line prints first, but it is the rain that says the bowl is actually full.
      done    = [[^A rain of nourishing manna falls from heaven]],
      -- Marks the equilibrium spent on send, for the reason every other equilibrium cost
      -- here does: Char.Vitals goes on reporting it as available until the game has run the
      -- command. The game's own "Equilibrium used: 3.00s." replaces this with the exact
      -- figure a moment later.
      spends  = 3.0,
   },
   {
      command = "get bowl",
      needs   = { standing = true, bal = true, eq = true },
      done    = [[^You pick up an earthenware bowl\.$]],
   },
   {
      command = "drink bowl",
      needs   = {},
      done    = [[^You feel utterly replete\.$]],
   },
}

--- How many times to send one step before giving up on the whole sequence.
---
--- Same reasoning as the restocker's STOCK_ATTEMPTS and loot's STOW_ATTEMPTS: when the model
--- is wrong the honest response is to stop and say which step stalled, rather than retry
--- forever. The likely causes are all things a message would explain -- no bowl carried, the
--- rite unavailable, a cost this does not know about -- and none of them get better by
--- sending the command again a fourth time.
M.ATTEMPTS = 3

--- How long to leave a step alone after sending it, before counting that as a failed try.
---
--- Long enough for the round trip and for the game to actually run the command. The
--- confirmation normally arrives well inside this and advances the step immediately, so this
--- only paces the retries of a step that is going wrong.
M.STEP_GUARD = 2.5

--- Which step we are on, or nil when idle.
M.step = nil

--- Attempts spent on the current step.
M.attempts = 0

local function idle()
   M.step, M.attempts = nil, 0
   emunah.timers.stop("manna.step")
end

--- Is the sequence running?
function M.running()
   return M.step ~= nil
end

--- Try to send the current step.
---
--- Called on every tick as well as on each confirmation, so a step waiting on equilibrium
--- goes out the moment it comes back rather than on the next unrelated event -- the same
--- reason loot.lua re-sweeps on balance recovery.
function M.attempt()
   local step = M.STEPS[M.step or 0]
   if not step then return false end

   -- One in flight at a time. Without this, every prompt during the 3s equilibrium wait
   -- would count as another attempt and the budget would be gone before the wait was over.
   if not emunah.timers.ready("manna.step") then return false end

   -- act.blocked() reads Char.Vitals' equilibrium FLAG, which is true again the instant the
   -- bar refills -- but the rite's 3 seconds are tracked as a timer, armed from the game's
   -- own announcement. Both have to be satisfied or `get bowl` goes out into "You must
   -- regain equilibrium first." while the flag says it is fine.
   if step.needs.eq and not emunah.have.balance("equilibrium") then return false end

   if M.attempts >= M.ATTEMPTS then
      log.warn("Manna: %q sent %d times with no answer -- stopping. Check you are carrying "
         .. "the bowl and that the rite is available.", step.command, M.attempts)
      idle()
      return false
   end

   if not emunah.act.send(step.command, step.needs) then return false end

   M.attempts = M.attempts + 1
   emunah.timers.start("manna.step", M.STEP_GUARD)

   if step.spends then
      emunah.gmcp.vitals.spend("eq")
      emunah.timers.start("cure.equilibrium", step.spends)
   end
   return true
end

--- Move to the next step, or finish.
local function advance()
   M.step = (M.step or 0) + 1
   M.attempts = 0
   emunah.timers.stop("manna.step")

   if not M.STEPS[M.step] then
      idle()
      log.info("Manna: <ansi_light_green>done<ansi_yellow>.")
      event.raise("manna.finished")
      return
   end
   M.attempt()
end

--- Run the sequence.
function M.start()
   if M.running() then
      log.info("Manna: already running (step %d of %d).", M.step, #M.STEPS)
      return false
   end
   M.step, M.attempts = 1, 0
   emunah.timers.stop("manna.step")
   log.info("Manna: %d steps.", #M.STEPS)
   event.raise("manna.started")
   M.attempt()
   return true
end

--- Give up on it.
function M.stop()
   if not M.running() then return false end
   log.info("Manna: stopped at step %d.", M.step)
   idle()
   return true
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

do
   emunah._persist = emunah._persist or {}
   for _, id in ipairs(emunah._persist.mannaTriggers or {}) do killTrigger(id) end
   emunah._persist.mannaTriggers = {}

   -- One trigger per step, each live only while that step is the one we are waiting on.
   -- Scoped that way rather than fired whenever the line appears, because these are ordinary
   -- game messages: drinking a bowl by hand would otherwise advance a sequence nobody
   -- started, and "You pick up an earthenware bowl." is not exclusive to this rite.
   for index, step in ipairs(M.STEPS) do
      local id = tempRegexTrigger(step.done, function()
         if M.step == index then advance() end
      end)
      if id then table.insert(emunah._persist.mannaTriggers, id) end
   end
end

-- Retry the current step on every prompt. This is what covers the equilibrium wait between
-- the rite and the GET: nothing else would send it, since the sequence advances on
-- confirmations and the confirmation for step 1 has already been and gone.
event.register("emunah.tick", function()
   if M.running() then M.attempt() end
end, "manna")

-- A session boundary makes the sequence meaningless -- the bowl may be on the floor of a
-- room we are no longer in, and step 2 would pick up whatever "bowl" resolves to now.
event.register("sysDisconnectionEvent", function() idle() end, "manna")

return M

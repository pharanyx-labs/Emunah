--- The single gate every automated command passes through.
---
--- WHY THIS EXISTS
--- ---------------
--- Achaea refuses commands for reasons that have nothing to do with the command itself:
--- you are stunned, you are lying down, the balance it costs has not come back. Each of
--- those used to be checked -- when it was checked at all -- at the individual call site,
--- so bashing, the curing queue and loot each grew their own partial copy of the rules.
--- Every newly discovered rule then had to be added in three places, and whichever one was
--- missed carried on spamming the game. Several rounds of "it is still sending commands it
--- cannot send" were all that same shape. This module is the one place that knows the
--- rules; call sites say what a command COSTS, not when it is allowed.
---
--- THE RULES, AS THE GAME ACTUALLY IMPLEMENTS THEM
--- ----------------------------------------------
---   stunned   Nothing works. Not attacks, not cures, not movement -- every command is
---             refused with "You are too stunned to be able to do anything." This is
---             checked for EVERY command regardless of what it asks for, which is why it
---             is not something a caller can declare a need for.
---
---   asleep    The same shape as stunned -- "You are asleep and can do nothing. WAKE will
---             attempt to wake you." -- with exactly one exception, which the game names in
---             its own rejection: WAKE. That one caller passes `whileAsleep = true`.
---
---             This is not a theoretical case. Achaea applies `prone` alongside `sleeping`,
---             so the knockdown response fires while asleep: in the 06:03 capture, STAND
---             went out three times over twelve seconds and drew that rejection every time,
---             because nothing knew the character was asleep. One check here covers every
---             call site, which is the whole argument for this module.
---
---   prone     Only things that need you upright are refused ("You must be standing
---             first."). Deliberately NOT applied to everything: eating a herb and drinking
---             an elixir work perfectly well while flat on your back, and blocking curing
---             while knocked down in a fight is how an automated system kills you. Callers
---             opt in with `standing = true`.
---
---   bal / eq  The ordinary balances, straight from Char.Vitals.
---
---   dead      Nothing is sent. The user's rule: when the character dies Emunah pauses
---             completely, and picks up again on revival. `alive` is still accepted from
---             older call sites but no longer changes anything.
---
---   unconscious  Same as stunned. The reference system refuses every action on it.
---
---   halted    Nothing is sent. QUIT or QQ typed means the client is closing (the user,
---             2026-10-04): once INR ALL has gone out, the system stops entirely. See
---             M.halt().
---
---   paralysed / entangled / arm balance   See M.blocked() below.
---
--- Requirements are a plain table so a caller states only what it actually costs:
---
---     emunah.act.send("smite 12345", { standing = true, bal = true })
---     emunah.act.send("get 999",     { standing = true })

local M = {}

--- Hold everything back until this time. See M.rateLimited().
M.backoffUntil = nil

--- Why the system has stopped entirely, or nil. Held on the module table on purpose: a
--- reload (emreload) is a deliberate restart and clears it, as does a new connection.
M.halted = nil

--- Stop sending anything at all. Everything automated goes through M.blocked(), so this
--- one flag is the whole of "stop the system" -- curing, keep-up, the hunt, loot, pipes.
function M.halt(reason)
   if M.halted then return end
   M.halted = reason or "halted"
   emunah.log.info("<ansi_light_red>Stopped<ansi_yellow> -- %s. Nothing more will be sent "
      .. "until you reconnect, emreload, or `emset pause`.", M.halted)
   emunah.event.raise("halted", M.halted)
end

function M.resume()
   if not M.halted then return false end
   M.halted = nil
   emunah.event.raise("resumed")
   return true
end

--- Achaea has throttled us. Confirmed live: "Now now, don't be so hasty!" after steps went
--- out roughly one round trip apart.
---
--- Backing off globally rather than per-subsystem is the point. Bashing, curing, the walker
--- and loot each pace themselves against their own resource, and none of them can see the
--- others -- so each can be individually reasonable while the total is too fast. The game
--- is complaining about the sum, so the sum is what has to slow down.
function M.rateLimited(seconds)
   seconds = tonumber(seconds) or M.BACKOFF
   M.backoffUntil = emunah.util.now() + seconds
   emunah.log.debug("Rate limited -- holding all commands for %.1fs.", seconds)
   emunah.event.raise("rateLimited", seconds)
end

M.BACKOFF = 1.5

--- Does the character have this affliction? The curing engine's view when it is running
--- (it knows about DIAG and refusal-detected afflictions), the server's list otherwise.
function M.afflicted(name)
   local engine = emunah.curing and emunah.curing.engine
   if engine and engine.has and engine.has(name) then return true end
   local afflictions = emunah.gmcp and emunah.gmcp.afflictions
   return (afflictions and afflictions.has and afflictions.has(name)) or false
end

--- Why a command with these requirements cannot be sent right now, or nil if it can.
--- Returned as a short reason string so callers can log something useful rather than
--- silently doing nothing.
--- @param needs table|nil { standing = bool, bal = bool, eq = bool, unbound = bool,
---                          alive = bool, whileAsleep = bool }
--- @return string|nil reason
--- What a command with no stated requirements needs. Shared and never written: blocked() is
--- asked once per vector per tick (queue.flushVector) and per send, and `needs or {}` made a
--- fresh table every one of those times.
local NONE = {}

function M.blocked(needs)
   needs = needs or NONE

   if M.halted then return "halted" end

   if M.backoffUntil then
      if emunah.util.now() < M.backoffUntil then return "rate limited" end
      M.backoffUntil = nil
   end

   -- Resolved at call time, not captured at load time: core/ loads before curing/ and
   -- gmcp/, and this module is reachable from both.
   local detect = emunah.curing and emunah.curing.detect

   -- NOT IN THE GAME: NOTHING. Before the first Char.Vitals of a connection, anything sent
   -- lands on the login menu (gmcp/vitals.lua's M.live()).
   local session = emunah.gmcp and emunah.gmcp.vitals
   if session and session.live and not session.live() then return "not logged in" end

   -- DEAD: NOTHING. Every automated command is held while dead, at the user's direction --
   -- the system pauses completely and resumes on revival. (It used to be opt-in, verified
   -- only for OUTR and EAT; `alive` is still accepted and now redundant.)
   local vitals = emunah.gmcp and emunah.gmcp.vitals
   if vitals and vitals.maxhp > 0 and vitals.hp <= 0 then return "dead" end

   if detect and detect.isStunned() then return "stunned" end
   if detect and detect.isUnconscious and detect.isUnconscious() then return "unconscious" end
   -- Opt-OUT rather than opt-in, unlike `standing`: the game's own rejection
   -- says nothing works but WAKE, so the safe default is to block, and WAKE is the single
   -- caller that declares itself an exception.
   if not needs.whileAsleep and detect and detect.isAsleep() then return "asleep" end
   if needs.standing and detect and detect.isProne() then return "prone" end

   -- PARALYSED, for anything physical. The queue already holds paralysed vectors
   -- (queue.WHILE_PARALYSED, on play evidence: sips, salves and `perform hands` all
   -- refused), but attacks, movement, looting and STAND go straight through here and did
   -- not ask. The reference system's balance_controller refuses its balanceful actions on the same state.
   if needs.bal or needs.eq or needs.standing then
      if M.afflicted("paralysis") then return "paralysed" end
   end

   -- ENTANGLED, for anything that needs you upright and moving: attacking, walking,
   -- picking things up -- and STAND, which cannot declare `standing` so says `unbound`.
   -- The reference system refuses all of these while webbed, bound, roped, transfixed or impaled
   -- (balance_controller, and prone's isadvisable for STAND). Cures
   -- do not declare `standing`, so eating and applying carry on -- WRITHE is the escape and
   -- it is not gated here either.
   if needs.standing or needs.unbound then
      local afflist = emunah.curing and emunah.curing.afflist
      if afflist and afflist.writhes then
         for name in pairs(afflist.writhes) do
            if M.afflicted(name) then return "entangled" end
         end
      end
   end

   if needs.bal or needs.eq then
      if not vitals then return "no vitals yet" end
      -- Both arms, as well as the balance itself (the reference system's check_balanceful_acts).
      if detect and detect.armsBalanced and not detect.armsBalanced() then
         return "arm off balance"
      end
      if needs.bal and not vitals.bal then return "no balance" end
      if needs.eq and not vitals.eq then return "no equilibrium" end
   end

   return nil
end

--- Can a command with these requirements go out right now?
function M.can(needs)
   return M.blocked(needs) == nil
end

--- Send a command, or don't. Returns whether it actually went.
---
--- The debug line is deliberately on BOTH paths: `emunah debug` is how you tell "the bot
--- decided not to act" apart from "the bot is not running", and the second is what a silent
--- refusal looks like from the outside.
--- @return boolean sent
function M.send(command, needs)
   if type(command) ~= "string" or command == "" then return false end

   local why = M.blocked(needs)
   if why then
      -- Say it once, not once per retry. A step blocked on balance is retried every step
      -- delay for as long as the balance lasts, which put five identical "Held" lines in
      -- the log for one perfectly ordinary post-kill pause -- noise that buries the lines
      -- worth reading. Repeat only when the command or the reason actually changes.
      local held = command .. "\0" .. why
      if M.lastHeld ~= held then
         M.lastHeld = held
         emunah.log.debug("Held %q -- %s.", command, why)
      end
      return false
   end
   M.lastHeld = nil

   -- `quiet`: don't echo the command locally. For housekeeping whose output is gagged too
   -- (pipes.lua), where a lone echoed "light pipe367581" is the noise left behind.
   if needs and needs.quiet then send(command, false) else send(command) end
   -- Logged AFTER the send. With `emset debug` on this is a console print -- Qt work on the
   -- thread that has not yet handed the command to the socket -- so before the send it
   -- delayed every command by exactly the cost of describing it.
   emunah.log.debug("-> %s", command)
   return true
end

-- A new connection is a new session: whatever stopped the last one no longer applies.
emunah.event.register("sysConnectionEvent", function() M.resume() end, "act")

return M

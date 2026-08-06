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
---   alive     Refused while dead. Opt-in for the same reason `standing` is: it is known
---             for the commands that declare it, not for every command.
---
--- Requirements are a plain table so a caller states only what it actually costs:
---
---     emunah.act.send("smite 12345", { standing = true, bal = true })
---     emunah.act.send("get 999",     { standing = true })

local M = {}

--- Hold everything back until this time. See M.rateLimited().
M.backoffUntil = nil

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

--- Why a command with these requirements cannot be sent right now, or nil if it can.
--- Returned as a short reason string so callers can log something useful rather than
--- silently doing nothing.
--- @param needs table|nil { standing = bool, bal = bool, eq = bool }
--- @return string|nil reason
function M.blocked(needs)
   needs = needs or {}

   if M.backoffUntil then
      if emunah.util.now() < M.backoffUntil then return "rate limited" end
      M.backoffUntil = nil
   end

   -- Resolved at call time, not captured at load time: core/ loads before curing/ and
   -- gmcp/, and this module is reachable from both.
   local detect = emunah.curing and emunah.curing.detect

   if detect and detect.isStunned() then return "stunned" end
   -- Opt-OUT rather than opt-in, unlike `standing` and `alive`: the game's own rejection
   -- says nothing works but WAKE, so the safe default is to block, and WAKE is the single
   -- caller that declares itself an exception.
   if not needs.whileAsleep and detect and detect.isAsleep() then return "asleep" end
   if needs.standing and detect and detect.isProne() then return "prone" end

   -- Death is opt-in rather than global, deliberately. It is verified for the things that
   -- declare it (OUTR and EAT are refused while dead), and nothing else here has been
   -- checked -- a global gate would be asserting a rule about every command in the game
   -- from evidence about two of them.
   if needs.alive then
      local vitals = emunah.gmcp and emunah.gmcp.vitals
      if vitals and vitals.maxhp > 0 and vitals.hp <= 0 then return "dead" end
   end

   if needs.bal or needs.eq then
      local vitals = emunah.gmcp and emunah.gmcp.vitals
      if not vitals then return "no vitals yet" end
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

   emunah.log.debug("-> %s", command)
   send(command)
   return true
end

return M

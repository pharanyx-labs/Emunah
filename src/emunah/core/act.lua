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
---
--- HOW LONG: half a second plus the round trip. It was a flat 1.5s, and a walk lost about
--- two seconds to each "hasty" -- three in one 27-second walk through Targossas (09:06:58,
--- 09:07:11, 09:07:22 on 2026-10-16). mmp tries again 0.5s plus latency after the same line
--- (its "Too quick" trigger, `mmp.setmovetimer(0.5)`), and walked without the complaint.
function M.rateLimited(seconds)
   seconds = tonumber(seconds) or M.backoff()
   M.backoffUntil = emunah.util.now() + seconds
   emunah.log.debug("Rate limited -- holding all commands for %.2fs.", seconds)
   emunah.event.raise("rateLimited", seconds)
end

M.BACKOFF = 0.5

--- The hold after "hasty": M.BACKOFF plus the network latency.
function M.backoff()
   local latency = 0
   if type(getNetworkLatency) == "function" then
      local ok, value = pcall(getNetworkLatency)
      if ok then latency = tonumber(value) or 0 end
   end
   return M.BACKOFF + latency
end

-- TYPED COMMANDS WIN (the user, 2026-10-15). A command you type goes straight to the game,
-- and Emunah's next send could take the balance it needed first. So for a moment after
-- anything you type, everything automated holds. The reference system's override mode does the same: it
-- pauses for the network latency plus `sacdelay`, 0.5s (controllers.lua, setup.lua).
-- `queue.typedHold` sets the 0.5; 0 turns it off. Anything sent by another script counts
-- as typed too, since Mudlet cannot tell them apart.
M.TYPED_HOLD = 0.5
M.typedUntil = nil

function M.typed()
   local hold = tonumber(emunah.config.get("queue.typedHold", M.TYPED_HOLD)) or M.TYPED_HOLD
   if hold <= 0 then return end
   local latency = 0
   if type(getNetworkLatency) == "function" then
      local ok, value = pcall(getNetworkLatency)
      if ok then latency = tonumber(value) or 0 end
   end
   M.typedUntil = emunah.util.now() + hold + latency
end

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

function M.blocked(needs, spends)
   needs = needs or NONE

   if M.halted then return "halted" end

   if M.backoffUntil then
      if emunah.util.now() < M.backoffUntil then return "rate limited" end
      M.backoffUntil = nil
   end

   -- Only what wants balance or equilibrium: that is what a typed command races for.
   -- Holding everything, as the reference system does, also held Emunah's answers to what you typed --
   -- INR ALL after QUIT, a purchase's GET GOLD -- and those are yours too. `user`: your
   -- own command off the queue (queue.user), the thing being waited for.
   if M.typedUntil and (needs.bal or needs.eq) and not needs.user then
      if emunah.util.now() < M.typedUntil then return "you typed a command" end
      M.typedUntil = nil
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
      -- SENT, NOT YET ANSWERED. Something of ours is about to spend this resource, whatever
      -- Char.Vitals says meanwhile. vitals.spend() marks the flag, but a Char.Vitals the
      -- server sent before it ran the command puts the flag back: at 11:36:50.33
      -- (2026-10-04) `perform bliss` and the horse's follow order went out behind
      -- `vault horse368644`, and both came back "You must regain balance first."
      --
      -- OCCUPYING THE SLOT IS NOT SPENDING THE RESOURCE. A balance command that does not
      -- spend balance must not hold the next one that needs it. `spends` is that
      -- distinction. The in-flight slot is asked before the flag, so a send of ours that
      -- already cleared the flag still reports as in flight.
      --
      -- Login 2026-10-17 11:26:34.91: `touch mindseye` had spent equilibrium, Char.Defences
      -- confirmed the slot, and `wield mace` plus `vault pegasus510623` went out into
      -- "You must regain equilibrium first." The timer is armed at send (M.arm) and GMCP
      -- cannot overwrite it. "Equilibrium used" / "Balance used" replaces it with the real cost.
      --
      -- AHEAD OF THE SPENDER. What this prompt's line has already spent was there a moment
      -- ago. A command that needs it but spends nothing goes in front of the spender
      -- instead of waiting a whole balance (M.ahead).
      local _, ahead = M.ahead(needs, spends)
      local wantBal = needs.bal and not ahead.bal
      local wantEq = needs.eq and not ahead.eq
      local queue = emunah.queue
      if queue then
         local flight = queue.awaiting("balance")
         local spent = flight and flight.spends
         if wantBal and (spent == "bal" or spent == "both") then
            return "balance in flight"
         end
         flight = queue.awaiting("equilibrium")
         spent = flight and flight.spends
         if wantEq and (spent == "eq" or spent == "both") then
            return "equilibrium in flight"
         end
         -- Your queued one-off goes before anything automated that wants the same balance.
         if not needs.user and queue.userWaiting and queue.userWaiting(needs) then
            return "your queued command first"
         end
      end
      if wantBal and not vitals.bal then return "no balance" end
      if wantEq and not vitals.eq then return "no equilibrium" end
      local timers = emunah.timers
      if timers then
         if wantBal and not timers.ready("attack.balance") then return "no balance" end
         if wantEq and not timers.ready("cure.equilibrium") then return "no equilibrium" end
      end
   end

   return nil
end

--- Can a command with these requirements go out right now?
function M.can(needs, spends)
   return M.blocked(needs, spends) == nil
end

--- `spends` ("bal" | "eq" | "both" | nil) as a set.
local function spentSet(spends)
   return { bal = spends == "bal" or spends == "both", eq = spends == "eq" or spends == "both" }
end

--- Mark balance or equilibrium spent, in a way the next Char.Vitals cannot undo.
---
--- `field` is "bal" or "eq". vitals.spend() alone loses to a stale vitals push (see
--- M.blocked). The matching cooldown is what actually holds the next command, and the
--- game's cost line restarts it with the real duration. The length is one round trip:
--- long enough that the stale push arrives inside it, short enough that a rejection
--- (nothing was spent) does not sit out a full balance.
function M.arm(field)
   local vitals = emunah.gmcp and emunah.gmcp.vitals
   if vitals and vitals.spend then vitals.spend(field) end
   M.armedInBatch(field)
   local timer = (field == "bal") and "attack.balance"
      or (field == "eq") and "cure.equilibrium"
   if not timer or not emunah.timers then return end
   local class = emunah.class
   local fn = class and class.active and class.active.inflightGuard
   local guard = 1.0
   if type(fn) == "function" then
      local ok, value = pcall(fn)
      value = ok and tonumber(value)
      if value and value > 0 then guard = value end
   end
   emunah.timers.start(timer, guard)
end

-- ---------------------------------------------------------------------------
-- ONE LINE PER PROMPT
-- ---------------------------------------------------------------------------
--
-- What a prompt decides goes out together. The reference system collects every command of a
-- prompt and sends them at the end of it as one line, joined by the IN-GAME command
-- separator (its `commandseparator`: "Will use | as the in-game command separator."), ten
-- to a line and never over 2048 characters. Here the batch is open from the balance changes
-- of a Char.Vitals to the end of its tick (gmcp/vitals.lua), and around every timer that
-- ticks (core/timers.lua) and every confirmation that lapses (core/queue.lua), so the
-- cures, keep-up, the attack and the walk of one moment leave in one send(), in the order
-- they were decided.
--
-- THE GAME'S SEPARATOR, NOT MUDLET'S. This used to join with Mudlet's `;;`, and Mudlet
-- splits that again before anything leaves ("Send honours command separator defined within
-- Mudlet settings.", its documentation of send()), so the game still received one line per
-- command and the join saved nothing but send() calls. CONFIG SEPARATOR (the user,
-- 2026-10-16: "Your command separator is now: |") makes the GAME split: one line goes out
-- and the server runs every command in it. core/separator.lua learns it from the game,
-- each session, and until the game has said what it is, every command goes on a line of its
-- own -- a guessed separator the game does not have would turn "eat kelp|apply mending"
-- into one command it cannot run.
--
-- M.JOIN is how Emunah writes two commands as one when it composes them (`outr kelp;;eat
-- kelp`, a batch of restock trips). It never reaches the game: M.send() splits at it, and
-- each part goes out as a command of its own, joined again with the game's separator or not
-- at all. So nothing depends on what Mudlet's own separator happens to be set to.
--
-- NOTHING ABOUT BALANCE CHANGES. Every command in a batch passed M.blocked() when it was
-- added, and whatever it spends was marked spent then -- the in-flight guard M.arm starts,
-- which a later Char.Vitals cannot clear. A later command of the same prompt that needs
-- that resource is held. A command that only needed it, or that spends a different one,
-- is not. A batch never holds two commands that spend one balance; the separator only
-- removes the gaps between commands that could all go anyway.

--- How Emunah writes several commands as one. Split again before anything is sent.
M.JOIN = ";;"

--- The joiner for composing chained commands, or "" when chaining is off (`queue.chain`).
--- Callers test it against "" to decide whether two commands may go as one.
function M.separator()
   if emunah.config.get("queue.chain", true) == false then return "" end
   return M.JOIN
end

--- The game's own command separator, when it has confirmed one this session and chaining
--- is on; nil otherwise, and then every command goes on a line of its own.
function M.gameSeparator()
   if emunah.config.get("queue.chain", true) == false then return nil end
   local separator = emunah.separator
   return separator and separator.get() or nil
end

--- The most commands joined into one line: ten, as the reference system joins them.
M.BATCH_MAX = 10

--- The longest line joined: the reference system's `achaea_command_max_length` is 2048.
M.LINE_MAX = 2000

local batch, depth = nil, 0

-- The open batch's bookkeeping for M.ahead: which entry first spent each balance, and
-- where the last command collected went.
local armedAt, lastAt = {}, nil

--- Where a command that needs `needs` and spends `spends` has to go in the open batch, so
--- that it reaches the game before whatever this batch already spent that it needs.
---
--- A prompt's line runs in order. `wield mace` and `light pipes` need balance and
--- equilibrium and spend neither, so in front of `hypersight on` they work and behind it
--- they are refused. The 2026-10-18 08:24 login held `wield mace` seven seconds and the
--- pipes ten for that reason: keep-up had spent equilibrium earlier in the same tick.
---
--- @return number|nil the batch index to insert at, or nil when no balance this needs was
---   spent by the batch (it goes at the end, as ever)
--- @return table the fields that position makes available: { bal = bool, eq = bool }
function M.ahead(needs, spends)
   if not batch or not needs then return nil, NONE end
   local spent = spentSet(spends)
   local at, fields = nil, {}
   for _, field in ipairs({ "bal", "eq" }) do
      local index = armedAt[field]
      if needs[field] and not spent[field] and index then
         fields[field] = true
         if not at or index < at then at = index end
      end
   end
   if not at then return nil, NONE end
   -- It must not spend anything a command it jumps needs: `vault` (spends balance) in
   -- front of `touch cloak` (needs it) would refuse the cloak.
   for index = at, #batch do
      local entry = batch[index]
      for field, yes in pairs(spent) do
         if yes and entry.needs and entry.needs[field] then return nil, NONE end
      end
   end
   return at, fields
end

--- The command just collected spent `field`. M.arm calls it.
function M.armedInBatch(field)
   if not batch or not lastAt then return end
   if not armedAt[field] or lastAt < armedAt[field] then armedAt[field] = lastAt end
end

local function transmit(text, echo)
   -- `sending` tells core/outgoing.lua these are ours, not typed: Mudlet raises
   -- sysDataSendRequest from inside send(), before it returns.
   M.sending = true
   if echo then send(text) else send(text, false) end
   M.sending = false
end

--- Send what a batch collected: joined with the game's separator, ten at a time, never
--- mixing an echoed command with a quiet one (`quiet` housekeeping stays off the screen),
--- and in the order it was decided. With no separator, one line per command.
local function flush(pending)
   local sep = M.gameSeparator()
   if not sep then
      for _, entry in ipairs(pending) do transmit(entry.command, entry.echo) end
      return
   end
   local chunk, echo, length = {}, nil, 0
   for _, entry in ipairs(pending) do
      if #chunk > 0 and (entry.echo ~= echo or #chunk >= M.BATCH_MAX
                         or length + #sep + #entry.command > M.LINE_MAX) then
         transmit(table.concat(chunk, sep), echo)
         chunk, length = {}, 0
      end
      echo = entry.echo
      length = length + (#chunk > 0 and #sep or 0) + #entry.command
      chunk[#chunk + 1] = entry.command
   end
   if #chunk > 0 then transmit(table.concat(chunk, sep), echo) end
end

--- Add a command to `list`, one entry per command written into it with M.JOIN, at `at`
--- (the end when nil).
local function collect(list, command, echo, needs, at)
   local parts = {}
   if not command:find(M.JOIN, 1, true) then
      parts[1] = command
   else
      local from = 1
      while true do
         local stop = command:find(M.JOIN, from, true)
         local part = command:sub(from, stop and stop - 1 or nil):match("^%s*(.-)%s*$")
         if part ~= "" then parts[#parts + 1] = part end
         if not stop then break end
         from = stop + #M.JOIN
      end
   end
   at = at or (#list + 1)
   for offset, part in ipairs(parts) do
      table.insert(list, at + offset - 1, { command = part, echo = echo, needs = needs })
   end
   if list == batch and #parts > 0 then
      for field, index in pairs(armedAt) do
         if index >= at then armedAt[field] = index + #parts end
      end
      lastAt = at + #parts - 1
   end
end

--- Open a batch: until the matching M.endBatch(), M.send() collects instead of sending.
function M.beginBatch()
   depth = depth + 1
   batch = batch or {}
end

--- Close a batch, and send what it collected once the outermost one closes.
function M.endBatch()
   depth = depth - 1
   if depth > 0 then return end
   depth = 0
   local pending = batch
   batch = nil
   armedAt, lastAt = {}, nil
   if pending and #pending > 0 then flush(pending) end
end

--- Run `fn` inside a batch. The batch is sent even if `fn` fails, and the error rethrown.
function M.batched(fn, ...)
   M.beginBatch()
   local ok, err = pcall(fn, ...)
   M.endBatch()
   if not ok then error(err, 0) end
end

--- Is a batch open? For anything that has to know whether its send has left yet.
function M.batching()
   return batch ~= nil
end

--- command -> the reason it was last held, until it goes. See M.send.
M.held, M.heldCount = {}, 0

--- The most held commands remembered before the list starts again.
M.HELD_MAX = 64

--- Send a command, or don't. Returns whether it actually went.
---
--- The debug line is deliberately on BOTH paths: `emunah debug` is how you tell "the bot
--- decided not to act" apart from "the bot is not running", and the second is what a silent
--- refusal looks like from the outside.
--- @return boolean sent
--- @param spends string|nil "bal" | "eq" | "both": what the command uses up, as against what
---   it only needs. See M.ahead.
function M.send(command, needs, spends)
   if type(command) ~= "string" or command == "" then return false end

   local why = M.blocked(needs, spends)
   if why then
      -- Say it once, not once per retry. A step blocked on balance is retried every step
      -- delay for as long as the balance lasts, which put five identical "Held" lines in
      -- the log for one perfectly ordinary post-kill pause -- noise that buries the lines
      -- worth reading. Repeat only when that command's reason actually changes.
      --
      -- PER COMMAND. One remembered line let three held watches and a vault take turns
      -- clearing it, and all four printed on every prompt of an equilibrium (2026-10-23
      -- 10:00:48: forty-odd lines for one wait).
      if M.held[command] ~= why then
         -- Bounded: a command held and never sent (a target that left) stays here.
         M.heldCount = M.heldCount + (M.held[command] == nil and 1 or 0)
         if M.heldCount > M.HELD_MAX then M.held, M.heldCount = {}, 1 end
         M.held[command] = why
         emunah.log.debug("Held %q -- %s.", command, why)
      end
      return false
   end
   if M.held[command] ~= nil then
      M.held[command] = nil
      M.heldCount = M.heldCount - 1
   end

   -- `quiet`: don't echo the command locally. For housekeeping whose output is gagged too
   -- (pipes.lua), where a lone echoed "light pipe367581" is the noise left behind.
   local echo = not (needs and needs.quiet)
   if batch then
      collect(batch, command, echo, needs, (M.ahead(needs, spends)))
   elseif command:find(M.JOIN, 1, true) then
      local parts = {}
      collect(parts, command, echo, needs)
      flush(parts)
   else
      transmit(command, echo)
   end
   -- Logged AFTER the send. With `emset debug` on this is a console print -- Qt work on the
   -- thread that has not yet handed the command to the socket -- so before the send it
   -- delayed every command by exactly the cost of describing it.
   emunah.log.debug("-> %s", command)
   return true
end

emunah.event.register("emunah.sent", function(_, _, typed)
   if typed then M.typed() end
end, "act")

-- A new connection is a new session: whatever stopped the last one no longer applies.
emunah.event.register("sysConnectionEvent", function() M.resume() end, "act")

return M

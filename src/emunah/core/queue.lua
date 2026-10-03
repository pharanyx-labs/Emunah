--- Balance-gated action queue.
---
--- Achaea does not have one queue, it has several independent ones. Eating a herb, applying
--- a salve and smoking a pipe consume three different balances and can all happen in the
--- same second; two herbs cannot. So this is not a single FIFO -- it is one slot per
--- "vector", where a vector is any resource that gates an action.
---
--- Each slot holds at most one command. Pushing a higher-priority action onto an occupied
--- slot replaces it, which is what you want in combat: if paralysis lands while a queued
--- cure for anorexia is still waiting on herb balance, the paralysis cure should take that
--- balance instead. Lower-priority pushes onto an occupied slot are dropped rather than
--- stacked, because a backlog of stale cures is worse than none.

local M = {}

local log = emunah.log

--- Known vectors. `free` is for actions with no cost at all.
--- `rift` is not a balance at all -- OUTR costs nothing. It is a vector so that one pull
--- can be in flight at a time: the item does not appear in Char.Items instantly, and
--- without a slot to hold, every tick in that window pulls another one.
M.VECTORS = {
   "free", "balance", "equilibrium",
   "herb", "salve", "elixir", "purgative", "smoke", "focus", "tree", "writhe", "special",
   "moss", "rift",
}

local slots     = {}   -- vector -> pending action
local inFlight  = {}   -- vector -> action awaiting confirmation

--- Can this vector be used right now? Delegates to the capability layer, which knows
--- about both GMCP-reported balances (bal/eq) and timed ones (herb/salve/...).
--- Resolved at call time rather than load time because have/ loads after core/.
local function vectorReady(vector)
   if inFlight[vector] then return false end
   local have = emunah.have
   if have and have.balance then return have.balance(vector) end
   -- Before the capability layer exists, only untimed actions are safe to send.
   return vector == "free"
end

--- Queue an action.
--- @param vector string one of M.VECTORS
--- @param command string the game command to send
--- @param opts table|nil { priority = number (lower wins, default 100),
---                         tag = string (what this is for, e.g. an affliction name),
---                         confirm = number (seconds to wait for confirmation),
---                         needs = table passed to act.blocked(), e.g. { standing = true },
---                         valid = function -> boolean, re-checked at send time,
---                         onSent = function, onTimeout = function }
--- @return boolean queued
function M.push(vector, command, opts)
   opts = opts or {}
   if type(command) ~= "string" or command == "" then return false end

   local existing = slots[vector]
   local priority = opts.priority or 100

   if existing and existing.priority <= priority then
      -- Only worth saying when something DIFFERENT lost the slot. The engine re-pushes the
      -- same cure on every tick while the condition holds, so logging each identical
      -- rejection produced dozens of "keeping drink health over drink health" lines in one
      -- fight -- noise that buried every line worth reading.
      if existing.command ~= command then
         log.debug("Queue %s: keeping %q (p%d) over %q (p%d)",
            vector, existing.command, existing.priority, command, priority)
      end
      return false
   end

   if existing then
      log.debug("Queue %s: %q (p%d) pre-empts %q (p%d)",
         vector, command, priority, existing.command, existing.priority)
   end

   slots[vector] = {
      vector    = vector,
      command   = command,
      priority  = priority,
      tag       = opts.tag,
      confirm   = opts.confirm,
      needs     = opts.needs,
      valid     = opts.valid,
      onSent    = opts.onSent,
      onTimeout = opts.onTimeout,
      queuedAt  = emunah.util.now(),
   }
   return true
end

--- Send whatever is pending on any vector that is currently free.
--- Called once per tick (per Char.Vitals update), never per line.
---
--- Every send goes through core/act.lua, the one place that knows when the game will refuse
--- a command outright. Two layers, and they answer different questions: vectorReady() is
--- "has THIS resource come back", act is "can the character act at all right now".
---
--- Note what cures deliberately do NOT declare: a standing requirement. An earlier version
--- blocked the whole flush while prone, which is both wrong (eating a herb and drinking an
--- elixir work perfectly well lying down) and actively dangerous -- being knocked flat in a
--- fight is precisely when refusing to heal gets the character killed. Only actions that
--- genuinely need you upright pass `needs = { standing = true }` to push().
--- @return number actions sent
--- Vectors that still work while paralysed.
---
--- PARALYSIS BLOCKS ALMOST EVERYTHING, and the game says so three different ways:
---
---   "Your state of paralysis prevents you from doing that."   (drink health)
---   "You are paralysed and cannot do that."                   (drink health)
---   "Frustratingly, your body won't respond to your call to action."  (perform hands)
---
--- Eating is the exception, and it has to be: bloodroot is what cures paralysis, so a rule
--- that blocked everything would lock the character out of its own escape. Observed in the
--- arena as sips, hands and salves going out repeatedly into rejections while the one
--- command that would have worked waited behind them.
---
--- `tree` is NOT here, and now on evidence rather than its absence. Confirmed live
--- 2026-08-03 16:14:25.08: `touch tree` sent while paralysed (and anorexic, per the DIAG at
--- 16:14:13.90 moments earlier) came back "Frustratingly, your body won't respond to your
--- call to action." -- the exact paralysis-refusal text already registered in
--- detect/patterns.lua. So touching the tattoo is blocked the same as everything else;
--- letting it through would only spend the round trip queueTree() is trying to avoid in the
--- first place, on the one occasion it matters most (nothing else curable, tree the last
--- resort).
-- `rift` too: OUTR is how the bloodroot that cures paralysis gets into your hand. Held,
-- it deadlocked: 14:26:06-14:27:20 on 2026-09-28, paralysed with bloodroot only in the
-- rift, nothing went out for 74 seconds until a Bard's sonata cured it. The reference
-- system's `canoutr` (setup.lua) is false only for webbed/bound/transfixed/roped/impaled
-- or both arms crippled -- never paralysis -- and its herb gate is `sys.canoutr or
-- can_eat_for`. Those real blockers are in afflist.blocks and have.vectorBlocked().
M.WHILE_PARALYSED = {
   herb = true, moss = true, free = true, writhe = true, rift = true,
}

local function paralysed()
   local engine = emunah.curing and emunah.curing.engine
   if engine and engine.has and engine.has("paralysis") then return true end
   local afflictions = emunah.gmcp and emunah.gmcp.afflictions
   return afflictions and afflictions.has("paralysis") or false
end

--- Send what is pending on one vector, if it can go. The body of flush(), for one slot.
--- @return boolean sent
local function dispatch(vector)
   local action = slots[vector]

   -- STILL WANTED? A queued action waits for its vector, and a contested vector can
   -- take seconds -- `perform hands` needs equilibrium, which attacking and penitence
   -- also spend. In that gap the reason for the action can simply stop being true:
   -- health recovers, the affliction is cured by another vector, the defence comes back.
   -- Sending it anyway spends a real balance on a condition that no longer exists, and
   -- the observed case was `perform hands` going out at full health because it had been
   -- queued at 30%.
   if action and action.valid and not action.valid() then
      log.debug("Dropping [%s] %s -- no longer needed.", vector, action.command)
      slots[vector] = nil
      action = nil
   end

   -- BLOCKED SINCE IT WAS QUEUED? Held, not dropped: the block usually clears (an
   -- epidermal cures anorexia) and the cure is still wanted when it does. See
   -- have.vectorBlocked() for why this is re-asked here rather than trusted from push.
   local have = emunah.have
   if action and have and have.vectorBlocked then
      local why = have.vectorBlocked(vector)
      if why then
         if action.heldFor ~= why then
            action.heldFor = why
            log.debug("Holding [%s] %s -- %s.", vector, action.command, why)
         end
         action = nil
      end
   end

   -- act.send() returning false means the game would refuse it for a reason unrelated to
   -- this vector (see act). The action stays queued rather than being dropped, so the
   -- next tick tries again -- which is why this is one condition and not an early exit.
   if action and vectorReady(vector) and emunah.act.send(action.command, action.needs) then
      slots[vector] = nil
      action.sentAt = emunah.util.now()

      log.debug("Sent [%s] %s%s", vector, action.command,
         action.tag and (" (" .. action.tag .. ")") or "")

      if action.confirm and action.confirm > 0 then
         inFlight[vector] = action
         -- Re-arm if the game never confirms. A cure that was swallowed by a
         -- rejection message would otherwise wedge the vector forever.
         action.timeoutId = tempTimer(action.confirm, function()
            if inFlight[vector] ~= action then return end
            inFlight[vector] = nil
            log.debug("No confirmation for [%s] %s -- re-arming.", vector, action.command)
            if action.onTimeout then
               local ok, err = pcall(action.onTimeout, action)
               if not ok then log.error("Queue timeout callback failed: %s", tostring(err)) end
            end
            -- The vector is free again, and nothing else is going to say so: a confirmation
            -- that never came is a quiet moment by definition. Without this the next cure on
            -- it waited for whatever unrelated prompt arrived next -- in test/latency.lua's
            -- scripted fight, a salve the game would have taken at 2.2s had not gone out by
            -- 8.2s.
            emunah.event.raise("queue.timeout", vector)
         end)
      end

      if action.onSent then
         local ok, err = pcall(action.onSent, action)
         if not ok then log.error("Queue onSent callback failed: %s", tostring(err)) end
      end
      return true
   end
   return false
end

function M.flush()
   -- Cheap early out: stun refuses everything, so there is no point walking the vectors.
   if not emunah.act.can() then return 0 end

   local locked = paralysed()

   local sent = 0
   for _, vector in ipairs(M.VECTORS) do
      -- Paralysed: skip what the game will refuse. The refusal costs a round trip in a fight
      -- where the eat that fixes this is waiting behind it.
      if slots[vector] and not (locked and not M.WHILE_PARALYSED[vector]) then
         if dispatch(vector) then sent = sent + 1 end
      end
   end
   return sent
end

--- Send what is pending on ONE vector, now, under the same rules as flush().
---
--- For the curing engine, which resolves vector by vector and sends each cure the moment it
--- is chosen. Pushing every vector and flushing once at the end let two vectors choose the
--- SAME affliction in one tick -- `apply epidermal to body` and `focus` both went out for one
--- anorexia, spending a focus balance on something the salve was already curing. The guard
--- that stops that (engine's CURE_GUARD) is armed on send, so the send has to come before
--- the next vector is resolved. svof gets the same effect from `doingaction`.
--- @return number actions sent (0 or 1)
---
--- Cheapest test first. The engine calls this for every cure vector on every tick, and in a
--- lock most of them are waiting on their balance -- so "is this vector even ready" settles
--- most calls before act.can() walks stun, sleep, death and the rest. A slot skipped here
--- is re-examined, valid() and all, by the next flush.
function M.flushVector(vector)
   if not slots[vector] then return 0 end
   if not vectorReady(vector) then return 0 end
   if not M.WHILE_PARALYSED[vector] and paralysed() then return 0 end
   if not emunah.act.can() then return 0 end
   return dispatch(vector) and 1 or 0
end

--- Mark the in-flight action on a vector as confirmed by the game.
--- @return table|nil the action that was confirmed
function M.confirm(vector)
   local action = inFlight[vector]
   if not action then return nil end
   if action.timeoutId then killTimer(action.timeoutId) end
   inFlight[vector] = nil
   return action
end

--- What is waiting on a vector, if anything.
function M.pending(vector)
   return slots[vector]
end

--- What has been sent on a vector but not yet confirmed.
function M.awaiting(vector)
   return inFlight[vector]
end

--- Drop the pending action on one vector, or all of them.
function M.clear(vector)
   if vector then
      slots[vector] = nil
      return
   end
   slots = {}
end

--- Drop everything, pending and in-flight. Used on disconnect and when curing is
--- switched off mid-fight -- leaving in-flight entries around would block the vectors
--- when curing is switched back on.
function M.reset()
   for _, action in pairs(inFlight) do
      if action.timeoutId then killTimer(action.timeoutId) end
   end
   slots, inFlight = {}, {}
end

--- Snapshot for the UI and for `emunah debug queue`.
function M.snapshot()
   local out = {}
   for _, vector in ipairs(M.VECTORS) do
      if slots[vector] or inFlight[vector] then
         out[vector] = {
            pending  = slots[vector] and slots[vector].command,
            inFlight = inFlight[vector] and inFlight[vector].command,
         }
      end
   end
   return out
end

emunah.event.register("sysDisconnectionEvent", function()
   M.reset()
end, "queue")

-- Death: drop everything queued or in flight. act.blocked() already holds every send while
-- dead, but a cure chosen for the body you just lost must not fire the moment you revive.
-- Curing itself resumes on revival: it re-reads the state it finds then.
emunah.event.register("emunah.character.died", function()
   M.reset()
   log.info("Dead -- Emunah is paused. Nothing will be sent until you are alive again.")
end, "queue")

emunah.event.register("emunah.character.revived", function()
   log.info("Alive again -- curing resumes. Bashing and walking stay off until you restart them.")
end, "queue")

return M

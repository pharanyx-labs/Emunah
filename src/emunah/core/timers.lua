--- Named cooldowns.
---
--- Every balance in Achaea is a cooldown: you eat a herb, herb balance is gone for a
--- couple of seconds, then it returns. Some of those returns are announced by the game
--- (balance and equilibrium arrive via Char.Vitals), and some are only observable by
--- timing (herb, salve, elixir, smoke, focus). This module handles the timed kind and
--- gives the UI something to render, while gmcp/vitals.lua handles the announced kind.
---
--- Timer ids live on emunah._timers so a reload can cancel the previous generation
--- rather than leaving orphaned tempTimers firing into a dead namespace.

local M = {}

local log = emunah.log

local function registry()
   emunah._timers = emunah._timers or {}
   return emunah._timers
end

--- Start (or restart) a named cooldown.
--- @param name string e.g. "herb", "salve", "smoke"
--- @param duration number seconds
--- @param onExpire function|nil called when it lapses
--- @return boolean
function M.start(name, duration, onExpire)
   duration = tonumber(duration)
   if not name or not duration or duration <= 0 then return false end

   M.stop(name)

   local reg = registry()
   local entry = { name = name, duration = duration, startedAt = emunah.util.now(),
                   onExpire = onExpire }

   entry.id = tempTimer(duration, function()
      -- Guard against a timer outliving the generation that created it: if the registry
      -- entry has been replaced, this callback belongs to a stale timer.
      local current = registry()[name]
      if current ~= entry then return end
      registry()[name] = nil
      if onExpire then
         local ok, err = pcall(onExpire, name)
         if not ok then log.error("Timer callback for %q failed: %s", name, tostring(err)) end
      end
      emunah.event.raise("timer.expired", name)
   end)

   reg[name] = entry
   emunah.event.raise("timer.started", name, duration)
   return true
end

--- Cancel a cooldown early -- used when the game tells us a balance is back sooner than
--- our estimate, which is the normal case for anything with a speed modifier.
function M.stop(name)
   local reg = registry()
   local entry = reg[name]
   if not entry then return false end
   if entry.id then killTimer(entry.id) end
   reg[name] = nil
   return true
end

--- How long past its end a cooldown may still be sitting in the registry before it is
--- treated as orphaned. Mudlet runs a due tempTimer on its next event-loop pass, so a live
--- one is never this late.
M.ORPHAN_GRACE = 0.5

--- A cooldown whose time is up is OVER, whether or not its tempTimer callback ran.
---
--- Asking only "is the entry there?" made a lost callback permanent. Live, 15:20:28 on
--- 2026-09-28: smoke balance read down with "cure.smoke" at 0.0s remaining, and `smoke
--- elm` for earworm sat queued behind it for as long as anyone watched -- the timer had
--- ended, its entry had not. How the callback was lost is not yet known (a stale
--- killTimer on a reused id is the prime suspect), so this does not guess at it: it
--- expires the orphan exactly as the callback would have, and says so, so the next one
--- names the timer involved.
local function expireIfLapsed(name)
   local reg = registry()
   local entry = reg[name]
   if not entry then return nil end
   if emunah.util.now() - entry.startedAt < entry.duration + M.ORPHAN_GRACE then return entry end
   reg[name] = nil
   log.warn("Timer %q outlived its callback by %.1fs -- expiring it now.", name,
      emunah.util.now() - entry.startedAt - entry.duration)
   if entry.onExpire then
      local ok, err = pcall(entry.onExpire, name)
      if not ok then log.error("Timer callback for %q failed: %s", name, tostring(err)) end
   end
   emunah.event.raise("timer.expired", name)
   return nil
end

--- Is this cooldown currently running?
function M.active(name)
   return expireIfLapsed(name) ~= nil
end

--- Inverse of active(): the cooldown is available for use.
function M.ready(name)
   return expireIfLapsed(name) == nil
end

--- Seconds left, or 0 when not running.
function M.remaining(name)
   local entry = registry()[name]
   if not entry then return 0 end
   local left = entry.duration - (emunah.util.now() - entry.startedAt)
   return left > 0 and left or 0
end

--- Fraction elapsed, 0..1. Feeds TimerGauge in the UI.
function M.progress(name)
   local entry = registry()[name]
   if not entry or entry.duration <= 0 then return 1 end
   local elapsed = (emunah.util.now() - entry.startedAt) / entry.duration
   if elapsed < 0 then return 0 end
   if elapsed > 1 then return 1 end
   return elapsed
end

--- Cancel everything. Called on reload and on disconnect, since balances are meaningless
--- across a session boundary.
function M.stopAll()
   local n = 0
   for name in pairs(registry()) do
      if M.stop(name) then n = n + 1 end
   end
   emunah._timers = {}
   return n
end

--- Snapshot of running cooldowns, for the UI and for `emunah debug timers`.
function M.list()
   local out = {}
   for name in pairs(registry()) do
      out[name] = M.remaining(name)
   end
   return out
end

emunah.event.register("sysDisconnectionEvent", function()
   M.stopAll()
end, "timers")

return M

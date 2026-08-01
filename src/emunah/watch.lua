--- Checks run on every Char.* event.
---
--- WHY ONE MODULE
--- --------------
--- Safety used to be one flat health percentage, checked separately in bashing, pvp and the
--- walker, each with its own copy and its own threshold. That is three places to change
--- when a rule changes, and every rule that was not health simply did not exist: endurance,
--- willpower, mana, the class resource and the rate of damage were all tracked and none of
--- them was ever read.
---
--- So: the character's state changes only when the game says so, and it says so on
--- Char.Vitals (every prompt) and Char.Status. Both are checked here, once, and consumers
--- ask `watch.unsafe()` rather than each inventing the question.
---
--- STOPPING VERSUS OBSERVING
--- -------------------------
--- Two kinds of check, deliberately separated:
---
---   unsafe()  -- a reason to stop the loops NOW, as a string, or nil. Only conditions
---                where continuing is actively harmful.
---   observe() -- notices worth reporting or reacting to, which never stop anything.
---
--- Conflating them is how an automated system either dies quietly or refuses to act for a
--- reason nobody can see.

local M = {}

local log   = emunah.log
local event = emunah.event

--- Defaults, all overridable with `emunah set watch.<key> <value>`. Percentages of max.
M.config = {
   -- Losing this much of your health bar within damageWindow ticks stops the loops. A
   -- static floor reacts too late: at 950 max health and 100 per hit, "stop below 40%"
   -- means noticing after the fourth hit, with two hits left before death. Rate is the
   -- signal that something is going wrong faster than the floor can catch.
   damageSpike  = 25,
   -- The window has to be longer than one heal cycle, or a single hit trips it even when
   -- the elixir puts the health straight back. Confirmed live: a goat hitting for ~25% per
   -- ram tripped "26% in 4 ticks" during a fight that was being sustained perfectly well --
   -- health oscillated 55-95% for half a minute afterwards. A burst followed by a full heal
   -- is not a decline, and a window that cannot see the heal cannot tell the difference.
   damageWindow = 10,
   -- ...but only once there is not much bar left to absorb it. A rate on its own is not
   -- danger: a denizen hitting for a quarter of your health trips a 25% rate on ONE normal
   -- exchange, and stopping there means never fighting anything that hits hard. Confirmed
   -- live -- the loop stopped at 75% health, mid-fight, with plenty of room. What is
   -- actually dangerous is losing that fast while ALREADY low, because that is the shape of
   -- a fight you do not get to finish.
   damageSpikeBelow = 60,

   -- Endurance and willpower are drained by fighting and recover slowly. Hitting zero is
   -- not fatal but it is a long, helpless wait, so stop while there is still some left.
   endurance = 15,
   willpower = 15,

   -- Separate from the curing engine's healing threshold, which decides when to drink.
   -- This decides when to stop fighting.
   mana = 10,

   -- The class resource (Devotion for Priest, Kai for Monk...). Attacking without it
   -- spends balance for a weak or failed attack.
   resource = 10,

   -- Below this, stop regardless of anything else. The spike check is ADVISORY while
   -- something is actively hitting us -- see M.unsafe() -- so this is the floor that still
   -- applies when it is suppressed.
   critical = 30,
}

local function setting(key)
   local value = emunah.config.get("watch." .. key)
   if value == nil then return M.config[key] end
   return tonumber(value) or M.config[key]
end

--- Recent health samples, newest last. Bounded by damageWindow.
M.samples = {}

--- Charstat names we have already reported, so the discovery warning fires once each.
M.seenStats = {}

-- ---------------------------------------------------------------------------
-- stopping conditions
-- ---------------------------------------------------------------------------

--- How much health has been lost across the sample window, as a percentage of max.
function M.damageRate()
   local first, last = M.samples[1], M.samples[#M.samples]
   if not (first and last) or #M.samples < 2 then return 0 end
   local lost = first - last
   return lost > 0 and lost or 0
end

--- Is something actually fighting us? Attackable creatures in the room, which is as close
--- as GMCP gets to "engaged" -- there is no message for it.
function M.inCombat()
   local denizens = emunah.denizens
   return denizens ~= nil and #denizens.here() > 0
end

--- A reason to stop, or nil. Ordered most-serious first so the reported reason is the
--- most useful one when several are true at once.
--- @return string|nil
function M.unsafe()
   local vitals = emunah.gmcp.vitals
   if not vitals then return nil end

   -- Dead. Nothing below this matters, and every loop should already be stopping.
   if vitals.maxhp > 0 and vitals.hp <= 0 then return "you are dead" end

   local critical = tonumber(setting("critical")) or 0
   if critical > 0 and vitals.percent.hp < critical then
      return ("health critical (%d%%)"):format(vitals.percent.hp)
   end

   -- THE SPIKE IS ADVISORY WHILE SOMETHING IS HITTING US.
   --
   -- Stopping does not make an aggressive denizen stop. Confirmed live: the check fired
   -- mid-fight against a goat, the loops halted, and the goat carried on ramming for ~270 a
   -- time -- so the character stood there tanking and drinking, neither fighting nor
   -- leaving, which is strictly worse than finishing the kill. The fight was being
   -- sustained comfortably the whole while.
   --
   -- So in combat the spike is not a reason to stop; `critical` above is the floor that
   -- still applies. Out of combat it stands, because a drain nothing is fighting back
   -- against -- bleeding, poison, a room effect -- is exactly the case where stopping is
   -- the whole remedy.
   if not M.inCombat() then
      local spike  = tonumber(setting("damageSpike")) or 0
      local buffer = tonumber(setting("damageSpikeBelow")) or 0
      if spike > 0 and M.damageRate() >= spike and vitals.percent.hp < buffer then
         return ("losing health fast (%.0f%% in %d ticks, at %d%%)"):format(
            M.damageRate(), #M.samples, vitals.percent.hp)
      end
   end

   -- Each is skipped unless the game has actually told us a maximum. A resource we have no
   -- reading for is unknown, not empty -- treating it as empty would stop every loop for
   -- "endurance below 15%" in the window before the first complete Char.Vitals arrives, or
   -- forever on a class or client that never reports it.
   local checks = {
      { key = "mana",      value = vitals.mp, max = vitals.maxmp, label = "mana" },
      { key = "endurance", value = vitals.ep, max = vitals.maxep, label = "endurance" },
      { key = "willpower", value = vitals.wp, max = vitals.maxwp, label = "willpower" },
   }
   for _, check in ipairs(checks) do
      local threshold = tonumber(setting(check.key)) or 0
      if threshold > 0 and (check.max or 0) > 0 then
         local pct = check.value / check.max * 100
         if pct < threshold then
            return ("%s below %d%%"):format(check.label, threshold)
         end
      end
   end

   local resource, name = M.resource()
   local floor = tonumber(setting("resource")) or 0
   if resource and floor > 0 and resource < floor then
      return ("%s below %d%%"):format(tostring(name):lower(), floor)
   end

   return nil
end

--- The class's own resource as a percentage, plus its name, or nil when the class does not
--- report one. Read from charstats rather than hardcoded, so a new class needs no change
--- here -- Priest reports Devotion, Monk reports Kai, and both arrive the same way.
function M.resource()
   local class = emunah.class
   if not (class and class.active and class.active.RESOURCE) then return nil end
   local name = class.active.RESOURCE
   local vitals = emunah.gmcp.vitals
   local value = vitals and vitals.stat(name)
   if type(value) ~= "number" then return nil end
   return value, name
end

-- ---------------------------------------------------------------------------
-- observations
-- ---------------------------------------------------------------------------

--- Non-stopping notices. Each is cheap and fires at most once per change.
local function observe()
   local vitals = emunah.gmcp.vitals
   if not vitals then return end

   -- Bleeding, from the numeric charstat rather than the per-tick damage message. The
   -- number is the reliable source: the message only appears when you actually lose health
   -- to it, so it says nothing about whether the bleed is getting worse.
   local bleed = vitals.bleeding()
   if bleed > 0 and bleed ~= M.lastBleed then
      log.debug("Bleeding %d.", bleed)
      event.raise("bleeding", bleed)
   end
   M.lastBleed = bleed

   -- Charstat discovery. Nothing in this project knows what a given class reports until
   -- someone plays it, and guessing is how the rest of this codebase went wrong -- so say
   -- what actually arrived, once, and let it be written down.
   for name in pairs(vitals.stats or {}) do
      if not M.seenStats[name] then
         M.seenStats[name] = true
         log.debug("New charstat: %s = %s", name, tostring(vitals.stats[name]))
      end
   end
end

--- Char.Status.target is NOT a live view of what we are attacking, so nothing compares it.
---
--- Two live observations settle it. It read "21240" while we attacked replica "302211", and
--- later "110208" -- the goat from the PREVIOUS fight, several kills earlier -- while we
--- attacked "572474". Char.Status is not re-sent on room changes or on retargeting, so the
--- field is simply stale, and a check against it produced nothing but noise on every tick.
---
--- IRE.Target.Set and IRE.Target.Info are the trustworthy pair; the prompt agreed with them
--- both times. See docs/game/gmcp.md.

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

--- Record a health sample and trim the window.
local function sample()
   local vitals = emunah.gmcp.vitals
   if not vitals or vitals.maxhp <= 0 then return end
   M.samples[#M.samples + 1] = vitals.percent.hp
   local window = math.max(2, tonumber(setting("damageWindow")) or 4)
   while #M.samples > window do table.remove(M.samples, 1) end
end

--- Forget the window. Called when a fight starts or ends, so damage from the previous
--- engagement cannot stop the next one before it begins.
function M.reset()
   M.samples = {}
   M.lastBleed = nil
end

event.register("emunah.tick", function()
   sample()
   observe()
end, "watch")

event.register("emunah.bashing.started", M.reset, "watch")
event.register("emunah.pvp.started", M.reset, "watch")
event.register("sysDisconnectionEvent", M.reset, "watch")

return M

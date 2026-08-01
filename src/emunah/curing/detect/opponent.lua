--- Opponent affliction tracking.
---
--- The PvP counterpart to curing/engine.lua's M.tracked, but for someone else's
--- afflictions. There is no GMCP equivalent for this -- Char.Afflictions only ever reports
--- YOUR OWN state -- so everything here has to come from third-person combat text, and the
--- same discipline that governs curing/detect/patterns.lua applies: a pattern that fires on
--- the wrong line asserts an affliction on the wrong person, which is worse than not
--- knowing. Grow this from `emunah learn on` transcripts of real fights, not from memory --
--- see patterns.lua's header for the reasoning this module inherits wholesale.
---
--- This file ships with NO patterns, deliberately -- it is framework, not corpus, exactly
--- like detect/init.lua shipped before patterns.lua had anything in it. The corpus lives
--- wherever self-affliction patterns do (patterns.lua, or a sibling file), added via
--- M.add() once real third-person messages are on hand.
---
--- PATTERN SHAPE
--- -------------
--- Achaea's third-person combat messages name the actor, so a pattern here needs exactly
--- one capture group for that name -- Mudlet puts it in matches[2]:
---
---   opponent.add("paralysis", [[^(\w+) collapses, paralysed\.$]])
---
--- WHY AGE, NOT RECONCILE
--- ----------------------
--- curing/engine.lua's reconcile() works because Char.Afflictions.List is authoritative for
--- YOUR OWN state -- if the game does not mention an affliction, and the record came from
--- GMCP, it is gone. There is no equivalent feed for an opponent, so there is nothing to
--- reconcile against: an entry here can only be retracted by another trigger (if one is
--- ever written for the relevant cure-side message) or aged out by M.prune(). Callers that
--- plan around this data should treat every entry as "true as of `since`", not "true now".

local M = {}

local log   = emunah.log
local event = emunah.event

--- name (lower) -> { affliction (lower) -> since }
M.tracked = {}

--- Trigger ids live on _persist so a reload can kill the previous generation -- same
--- problem, and same fix, as curing/detect/init.lua and core/event.lua.
local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.opponentTriggers = emunah._persist.opponentTriggers or {}
   return emunah._persist.opponentTriggers
end

--- Remove every trigger this module owns.
function M.killAll()
   local reg = registry()
   local n = 0
   for _, id in ipairs(reg) do
      if killTrigger(id) then n = n + 1 end
   end
   emunah._persist.opponentTriggers = {}
   return n
end

-- ---------------------------------------------------------------------------
-- registration
-- ---------------------------------------------------------------------------

--- Register a third-person gain pattern for an affliction. The pattern's one capture group
--- must be the actor's name.
--- @param affliction string
--- @param pattern string a Mudlet-flavoured (PCRE) regex with one capture group
--- @return boolean
function M.add(affliction, pattern)
   affliction = tostring(affliction or ""):lower()
   if affliction == "" or type(pattern) ~= "string" then return false end

   local id = tempRegexTrigger(pattern, function()
      local name = matches and matches[2]
      if type(name) ~= "string" or name == "" then return end
      M.assert(name, affliction)
   end)

   if not id then
      log.error("Could not create an opponent trigger for %s.", affliction)
      return false
   end

   table.insert(registry(), id)
   return true
end

--- Register a third-person CURE pattern: retracts the affliction instead of asserting it.
--- A handful of these exist even though there's no general reconcile path (see the module
--- header) -- specific messages like "writhed free of the ropes" are a real, unambiguous
--- confirmation when Achaea happens to say them, same principle as patterns.lua's cure-side
--- entries. A separate function rather than overloading M.add(), so the existing two-arg
--- gain signature stays unchanged.
--- @param affliction string
--- @param pattern string a Mudlet-flavoured (PCRE) regex with one capture group
--- @return boolean
function M.addCure(affliction, pattern)
   affliction = tostring(affliction or ""):lower()
   if affliction == "" or type(pattern) ~= "string" then return false end

   local id = tempRegexTrigger(pattern, function()
      local name = matches and matches[2]
      if type(name) ~= "string" or name == "" then return end
      M.forget(name, affliction)
   end)

   if not id then
      log.error("Could not create an opponent cure trigger for %s.", affliction)
      return false
   end

   table.insert(registry(), id)
   return true
end

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

--- Record that an opponent has an affliction. Exposed directly (not just as a trigger
--- callback) so tests, and any future non-regex source, can drive it without a trigger.
function M.assert(name, affliction)
   name = tostring(name or ""):lower()
   affliction = tostring(affliction or ""):lower()
   if name == "" or affliction == "" then return false end

   M.tracked[name] = M.tracked[name] or {}
   M.tracked[name][affliction] = emunah.util.now()
   event.raise("opponent.afflicted", name, affliction)
   return true
end

--- Retract one affliction for one opponent, or everything known about them.
function M.forget(name, affliction)
   name = tostring(name or ""):lower()
   local afflictions = M.tracked[name]
   if not afflictions then return false end

   if affliction then
      afflictions[tostring(affliction):lower()] = nil
   else
      M.tracked[name] = nil
   end
   return true
end

function M.has(name, affliction)
   local afflictions = M.tracked[tostring(name or ""):lower()]
   if not afflictions then return false end
   return afflictions[tostring(affliction or ""):lower()] ~= nil
end

--- Every affliction currently tracked for one opponent, sorted.
function M.list(name)
   local out = {}
   for affliction in pairs(M.tracked[tostring(name or ""):lower()] or {}) do
      out[#out + 1] = affliction
   end
   table.sort(out)
   return out
end

--- Count afflictions for one opponent, or across everyone tracked.
function M.count(name)
   if name then
      return emunah.util.count(M.tracked[tostring(name):lower()] or {})
   end
   local total = 0
   for _, afflictions in pairs(M.tracked) do
      total = total + emunah.util.count(afflictions)
   end
   return total
end

--- Drop entries older than maxAge seconds. Not wired to a timer -- there is not yet a
--- consumer whose real needs would tell us the right default, and inventing one without
--- data is exactly the kind of guess this module otherwise avoids. Call it explicitly
--- (e.g. when a PvP session ends) until something in Phase 3 needs it continuously.
function M.prune(maxAge)
   maxAge = tonumber(maxAge) or 30
   local now = emunah.util.now()
   for name, afflictions in pairs(M.tracked) do
      for affliction, since in pairs(afflictions) do
         if now - since > maxAge then afflictions[affliction] = nil end
      end
      if not next(afflictions) then M.tracked[name] = nil end
   end
end

function M.clear(name)
   if name then
      M.tracked[tostring(name):lower()] = nil
   else
      M.tracked = {}
   end
end

-- Drop the previous generation before installing this one.
M.killAll()

event.register("sysDisconnectionEvent", function()
   M.tracked = {}
end, "pvp.opponent")

-- Publish before loading the pattern file, same reason as curing/detect/init.lua:
-- opponent_patterns.lua reaches back through emunah.curing.detect.opponent to register
-- itself, and that path does not exist until this module returns unless published here.
emunah.curing = emunah.curing or {}
emunah.curing.detect = emunah.curing.detect or {}
emunah.curing.detect.opponent = M

package.loaded["emunah.curing.detect.opponent_patterns"] = nil
local ok, err = pcall(require, "emunah.curing.detect.opponent_patterns")
if not ok then
   log.warn("No opponent detection patterns loaded: %s", tostring(err))
end

return M

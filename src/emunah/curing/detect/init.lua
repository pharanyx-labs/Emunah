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
---     precision where a pattern is known to be right, and `emunah learn on` captures
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
function M.standUp()
   return emunah.act.send("stand", { bal = true })
end

--- Upper bound on how long either state is believed without a clearing message. Both flags
--- gate sending, so a clear that never arrives is not a degraded bot but a frozen one --
--- these bound the damage. Generous on purpose: they should only ever fire when a message
--- was genuinely missed, never in place of the real one.
M.STUN_GUARD  = 6.0
M.PRONE_GUARD = 10.0

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

   -- Free whichever vector was waiting on this cure. This is the whole point of having a
   -- cure-side pattern: without it the vector stays blocked until the fallback timer
   -- lapses, which costs roughly a full extra cure's worth of time per affliction.
   for _, vector in ipairs(queue.VECTORS) do
      local action = queue.awaiting(vector)
      if action and action.tag == affliction then
         queue.confirm(vector)
         emunah.have.recover(vector)
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
      log.info("Learn mode on. Candidate lines -> <ansi_cyan>%s<ansi_yellow>", LEARN_PATH)
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
   log.info("Learn mode off. Captured lines are in %s", LEARN_PATH)
   return true
end

function M.toggleLearning()
   if M.learning then M.stopLearning() else M.startLearning() end
   return M.learning
end

M.learnPath = LEARN_PATH

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
local STATE_FLAGS = { prone = "prone", stunned = "stunned" }

event.register("emunah.affliction.added", function(_, name)
   local flag = STATE_FLAGS[tostring(name or ""):lower()]
   if flag and not M[flag] then
      log.debug("GMCP reports %s.", name)
      M[flag] = true
      if flag == "prone" then M.standUp() end
   end
end, "curing.detect")

event.register("emunah.affliction.removed", function(_, name)
   local flag = STATE_FLAGS[tostring(name or ""):lower()]
   if flag and M[flag] then
      M[flag] = false
      emunah.timers.stop(flag == "prone" and "prone.guard" or "stun.guard")
      event.raise("recovered")
   end
end, "curing.detect")

-- Keep trying while we are down. Self-limiting: standing spends the balance it requires, so
-- a successful attempt blocks the next tick's, and "You stand up." clears the flag anyway.
event.register("emunah.tick", function()
   if M.prone and not M.stunned then M.standUp() end
end, "curing.detect")

return M

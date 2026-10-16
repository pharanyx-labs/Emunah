--- The game's own command separator: CONFIG SEPARATOR.
---
--- WHY THIS EXISTS
--- ---------------
--- With a separator set, the game splits a line into commands itself:
---
---     config Separator |
---     Your command separator is now: |
---
--- so "eat kelp|apply mending|smoke elm" is one line on the wire and three commands in the
--- game. core/act.lua joins what one prompt decides that way (the user, 2026-10-16: "we can
--- definitely make things much more efficient now"). Mudlet's own `;;` never did this: Mudlet
--- splits at it before sending, so the game still got one line per command.
---
--- A SEPARATOR IS USED ONLY ONCE THE GAME HAS SAID WHAT IT IS, THIS SESSION. Joining with a
--- separator the game does not have sends "eat kelp|apply mending" as one command, which the
--- game cannot run -- every cure of that prompt lost. So nothing is remembered between
--- sessions and nothing is assumed: on the first prompt of each session Emunah asks (CONFIG
--- COMMANDSEPARATOR, quietly, its answer hidden), and until the answer is read every command
--- goes on a line of its own, exactly as before. Typing a CONFIG SEPARATOR command yourself
--- stops the joining at once; the game's answer, or Emunah's own question after it, settles
--- it again.
---
--- The game's answers, from the user's session (2026-10-16 16:24 and 16:59:57):
---
---     You can set a separator to be able to send multiple commands to Achaea at once.
---     You currently have no separator set. Use CONFIG SEPARATOR <separator> to set one.
---     Your command separator is now: |        <- CONFIG SEPARATOR |
---     Your current separator is: |            <- CONFIG COMMANDSEPARATOR, with one set
---
--- One pattern reads both "Your ... separator is ...: X" lines. If the game ever words them
--- some other way, nothing is read and nothing is joined -- the safe way to be wrong.

local M = {}

local log = emunah.log

--- What Emunah asks the game.
M.QUERY = "config commandseparator"

--- How long the answer to that question is expected, and hidden.
M.WAIT = 5.0

--- Asked this many times in a session without an answer that could be read: stop asking.
M.MAX_ASKS = 3

--- How long after an unanswered question to ask again.
M.RETRY = 30.0

--- After a CONFIG SEPARATOR command of yours, how long to wait for the game's own answer
--- before asking.
M.RECHECK = 2.0

--- Session state, kept across a reload (a reload is not a new session).
---   value    the separator the game named, or nil for none
---   known    the game has answered this session; until then nothing is joined
---   askedAt  when Emunah last asked; asks  how many times this session
---   told     the value last reported, so a change is said once
local function state()
   emunah._persist = emunah._persist or {}
   local s = emunah._persist.separator
   if not s then
      s = { asks = 0 }
      emunah._persist.separator = s
   end
   return s
end

--- The game's separator, if the game has named one this session; nil otherwise.
function M.get()
   local s = state()
   if s.known then return s.value end
   return nil
end

--- The separator last named by the game, confirmed this session or not. For reading what
--- went out (core/outgoing.lua), where the game splits whether or not Emunah joins.
function M.last()
   return state().value
end

--- Has the game answered this session?
function M.known()
   return state().known == true
end

--- Is an answer to Emunah's own question expected now? Then its lines are hidden.
local function asking()
   local s = state()
   return s.askedAt ~= nil and emunah.util.now() - s.askedAt < M.WAIT
end

--- Forget everything: a new session.
function M.reset()
   emunah._persist = emunah._persist or {}
   emunah._persist.separator = { asks = 0 }
end

--- The game has said what its separator is: `value`, or nil for none.
function M.settle(value)
   local s = state()
   if value then
      value = tostring(value):match("^%s*(.-)%s*$")
      if value == "" then value = nil end
   end
   s.value, s.known, s.askedAt = value, true, nil
   if s.told == (value or false) then return end
   s.told = value or false
   if value then
      log.info("The game splits commands at <ansi_white>%s<ansi_yellow>: what one prompt "
         .. "decides now leaves as one line.", value)
   else
      log.info("No in-game command separator, so every command goes on a line of its own. "
         .. "<ansi_white>CONFIG SEPARATOR |<ansi_yellow> lets Emunah send a prompt's commands "
         .. "as one line.")
   end
   emunah.event.raise("separator", value)
end

--- What is known stops counting: a CONFIG SEPARATOR command is on its way to the game.
--- Joining stops until the game answers.
function M.unsettle()
   local s = state()
   s.known = false
end

--- Ask the game, quietly, if nothing is known and it is time to. Returns whether it asked.
function M.ask(force)
   local s = state()
   if s.known and not force then return false end
   if s.askedAt and emunah.util.now() - s.askedAt < M.RETRY then return false end
   if (s.asks or 0) >= M.MAX_ASKS then return false end
   if not emunah.act.send(M.QUERY, { quiet = true }) then return false end
   s.asks = (s.asks or 0) + 1
   s.askedAt = emunah.util.now()
   if s.asks >= M.MAX_ASKS then
      -- The answer to this last one may still be read; say so only if it is not.
      tempTimer(M.WAIT, function()
         if not state().known then
            log.warn("Could not read the game's command separator after %d tries, so every "
               .. "command goes on a line of its own. `config commandseparator` shows it.",
               M.MAX_ASKS)
         end
      end)
   end
   return true
end

-- ---------------------------------------------------------------------------
-- the game's answers
-- ---------------------------------------------------------------------------

local function registry()
   emunah._persist = emunah._persist or {}
   for _, id in ipairs(emunah._persist.separatorTriggers or {}) do killTrigger(id) end
   emunah._persist.separatorTriggers = {}
   return emunah._persist.separatorTriggers
end

do
   local ids = registry()
   local function keep(id) if id then ids[#ids + 1] = id end end

   -- The question's first line. Only ever hidden when Emunah asked.
   keep(tempRegexTrigger(
      [[^You can set a separator to be able to send multiple commands to Achaea at once\.$]],
      function()
         if asking() then emunah.ui.gag.current() end
      end))

   keep(tempRegexTrigger([[^You currently have no separator set\.]], function()
      local hide = asking()
      M.settle(nil)
      if hide then emunah.ui.gag.withPrompt() end
   end))

   -- "Your command separator is now: |" (setting it) and "Your current separator is: |"
   -- (asking). The separator is the last word: a separator has no spaces in it.
   keep(tempRegexTrigger([[^Your [\w ]*separator is[^:]*: ?(\S+)$]],
      function()
         local hide = asking()
         M.settle(matches[2])
         if hide then emunah.ui.gag.withPrompt() end
      end))
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

-- The first prompt of a session: ask. Every later prompt costs one comparison.
emunah.event.register("emunah.tick", function()
   if not state().known then M.ask() end
end, "separator")

-- A CONFIG SEPARATOR command of yours: stop joining until the game answers it. If its
-- answer is not one this can read (clearing it, say), ask.
emunah.event.register("emunah.sent", function(_, command, typed)
   if not typed or type(command) ~= "string" then return end
   if not command:find("^config%s+%a*sep") then return end
   M.unsettle()
   local s = state()
   s.asks = 0
   tempTimer(M.RECHECK, function()
      if not state().known then M.ask() end
   end)
end, "separator")

-- A new connection is a new session, perhaps a different character.
emunah.event.register("sysConnectionEvent", function() M.reset() end, "separator")
emunah.event.register("sysDisconnectionEvent", function() M.reset() end, "separator")

return M

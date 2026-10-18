--- Hiding lines, the reference system's way: deleteLine() in the trigger.
---
--- Mudlet commits a packet one line at a time and runs the triggers on each line as it is
--- committed (TBuffer::commitLineData). A trigger deleting the line it fired on is the case
--- that code is written for: the line goes before the next one is added, so nothing below
--- it moves and every later line of the packet still reaches its triggers. A second
--- deleteLine() on the same line does nothing, because the cursor is left on an index that
--- is now past the end of the buffer (TBuffer::deleteLines range-checks it).
---
--- This replaces a deferred delete: paint the line in its own background, then search the
--- buffer for its text on a zero-delay timer and delete it there. That was built on a belief
--- that deleting in a trigger lost the rest of a PIPELIST; the code that showed it is not
--- in the history, and Mudlet's source says otherwise. What the deferred delete did
--- produce was the bugs: rows flashing before they went, a search settling on the wrong
--- copy of a repeated line, and an empty row that only vanished when you copied text.
---
--- After deleteLine(), an echo from the same trigger goes on the line above, so a redraw
--- starts with "\n" (ui/echo.lua's oecho, elist.lua's draw).

local M = {}

-- ---------------------------------------------------------------------------
-- Our own output, while a line it could land on is about to go
-- ---------------------------------------------------------------------------
--
-- AN ECHO MADE WHILE A LINE IS PROCESSED BELONGS TO THAT LINE, and goes with it when the
-- line is deleted. A gagged PIPELIST's prompt runs the prompt trigger's second pass
-- (lines came after its Char.Vitals), and what that pass printed went with the prompt:
-- login 2026-10-18 10:09:21, `smoke skullcap` went out with no `-> smoke skullcap` and
-- no `Sent [smoke]` anywhere, and it read as a command from some other script. So while
-- a prompt is due to be hidden, core/log.lua hands its lines here, and they are printed
-- once that prompt has been dealt with.

--- Longest a pending prompt delete holds output. The prompt is the next line of the same
--- packet, so this is only a backstop for one that never comes.
M.HOLD_MAX = 2.0

local held = {}
local armed, armedAt = 0, nil

-- Forward: the idle poll's answer prompt, below, may be deleted too.
local awaitingUntil = nil
local afterPrompt = false

--- Is a line we are about to delete still to come, so that output now could go with it?
function M.holding()
   local now = emunah.util.now()
   if armed > 0 and armedAt and now - armedAt > M.HOLD_MAX then armed = 0 end
   if armed > 0 then return true end
   return awaitingUntil ~= nil and afterPrompt and now <= awaitingUntil
end

--- Print what was held, in order.
function M.release()
   if #held == 0 then return end
   local out = held
   held = {}
   for _, text in ipairs(out) do cecho(text) end
end

--- Keep `text` (cecho markup) until the line it could land on has been dealt with.
function M.hold(text)
   held[#held + 1] = text
   if #held == 1 and type(tempTimer) == "function" then
      tempTimer(M.HOLD_MAX, function() M.release() end)
   end
end

local function deletable()
   return type(deleteLine) == "function"
end

--- Hide the line being processed. Call from a trigger, on the line it fired on.
function M.current()
   if not deletable() then return false end
   deleteLine()
   return true
end

--- Hide the line being processed and, if the very next line is a prompt, that prompt too.
--- How the reference system gags a reply that is all housekeeping, so it does not
--- leave a bare prompt behind. Gag every line of a block this way and only the last one's
--- arming finds a prompt; anything shown after it (someone arriving) keeps the prompt.
function M.withPrompt()
   if not M.current() then return false end
   if type(tempLineTrigger) == "function" then
      armed, armedAt = armed + 1, emunah.util.now()
      tempLineTrigger(1, 1, function()
         if type(isPrompt) == "function" and isPrompt() then deleteLine() end
         armed = math.max(armed - 1, 0)
         if armed == 0 then M.release() end
      end)
   end
   return true
end

-- ---------------------------------------------------------------------------
-- A prompt we asked for
-- ---------------------------------------------------------------------------

--- How long after asking for a prompt the answer is still expected.
M.PROMPT_WINDOW = 3.0

-- `awaitingUntil`: when the prompt we asked for stops being expected, or nil when none is.
-- `afterPrompt`: was the last line through M.onLine() a prompt? Counts lines that were
-- hidden, too. Both declared above, for M.holding().

--- Hide the answer to a blank line sent from a timer (curing/engine.lua's idle poll), where
--- there is no line to hang a tempLineTrigger off.
---
--- THE ANSWER IS THE PROMPT WITH NOTHING ABOVE IT, not merely the next prompt. The poll
--- fired a moment before the Rite of Revitalisation's own 15-second prompt was handled
--- (07:54:27.90, 07:54:57.92, ... 2026-10-16), so the Rite's line came first and the gag
--- gave up, and its answer drew a second prompt 0.27s later, every 30 seconds. Whatever
--- arrives in between, the answer is the prompt straight after another one: an empty block
--- says nothing a gauge does not.
function M.nextPrompt()
   awaitingUntil = emunah.util.now() + M.PROMPT_WINDOW
end

--- Every line. See M.nextPrompt().
function M.onLine()
   local prompt = type(isPrompt) == "function" and isPrompt() or false
   if awaitingUntil and emunah.util.now() > awaitingUntil then awaitingUntil = nil end
   if prompt and afterPrompt and awaitingUntil then
      awaitingUntil = nil
      M.current()
   end
   afterPrompt = prompt
   if armed == 0 then M.release() end
end

-- ---------------------------------------------------------------------------
-- Lines nobody needs to read
-- ---------------------------------------------------------------------------

--- Hidden with the prompt after them. Nothing in Emunah reads these.
M.LINES = {
   -- Every 15 seconds in a Rite of Revitalisation (2026-10-16, 07:54:12.90 onwards).
   [[^The Rite of Revitalisation refreshes your body and mind\.$]],
}

do
   emunah._persist = emunah._persist or {}
   for _, id in ipairs(emunah._persist.gagTriggers or {}) do killTrigger(id) end
   if emunah._persist.gagTrigger then killTrigger(emunah._persist.gagTrigger) end
   emunah._persist.gagTrigger = nil
   local ids = { tempRegexTrigger([[^]], function() M.onLine() end) }
   for _, pattern in ipairs(M.LINES) do
      ids[#ids + 1] = tempRegexTrigger(pattern, function() M.withPrompt() end)
   end
   emunah._persist.gagTriggers = ids
end

return M

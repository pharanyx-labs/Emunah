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
      tempLineTrigger(1, 1, function()
         if type(isPrompt) == "function" and isPrompt() then deleteLine() end
      end)
   end
   return true
end

-- ---------------------------------------------------------------------------
-- A prompt we asked for
-- ---------------------------------------------------------------------------

--- How long after asking for a prompt the next one is still taken to be the answer.
M.PROMPT_WINDOW = 3.0

--- When the prompt we asked for stops being expected, or nil when none is.
local awaitingUntil = nil

--- Hide the next line if it is a bare prompt arriving within M.PROMPT_WINDOW. For a blank
--- line sent from a timer (curing/engine.lua's idle poll), where there is no line to hang
--- a tempLineTrigger off. Anything else arriving first means the block is not only ours,
--- and the prompt stays.
function M.nextPrompt()
   awaitingUntil = emunah.util.now() + M.PROMPT_WINDOW
end

--- Every line. See M.nextPrompt().
function M.onLine()
   if not awaitingUntil then return end
   local ours = emunah.util.now() <= awaitingUntil
      and type(isPrompt) == "function" and isPrompt()
   awaitingUntil = nil
   if ours then M.current() end
end

do
   emunah._persist = emunah._persist or {}
   if emunah._persist.gagTrigger then killTrigger(emunah._persist.gagTrigger) end
   emunah._persist.gagTrigger = tempRegexTrigger([[^]], function() M.onLine() end)
end

return M

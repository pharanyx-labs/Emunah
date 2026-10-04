--- Hiding lines that arrive in one packet with other lines, without breaking that packet.
---
--- Moved here from pipes.lua, which found each trap in play, so that ELIST (elist.lua) can
--- hide the game's listing and draw its own the same way.
---
--- NEVER deleteLine() OR replace() INSIDE A TRIGGER. Deleting while Mudlet was still
--- working through the lines of the same packet shifted the buffer, and every PIPELIST row
--- after the first was never parsed (play: "it's also only lighting the skullcap pipe").
--- Replacing the line with "" is the same trap: Mudlet drops a blank line and the rows
--- after it shift too. ih.lua's delete-and-relink, left running on ELIST, fused one row
--- onto another (2026-10-04, 09:13:02.44).
---
--- A zero-width stand-in was the trap after that one. The slot stays, and the characters
--- have no width, so the window shows an empty row. That row is still there when you go
--- to copy the text, and the copy lays the window out again -- which is when the empty
--- rows vanish. So a hidden line keeps its characters, painted in the line's own
--- background, the way Mudlet itself draws a line you are not meant to read, and a
--- zero-delay timer -- run once the packet has been processed -- deletes by the original
--- sentence, from the bottom up, so removing one never moves another.

local M = {}

--- Lines waiting for the timer: { line, text, prompt }.
local pending = {}

--- owner -> function(removedIndexes), run after each flush.
local listeners = {}

--- Paint the line being processed in its own background. The sentence stays, so the
--- timer can find it; only the colour changes, and that happens before the packet paints.
--- No colour API, or no real line under the cursor, leaves it readable until the delete
--- rather than inventing a stand-in for the search to miss.
local function concealCurrent()
   if type(selectCurrentLine) ~= "function" or type(setFgColor) ~= "function"
      or type(getBgColor) ~= "function" then
      return
   end
   -- false means the cursor is not on a real line. Colouring anyway would restyle
   -- whatever the cursor last touched, which may be a line we were told to leave alone.
   if selectCurrentLine() == false then return end
   local r, g, b = getBgColor()
   r, g, b = tonumber(r), tonumber(g), tonumber(b)
   if r and g and b then setFgColor(r, g, b) end
   -- The colour is on the characters now. A selection left behind is a highlight, and
   -- it is what a copy would grab.
   if type(deselect) == "function" then deselect() end
end


--- How far from its recorded number a gagged line is looked for before giving up on it.
M.SEARCH = 200

--- Does this buffer line still hold what we recorded?
---
--- A prompt matches with its trailing space stripped: Mudlet finishes the line, which had
--- no newline of its own, a moment after we read it, and that space is not a command. A
--- command you typed is echoed onto the prompt as real text, and that line is left alone.
local function lineMatches(current, wanted, prompt)
   if current == wanted then return true end
   if not prompt or type(current) ~= "string" or type(wanted) ~= "string" then return false end
   return current:gsub("%s+$", "") == wanted:gsub("%s+$", "")
end

--- Where the line reading `text` is now, looking outward from where it was recorded.
---
--- DELETE BY TEXT, NOT BY NUMBER. A line's number is recorded when its trigger fires and
--- used a moment later, and anything that moves the buffer in between -- Mudlet trimming
--- the scrollback once it is full, another script deleting a line -- makes that number
--- point somewhere else. Deleting by number then removes the wrong line AND leaves the
--- right one: "overgagging on some lines and not gagging others" (2026-09-28), both at
--- once. So the recorded number is only where the search starts, and a line whose text is
--- not found is left alone rather than something else being deleted in its place.
---
--- `removed` is the set of indexes already deleted in this flush. Deleting one line shifts
--- everything below it, so an index already used is not a second copy -- but the copy can
--- be the next index the search would have stopped on. Skip those and keep looking.
local function locate(entry, removed)
   local line, text = entry.line, entry.text
   if not text then return nil end
   local count = type(getLineCount) == "function" and getLineCount("main") or line
   for offset = 0, M.SEARCH do
      for _, at in ipairs(offset == 0 and { line } or { line - offset, line + offset }) do
         if at >= 1 and at <= count and not removed[at] then
            moveCursor("main", 0, at)
            if lineMatches(getCurrentLine(), text, entry.prompt) then return at end
         end
      end
   end
   return nil
end

local function flush()
   table.sort(pending, function(a, b) return a.line > b.line end)
   local removed, removedAt = {}, {}
   for _, entry in ipairs(pending) do
      -- An old prompt is only removed while it still reads as it did: if you have typed a
      -- command since, Mudlet echoed it onto that prompt, and the line is yours -- the text
      -- no longer matches, so locate() does not find it.
      local at = locate(entry, removed)
      if at then
         moveCursor("main", 0, at)
         deleteLine("main")
         removed[at] = true
         removedAt[#removedAt + 1] = at
      end
   end
   pending = {}
   moveCursorEnd("main")
   -- Bottom up, so each index is where that line was before anything above it moved.
   for _, fn in pairs(listeners) do fn(removedAt) end
end

--- Hide the line being processed. Returns false if it was already recorded: two triggers
--- gagging one line must count it once, or pipes.lua's block count outruns its lines and
--- collapses a prompt that still has a visible line above it.
---
--- The colour changes HERE, before this trigger returns, so the packet is not painted
--- with the words still readable. The characters stay: the timer deletes by them, and
--- replacing them is what left the empty rows. Doing the deleteLine now would shift
--- the rest of the packet.
function M.current()
   if type(getLineNumber) ~= "function" then return false end
   local line = getLineNumber("main")
   if not line then return false end
   for _, entry in ipairs(pending) do
      if entry.line == line then return false end
   end
   -- The sentence the timer searches for is the one that arrived. Concealing does not
   -- change it; reading it first means a later call cannot either.
   local text = getCurrentLine()
   concealCurrent()
   M.add({ line = line, text = text })
   return true
end

--- Queue a line recorded earlier (pipes.lua's stranded prompt): { line, text, prompt }.
function M.add(entry)
   if #pending == 0 then tempTimer(0, flush) end
   pending[#pending + 1] = entry
end

--- Be told, after each flush, which lines went: their indexes, highest first. Keyed by
--- owner so a reload replaces rather than stacks.
function M.onFlush(owner, fn)
   listeners[owner] = fn
end

return M

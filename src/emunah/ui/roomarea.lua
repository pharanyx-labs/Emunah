--- The room's area, shown at the end of the room-name line: "Fish Street (Targossas, the
--- City of)". Asked for by the user (2026-10-12), driven by GMCP Room.Info rather than a
--- map lookup, so it works in rooms the map does not have.
---
--- THE ORDER IS NOT KNOWN, SO BOTH ARE HANDLED
--- ------------------------------------------
--- Room.Info and the room-name line arrive separately, and nothing in docs/game/ says which
--- comes first (docs/game/gmcp.md only orders the GMCP messages among themselves). Rather
--- than guess, both orders work, and a miss costs nothing because this only decorates text:
---
---   name line first   Room.Info looks back over the lines since the last prompt for one
---                     that starts with the room's name, and tags it.
---   Room.Info first   nothing to find yet, so a one-shot trigger waits for a line that
---                     starts with the name, and tags that.
---
--- If Room.Info lands after the prompt that closes its room's output, "since the last
--- prompt" is empty, and the look-back covers the block before that prompt instead.
---
--- WHY "SINCE THE LAST PROMPT" AND NOT "THE LAST FEW LINES"
--- ---------------------------------------------------------
--- A speedwalk along Fish Street passes four rooms called "Fish Street". Looking back an
--- arbitrary number of lines would find the previous room's name line and stamp this room's
--- area on it -- the same area here, but a different one at an area border. Each room's
--- output ends with a prompt, so a line before that prompt belongs to an earlier room.
--- The waiting trigger is disarmed for the same reason when Room.Info names a different
--- room, or after two prompts with no name line.
---
--- THE TWO ORDERS LOOK ALIKE AT ONE MOMENT. Room.Info for the next room, arriving before
--- its lines, sees nothing since the last prompt -- exactly what Room.Info arriving after
--- its own room's prompt sees. The previous block is searched in both cases, and a name line
--- there that is ALREADY TAGGED belongs to an earlier Room.Info: it is skipped and the
--- trigger armed instead. Only an untagged one is this Room.Info's, arriving late.
---
--- Room.Info is sent twice, identically, on every move (docs/game/gmcp.md). A second copy
--- for the same room with no prompt in between is that duplicate, and is ignored.

local M = {}

local event  = emunah.event
local config = emunah.config
local theme  = emunah.ui.theme

--- How far back to look, at most, for the name line. A room's name, description, exits,
--- items and people are well under this; it bounds the cost if the prompt marks are stale.
M.LOOKBACK = 30

--- Prompts a waiting trigger survives before it gives up.
M.PATIENCE = 2

-- Reload-safe: the previous generation's trigger is killed before this one exists.
emunah._persist.roomAreaTriggers = emunah._persist.roomAreaTriggers or {}
for _, id in ipairs(emunah._persist.roomAreaTriggers) do killTrigger(id) end
emunah._persist.roomAreaTriggers = {}

--- Line numbers of the last two prompts, in the numbering getLineNumber() uses.
M.lastPrompt, M.prevPrompt = nil, nil

--- The waiting trigger, if any: { id, num, names, area, prompts }.
M.waiting = nil

function M.enabled()
   return config.get("ui.roomArea", true) ~= false
end

local function suffix(area)
   return " (" .. area .. ")"
end

--- Does `line` start with the room's name? Room.Info's name, and the same without a
--- trailing period, since nothing establishes whether the title line carries one.
local function names(name)
   name = tostring(name or "")
   local out = { name }
   if name:sub(-1) == "." then out[2] = name:sub(1, -2) end
   return out
end

local function startsWithName(line, candidates)
   for _, name in ipairs(candidates) do
      if name ~= "" and line:sub(1, #name) == name then return true end
   end
   return false
end

local function tagged(line, area)
   local tag = suffix(area)
   return line:sub(-#tag) == tag
end

local function width(line)
   local len = utf8 and utf8.len and utf8.len(line)
   return len or #line
end

--- Lines this module has tagged, by line number. A set rather than a look at the line's
--- ending: "Tsol'aa city (Kelsys)" ends with a bracket of its own.
M.taggedLines = {}

--- Append the area to buffer line `index`, whose text is `line`.
local function tag(index, line, area)
   M.taggedLines[index] = true
   moveCursor(width(line), index)
   dinsertText(theme.dc("textDim") .. suffix(area))
   moveCursorEnd()
end

local function disarm()
   if M.waiting then
      killTrigger(M.waiting.id)
      M.waiting = nil
   end
   emunah._persist.roomAreaTriggers = {}
end

--- Look back for the name line. Returns true once it is tagged, or nil to wait for it.
local function lookBack(candidates, area)
   moveCursorEnd()
   local now = getLineNumber()
   -- A prompt mark past the end of the buffer is stale: Mudlet trims its oldest lines once
   -- the buffer is full, and every line number shifts down.
   if M.lastPrompt and M.lastPrompt > now then
      M.lastPrompt, M.prevPrompt, M.taggedLines = nil, nil, {}
   end
   local from, previousBlock
   if M.lastPrompt and now > M.lastPrompt then
      from = M.lastPrompt + 1
   elseif M.lastPrompt then
      -- Nothing since the prompt: look in the block it closed (see the header).
      from = (M.prevPrompt or (M.lastPrompt - M.LOOKBACK)) + 1
      now = M.lastPrompt - 1
      previousBlock = true
   else
      from = now - M.LOOKBACK
   end
   from = math.max(from, now - M.LOOKBACK)
   local found
   for index = now, from, -1 do
      moveCursor(0, index)
      local line = getCurrentLine() or ""
      if startsWithName(line, candidates) then
         if previousBlock and M.taggedLines[index] then break end   -- an earlier room's
         if not tagged(line, area) then tag(index, line, area) end
         found = true
         break
      end
   end
   moveCursorEnd()
   return found
end

local function arm(num, candidates, area)
   disarm()
   local waiting = { num = num, names = candidates, area = area, prompts = 0 }
   -- Any non-empty line; the name is compared in Lua. Escaping a room name into a regex
   -- ("Tsol'aa city (Kelsys)") is where a pattern bug would hide, and the trigger only
   -- lives until the name line or the next prompt or two.
   waiting.id = tempRegexTrigger([[^.]], function()
      local line = getCurrentLine() or ""
      if not startsWithName(line, waiting.names) then return end
      if not tagged(line, waiting.area) then tag(getLineNumber(), line, waiting.area) end
      if M.waiting == waiting then disarm() end
   end)
   M.waiting = waiting
   table.insert(emunah._persist.roomAreaTriggers, waiting.id)
end

--- Prompts seen, so a duplicate Room.Info (same room, no prompt between) can be told from
--- a LOOK in the same room (a prompt between).
M.prompts = 0
M.lastInfo = nil

function M.onRoom()
   local info = gmcp and gmcp.Room and gmcp.Room.Info
   if type(info) ~= "table" then return end
   local num, area = tonumber(info.num), info.area and tostring(info.area) or ""
   if M.lastInfo and M.lastInfo.num == num and M.lastInfo.prompts == M.prompts then return end
   M.lastInfo = { num = num, prompts = M.prompts }
   -- A different room: whatever was waiting belongs to the last one.
   if M.waiting and M.waiting.num ~= num then disarm() end
   if not M.enabled() or area == "" or not info.name or info.name == "" then return end
   local candidates = names(info.name)
   if lookBack(candidates, area) then
      disarm()
      return
   end
   arm(num, candidates, area)
end

function M.onPrompt()
   M.prompts = M.prompts + 1
   M.prevPrompt, M.lastPrompt = M.lastPrompt, getLineNumber()
   for index in pairs(M.taggedLines) do
      if index < M.lastPrompt - 4 * M.LOOKBACK then M.taggedLines[index] = nil end
   end
   if M.waiting then
      M.waiting.prompts = M.waiting.prompts + 1
      if M.waiting.prompts >= M.PATIENCE then disarm() end
   end
end

event.register("gmcp.Room.Info", M.onRoom, "roomarea")
event.register("emunah.prompt", M.onPrompt, "roomarea")

return M

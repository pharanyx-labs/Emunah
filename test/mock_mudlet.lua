--- A minimal Mudlet API mock, enough to load and exercise Emunah outside the client.
---
--- This is not a Mudlet emulator. It implements the calls Emunah actually makes, with
--- synchronous event dispatch and manually-advanced timers, so tests can drive the system
--- deterministically: feed a GMCP message, assert on the resulting state.
---
--- Geyser is deliberately left undefined by default. Every UI module is supposed to
--- degrade gracefully when it is missing, and the surest way to keep that true is for the
--- default test environment not to have it.

local mock = {}

--- Build a set from a list of strings.
function mock.set(list)
   local out = {}
   for _, value in ipairs(list) do out[value] = true end
   return out
end

mock.sent      = {}   -- commands sent with send()
mock.gmcpSent  = {}   -- payloads sent with sendGMCP()
mock.echoed    = {}   -- console output
mock.timers    = {}   -- id -> { at, fn }
mock.aliases   = {}
mock.triggers  = {}
mock.handlers  = {}   -- event -> { id -> fn }

local nextId = 0
local function newId()
   nextId = nextId + 1
   return nextId
end

mock.clock = 0

function mock.reset()
   mock.sent, mock.gmcpSent, mock.echoed = {}, {}, {}
   mock.timers, mock.aliases, mock.triggers = {}, {}, {}
   mock.handlers = {}
   mock.links = {}
   mock.popups = {}
   mock.deletedLines = 0
   mock.currentLine, mock.formatted = "", {}
   mock.clock = 0
   nextId = 0
end

-- ---------------------------------------------------------------------------
-- install into the global environment
-- ---------------------------------------------------------------------------

function mock.install(homeDir)
   _G.gmcp = {}

   function _G.getMudletHomeDir() return homeDir end
   function _G.getMainWindowSize() return 1920, 1080 end

   local function record(text)
      mock.echoed[#mock.echoed + 1] = tostring(text)
   end
   _G.cecho, _G.decho, _G.echo, _G.hecho = record, record, record, record
   _G.debugc = record
   function _G.display(value) record(tostring(value)) end

   -- Clickable links: cechoLink/dechoLink(text, command, hint, useCurrentFormat) -- the
   -- "c"/"d" prefix only controls how colour tags in `text` are parsed (named vs
   -- decimal-tuple), same distinction as cecho/decho. `command` is Lua SOURCE, evaluated
   -- fresh when clicked -- not a function reference -- matching real Mudlet. mock.click(index)
   -- simulates a click by running exactly that source. The 4th argument is `useCurrentFormat`
   -- (Mudlet's own name, per TLuaInterpreterUI.cpp) -- it keeps the caller's own colour tags
   -- instead of Mudlet's default link styling, and has nothing to do with click behaviour.
   mock.links = {}
   local function recordLink(text, command, hint)
      mock.links[#mock.links + 1] = { text = text, command = command, hint = hint }
      record(text)
   end
   _G.cechoLink, _G.dechoLink, _G.echoLink, _G.hechoLink =
      recordLink, recordLink, recordLink, recordLink

   -- Popup links: cechoPopup/dechoPopup(text, commandList, hintList, useCurrentFormat) --
   -- same click-time-evaluated-source idiom as the plain link functions above, except this
   -- one offers several commands instead of one: left-click runs commandList[1], right-click
   -- opens a menu of every entry in commandList (real Mudlet behaviour, confirmed against
   -- Mudlet's own GUIUtils.lua/TLuaInterpreterUI.cpp -- not modelled here, since this mock
   -- has no real mouse-button discrimination and cannot represent that distinction; use
   -- mock.popupClick() to simulate choosing an entry from the menu regardless of which
   -- button a real click would have used). This is how a console-embedded link can offer
   -- more than one action (shop.lua's "buy 1 / 10 / 100" and "fill rift" menus).
   mock.popups = {}
   local function recordPopup(text, commandList, hintList)
      mock.popups[#mock.popups + 1] = { text = text, commands = commandList, hints = hintList }
      record(text)
   end
   _G.cechoPopup, _G.dechoPopup, _G.echoPopup, _G.hechoPopup =
      recordPopup, recordPopup, recordPopup, recordPopup

   --- Simulate choosing one entry (1-indexed) from a captured popup menu (1-indexed).
   --- @return boolean ok, string|nil err
   function mock.popupClick(index, choice)
      local popup = mock.popups[index]
      if not popup then return false, "no such popup" end
      local command = popup.commands and popup.commands[choice]
      if not command then return false, "no such choice" end
      local fn, err = (loadstring or load)(command)
      if not fn then return false, err end
      return pcall(fn)
   end

   -- Deletes the current line, real Mudlet's half of the "rewrite this line as a
   -- clickable one" idiom (deleteLine() then re-echo). Nothing in this mock models line
   -- buffers precisely enough to actually remove anything; recording that it was called
   -- is enough for a test to assert the rewrite happened.
   mock.deletedLines = 0
   -- A real buffer for the main window, so a gag can be checked for WHICH lines it removed.
   -- mock.line() appends to it and makes that line current; moveCursor/deleteLine then act
   -- on it by number, as Mudlet's do. Deleting shifts the lines below up, exactly the
   -- behaviour that makes deleting mid-packet dangerous (see pipes.lua).
   mock.buffer = {}
   mock.cursor = nil
   mock.deletedText = {}
   -- Whole-line foreground set by selectCurrentLine + setFgColor, keyed by buffer index.
   -- Pipes conceals a gag by painting the line in its own background; the text stays so
   -- the timer can still find it. deselect() must not forget that colour.
   mock.lineFg = {}
   mock.bgColor = { 0, 0, 0 }
   function _G.getLineNumber() return mock.cursor or #mock.buffer end
   function _G.getLineCount() return #mock.buffer end
   function _G.moveCursor(window, x, y)
      if type(window) ~= "string" then y = x end
      mock.cursor = y
      return true
   end
   function _G.moveCursorEnd() mock.cursor = nil return true end
   function _G.deleteLine()
      mock.deletedLines = mock.deletedLines + 1
      local line = mock.cursor or #mock.buffer
      -- ~= nil, not a truthiness check: an empty string is a real buffer row, and the
      -- gag's bug was exactly a row that looked empty and never went away.
      if mock.buffer[line] ~= nil then
         mock.deletedText[#mock.deletedText + 1] = table.remove(mock.buffer, line)
         local shifted = {}
         for index, colour in pairs(mock.lineFg) do
            if index < line then shifted[index] = colour
            elseif index > line then shifted[index - 1] = colour end
         end
         mock.lineFg = shifted
      end
   end

   -- In-place line formatting: the selectString + set*() family, which is how a highlighter
   -- restyles text that has already arrived.
   --
   -- Modelled rather than stubbed, because the interesting bugs here are all about WHICH
   -- text got selected. selectString's second argument is an ORDINAL -- restyling the second
   -- "Malefactor" on a line means asking for occurrence 2 -- and a stub that ignored it
   -- would happily pass a highlighter that styles the first occurrence three times and
   -- leaves the other two plain, which is exactly the bug worth catching.
   --
   -- mock.formatted records one entry per styled run, in the order they were applied.
   mock.currentLine = ""
   mock.formatted = {}
   local selection = nil

   --- Set the line a trigger is notionally firing on.
   function mock.setLine(text)
      mock.currentLine = tostring(text or "")
      mock.formatted = {}
      selection = nil
   end

   -- The line at the cursor once moveCursor() has been used, as in Mudlet; the line being
   -- processed otherwise.
   function _G.getCurrentLine()
      if mock.cursor and mock.buffer and mock.buffer[mock.cursor] then
         return mock.buffer[mock.cursor]
      end
      return mock.currentLine
   end
   -- Mudlet echoes a typed command onto the end of the last line -- usually the prompt.
   function mock.typedEcho(text)
      if mock.buffer and #mock.buffer > 0 then
         mock.buffer[#mock.buffer] = mock.buffer[#mock.buffer] .. tostring(text)
      end
   end

   --- selectCurrentLine selects the whole buffer row. Pipes uses it with setFgColor to
   --- hide a line without replace() or deleteLine(); both of those move the rows Mudlet
   --- has not finished processing. replace() is still here for anything that rewrites.
   function _G.selectCurrentLine()
      local lineNo = getLineNumber()
      if not lineNo or lineNo < 1 then return false end
      selection = { text = getCurrentLine(), at = 1, whole = true, line = lineNo }
      return true
   end

   function _G.replace(with)
      if not selection then return false end
      local newText = tostring(with or "")
      local lineNo = selection.line or getLineNumber()
      if selection.whole then
         if mock.buffer and lineNo and mock.buffer[lineNo] ~= nil then
            mock.buffer[lineNo] = newText
         end
         if not mock.cursor or mock.cursor == lineNo or lineNo == #mock.buffer then
            mock.currentLine = newText
         end
      end
      selection = nil
      return true
   end

   --- Real Mudlet returns the 0-based start index, or -1 when the occurrence is not there.
   function _G.selectString(text, occurrence)
      occurrence = tonumber(occurrence) or 1
      local from, start, stop = 1, nil, nil
      for _ = 1, occurrence do
         start, stop = mock.currentLine:find(tostring(text), from, true)
         if not start then selection = nil return -1 end
         from = start + 1
      end
      selection = { text = mock.currentLine:sub(start, stop), at = start,
                    bold = false, italic = false, underline = false }
      mock.formatted[#mock.formatted + 1] = selection
      return start - 1
   end

   --- selectSection(from, length): `from` is 0-based, as in Mudlet.
   function _G.selectSection(from, length)
      from, length = tonumber(from) or 0, tonumber(length) or 0
      if from < 0 or length <= 0 or from + length > #mock.currentLine then
         selection = nil
         return false
      end
      selection = { text = mock.currentLine:sub(from + 1, from + length), at = from + 1,
                    bold = false, italic = false, underline = false }
      mock.formatted[#mock.formatted + 1] = selection
      return true
   end

   function _G.deselect() selection = nil end

   --- Background of the current selection, as Mudlet returns it: three components.
   function _G.getBgColor()
      local bg = mock.bgColor or { 0, 0, 0 }
      return bg[1], bg[2], bg[3]
   end

   local function styler(field)
      return function(...)
         if not selection then return end
         local args = { ... }
         if field == "colour" then
            local r = tonumber(args[1]) or 0
            local g = tonumber(args[2]) or 0
            local b = tonumber(args[3]) or 0
            selection.colour = string.format("#%02x%02x%02x", r, g, b)
            -- A whole-line colour has to outlive deselect(), which the gag calls so the
            -- selection itself is not what a copy grabs.
            if selection.whole and selection.line then
               mock.lineFg[selection.line] = { r, g, b }
            end
         else
            selection[field] = args[1] ~= false
         end
      end
   end
   _G.setFgColor   = styler("colour")
   _G.setBold      = styler("bold")
   _G.setItalics   = styler("italic")
   _G.setUnderline = styler("underline")
   --- setLink([window,] command, tooltip) on the selection: kept on it, so a test can read
   --- the link a name was given and run it as a click would.
   function _G.setLink(...)
      if not selection then return end
      local args = { ... }
      if #args >= 3 then table.remove(args, 1) end
      selection.link, selection.linkHint = args[1], args[2]
   end

   --- What was applied to a given piece of text, or nil. Occurrence defaults to the first.
   function mock.formatOf(text, occurrence)
      local n = 0
      for _, entry in ipairs(mock.formatted) do
         if entry.text == text then
            n = n + 1
            if n == (tonumber(occurrence) or 1) then return entry end
         end
      end
      return nil
   end

   -- HTTP. Both of Mudlet's mechanisms are modelled, because namedb/api.lua picks between
   -- them at runtime and each delivers its result through a DIFFERENT pair of events --
   -- getting either pair wrong means every lookup silently never completes.
   --
   -- Nothing here touches the network. mock.serve() registers canned bodies by URL, and
   -- mock.respond() delivers them; a URL with no canned body fails the way a 403 does,
   -- which is what the API returns for a name that is not a character.
   mock.requests = {}     -- { url, handle } in order
   mock.responses = {}    -- url -> body string, or { error = "..." }
   mock.hasGetHTTP = true

   function mock.serve(url, body) mock.responses[url] = body end

   function _G.getHTTP(url)
      mock.requests[#mock.requests + 1] = { url = url, handle = url, kind = "getHTTP" }
   end

   function _G.downloadFile(path, url)
      mock.requests[#mock.requests + 1] = { url = url, handle = path, kind = "downloadFile" }
   end

   --- Deliver every outstanding request. Returns how many were answered.
   ---
   --- Synchronous on purpose: the queue in namedb/api.lua paces requests with tempTimer, so
   --- a test drives it with mock.advance() and calls this to let each one land.
   function mock.respond()
      local outstanding = mock.requests
      mock.requests = {}
      for _, request in ipairs(outstanding) do
         local body = mock.responses[request.url]
         if body == nil then
            if request.kind == "getHTTP" then
               raiseEvent("sysGetHttpError", "403 Forbidden", request.url)
            else
               raiseEvent("sysDownloadError", "403 Forbidden", request.handle)
            end
         elseif request.kind == "getHTTP" then
            raiseEvent("sysGetHttpDone", request.url, body)
         else
            local file = io.open(request.handle, "w")
            if file then file:write(body) file:close() end
            raiseEvent("sysDownloadDone", request.handle)
         end
      end
      return #outstanding
   end

   --- Simulate clicking a captured link (1-indexed, in echo order).
   --- @return boolean ok, string|nil err
   function mock.click(index)
      local link = mock.links[index]
      if not link then return false, "no such link" end
      local fn, err = (loadstring or load)(link.command)
      if not fn then return false, err end
      return pcall(fn)
   end

   --- Recorded rather than pure no-ops, so a test can assert a region actually reserves
   --- console space (setBorderTop > 0) rather than only checking the container geometry
   --- that space is meant to correspond to.
   mock.borders = { left = 0, right = 0, top = 0, bottom = 0 }
   --- Mudlet's hideWindow(name): labels and mini-consoles alike, by name.
   mock.hiddenWindows = {}
   function _G.hideWindow(name) mock.hiddenWindows[name] = true return true end

   function _G.setBorderLeft(px)   mock.borders.left   = px end
   function _G.setBorderRight(px)  mock.borders.right  = px end
   function _G.setBorderTop(px)    mock.borders.top    = px end
   function _G.setBorderBottom(px) mock.borders.bottom = px end

   --- Round-trip time to the game, in seconds. Real Mudlet measures this; tests set it to
   --- exercise the latency-sized in-flight guard (see class/priest.lua).
   --- Wall clock, driven by mock.advance() like every other timing source here. Real
   --- Mudlet's getEpoch() is what util.now() prefers; os.clock() is CPU time and unusable
   --- for durations.
   function _G.getEpoch() return mock.clock end

   mock.latency = 0.1
   function _G.getNetworkLatency() return mock.latency end

   -- Mudlet's isPrompt(): true while triggers run on the line the game marked as its prompt.
   -- mock.prompt(text) feeds a line that way.
   mock.onPrompt = false
   function _G.isPrompt() return mock.onPrompt end

   -- Mudlet's printCmdLine(text): puts text on the input line for the user to finish.
   mock.cmdLine = nil
   function _G.printCmdLine(text) mock.cmdLine = tostring(text) end

   mock.echoed_sends = {}
   -- Real Mudlet raises sysDataSendRequest for every command bound for the game, sent or
   -- typed; core/outgoing.lua is built on it.
   function _G.send(command, echo)
      mock.sent[#mock.sent + 1] = tostring(command)
      mock.echoed_sends[#mock.echoed_sends + 1] = echo ~= false
      if _G.raiseEvent then _G.raiseEvent("sysDataSendRequest", tostring(command)) end
   end
   function _G.sendGMCP(payload) mock.gmcpSent[#mock.gmcpSent + 1] = tostring(payload) end
   function _G.ansi2decho(text) return tostring(text) end

   -- events -------------------------------------------------------------
   function _G.registerAnonymousEventHandler(event, fn)
      local id = newId()
      mock.handlers[event] = mock.handlers[event] or {}
      mock.handlers[event][id] = fn
      return id
   end

   function _G.killAnonymousEventHandler(id)
      for _, handlers in pairs(mock.handlers) do
         if handlers[id] then handlers[id] = nil return true end
      end
      return false
   end

   function _G.raiseEvent(event, ...)
      local handlers = mock.handlers[event]
      if not handlers then return end
      -- Snapshot: a handler may register or kill handlers while we iterate.
      --
      -- IN REGISTRATION ORDER, as Mudlet calls them -- ids only ever increase, so sorting by id
      -- is that order. `pairs()` order is the hash's, and it hid what actually runs first: the
      -- UI loads before curing/engine.lua, so in Mudlet the vitals strip painted ahead of the
      -- tick on every prompt, while the mock happened to run them the other way round.
      local snapshot = {}
      for id, fn in pairs(handlers) do snapshot[#snapshot + 1] = { id = id, fn = fn } end
      table.sort(snapshot, function(a, b) return a.id < b.id end)
      for _, entry in ipairs(snapshot) do
         if mock.handlers[event] and mock.handlers[event][entry.id] then
            local ok, err = pcall(entry.fn, event, ...)
            if not ok then
               error(("handler for %s failed: %s"):format(event, tostring(err)), 0)
            end
         end
      end
   end

   --- How many handlers are registered for an event. The duplicate-handler regression
   --- test reads this directly.
   function mock.handlerCount(event)
      local n = 0
      for _ in pairs(mock.handlers[event] or {}) do n = n + 1 end
      return n
   end

   -- timers -------------------------------------------------------------
   function _G.tempTimer(delay, fn)
      local id = newId()
      mock.timers[id] = { at = mock.clock + delay, fn = fn }
      return id
   end

   function _G.killTimer(id)
      if mock.timers[id] then mock.timers[id] = nil return true end
      return false
   end

   --- Advance the clock and fire anything due.
   function mock.advance(seconds)
      mock.clock = mock.clock + seconds
      local due = {}
      for id, timer in pairs(mock.timers) do
         if timer.at <= mock.clock then due[#due + 1] = { id = id, fn = timer.fn } end
      end
      table.sort(due, function(a, b) return a.id < b.id end)
      for _, entry in ipairs(due) do
         -- Killed by a timer that fired before it in this same batch: Mudlet would not run
         -- it, so neither does this. Running it let the walker's dead retry clear the live
         -- one's handle, and that orphan then stepped for code that should have stalled.
         if mock.timers[entry.id] then
            mock.timers[entry.id] = nil
            entry.fn()
         end
      end
      return #due
   end

   -- aliases and triggers ----------------------------------------------

   --- Lua-pattern character classes that are meaningless (and silently wrong) in a PCRE
   --- regex. Mudlet's tempAlias/tempRegexTrigger take REGEXES, but the rest of a Lua
   --- codebase uses Lua patterns, so writing `%s` where `\s` is meant is an easy slip --
   --- and it fails silently: the alias simply never matches and the command goes to the
   --- game. Recorded here so a test can assert none of ours contain them.
   mock.badAliasPatterns = {}

   local function checkRegex(pattern)
      -- %s %d %w %a %u %l %p %x and their negations are Lua-pattern classes. In PCRE, `%`
      -- is a literal, so these quietly change what the pattern means.
      if tostring(pattern):find("%%[sdwaulpxSDWAULPX]") then
         mock.badAliasPatterns[#mock.badAliasPatterns + 1] = pattern
      end
   end

   function _G.tempAlias(pattern, fn)
      checkRegex(pattern)
      local id = newId()
      mock.aliases[id] = { pattern = pattern, fn = fn }
      return id
   end
   function _G.killAlias(id)
      if mock.aliases[id] then mock.aliases[id] = nil return true end
      return false
   end

   function _G.tempRegexTrigger(pattern, fn)
      local id = newId()
      mock.triggers[id] = { pattern = pattern, fn = fn }
      return id
   end
   function _G.killTrigger(id)
      if mock.triggers[id] then mock.triggers[id] = nil return true end
      return false
   end

   -- Keybindings. mudlet.key holds real Qt key codes; the numpad ones matter because a
   -- numpad key sends the DIGIT with Num Lock on and the NAVIGATION key with it off, so
   -- both sets have to be bindable or the pad silently stops working.
   mock.keys = {}
   _G.mudlet = _G.mudlet or {}
   _G.mudlet.keymodifier = {
      None = 0x00000000, Shift = 0x02000000, Control = 0x04000000,
      Alt = 0x08000000, Meta = 0x10000000, Keypad = 0x20000000,
      GroupSwitch = 0x40000000,
   }
   _G.mudlet.key = {
      Enter = 0x01000005, Insert = 0x01000006, Delete = 0x01000007,
      Clear = 0x0100000b, Home = 0x01000010, End = 0x01000011,
      Left = 0x01000012, Up = 0x01000013, Right = 0x01000014,
      Down = 0x01000015, PageUp = 0x01000016, PageDown = 0x01000017,
      Asterisk = 0x2a, Plus = 0x2b, Minus = 0x2d, Period = 0x2e, Slash = 0x2f,
      ["0"] = 0x30, ["1"] = 0x31, ["2"] = 0x32, ["3"] = 0x33, ["4"] = 0x34,
      ["5"] = 0x35, ["6"] = 0x36, ["7"] = 0x37, ["8"] = 0x38, ["9"] = 0x39,
      -- Qt::Key_F1.. F5/F11/F12 are the ones keys.lua's action bindings need.
      F5 = 0x01000034, F11 = 0x0100003a, F12 = 0x0100003b,
   }

   function _G.tempKey(modifier, code, fn)
      local id = newId()
      mock.keys[id] = { modifier = modifier, code = code, fn = fn }
      return id
   end
   function _G.killKey(id)
      if mock.keys[id] then mock.keys[id] = nil return true end
      return false
   end
   function mock.keyCount()
      local n = 0
      for _ in pairs(mock.keys) do n = n + 1 end
      return n
   end
   --- Press a key: finds the binding by modifier+code and fires it.
   function mock.press(modifier, code)
      for _, binding in pairs(mock.keys) do
         if binding.modifier == modifier and binding.code == code then
            binding.fn()
            return true
         end
      end
      return false
   end

   function mock.aliasCount()
      local n = 0
      for _ in pairs(mock.aliases) do n = n + 1 end
      return n
   end
   function mock.triggerCount()
      local n = 0
      for _ in pairs(mock.triggers) do n = n + 1 end
      return n
   end

   -- yajl ---------------------------------------------------------------
   local function encode(value)
      local t = type(value)
      if t == "string" then return '"' .. value:gsub('"', '\\"') .. '"' end
      if t == "number" or t == "boolean" then return tostring(value) end
      if t ~= "table" then return "null" end
      if #value > 0 then
         local parts = {}
         for _, item in ipairs(value) do parts[#parts + 1] = encode(item) end
         return "[" .. table.concat(parts, ",") .. "]"
      end
      local parts = {}
      for key, item in pairs(value) do
         parts[#parts + 1] = '"' .. tostring(key) .. '":' .. encode(item)
      end
      return "{" .. table.concat(parts, ",") .. "}"
   end
   _G.yajl = { to_string = encode }

   -- table.save / table.load -------------------------------------------
   local store = {}

   --- Real table.save() SERIALISES to a file: the saved copy stops sharing identity with
   --- the live table the instant it is written. Storing the reference instead made every
   --- round-trip test vacuous -- "save, load, assert the value came back" passed without
   --- anything ever being written, because it was reading the same table it had just
   --- mutated. Deep-copying models the real thing and lets a persistence test mean
   --- something.
   local function freeze(value, seen)
      if type(value) ~= "table" then return value end
      seen = seen or {}
      if seen[value] then return seen[value] end
      local copy = {}
      seen[value] = copy
      for key, item in pairs(value) do copy[key] = freeze(item, seen) end
      return copy
   end

   function table.save(path, tbl) store[path] = freeze(tbl) end
   function table.load(path, target)
      local saved = store[path]
      if not saved then return false end
      for key, value in pairs(saved) do target[key] = value end
      return true
   end
   mock.store = store

   -- Several modules (denizens.lua, core/config.lua) check `io.open(path, "r")` for
   -- existence before calling table.load(path, ...) -- a real, working pattern in real
   -- Mudlet, where table.save/table.load genuinely touch the filesystem. Here they touch
   -- `store` instead, so an unmocked io.open would check a file that was never written,
   -- always report "missing", and mask the entire load path from every test -- reload
   -- persistence would look broken (or worse, look fine because nothing ever exercised
   -- it) regardless of whether M.load() itself has a bug. Only READ-mode opens for a path
   -- `store` actually has are redirected; anything else keeps the real io.open, so genuine
   -- disk operations (learn mode's append-only log, say) are unaffected.
   local realIoOpen = io.open
   function io.open(path, mode)
      if (mode == nil or mode == "r") and store[path] ~= nil then
         return { close = function() return true end }
      end
      return realIoOpen(path, mode)
   end

   -- os.clock must follow the mock clock so age/cooldown maths is testable.
   local realClock = os.clock
   os.clock = function() return mock.clock end
   mock.realClock = realClock
end

-- ---------------------------------------------------------------------------
-- draw-call accounting
-- ---------------------------------------------------------------------------
--
-- COUNTS, NOT TIMES, and the distinction is the whole point. Under real Mudlet a decho is a
-- Qt rich-text parse and a setStyleSheet is a stylesheet reparse plus a re-layout; against
-- this stub both are a string assignment. So timing a repaint here measures the stub.
--
-- What DOES transfer is how many times the UI reaches for Qt at all. "This panel used to
-- issue thirty-four draw calls per repaint and now issues one", and "a burst of five item
-- events used to repaint five times and now paints once", are the two regressions worth
-- protecting, and both are counts.

mock.draws = { draw = 0, clear = 0, style = 0, value = 0 }

function mock.count(kind)
   mock.draws[kind] = (mock.draws[kind] or 0) + 1
end

--- Zero the counters and return the table, so a test reads
---     local drawn = mock.countDraws()
---     ... do the thing ...
---     eq(drawn.draw, 1, "...")
function mock.countDraws()
   mock.draws.draw, mock.draws.clear = 0, 0
   mock.draws.style, mock.draws.value = 0, 0
   return mock.draws
end

--- Install a Geyser stub so the UI construction path can actually be exercised.
---
--- Records every widget created so tests can assert on layout rather than just on "it did
--- not throw". Kept out of mock.install() on purpose: the default environment has no
--- Geyser, which is what keeps the graceful-degradation path honest.
function mock.installGeyser()
   mock.widgets = {}

   --- Methods each Geyser class actually has, taken from Mudlet's own sources.
   ---
   --- This is deliberately strict. An earlier version of this mock gave every widget
   --- every method, which let ui/affpanel.lua ship a MiniConsole:setStyleSheet() call --
   --- a Label/Gauge method that MiniConsole does not have. A permissive mock does not
   --- merely fail to catch that class of bug, it actively hides it, so the method sets
   --- below are restricted to what the real classes expose.
   local METHODS = {
      -- Geyser.MiniConsole: no setStyleSheet, no echo-replace semantics.
      miniconsole = {
         "echo", "decho", "cecho", "hecho", "clear", "show", "hide",
         "setColor", "setFont", "setFontSize", "setWrap", "setBufferSize",
         "enableScrollBar", "disableScrollBar", "setBackgroundImage", "resetFormat",
         "cechoLink", "dechoLink", "echoLink", "hechoLink", "move", "resize",
      },
      -- Geyser.Label
      label = {
         "echo", "decho", "cecho", "hecho", "clear", "show", "hide",
         "setStyleSheet", "setFgColor", "setFont", "setFontSize", "setAlignment",
         "setBold", "setItalics", "setUnderline", "setBackgroundImage",
         "setClickCallback", "setToolTip", "setCursor", "move", "resize",
      },
      -- Geyser.Gauge
      gauge = {
         "setValue", "setColor", "setText", "setFormat", "setStyleSheet",
         "setFontSize", "setAlignment", "setFgColor", "echo", "show", "hide", "move", "resize",
      },
      -- Geyser.Container
      container = { "show", "hide", "move", "resize" },
      adjustable = {
         "show", "hide", "save", "load", "attach", "detach", "lockContainer",
         "minimize", "restore", "echo", "setTitle",
      },
   }

   --- Constructor fields Geyser.MiniConsole actually reads, from its own new() plus the
   --- geometry/colour fields handled by Geyser.Container and Geyser.Color.applyColors.
   ---
   --- Geyser ignores unknown cons fields silently, so a misspelled option (wrapWidth for
   --- wrapAt) costs you the feature with no error anywhere. Recording them lets a test
   --- assert the panels only pass fields that do something.
   local CONSOLE_FIELDS = mock.set({
      "name", "x", "y", "width", "height", "type", "container", "windowname", "hidden",
      "color", "fgColor", "bgColor",
      "font", "fontSize", "wrapAt", "autoWrap", "scrollBar", "horizontalScrollBar",
      "commandLine", "cmdLineStylesheet", "scrolling", "useAdd2",
   })

   mock.unknownConsFields = {}

   local function widget(kind, cons, parent)
      if kind == "miniconsole" then
         for key in pairs(cons or {}) do
            if not CONSOLE_FIELDS[key] then
               mock.unknownConsFields[#mock.unknownConsFields + 1] =
                  (cons.name or "?") .. "." .. key
            end
         end
      end

      local self = {
         name = cons and cons.name or ("anon" .. newId()),
         kind = kind, cons = cons or {}, parent = parent,
         contents = nil, value = nil, shown = true,
      }

      -- MiniConsoles accumulate text until cleared; Labels replace their contents.
      local function write(text)
         mock.count("draw")
         if kind == "miniconsole" then
            self.contents = (self.contents or "") .. tostring(text)
         else
            self.contents = tostring(text)
         end
         return self
      end

      local implementations = {
         echo = write, decho = write, cecho = write, hecho = write,
         clear = function() mock.count("clear") self.contents = "" return self end,
         show  = function() self.shown = true return self end,
         hide  = function() self.shown = false return self end,
         setStyleSheet = function(_, sheet)
            mock.count("style")
            self.style = sheet
            return self
         end,
         -- Geyser's move(x, y) and resize(width, height): new constraints, same formats. A
         -- nil keeps the current one, as Geyser.Container:move/resize do.
         move = function(_, x, y)
            self.cons.x, self.cons.y = x or self.cons.x, y or self.cons.y
            return self
         end,
         resize = function(_, width, height)
            self.cons.width = width or self.cons.width
            self.cons.height = height or self.cons.height
            return self
         end,
         -- Kept, so a test can click a label and read what it says on hover.
         setClickCallback = function(_, fn) self.onClick = fn return self end,
         setToolTip = function(_, text) self.tooltip = text return self end,
         enableScrollBar  = function() self.scrollBar = true  return self end,
         disableScrollBar = function() self.scrollBar = false return self end,
         setValue = function(_, current, max, text)
            mock.count("value")
            self.value = { current = current, max = max, text = text }
            return self
         end,
      }
      local function linkImpl(_, text, command, hint, singleClick)
         mock.links[#mock.links + 1] =
            { window = self.name, text = text, command = command, hint = hint }
         return write(text)
      end
      implementations.cechoLink, implementations.dechoLink = linkImpl, linkImpl
      implementations.echoLink,  implementations.hechoLink = linkImpl, linkImpl

      for _, method in ipairs(METHODS[kind] or {}) do
         local implementation = implementations[method]
         if implementation then
            if implementation == write then
               self[method] = function(_, text) return write(text) end
            else
               self[method] = implementation
            end
         else
            self[method] = function() return self end
         end
      end

      mock.widgets[self.name] = self
      return self
   end

   local function constructor(kind)
      return { new = function(_, cons, parent) return widget(kind, cons, parent) end }
   end

   _G.Geyser = {
      Gauge       = constructor("gauge"),
      Label       = constructor("label"),
      MiniConsole = constructor("miniconsole"),
      Container   = constructor("container"),
   }

   -- Geyser.Mapper. Mudlet has ONE map widget per profile and Geyser.Mapper is a handle
   -- onto it, so createMapper() calls are recorded rather than counted as new objects --
   -- a second :new() repositions the same widget, it does not make a second map. The
   -- constructor also defaults `embedded` to true when neither embedded nor dockPosition
   -- is given, which is what makes the map draw inside our container instead of floating
   -- free; the assertion for that lives in test/run.lua.
   mock.mapperCalls = {}

   function _G.createMapper(windowname, x, y, w, h)
      mock.mapperCalls[#mock.mapperCalls + 1] =
         { windowname = windowname, x = x, y = y, width = w, height = h }
      return true
   end
   function _G.openMapWidget() return true end
   function _G.closeMapWidget() return true end
   function _G.centerview(roomId) mock.centeredOn = roomId return true end

   _G.Geyser.Mapper = {
      new = function(self, cons, container)
         cons = cons or {}
         local created = widget("mapper", cons, container)
         if cons.embedded == nil and not cons.dockPosition then
            created.embedded = true
         else
            created.embedded = cons.embedded
         end
         if created.embedded then
            createMapper("main", 0, 0, 100, 100)
         end
         function created:reposition()
            if created.embedded then createMapper("main", 0, 0, 100, 100) end
            return true
         end
         return created
      end,
   }
   -- Gauges expose front/back/text sub-labels.
   local gaugeNew = _G.Geyser.Gauge.new
   _G.Geyser.Gauge.new = function(selfRef, cons, parent)
      local gauge = gaugeNew(selfRef, cons, parent)
      gauge.front = widget("label", { name = gauge.name .. ".front" }, gauge)
      gauge.back  = widget("label", { name = gauge.name .. ".back" }, gauge)
      gauge.text  = widget("label", { name = gauge.name .. ".text" }, gauge)
      return gauge
   end

   -- Adjustable.Container deliberately mirrors the real constructor's shape, including
   -- the `self.parent:new(...)` indirection on the first line. That means calling it as
   -- `.new(options)` instead of `:new(options)` fails here exactly as it does in Mudlet
   -- ("attempt to index field 'parent'"), rather than quietly succeeding and letting a
   -- broken call ship.
   -- Adjustable.Container deliberately mirrors the real constructor's shape, including
   -- the `self.parent:new(...)` indirection on the first line. That means calling it as
   -- `.new(options)` instead of `:new(options)` fails here exactly as it does in Mudlet
   -- ("attempt to index field 'parent'"), rather than quietly succeeding and letting a
   -- broken call ship.
   --
   -- It also reproduces two behaviours that are easy to miss and that between them can
   -- leave the whole interface invisible with no error anywhere:
   --
   --   * `all` is keyed by NAME, and a new container of an existing name INHERITS that
   --     container's `hidden` flag (real source, GeyserAdjustableContainer.lua ~1126).
   --   * autoLoad restores a previously saved `hidden` from disk.
   --
   -- mock.savedContainerState stands in for <profile>/AdjustableContainer/<name>.lua.
   mock.savedContainerState = mock.savedContainerState or {}

   _G.Adjustable = {
      Container = {
         all = {},
         parent = {
            new = function(_, cons, container)
               return widget("adjustable", cons, container)
            end,
         },
      },
   }

   _G.Adjustable.Container.new = function(self, cons, container)
      local created = self.parent:new(cons, container)
      local name = created.name

      -- Inherit hidden from an existing container of the same name.
      local existing = self.all[name]
      if existing and existing.shown == false then
         created.shown = false
      end

      -- autoLoad restores saved state, including hidden.
      if cons and cons.autoLoad and mock.savedContainerState[name] then
         created.shown = not mock.savedContainerState[name].hidden
      end

      function created:deleteSaveFile()
         mock.savedContainerState[name] = nil
         return true
      end

      self.all[name] = created
      return created
   end
end

function mock.uninstallGeyser()
   _G.Geyser = nil
   _G.Adjustable = nil
   mock.widgets = {}
end

--- Install a fake map: a grid of rooms in one area, so the walker can be exercised.
---
--- Rooms are laid out on a line at x = index, which makes coordinate distance and path
--- length agree and keeps the expected walk order obvious.
--- @param count number rooms to create
function mock.installMap(count)
   mock.map = { rooms = {}, area = 1, walkedTo = {} }
   for id = 1, count do
      mock.map.rooms[id] = { x = id, y = 0, z = 0, area = 1 }
   end

   _G.speedWalkDir = {}

   function _G.getRoomArea(id)
      local room = mock.map.rooms[tonumber(id)]
      return room and room.area or nil
   end

   function _G.getAreaRooms(area)
      local out = {}
      for id, room in pairs(mock.map.rooms) do
         if room.area == area then out[#out + 1] = id end
      end
      table.sort(out)
      return out
   end

   function _G.getRoomCoordinates(id)
      local room = mock.map.rooms[tonumber(id)]
      if not room then return nil end
      return room.x, room.y, room.z
   end

   --- Rooms sit in a line with id == x, so a path is the run of ids between them. Real
   --- Mudlet fills BOTH speedWalkDir and speedWalkPath; the walker reads the latter to take
   --- a single step rather than speedwalking a whole route, so the mock has to supply it.
   function _G.getPath(from, to)
      local a, b = mock.map.rooms[tonumber(from)], mock.map.rooms[tonumber(to)]
      _G.speedWalkDir, _G.speedWalkPath = {}, {}
      if not (a and b) then return false end
      local forward = b.x >= a.x
      local steps = math.abs(b.x - a.x)
      for step = 1, steps do
         _G.speedWalkDir[step] = forward and "e" or "w"
         _G.speedWalkPath[step] = a.x + (forward and step or -step)
      end
      mock.map.lastPathfind = (mock.map.lastPathfind or 0) + 1
      mock.map.pathTo = tonumber(to)
      return true
   end

   function _G.getAreaTable() return { ["Test Area"] = 1 } end
   function _G.getRooms()
      local out = {}
      for id in pairs(mock.map.rooms) do out[id] = "Room " .. id end
      return out
   end
   function _G.getRoomName(id)
      return mock.map.rooms[tonumber(id)] and ("Room " .. id) or nil
   end

   -- Records WHERE the walk was headed (the last getPath's destination), so a test can
   -- check the room a walk was sent to, not only that one went out.
   function _G.doSpeedWalk()
      mock.map.walkedTo[#mock.map.walkedTo + 1] = mock.map.pathTo or true
      return true
   end

   -- Mudlet table helpers the walker and Geyser rely on.
   function table.size(t)
      local n = 0
      for _ in pairs(t or {}) do n = n + 1 end
      return n
   end
   function table.contains(t, value)
      for _, v in pairs(t or {}) do if v == value then return true end end
      return false
   end
end

--- Count of getPath calls, for asserting the walker is not pathfinding everything.
function mock.pathfindCount()
   return (mock.map and mock.map.lastPathfind) or 0
end

--- Deliver a GMCP message: set the payload at the dotted path and raise the event.
function mock.feed(message, payload)
   local node = _G.gmcp
   local parts = {}
   for part in message:gmatch("[^.]+") do parts[#parts + 1] = part end
   for index = 1, #parts - 1 do
      node[parts[index]] = node[parts[index]] or {}
      node = node[parts[index]]
   end
   node[parts[#parts]] = payload
   raiseEvent("gmcp." .. message)
end

--- Translate the small regex subset our aliases and triggers use into Lua patterns.
--- Deliberately narrow: anything fancier than this should not be in a pattern anyway.
--- Shared by mock.command() (aliases) and mock.line() (triggers) so both understand the
--- same subset -- a real trigger pattern like `\d+` should behave identically whichever
--- mock function is exercising it.
---
--- Character-class-aware on purpose. A blanket `gsub("%-", "%%-")` escapes EVERY hyphen,
--- including the one in `[a-zA-Z]` that means "range" -- Lua patterns use the identical
--- `a-z` range syntax inside `[...]`, so escaping it there turns "a to z" into the five
--- literal characters {a, -, z, A, Z} and the class silently stops matching almost
--- everything it was meant to. A single-pass scanner that tracks whether it is currently
--- inside `[...]` is what tells "hyphen as range" from "hyphen as a literal quantifier-
--- adjacent character" apart -- position, not the character itself, is what disambiguates.
local function toLuaPattern(regex)
   local out = {}
   local i, n = 1, #regex
   local inClass = false
   while i <= n do
      local c = regex:sub(i, i)
      if c == "%" then
         out[#out + 1] = "%%"
      elseif c == "[" then
         inClass = true
         out[#out + 1] = c
      elseif c == "]" then
         inClass = false
         out[#out + 1] = c
      elseif c == "-" and not inClass then
         out[#out + 1] = "%-"
      elseif c == "\\" then
         local nextChar = regex:sub(i + 1, i + 1)
         if nextChar == "s" then out[#out + 1] = "%s"
         elseif nextChar == "d" then out[#out + 1] = "%d"
         elseif nextChar == "w" then out[#out + 1] = "%w"
         -- The negated classes. Lua spells them with the capital letter too, so the
         -- translation is direct -- but without this branch `\S` fell through to the
         -- punctuation test, failed it, and came out as a literal backslash followed by an
         -- `S`. A column-anchored pattern using `\S+` then matched nothing here while
         -- working in Mudlet, which is the failure mode this whole translator exists to
         -- prevent.
         elseif nextChar == "S" then out[#out + 1] = "%S"
         elseif nextChar == "D" then out[#out + 1] = "%D"
         elseif nextChar == "W" then out[#out + 1] = "%W"
         -- An escaped punctuation character is a LITERAL in PCRE, and Lua's magic set is
         -- not the same set, so it has to be re-escaped Lua's way rather than passed
         -- through. Only `\.` was handled: `\?` fell to the else branch and came out as a
         -- literal backslash followed by a Lua `?` quantifier -- "an optional backslash",
         -- which matches nothing and fails silently. A real trigger
         -- ("What is it that you wish to drink?") looked dead in tests and worked in Mudlet.
         elseif nextChar:match("^%p$") then out[#out + 1] = "%" .. nextChar
         else out[#out + 1] = c; nextChar = nil end
         if nextChar then i = i + 1 end
      elseif (c == "+" or c == "*") and regex:sub(i + 1, i + 1) == "?" then
         -- PCRE lazy quantifier. Lua spells `.+?` and `.*?` as `.-`, and there is no
         -- separate one-or-more form. Dropping the `?` instead -- which is what happened
         -- before this branch existed -- silently converts a lazy match to a greedy one:
         -- `(.+?), condemning` would swallow every comma on the line. The pattern then
         -- matches nothing in the mock while working perfectly in Mudlet.
         out[#out] = nil          -- discard the `.` this quantifier applies to
         out[#out + 1] = ".-"
         i = i + 1
      else
         out[#out + 1] = c
      end
      i = i + 1
   end
   return (table.concat(out):gsub("%(%?:", "("))   -- (?: non-capturing group -> plain (
end

--- One regex, as the LIST of Lua patterns that together mean the same thing.
---
--- Lua patterns have no alternation, and ui/names.lua's highlighter is one big
--- `(?:Alice|Bob|Carol)` -- the whole roster as a single trigger, which is the change that
--- got the name scan off the per-line path. Translating that to a Lua pattern is not
--- possible; enumerating it is, and enumerating it is exactly what PCRE does anyway.
---
--- Deliberately narrow, in the same spirit as toLuaPattern: ONE alternation group, and only
--- alternation inside it. Anything more layered than that does not belong in a trigger
--- pattern, and pretending to support it here would let a pattern pass the tests and fail
--- in Mudlet -- the precise failure this translator exists to prevent.
--- Translation is memoised by regex, and that is not just tidiness.
---
--- mock.line() runs every registered trigger against the line -- seventy-odd of them -- and
--- translated each pattern afresh every time. With ui/names.lua's roster trigger, one regex
--- expands to one Lua pattern per person, so a forty-name database made a single mock.line()
--- call do a hundred-odd translations. That is milliseconds per line of a benchmark whose
--- entire subject is microseconds per line.
---
--- Patterns are created once and never rewritten, so a plain unbounded table is right here.
local patternCache = {}

local function toLuaPatterns(regex)
   local hit = patternCache[regex]
   if hit then return hit end

   local before, branches, after = regex:match("^(.-)%((.-)%)(.*)$")
   if not branches or not branches:find("|", 1, true) then
      hit = { toLuaPattern(regex) }
      patternCache[regex] = hit
      return hit
   end
   -- A `?:` survives from the non-capturing group; strip it before splitting.
   branches = branches:gsub("^%?:", "")

   local out = {}
   for branch in (branches .. "|"):gmatch("(.-)|") do
      out[#out + 1] = toLuaPattern(before .. branch .. after)
   end
   patternCache[regex] = out
   return out
end

--- Type a command, the way a user would.
---
--- Matches it against the registered aliases and fires the first that matches, populating
--- `matches` as Mudlet does (matches[1] = whole match, matches[2..] = captures). Returns
--- true if an alias consumed it, false if it would have been sent to the game.
---
--- This exists because the previous mock only *stored* alias patterns and never matched
--- them, so `^emunah%s*(.*)$` -- a Lua pattern in a slot that takes a PCRE regex -- passed
--- every test and then failed on the very first real use.
function mock.command(text)
   for _, alias in pairs(mock.aliases) do
      local pattern = toLuaPattern(alias.pattern)
      local ok, captures = pcall(function()
         return { string.find(text, pattern) }
      end)
      if ok and captures[1] then
         local m = { text }
         for index = 3, #captures do m[#m + 1] = captures[index] end
         -- A pattern with no capture group still needs matches[2] absent, as in Mudlet.
         _G.matches = m
         alias.fn()
         return true
      end
   end
   -- Not an alias: it goes to the game, which Mudlet announces like any other send. Not
   -- added to mock.sent, which records what EMUNAH sent.
   raiseEvent("sysDataSendRequest", text)
   return false
end

--- Fire any trigger whose pattern matches a line, the way Mudlet would.
---
--- Populates `matches` from real capture groups (matches[1] = whole line, matches[2..] =
--- captures), the same as mock.command() already does for aliases -- a trigger with a
--- capture group (an actor's name in a third-person combat message, say) needs the actual
--- captured text, not a copy of the whole line.
--- Triggers fire in CREATION ORDER, as Mudlet does.
---
--- `pairs()` over the trigger table was non-deterministic, and that is not a cosmetic
--- difference: namedb/capture.lua depends on its listing patterns running before its
--- accounting pass on the same line, which is a real ordering guarantee Mudlet makes. An
--- unordered mock passes and fails the same code at random.
local function triggersInOrder()
   local ids = {}
   for id in pairs(mock.triggers) do ids[#ids + 1] = id end
   table.sort(ids)
   local ordered = {}
   for _, id in ipairs(ids) do ordered[#ordered + 1] = mock.triggers[id] end
   return ordered
end

function mock.prompt(text)
   mock.onPrompt = true
   local fired = mock.line(text)
   mock.onPrompt = false
   return fired
end

--- Real seconds mock.line() has spent MATCHING, as opposed to running trigger callbacks.
---
--- Matching here is string.find over translated Lua patterns, standing in for Mudlet's C++
--- PCRE -- a cost of the harness, not of Emunah. test/latency.lua subtracts it so what it
--- reports is the Lua our code actually runs. Accumulated as it goes, not per line, so a
--- reading taken from inside a callback (the moment of a send) is already correct.
mock.matchTime = 0

function mock.line(text)
   local fired = 0
   local clock = mock.realClock or os.clock
   local segment = clock()
   -- Real Mudlet exposes the line being processed to getCurrentLine(); a trigger that
   -- re-reads its own line (the highlighter, the capture ring buffer) needs that to be the
   -- line it is firing on rather than whatever was set last.
   mock.currentLine, mock.formatted = tostring(text), {}
   mock.buffer[#mock.buffer + 1] = mock.currentLine
   mock.cursor = nil
   for _, trigger in ipairs(triggersInOrder()) do
      -- A list, not a single pattern: an alternation regex is several Lua patterns, and the
      -- trigger fires on the FIRST that matches -- once, not once per branch, which is what
      -- Mudlet does with a single pattern however many alternatives it lists.
      for _, pattern in ipairs(toLuaPatterns(trigger.pattern)) do
         local ok, captures = pcall(function() return { string.find(text, pattern) } end)
         if ok and captures[1] then
            local m = { text }
            for index = 3, #captures do m[#m + 1] = captures[index] end
            _G.matches = m
            mock.matchTime = mock.matchTime + (clock() - segment)
            trigger.fn()
            segment = clock()
            fired = fired + 1
            break
         end
      end
   end
   mock.matchTime = mock.matchTime + (clock() - segment)
   return fired
end

return mock

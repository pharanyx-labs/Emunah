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
   mock.deletedLines = 0
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

   -- Clickable links: cechoLink/dechoLink(text, command, hint, singleClick) -- the "c"/"d"
   -- prefix only controls how colour tags in `text` are parsed (named vs decimal-tuple),
   -- same distinction as cecho/decho. `command` is Lua SOURCE, evaluated fresh when
   -- clicked -- not a function reference -- matching real Mudlet. mock.click(index)
   -- simulates a click by running exactly that source.
   mock.links = {}
   local function recordLink(text, command, hint)
      mock.links[#mock.links + 1] = { text = text, command = command, hint = hint }
      record(text)
   end
   _G.cechoLink, _G.dechoLink, _G.echoLink, _G.hechoLink =
      recordLink, recordLink, recordLink, recordLink

   -- Deletes the current line, real Mudlet's half of the "rewrite this line as a
   -- clickable one" idiom (deleteLine() then re-echo). Nothing in this mock models line
   -- buffers precisely enough to actually remove anything; recording that it was called
   -- is enough for a test to assert the rewrite happened.
   mock.deletedLines = 0
   function _G.deleteLine() mock.deletedLines = mock.deletedLines + 1 end

   --- Simulate clicking a captured link (1-indexed, in echo order).
   --- @return boolean ok, string|nil err
   function mock.click(index)
      local link = mock.links[index]
      if not link then return false, "no such link" end
      local fn, err = (loadstring or load)(link.command)
      if not fn then return false, err end
      return pcall(fn)
   end

   function _G.setBorderLeft() end
   function _G.setBorderRight() end
   function _G.setBorderTop() end
   function _G.setBorderBottom() end

   --- Round-trip time to the game, in seconds. Real Mudlet measures this; tests set it to
   --- exercise the latency-sized in-flight guard (see class/priest.lua).
   --- Wall clock, driven by mock.advance() like every other timing source here. Real
   --- Mudlet's getEpoch() is what util.now() prefers; os.clock() is CPU time and unusable
   --- for durations.
   function _G.getEpoch() return mock.clock end

   mock.latency = 0.1
   function _G.getNetworkLatency() return mock.latency end

   function _G.send(command) mock.sent[#mock.sent + 1] = tostring(command) end
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
      local snapshot = {}
      for id, fn in pairs(handlers) do snapshot[#snapshot + 1] = { id = id, fn = fn } end
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
         mock.timers[entry.id] = nil
         entry.fn()
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
   function table.save(path, tbl) store[path] = tbl end
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
         "cechoLink", "dechoLink", "echoLink", "hechoLink",
      },
      -- Geyser.Label
      label = {
         "echo", "decho", "cecho", "hecho", "clear", "show", "hide",
         "setStyleSheet", "setFgColor", "setFont", "setFontSize", "setAlignment",
         "setBold", "setItalics", "setUnderline", "setBackgroundImage",
         "setClickCallback", "setToolTip",
      },
      -- Geyser.Gauge
      gauge = {
         "setValue", "setColor", "setText", "setFormat", "setStyleSheet",
         "setFontSize", "setAlignment", "setFgColor", "echo", "show", "hide",
      },
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
         if kind == "miniconsole" then
            self.contents = (self.contents or "") .. tostring(text)
         else
            self.contents = tostring(text)
         end
         return self
      end

      local implementations = {
         echo = write, decho = write, cecho = write, hecho = write,
         clear = function() self.contents = "" return self end,
         show  = function() self.shown = true return self end,
         hide  = function() self.shown = false return self end,
         setStyleSheet = function(_, sheet) self.style = sheet return self end,
         setValue = function(_, current, max, text)
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

   function _G.doSpeedWalk()
      mock.map.walkedTo[#mock.map.walkedTo + 1] = true
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
         -- An escaped punctuation character is a LITERAL in PCRE, and Lua's magic set is
         -- not the same set, so it has to be re-escaped Lua's way rather than passed
         -- through. Only `\.` was handled: `\?` fell to the else branch and came out as a
         -- literal backslash followed by a Lua `?` quantifier -- "an optional backslash",
         -- which matches nothing and fails silently. A real trigger
         -- ("What is it that you wish to drink?") looked dead in tests and worked in Mudlet.
         elseif nextChar:match("^%p$") then out[#out + 1] = "%" .. nextChar
         else out[#out + 1] = c; nextChar = nil end
         if nextChar then i = i + 1 end
      else
         out[#out + 1] = c
      end
      i = i + 1
   end
   return (table.concat(out):gsub("%(%?:", "("))   -- (?: non-capturing group -> plain (
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
   return false
end

--- Fire any trigger whose pattern matches a line, the way Mudlet would.
---
--- Populates `matches` from real capture groups (matches[1] = whole line, matches[2..] =
--- captures), the same as mock.command() already does for aliases -- a trigger with a
--- capture group (an actor's name in a third-person combat message, say) needs the actual
--- captured text, not a copy of the whole line.
function mock.line(text)
   local fired = 0
   for _, trigger in pairs(mock.triggers) do
      local pattern = toLuaPattern(trigger.pattern)
      local ok, captures = pcall(function() return { string.find(text, pattern) } end)
      if ok and captures[1] then
         local m = { text }
         for index = 3, #captures do m[#m + 1] = captures[index] end
         _G.matches = m
         trigger.fn()
         fired = fired + 1
      end
   end
   return fired
end

return mock

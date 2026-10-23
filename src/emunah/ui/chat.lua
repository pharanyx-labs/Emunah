--- Tabbed chat, drawn by Emunah itself.
---
--- A tab bar of Labels over one MiniConsole per tab, in the right-hand column under the
--- "Chat" title bar. All comes first and shows everything; the rest come from ui.chatTabs.
---
--- Capture happens in gmcp/comm.lua, not here. This module only renders. That split means
--- chat history keeps accumulating with the UI switched off, and a UI rebuild (or a reload,
--- since comm keeps its history on _persist) can catch fresh tabs up instead of starting
--- blank.
---
--- DRAWN WHEN SEEN. A message is written into the console on screen and nowhere else. Every
--- other tab only counts it, and is caught up from comm's history -- just the lines it has
--- not drawn yet -- when it is next shown. A market tab you never open never costs a draw,
--- and switching to a tab costs only what it missed. Each console keeps its own scrollback,
--- so a tab comes back where you left it.
---
--- WHAT A TAB SAYS. An unread count beside its name, in the accent colour; tells in the
--- warning colour, because a tell is the one that wants an answer. The title bar sums them.
---
--- EACH LINE. The time it arrived (not the time it was drawn, so a caught-up tab is not
--- stamped all alike), then the game's text, with the talker coloured as the name
--- highlighter colours them in the main window. Clicking the time puts the reply on the
--- command line: `tell <name> ` for a tell, the channel's own command for the rest.

local M = {}

local theme  = emunah.ui.theme
local layout = emunah.ui.layout
local log    = emunah.log

--- The tab that shows everything. Always first.
M.ALL = "All"

--- Height of the tab bar, in pixels.
M.TAB_PX = 22

--- Most lines a tab is caught up with at once. A tab that missed more starts at the newest
--- of them; comm keeps no more than this per tab anyway.
M.CATCH_UP = 300

M.mode    = "none"   -- "tabs" | "none"
M.order   = {}       -- tab names, All first
M.views   = {}       -- name -> { name, console, label, mark, unread, state }
M.console = nil      -- the console on screen
M.active  = (emunah._persist and emunah._persist.chatActive) or M.ALL

--- Declared here, above build(), which clears it. Declared further down, build() wrote a
--- global of the same name and the warning in M.append() never re-armed.
local warnedNoConsole = false

--- Set once the console has refused output, so a broken widget reports itself exactly once
--- rather than either spamming the log or -- worse -- saying nothing at all. Cleared by a
--- successful build: a fresh console is working until proven otherwise.
M.broken  = false

--- Set once a rebuild has been attempted, so a console that cannot be rebuilt is not
--- rebuilt on every single line arriving. Cleared by a successful build.
M.rebuilt = false

--- Messages that arrived with nowhere to put them. Counted so `emset chat` can say so, and
--- warned about once.
M.dropped = 0

local function available()
   return layout.container("right") ~= nil and type(Geyser) == "table"
end

--- A view by name, case-insensitively.
function M.find(name)
   name = tostring(name or ""):lower()
   for _, tab in ipairs(M.order) do
      if tab:lower() == name then return M.views[tab] end
   end
   return nil
end

-- ---------------------------------------------------------------------------
-- one line
-- ---------------------------------------------------------------------------

--- decho colour tag for a "#rrggbb".
local function hexTag(hex)
   local r, g, b = tostring(hex):match("^#(%x%x)(%x%x)(%x%x)$")
   if not r then return nil end
   return string.format("<%d,%d,%d>", tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
end

--- Colour the talker's name, as ui/names.lua would in the main window. Only the first
--- whole-word occurrence; after it, the colour that was in force before it comes back.
function M.highlight(text, talker)
   if not talker or talker == "" then return text end
   local names = emunah.ui.names
   if not (names and names.enabled and names.styleFor) then return text end
   local ok, style = pcall(names.styleFor, talker)
   local tag = ok and style and style.colour and hexTag(style.colour)
   if not tag then return text end

   local from = 1
   while true do
      local at, stop = text:find(talker, from, true)
      if not at then return text end
      local before, after = text:sub(at - 1, at - 1), text:sub(stop + 1, stop + 1)
      if not before:find("[%w]") and not after:find("[%w]") then
         local restore = "<r>"
         for found in text:sub(1, at - 1):gmatch("<[%d,:]*>") do restore = found end
         if restore == "<>" then restore = "<r>" end
         return text:sub(1, at - 1) .. tag .. talker .. restore .. text:sub(stop + 1)
      end
      from = stop + 1
   end
end

--- What a click on a line's time puts on the command line, or nil.
function M.replyFor(message)
   local channel = tostring(message.channel or ""):lower()
   if channel:find("^tell") and message.talker then
      return "tell " .. message.talker .. " "
   end
   local command = emunah.gmcp.comm.commandFor(channel)
   return command and (command .. " ") or nil
end

local function stamp(message)
   return os.date("%H:%M:%S", message.at or os.time())
end

--- Write one message into a console. Throws if the console does.
local function draw(console, message)
   local time = theme.dc("inactive") .. stamp(message)
   local reply = M.replyFor(message)
   if reply and console.dechoLink then
      console:dechoLink(time, string.format("printCmdLine(%q)", reply),
         "Reply: " .. reply, true)
      console:decho(" " .. theme.dc("text") .. M.highlight(message.text, message.talker) .. "\n")
   else
      console:decho(time .. " " .. theme.dc("text")
         .. M.highlight(message.text, message.talker) .. "\n")
   end
end

-- ---------------------------------------------------------------------------
-- failure
-- ---------------------------------------------------------------------------

--- Say, once, that rendering is failing and capture is not.
---
--- Every console write is wrapped in pcall, which is right -- a widget that throws must not
--- take the GMCP handler down with it -- but a bare pcall turns a broken chat window into a
--- silent one. Capture cannot stop here: gmcp/comm.lua records every message before this
--- module is ever called. A chat window that has gone quiet is therefore either the game no
--- longer sending, or this. Saying which turns an hour of guessing into one line.
local function renderFailed(reason)
   if not M.broken then
      M.broken = true
      log.warn("Chat console stopped accepting output (%s). Capture is unaffected -- "
         .. "the messages are still recorded; this is the window, not the feed.",
         tostring(reason))
   end

   -- REBUILD RATHER THAN ASK. Telling someone to run `emset ui rebuild` is no use when
   -- they are in a fight and the thing that broke is the window they would read the advice
   -- in. One attempt only: if the rebuild does not take, retrying per message turns a dead
   -- chat window into a dead client.
   if M.rebuilt then return false end
   M.rebuilt = true
   log.info("Rebuilding the chat console.")
   local ok, built = pcall(M.build)
   if ok and built then
      M.broken = false
      log.info("Chat console rebuilt.")
      return true
   end
   log.warn("Chat console could not be rebuilt (%s). `emset ui rebuild` retries the "
      .. "whole interface.", tostring(built))
   return false
end

-- ---------------------------------------------------------------------------
-- the tab bar
-- ---------------------------------------------------------------------------

local function tabStyle(state)
   local colour = theme.colour
   local active = state == "active"
   return string.format([[
      background-color: %s;
      border: 0px;
      border-bottom: 2px solid %s;
      border-top-left-radius: 3px;
      border-top-right-radius: 3px;
      qproperty-alignment: 'AlignCenter';
      font-family: "%s";
      font-size: %dpt;
   ]], active and colour.raised or colour.panel,
      active and colour.accent or (state == "tell" and colour.warning or colour.border),
      theme.font.family, theme.font.small)
end

local function tabState(view)
   if view.name == M.active then return "active" end
   if view.unread > 0 then return view.name == "Tells" and "tell" or "unread" end
   return "idle"
end

local function tabHTML(view, state)
   local name = theme.esc(view.name)
   if state == "active" then return theme.span("textBright", name, true) end
   if view.unread == 0 then return theme.span("textDim", name) end
   local count = view.unread > 999 and "999+" or tostring(view.unread)
   local colour = state == "tell" and "warning" or "accent"
   return theme.span(state == "tell" and "warning" or "text", name, state == "tell")
      .. "&nbsp;" .. theme.span(colour, count, true)
end

--- Repaint the tab bar and the title bar. Each label and stylesheet is drawn only when it
--- changes, so a message landing in a tab already showing a count costs one label echo.
function M.paintTabs()
   local unread, tells = 0, false
   for _, tab in ipairs(M.order) do
      local view = M.views[tab]
      if view and view.label then
         local state = tabState(view)
         if view.state ~= state then
            view.state = state
            pcall(view.label.setStyleSheet, view.label, tabStyle(state))
         end
         theme.paintLabel(view.label, "chat.tab." .. tab, tabHTML(view, state))
         if tab ~= M.ALL and state ~= "active" then
            unread = unread + view.unread
            if state == "tell" then tells = true end
         end
      end
   end
   if M.header then
      layout.header("chat", M.header, "Chat",
         unread > 0 and string.format("%d unread", unread) or nil,
         tells and "warning" or "accent")
   end
end

local function repaintSoon()
   theme.later("chat.tabs", M.paintTabs)
end

-- ---------------------------------------------------------------------------
-- showing a tab
-- ---------------------------------------------------------------------------

--- Draw what a view has not drawn yet, from comm's history.
local function catchUp(view)
   local comm = emunah.gmcp.comm
   local tab = view.name ~= M.ALL and view.name or nil
   local missed = comm.since(view.mark, tab, M.CATCH_UP)
   view.mark = comm.seq()
   view.unread = 0
   for _, message in ipairs(missed) do
      if not message.muted then
         local ok, err = pcall(draw, view.console, message)
         if not ok then return false, err end
      end
   end
   return true
end

--- Show a tab: hide the one on screen, catch this one up, and show it.
--- @return boolean false when there is no such tab
function M.show(name)
   local view = M.find(name)
   if not view then return false end
   local current = M.views[M.active]
   if current and current ~= view and current.console then
      pcall(current.console.hide, current.console)
   end
   M.active = view.name
   emunah._persist = emunah._persist or {}
   emunah._persist.chatActive = view.name
   M.console = view.console
   pcall(view.console.show, view.console)
   local ok, err = catchUp(view)
   if not ok then renderFailed(err) end
   M.paintTabs()
   return true
end

--- Clear a tab's console, or every tab's. Nothing is deleted from history: the console
--- forgets it, and a rebuild draws it again.
function M.clear(name)
   local seq = emunah.gmcp.comm.seq()
   for _, tab in ipairs(M.order) do
      local view = M.views[tab]
      if not name or view == M.find(name) then
         pcall(view.console.clear, view.console)
         view.mark, view.unread = seq, 0
      end
   end
   M.paintTabs()
end

-- ---------------------------------------------------------------------------
-- wrapping
-- ---------------------------------------------------------------------------
--
-- Measured here rather than left to Geyser's autoWrap, which wrapped short (2026-10-23
-- 14:26: lines broken at 65 characters in a console with room for more). The wrap is the
-- console's width, less the scrollbar and margin, over the width of one character of the
-- font it draws in. Mudlet does not reflow lines already drawn: a resize wraps the next.

--- Pixels of a console's width that are not text: the scrollbar and the margins.
M.WRAP_SPARE_PX = 22

--- Pixel width of one character of chat text, or nil where Mudlet cannot say.
function M.charWidth()
   if type(calcFontSize) ~= "function" then return nil end
   local ok, width = pcall(calcFontSize, theme.font.size, theme.font.family)
   width = ok and tonumber(width)
   return (width and width > 0) and width or nil
end

--- Characters per line for a console, or nil when it cannot be measured.
function M.wrapWidth(console)
   local charWidth = M.charWidth()
   if not (charWidth and console and type(console.get_width) == "function") then return nil end
   local ok, px = pcall(console.get_width, console)
   px = ok and tonumber(px)
   if not px or px <= 0 then return nil end
   return math.max(20, math.floor((px - M.WRAP_SPARE_PX) / charWidth))
end

--- Wrap every tab's console to its width. Only a console whose width changed is touched.
function M.rewrap()
   for _, tab in ipairs(M.order) do
      local view = M.views[tab]
      local columns = view and M.wrapWidth(view.console)
      if columns and columns ~= view.wrap then
         if pcall(view.console.setWrap, view.console, columns) then view.wrap = columns end
      end
   end
end

-- ---------------------------------------------------------------------------
-- building
-- ---------------------------------------------------------------------------

--- Chat owns the whole right-hand container, above the map, under the "Chat" title bar
--- layout.build() draws.
function M.build()
   if not available() then
      M.mode = "none"
      M.console, M.views, M.order = nil, {}, {}
      -- Nowhere to draw is news again after every attempt to build somewhere.
      warnedNoConsole = false
      return false
   end

   local parent = layout.container("right")
   local top = layout.TITLED_TOP

   M.header = layout.chatHeader
   M.order = { M.ALL }
   for _, tab in ipairs(emunah.gmcp.comm.tabs()) do M.order[#M.order + 1] = tab end
   if not M.find(M.active) then M.active = M.ALL end

   local bar = Geyser.Container:new({
      name = "emunah.chat.tabs", x = 4, y = top, width = "-8px", height = M.TAB_PX,
   }, parent)

   M.views = {}
   local n = #M.order
   for index, tab in ipairs(M.order) do
      local left = math.floor(100 * (index - 1) / n)
      local right = math.floor(100 * index / n)
      local key = tab:lower()

      local label = Geyser.Label:new({
         name = "emunah.chat.tab." .. key,
         x = left .. "%", y = 0, width = (right - left) .. "%", height = "100%",
      }, bar)
      label:setClickCallback(function() M.show(tab) end)
      label:setToolTip(tab == M.ALL and "Every channel" or ("Show " .. tab))
      -- A new, empty widget: whatever the paint cache says describes the one it replaced.
      theme.forgetPainted("chat.tab." .. tab)

      -- No setStyleSheet -- MiniConsole does not have it (see ui/theme.lua). A console of
      -- the same name survives a rebuild in Mudlet, text and all, so it is cleared and
      -- drawn again from history rather than drawn twice.
      -- Wrapped to the console's own width (M.rewrap), not the panels' fixed wrapAt
      -- (theme.consoleCons), which broke chat lines at 40 characters. The font is named so
      -- the width is measured in the font that is drawn.
      local cons = theme.consoleCons({
         name = "emunah.chat." .. key,
         x = 4, y = top + M.TAB_PX + 2, width = "-8px", height = "-4px",
         scrollBar = true, font = theme.font.family, autoWrap = M.charWidth() == nil,
      })
      cons.wrapAt = nil
      local console = Geyser.MiniConsole:new(cons, parent)
      if cons.autoWrap and console.enableAutoWrap then pcall(console.enableAutoWrap, console) end
      pcall(console.clear, console)
      pcall(console.hide, console)

      M.views[tab] = { name = tab, console = console, label = label, mark = 0, unread = 0 }
   end

   M.mode = "tabs"
   M.broken = false
   warnedNoConsole = false

   M.rewrap()
   -- Again once the packet is done: Adjustable.Container restores its saved size after
   -- the build, and the first measurement can be of the default one.
   theme.later("chat.rewrap", M.rewrap)
   M.show(M.active)
   if M.broken then return false end
   -- A fresh, working console earns back the one rebuild attempt renderFailed() spends on
   -- the next failure. Leaving this latched after a successful rebuild meant only the
   -- FIRST console failure of a session was ever repaired. Cleared only once the console
   -- has drawn: cleared before, a console that fails as it is shown would rebuild forever.
   M.rebuilt = false
   return true
end

-- ---------------------------------------------------------------------------
-- arriving
-- ---------------------------------------------------------------------------

--- Render one message: into the console on screen if it belongs there, and onto the
--- unread count of every other tab it belongs to.
function M.append(message)
   if not M.console then
      M.dropped = M.dropped + 1
      if not warnedNoConsole then
         warnedNoConsole = true
         log.warn("Chat has no console to render into (mode %q) -- messages are being "
            .. "captured but not shown. `emset ui rebuild` builds one.", M.mode)
      end
      return
   end
   if message.muted then return end

   local own = M.views[message.tab] or M.views[emunah.gmcp.comm.FALLBACK_TAB]
   local all = M.views[M.ALL]
   local shown = M.views[M.active]

   if own == shown or all == shown or not shown then
      local ok, err = pcall(draw, M.console, message)
      if not ok then
         renderFailed(err)
         return
      end
      if shown then shown.mark = message.seq or shown.mark end
   end

   local changed = false
   for _, view in ipairs({ own, all }) do
      if view and view ~= shown then
         view.unread = view.unread + 1
         changed = true
      end
   end
   if changed then repaintSoon() end
end

--- Unread messages per tab, for `emset chat`.
function M.unread(name)
   local view = M.find(name)
   return view and view.unread or 0
end

emunah.event.register("emunah.comm.text", function(_, message)
   M.append(message)
end, "ui.chat")

emunah.event.register("emunah.ui.built", function() M.build() end, "ui.chat")

-- A wider or narrower column wraps the next line to its new width.
emunah.event.register("sysWindowResizeEvent", function()
   theme.later("chat.rewrap", M.rewrap)
end, "ui.chat")
emunah.event.register("AdjustableContainerRepositionFinish", function(_, name)
   if name == "emunah.right" then theme.later("chat.rewrap", M.rewrap) end
end, "ui.chat")

M.build()

return M

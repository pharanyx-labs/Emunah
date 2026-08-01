--- Tabbed chat.
---
--- Routes Comm.Channel.Text into tabs. Uses the EMCO tabbed-console widget when it is
--- installed, and degrades to a single MiniConsole when it is not, so a missing optional
--- dependency costs you tabs rather than costing you chat.
---
--- Capture happens in gmcp/comm.lua, not here. This module only renders. That split means
--- chat history keeps accumulating with the UI switched off, and a UI rebuild can replay
--- the backlog into fresh tabs instead of starting blank -- which is what makes reloading
--- mid-conversation tolerable.

local M = {}

local theme  = emunah.ui.theme
local layout = emunah.ui.layout
local log    = emunah.log

M.console = nil
M.mode    = "none"   -- "emco" | "plain" | "none"

--- Set once the console has refused output, so a broken widget reports itself exactly once
--- rather than either spamming the log or -- worse -- saying nothing at all. Cleared by a
--- successful build: a fresh console is working until proven otherwise.
M.broken  = false

--- Locate EMCO.
---
--- Current versions do NOT publish a global: EMCO is a module you reach with
--- `require("MDK.emco")`. Checking only for a global (which is what most older examples
--- do) silently finds nothing on a perfectly good install and drops you to the plain
--- console with no error to explain it. So try the module first, then the historical
--- global spellings for standalone or older installs.
local function findEMCO()
   local ok, module = pcall(require, "MDK.emco")
   if ok and type(module) == "table" and module.new then return module end

   if type(EMCO) == "table" and EMCO.new then return EMCO end
   if type(demonnic) == "table" and type(demonnic.EMCO) == "table" then return demonnic.EMCO end
   return nil
end

local function available()
   return layout.container("right") ~= nil and type(Geyser) == "table"
end

--- Chat occupies the TOP of the right-hand column; ui/roompanel.lua takes the bottom half
--- below layout.CHAT_SPLIT. Both read that constant so the two cannot drift into
--- overlapping each other.
function M.build()
   if not available() then
      M.mode = "none"
      return false
   end

   local parent = layout.container("right")
   local height = string.format("%d%%", layout.percentOf(layout.CHAT_SPLIT) - 1)

   -- The all-tab has to be a real member of `consoles`. EMCO:setAllTabName() rejects any
   -- name that is not already in the list, and the object then ends up with an allTabName
   -- it never created a tab for -- which surfaces later as a nil index in
   -- adjustTabBackground(), nowhere near the actual mistake.
   local ALL_TAB = "All"
   local tabs = { ALL_TAB }
   for _, tab in ipairs(emunah.gmcp.comm.tabs()) do
      tabs[#tabs + 1] = tab
   end

   local emco = findEMCO()
   if emco then
      local ok, console = pcall(emco.new, emco, {
         name           = "emunah.chat",
         x = 2, y = 2, width = "-4px", height = height,
         consoles       = tabs,
         allTab         = true,
         allTabName     = ALL_TAB,
         blankLine      = false,
         timestamp      = true,
         timestampFormat = "HH:mm:ss",
         gap            = 2,
         tabHeight      = 22,
         fontSize       = theme.font.size,
         consoleColor   = theme.colour.base,
         activeTabBGColor    = theme.colour.raised,
         inactiveTabBGColor  = theme.colour.panel,
         activeTabFGColor    = theme.colour.textBright,
         inactiveTabFGColor  = theme.colour.textDim,
         tabBoxColor         = theme.colour.panel,
         consoleContainerColor = theme.colour.panel,
      }, parent)

      if ok and console then
         M.console = console
         M.mode = "emco"
         M.broken = false
         warnedNoConsole = false
         M.replay()
         return true
      end
      log.warn("EMCO is present but would not build (%s); falling back to a plain console.",
         tostring(console))
   end

   -- Fallback: one console, channel name prefixed per line.
   -- No setStyleSheet -- MiniConsole does not have it (see ui/theme.lua).
   local console = Geyser.MiniConsole:new(theme.consoleCons({
      name = "emunah.chat.plain",
      x = 2, y = 2, width = "-4px", height = height,
      scrollBar = true,
   }), parent)
   M.console = console
   M.mode = "plain"
   M.broken = false
   warnedNoConsole = false

   if not findEMCO() then
      log.info("EMCO not found -- chat is a single console. Install the MDK for tabs.")
   end

   M.replay()
   return true
end

--- Say, once, that rendering is failing and capture is not.
---
--- WHY THIS EXISTS. Both console writes below are wrapped in pcall, which is right -- a
--- widget that throws must not take the GMCP handler down with it -- but a bare pcall
--- turns a broken chat window into a silent one. The reported symptom was "chat capture
--- stops", and capture is the one thing that cannot stop here: gmcp/comm.lua records every
--- message into its own history before this module is ever called, precisely so the two
--- fail independently. A chat window that has gone quiet is therefore either the game no
--- longer sending, or this. Saying which turns an hour of guessing into one line.
--- Set once a rebuild has been attempted, so a console that cannot be rebuilt is not
--- rebuilt on every single line arriving.
M.rebuilt = false

local function renderFailed(reason)
   if not M.broken then
      M.broken = true
      log.warn("Chat console stopped accepting output (%s). Capture is unaffected -- "
         .. "the messages are still recorded; this is the window, not the feed.",
         tostring(reason))
   end

   -- REBUILD RATHER THAN ASK. Telling someone to run `emunah ui rebuild` is no use when
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
   log.warn("Chat console could not be rebuilt (%s). `emunah ui rebuild` retries the "
      .. "whole interface.", tostring(built))
   return false
end

--- Messages that arrived with nowhere to put them.
---
--- `M.append` returns early when there is no console, which is correct -- but silently, and
--- a chat window that never built looks exactly like one that stopped working. Counted so
--- `emunah chat` can say so, and warned about once.
M.dropped = 0
local warnedNoConsole = false

--- Render one message.
function M.append(message)
   if not M.console then
      M.dropped = M.dropped + 1
      if not warnedNoConsole then
         warnedNoConsole = true
         log.warn("Chat has no console to render into (mode %q) -- messages are being "
            .. "captured but not shown. `emunah ui rebuild` builds one.", M.mode)
      end
      return
   end

   if M.mode == "emco" then
      -- EMCO creates the tab set at construction; a channel that routes to an unknown tab
      -- would be dropped silently, so anything unexpected goes to the fallback tab.
      local tab = message.tab
      local ok, err = pcall(function() M.console:decho(tab, message.text .. "\n") end)
      if not ok then
         local fellBack, fallbackErr = pcall(function()
            M.console:decho(emunah.gmcp.comm.FALLBACK_TAB, message.text .. "\n")
         end)
         -- The first failure is ordinary: an unexpected tab name. The second is not --
         -- it means the console itself is gone, which is the case worth reporting.
         if not fellBack then renderFailed(fallbackErr or err) end
      end
      return
   end

   -- The plain console path was unguarded: a console that has gone away takes the GMCP
   -- handler down with it, and then nothing downstream of comm.text runs either.
   local ok, err = pcall(function()
      M.console:decho(string.format("%s[%s] %s\n",
         theme.dc("textDim"), message.tab, message.text))
   end)
   if not ok then renderFailed(err) end
end

--- Replay recent history into a freshly built console, so a reload does not blank the
--- conversation you were in the middle of.
function M.replay()
   local comm = emunah.gmcp.comm
   if not comm then return end
   for _, message in ipairs(comm.recent(40)) do
      M.append(message)
   end
end

emunah.event.register("emunah.comm.text", function(_, message)
   M.append(message)
end, "ui.chat")

emunah.event.register("emunah.ui.built", function() M.build() end, "ui.chat")

M.build()

return M

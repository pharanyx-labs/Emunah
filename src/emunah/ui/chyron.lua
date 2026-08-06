--- The chyron: a scrolling announcement ticker in its own strip at the top of the console.
---
--- Up to M.MAX_MESSAGES messages are held at once, oldest dropped first. All of them are
--- joined into one reel and scrolled continuously, the way a TV news chyron actually moves
--- -- not a slideshow that pauses on each message in turn. The reel wraps, so with one
--- message queued it loops that one message forever; with three, all three scroll past in
--- turn, on a loop, with no message ever pausing the motion.
---
--- Lives in ui/layout.lua's "top" container, which is scoped to the console's own width
--- (WIDTH_LEFT..100%-WIDTH_RIGHT) rather than the whole window -- see that module's header
--- for why. This module only ever fills the container it is given; it does not size or
--- position itself.

local M = {}

local theme  = emunah.ui.theme
local layout = emunah.ui.layout
local event  = emunah.event

--- Oldest-first queue of { text, colour }. A 4th M.send() drops the oldest.
M.messages = {}

M.MAX_MESSAGES = 3

--- Between reel entries, in the reel's own colour rather than each message's -- a run of
--- messages in different colours should not read as one of them bleeding into the next.
M.SEPARATOR = "     \226\128\162     "   -- "     •     "

--- Seconds between scroll steps. Small and frequent rather than large and rare: a chyron
--- that visibly jumps reads as broken, not as scrolling.
M.TICK_INTERVAL = 0.08

--- Characters advanced per tick. Kept as a knob rather than folded into TICK_INTERVAL so
--- either speed or smoothness can be tuned independently.
M.STEP = 1

--- Font size for the strip. Deliberately not theme.font.size (10pt, sized for dense side
--- panels) -- a ticker read at a glance needs to be a little larger, the same reasoning
--- ui/echo.lua's eventLabel uses for its own banner text.
local FONT_SIZE = 13

--- Rough monospace glyph width in pixels at FONT_SIZE, for estimating how many characters
--- fit the strip. theme.font.family is a monospace face, so this is a real average rather
--- than the rough guess a proportional font would need (see ui/echo.lua's CHAR_WIDTH, which
--- has to guess for exactly that reason).
local CHAR_WIDTH = FONT_SIZE * 0.6

local widget = nil
local scrollPos = 0
local tickId = nil

local function available()
   return type(Geyser) == "table" and layout.container("top") ~= nil
end

--- How many characters fit the strip right now, from the container's actual width -- not a
--- fixed guess, so a resized or differently-sized window still fills the visible strip
--- rather than under- or over-shooting it.
---
--- CACHED, because the answer only changes when the window does. This is read on every
--- scroll step -- 12.5 times a second, for as long as any message is up -- and it costs a
--- getMainWindowSize() plus two layout.percentOf() calls, each of which is a tostring() and
--- a pattern match. Invalidated from the sysWindowResizeEvent handler at the bottom of this
--- file, which is the only thing that can change it.
local cachedVisible = nil

local function visibleChars()
   if cachedVisible then return cachedVisible end
   local winWidth = getMainWindowSize() or 1920
   local consoleFraction = (100 - layout.percentOf(layout.WIDTH_LEFT)
      - layout.percentOf(layout.WIDTH_RIGHT)) / 100
   local pixels = winWidth * consoleFraction
   cachedVisible = math.max(math.floor(pixels / CHAR_WIDTH), 10)
   return cachedVisible
end

--- The reel: every queued message's own colour, joined by the separator in a dim border
--- colour so it stays visually distinct from any message's own accent.
local function reel()
   if #M.messages == 0 then return "" end
   local parts = {}
   for _, message in ipairs(M.messages) do
      parts[#parts + 1] = theme.dc(message.colour or "textBright") .. message.text
   end
   return table.concat(parts, theme.dc("border") .. M.SEPARATOR)
end

--- Plain-text length of a decho string -- the colour escapes take no space on screen, but
--- they do take characters in the Lua string, and slicing by raw byte position would cut a
--- message off mid-escape-code as often as mid-word.
local function visibleLength(text)
   return #(text:gsub("<%d+,%d+,%d+>", ""))
end

--- Render the current scroll position. Self-contained: the caller does not need to know how
--- the reel is built or where in it we currently are, only that the display now reflects it.
-- THE SCROLL IS PRECOMPUTED, because it runs at 12.5 Hz forever.
--
-- render() used to rebuild everything on every step: the reel, a `visibleLength` gsub that
-- copies the whole string, four concatenations to build `doubled`, and then a loop that
-- called `doubled:sub(index, index)` PER VISIBLE CHARACTER -- one single-byte string
-- allocation per glyph, roughly a hundred and fifty per step, twelve and a half times a
-- second. About 1875 allocations per second for as long as any message was on screen, all of
-- it collected on the UI thread, and none of it visible to test/bench.lua.
--
-- None of that depends on the scroll position. What does is a byte offset, and the colour in
-- force there. So the reel is compiled once when the message set changes into:
--
--   frame.doubled  the reel, its gap, and a repeat of both
--   frame.at[g]    byte offset in `doubled` where visible glyph g begins
--   frame.colour[g] the escape in force at glyph g, or "" if none
--
-- and a step becomes one sub() and one concat.
local frame = nil

local function compile()
   local text = reel()
   local visible = visibleChars()
   -- A gap of spaces between the end of the reel and its own repeat, sized to the visible
   -- width, so the loop reads as "the messages scrolled past and then came back around"
   -- rather than the last message running straight into the first with no seam at all.
   local gap = string.rep(" ", visible)
   -- Doubled so a window straddling the seam still has real characters on both sides.
   local doubled = text .. gap .. text .. gap

   local at, colour = {}, {}
   local glyphs, index, inForce = 0, 1, ""
   local size = #doubled
   while index <= size do
      local escape = doubled:match("^<%d+,%d+,%d+>", index)
      if escape then
         -- Colour escapes take no space on screen but do take bytes in the string, so they
         -- are counted against the byte offset and never against the glyph count.
         inForce = escape
         index = index + #escape
      else
         glyphs = glyphs + 1
         at[glyphs] = index
         colour[glyphs] = inForce
         index = index + 1
      end
   end

   frame = {
      doubled = doubled,
      at = at,
      colour = colour,
      -- One period of the loop: the reel's own visible length plus the gap.
      period = math.max((glyphs / 2), 1),
      glyphs = glyphs,
      visible = visible,
   }
   return frame
end

--- Throw away the compiled scroll. The next render() rebuilds it.
local function recompile()
   frame = nil
end

--- How many characters the strip shows at once. Exposed for `emunah ui` and for the tests,
--- which have to build the same window the renderer does in order to compare against it.
function M.width()
   return visibleChars()
end

local function render()
   if not widget then return end
   if #M.messages == 0 then
      widget:clear()
      return
   end

   local current = frame or compile()
   if current.glyphs == 0 then
      widget:clear()
      return
   end

   local visible = current.visible
   local pos = math.floor(scrollPos % current.period)

   local from = current.at[pos + 1]
   -- The window can run past the end of the doubled reel only if `period` and `glyphs`
   -- disagree, which they cannot -- but a nil here would be a hard error at 12.5 Hz, so the
   -- last glyph is the floor rather than trusting the arithmetic.
   local lastGlyph = math.min(pos + visible, current.glyphs)
   local to = (current.at[lastGlyph] or current.at[current.glyphs])

   -- The escape in force where the window starts has to be re-stated: the bytes carrying it
   -- are behind `from` and have been cut away, so without this the window is drawn in
   -- whatever colour the previous decho happened to leave behind.
   widget:decho(current.colour[pos + 1] .. current.doubled:sub(from, to))
end

--- Advance the scroll and re-render, then re-arm -- self-scheduling the same way
--- ui/echo.lua's eventLabelLoop is, so nothing outside this module has to keep it moving.
local function tick()
   tickId = nil
   scrollPos = scrollPos + M.STEP
   render()
   if #M.messages > 0 then tickId = tempTimer(M.TICK_INTERVAL, tick) end
end

local function ensureTicking()
   if tickId or #M.messages == 0 then return end
   tickId = tempTimer(M.TICK_INTERVAL, tick)
end

local function stopTicking()
   if tickId then killTimer(tickId) end
   tickId = nil
end

--- Queue a message to scroll through the chyron. The entry point "send a message to it
--- programmatically" is built around -- anything in the codebase can call this.
--- @param text string
--- @param colour string|nil a theme.colour key, default "textBright"
--- @return boolean
function M.send(text, colour)
   text = tostring(text or "")
   if text == "" then return false end

   table.insert(M.messages, { text = text, colour = colour })
   -- Oldest dropped first -- a chyron showing four things at once is not a chyron, it is a
   -- wall of text, and "three, on a loop" was the actual request.
   while #M.messages > M.MAX_MESSAGES do table.remove(M.messages, 1) end

   -- The reel changed, so the compiled scroll describes a reel that no longer exists.
   recompile()
   render()
   ensureTicking()
   return true
end

--- Drop every queued message and stop scrolling.
function M.clear()
   M.messages = {}
   scrollPos = 0
   recompile()
   stopTicking()
   if widget then widget:clear() end
end

function M.build()
   if not available() then return false end
   local parent = layout.container("top")

   widget = Geyser.Label:new({
      name = "emunah.chyron", x = 0, y = 0, width = "100%", height = "100%",
   }, parent)
   widget:setStyleSheet(string.format([[
      background-color: %s;
      color: %s;
      font-family: "%s";
      font-size: %dpt;
      qproperty-alignment: 'AlignLeft | AlignVCenter';
      padding-left: 4px;
   ]], theme.colour.base, theme.colour.textBright, theme.font.family, FONT_SIZE))

   render()
   -- `emunah ui rebuild` (or any other trigger of layout.build()) tears down and recreates
   -- the containers, which calls this again -- but it re-invokes the already-loaded module,
   -- it does not re-execute this file, so M.messages is untouched. Resume scrolling into the
   -- fresh widget rather than sitting on a silently-stale render until the next M.send().
   -- (A genuine `emreload` DOES re-execute this file top to bottom, same as every other
   -- module, and the queue starts empty again -- that is ordinary reload behaviour, not
   -- something this function needs to account for.)
   ensureTicking()
   return true
end

event.register("emunah.ui.built", function() M.build() end, "ui.chyron")

-- A resize changes how many characters fit the strip, which changes both the cached width
-- and the gap the compiled reel is padded with. Both are dropped here; the next scroll step
-- rebuilds them. This is the ONLY thing that can invalidate visibleChars(), which is what
-- makes caching it safe at 12.5 Hz.
event.register("sysWindowResizeEvent", function()
   cachedVisible = nil
   recompile()
end, "ui.chyron")

M.build()

return M

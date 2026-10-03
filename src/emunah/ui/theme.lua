--- Visual language for the interface.
---
--- One place for every colour, font and border so the panels stay consistent and a
--- retheme is a single-file change. Colours are given as hex strings for stylesheets and
--- as RGB triples for the echo functions, because Geyser wants the former and
--- cecho/decho want the latter.
---
--- The palette is a dark, low-saturation base with a small number of saturated accents
--- reserved for information that changes: health, balance, afflictions. Chrome never
--- competes with the game text -- in a MUD the scrolling text is the interface, and a UI
--- that draws the eye away from it is actively harmful during a fight.

local M = {}

M.colour = {
   -- surfaces, darkest to lightest. A cool slate rather than pure grey: it reads as
   -- deliberate next to the game text without competing with it.
   base      = "#0a0e13",
   panel     = "#10151c",
   raised    = "#171e27",
   border    = "#232c38",
   borderLit = "#36465a",

   -- text
   text      = "#c9d3de",
   textDim   = "#76838f",
   textBright = "#eef3f8",

   -- accents
   health    = "#d1504a",
   mana      = "#3f8bd6",
   endurance = "#d0973a",
   willpower = "#8b68d6",
   experience = "#38a571",

   balance   = "#4fb6df",
   equilibrium = "#a284de",

   affliction = "#e26363",
   defence   = "#58c084",
   warning   = "#e0ae48",
   inactive  = "#3a4553",
   -- Section titles and anything that says "this is ours, in progress": a cure sent and
   -- waiting for its answer is drawn in it, so in-flight reads differently from ready.
   accent    = "#5aa7f5",
   -- A genuinely dark red, distinct from the brighter `health`/`affliction` accents --
   -- reserved for "everything has stopped" states (the paused banner) so it reads as more
   -- severe than an ordinary affliction warning.
   danger    = "#8b1a1a",
}

--- RGB triples for decho/cecho, derived from the hex above so there is one source.
--- @param name string a key in M.colour
--- @return number, number, number
function M.rgb(name)
   local hex = M.colour[name] or M.colour.text
   local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
   return tonumber(r, 16) or 0, tonumber(g, 16) or 0, tonumber(b, 16) or 0
end

-- MEMOISED, because the palette is a constant and these are not cheap.
--
-- M.dc() parses a hex string with a pattern match, runs two tonumber()s, and formats a new
-- string -- 0.94us, measured -- and every panel calls it inside its per-row loops.
-- ui/roompanel.lua alone reaches it fourteen times per repaint, and it repaints on every
-- item event. The answer for a given key cannot change: M.colour is written at load, and
-- nothing in the codebase assigns to it afterwards.
--
-- Keyed on whatever was passed, including an unknown name -- which resolves to the `text`
-- fallback inside M.rgb() and should be just as cached, since a typo'd key in a hot loop is
-- exactly as expensive as a real one.
--- All three declared together and ABOVE every function that touches them, including
--- M.repalette() below: a `local` is only in scope for what follows it, so a cache declared
--- further down would leave repalette() assigning to a same-named global and silently
--- clearing nothing.
local dcCache, dcbCache, dcHexCache = {}, {}, {}
--- M.shade()'s memo, here with the others for the same reason.
local shadeCache = {}

--- A decho colour prefix, e.g. theme.dc("health") .. "text"
function M.dc(name)
   local hit = dcCache[name]
   if hit then return hit end
   local r, g, b = M.rgb(name)
   hit = string.format("<%d,%d,%d>", r, g, b)
   dcCache[name] = hit
   return hit
end

--- A decho background prefix.
function M.dcb(name)
   local hit = dcbCache[name]
   if hit then return hit end
   local r, g, b = M.rgb(name)
   hit = string.format("<:%d,%d,%d>", r, g, b)
   dcbCache[name] = hit
   return hit
end

--- Drop the memos. Only needed if the palette is ever edited at runtime -- nothing does that
--- today, and this exists so that if something starts to, the way to keep the cache honest
--- is already here rather than having to be discovered.
function M.repalette()
   dcCache, dcbCache, dcHexCache, shadeCache = {}, {}, {}, {}
end

--- A decho colour prefix from a raw "#rrggbb" string rather than a M.colour key -- for
--- colours that do not live in the palette, e.g. ui/names.lua's per-city tints.
--- Falls back to plain text (textDim) on anything that does not parse as hex.
--- Memoised for the same reason as M.dc(): ui/names.lua asks for a per-city tint once per
--- name, and ui/roompanel.lua once per player in the room, on every repaint.
function M.dcHex(hex)
   local hit = dcHexCache[hex]
   if hit then return hit end

   local r, g, b = tostring(hex or ""):match("^#(%x%x)(%x%x)(%x%x)$")
   if not r then return M.dc("textDim") end
   hit = string.format("<%d,%d,%d>", tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
   dcHexCache[hex] = hit
   return hit
end

M.font = {
   family = "Ubuntu Mono",   -- Mudlet ships this; falls back gracefully
   size   = 10,
   small  = 9,
}

-- ---------------------------------------------------------------------------
-- rich text, for Labels
-- ---------------------------------------------------------------------------
--
-- The structured panels -- afflictions, defences, the balance strip, the status pills -- are
-- Labels drawing Qt rich text, not MiniConsoles drawing decho. A console is a monospace
-- character grid: columns line up only by padding with spaces, and a name longer than its
-- column pushes the rest of the row out. A rich-text table aligns itself, takes a background
-- per cell, and costs the same single draw. Consoles stay where they earn it: the room
-- (clickable denizens need dechoLink) and chat (scrollback).

--- Escape text for rich text. Item and player names come from the game, and a `<` in one
--- would otherwise be read as markup and swallow the rest of the panel.
function M.esc(text)
   return (tostring(text or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- A palette colour as "#rrggbb", for rich text.
function M.hex(name)
   return M.colour[name] or name
end

--- Coloured text. `name` is a palette key or a raw "#rrggbb".
function M.span(name, text, bold)
   if bold then
      return string.format('<span style="color:%s; font-weight:bold">%s</span>', M.hex(name), text)
   end
   return string.format('<span style="color:%s">%s</span>', M.hex(name), text)
end

--- A small filled tag: text on a tinted background of its own colour.
function M.pill(name, text)
   local colour = M.hex(name)
   return string.format('<span style="background-color:%s; color:%s; font-weight:bold">&nbsp;%s&nbsp;</span>',
      M.shade(colour, 0.28), colour, text)
end

--- Draw a Label body only when it differs from what the label shows. The Label counterpart
--- of M.paint() below, and for the same reason: one draw per change, none otherwise.
function M.paintLabel(label, key, html)
   if not label then return false end
   local cache = emunah._persist and emunah._persist.paintedBodies
   if not cache then
      emunah._persist = emunah._persist or {}
      emunah._persist.paintedBodies = {}
      cache = emunah._persist.paintedBodies
   end
   if cache[key] == html then return false end
   cache[key] = html
   label:echo(html)
   return true
end

--- A section title bar's content: the title on the left, a summary in its own colour.
function M.headerHTML(title, summary, summaryColour)
   local right = summary and summary ~= ""
      and ("&nbsp;&nbsp;" .. M.span(summaryColour or "textDim", summary)) or ""
   return M.span("accent", "&#9632;") .. "&nbsp;" .. M.span("textBright", title, true) .. right
end

-- ---------------------------------------------------------------------------
-- painting a console
-- ---------------------------------------------------------------------------

--- Last body painted into each console, keyed by name.
---
--- Held on _persist so a reload does not repaint every panel with content identical to what
--- is already on screen -- and, more to the point, so it cannot go the other way and skip a
--- paint because a FRESH cache happens to agree with a console that was rebuilt empty.
local function painted()
   emunah._persist = emunah._persist or {}
   emunah._persist.paintedBodies = emunah._persist.paintedBodies or {}
   return emunah._persist.paintedBodies
end

--- Draw a whole console body in ONE call, and not at all if it has not changed.
---
--- Two separate wins, and they compound:
---
---   * ONE decho, not one per row. The panels used to emit a decho per affliction, per
---     defence cell, per room item -- thirty-odd Qt rich-text parses for one repaint of the
---     defence grid. Building the body with table.concat in Lua and handing Qt a single
---     string is the same pixels for a fraction of the work.
---
---   * NOTHING AT ALL when the body is byte-identical to what is already displayed. This is
---     what makes a burst cheap without changing when repaints happen: ui/roompanel.lua
---     redraws on every Char.Items.Add, and a restock that pulls five herbs fires five
---     events of which at most one changes what the room panel shows. The other four now
---     cost a string build and a compare, and Qt never hears about them.
---
--- WHEN a panel paints is M.later()'s business, below: after the packet, not inside it.
---
--- @param console table a Geyser.MiniConsole
--- @param key string stable identity for this console
--- @param body string the complete decho body, colour escapes and newlines included
--- @return boolean whether anything was actually drawn
function M.paint(console, key, body)
   if not console then return false end

   local cache = painted()
   if cache[key] == body then return false end
   cache[key] = body

   console:clear()
   if body ~= "" then console:decho(body) end
   return true
end

--- Forget what a console is displaying, so the next paint always draws.
--- Called when a console is rebuilt -- the widget is new and empty, whatever the cache says.
function M.forgetPainted(key)
   local cache = painted()
   if key then cache[key] = nil else emunah._persist.paintedBodies = {} end
end

-- ---------------------------------------------------------------------------
-- painting AFTER the packet
-- ---------------------------------------------------------------------------
--
-- Mudlet runs everything on one thread, and a packet is handled start to finish before the
-- event loop gets control back: every GMCP message, every line, every trigger, every send().
-- A panel that repaints inside that is a panel that repaints BEFORE THE CURE GOES OUT. The
-- vitals strip painted on `emunah.vitals`, which is raised ahead of the tick; the affliction
-- panel painted inside Char.Afflictions.Add, ahead of Char.Vitals altogether. Measured with
-- test/latency.lua: ten Qt draw calls -- each a rich-text parse or a stylesheet relayout under
-- Mudlet -- and ~80us of our own Lua, all spent before `eat bloodroot` was handed to the
-- socket.
--
-- So panels ask to be painted, and paint when the read is done: a zero-delay tempTimer fires
-- once Mudlet's event loop has control again, which is after the whole packet. Two requests
-- for one panel in one packet are one paint, which is the second saving -- an affliction
-- added and another cured in the same block used to draw the panel twice.
--
-- An earlier note here rejected deferring because "a panel could sit stale whenever events
-- arrive without a prompt behind them". That was about deferring to the next TICK. This
-- defers to the end of the current read, which every event has behind it.

local later, laterOrder = {}, {}

--- Paint `fn` once this packet has been handled. Keyed, so a panel asked for twice in one
--- packet paints once.
function M.later(key, fn)
   if later[key] == nil then laterOrder[#laterOrder + 1] = key end
   later[key] = fn
   emunah._persist = emunah._persist or {}
   if emunah._persist.paintTimer then return end
   emunah._persist.paintTimer = tempTimer(0, M.paintNow)
end

--- Run every deferred paint now. What the timer calls; also safe to call directly.
function M.paintNow()
   if emunah._persist then emunah._persist.paintTimer = nil end
   local fns, order = later, laterOrder
   later, laterOrder = {}, {}
   for _, key in ipairs(order) do
      local ok, err = pcall(fns[key])
      if not ok then emunah.log.error("Repainting %s failed: %s", key, tostring(err)) end
   end
end

-- ---------------------------------------------------------------------------
-- the countdown clock
-- ---------------------------------------------------------------------------
--
-- Some of what the panels show is a function of time, not of events: a balance's seconds
-- remaining, an affliction's age. Nothing in the game marks those moments, so a slow clock
-- redraws them -- and only while something is actually counting. Each panel registers one
-- function that repaints (through the paint caches, so an unchanged body costs a compare)
-- and returns whether it still has anything live. When none do, the clock stops; the next
-- balance spent or affliction tracked starts it again.
--
-- Deliberately coarse. Every tick is Qt work on the thread that handles the next packet,
-- so this runs at `ui.refresh` seconds (0.2 by default), not at the speed a number could
-- change. 0 switches countdowns off altogether.

local tickers = {}

--- Register a panel's clock function. `fn()` repaints and returns true while it has
--- something counting down.
function M.ticking(key, fn)
   tickers[key] = fn
end

--- Make sure the clock is running. Cheap to call on every event that might start a count.
function M.wakeClock()
   local interval = tonumber(emunah.config.get("ui.refresh", 0.2)) or 0.2
   if interval <= 0 then return end
   emunah._persist = emunah._persist or {}
   if emunah._persist.uiClock then return end
   emunah._persist.uiClock = tempTimer(interval, M.clockTick)
end

function M.clockTick()
   if emunah._persist then emunah._persist.uiClock = nil end
   local busy = false
   for key, fn in pairs(tickers) do
      local ok, live = pcall(fn)
      if not ok then
         emunah.log.error("UI clock for %s failed: %s", key, tostring(live))
      elseif live then
         busy = true
      end
   end
   if busy then M.wakeClock() end
end

-- A reload replaces this module; a timer the previous generation armed would run the old
-- painters against widgets the new one is about to rebuild. The new build paints anyway.
if emunah._persist then
   if emunah._persist.paintTimer then
      killTimer(emunah._persist.paintTimer)
      emunah._persist.paintTimer = nil
   end
   if emunah._persist.uiClock then
      killTimer(emunah._persist.uiClock)
      emunah._persist.uiClock = nil
   end
end

-- ---------------------------------------------------------------------------
-- stylesheets
-- ---------------------------------------------------------------------------

--- Panel background with a subtle border. Used by every container.
function M.panelStyle(opts)
   opts = opts or {}
   return string.format([[
      background-color: %s;
      border: 1px solid %s;
      border-radius: 4px;
      margin: %dpx;
   ]], opts.background or M.colour.panel, opts.border or M.colour.border, opts.margin or 2)
end

--- A section header strip: a raised bar with an accent rule along its foot.
function M.headerStyle()
   return string.format([[
      background-color: %s;
      color: %s;
      border: 0px;
      border-bottom: 1px solid %s;
      border-top-left-radius: 3px;
      border-top-right-radius: 3px;
      qproperty-alignment: 'AlignLeft | AlignVCenter';
      padding-left: 6px;
      font-family: "%s";
      font-size: %dpt;
   ]], M.colour.raised, M.colour.textDim, M.colour.borderLit, M.font.family, M.font.small)
end

--- The body of a rich-text section: top-aligned, padded, the darkest surface.
function M.bodyStyle()
   return string.format([[
      background-color: %s;
      color: %s;
      border: 0px;
      qproperty-alignment: 'AlignLeft | AlignTop';
      padding: 4px 6px;
      font-family: "%s";
      font-size: %dpt;
   ]], M.colour.base, M.colour.text, M.font.family, M.font.small)
end

--- Text on a gauge or a one-line label: centred, bright, small.
function M.captionStyle(align)
   return string.format([[
      color: %s; background-color: transparent; border: 0px;
      font-family: "%s"; font-size: %dpt;
      qproperty-alignment: '%s';
      padding-left: 6px; padding-right: 6px;
   ]], M.colour.textBright, M.font.family, M.font.small, align or "AlignCenter")
end

--- Gauge front, tinted by resource: a vertical gradient from the colour to a darker stop,
--- for depth without an image.
function M.gaugeFront(resource)
   local colour = M.colour[resource] or resource or M.colour.health
   return string.format([[
      background-color: qlineargradient(x1:0, y1:0, x2:0, y2:1,
         stop:0 %s, stop:1 %s);
      border-radius: 3px;
      border: 1px solid %s;
   ]], colour, M.shade(colour, 0.6), M.shade(colour, 0.45))
end

function M.gaugeBack(resource)
   local colour = M.colour[resource or "base"] or M.colour.base
   return string.format([[
      background-color: %s;
      border-radius: 3px;
      border: 1px solid %s;
   ]], resource and M.shade(colour, 0.18) or M.colour.base, M.colour.border)
end

--- Multiply a hex colour's channels. Used for gradient stops so the palette stays one
--- list of base colours rather than a list of pairs.
--- @param hex string "#rrggbb"
--- @param factor number 0..1 darkens, >1 lightens
---
--- Memoised: the balance strip and the status pills tint a cell per balance on every
--- repaint, from a fixed palette and a handful of factors -- a pattern match, three
--- tonumbers, a closure and a format each time for an answer that never changes.
function M.shade(hex, factor)
   local byFactor = shadeCache[hex]
   if not byFactor then
      byFactor = {}
      shadeCache[hex] = byFactor
   end
   local hit = byFactor[factor]
   if hit then return hit end

   local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
   if not r then return hex end
   local function apply(channel)
      local value = math.floor(tonumber(channel, 16) * factor)
      if value < 0 then value = 0 end
      if value > 255 then value = 255 end
      return value
   end
   hit = string.format("#%02x%02x%02x", apply(r), apply(g), apply(b))
   byFactor[factor] = hit
   return hit
end

--- Colour for a health-style percentage: green when healthy, through amber, to red.
--- Returned as a hex string.
function M.forPercent(pct)
   pct = tonumber(pct) or 100
   if pct >= 66 then return M.colour.defence end
   if pct >= 33 then return M.colour.warning end
   return M.colour.affliction
end

--- Background colour for MiniConsoles.
---
--- NOT a stylesheet. Geyser.MiniConsole has no setStyleSheet -- that is a Label/Gauge
--- method, and calling it on a console is a hard error. A console's background is set
--- through the `color` field of its constructor table instead, and it has no border or
--- corner radius at all. Panel chrome therefore comes from the Adjustable.Container the
--- consoles sit inside, which is a Label and does support styling.
function M.consoleColour()
   return M.colour.base
end

--- Standard constructor fields for a MiniConsole, so the panels stay consistent and
--- nobody has to remember which fields a console actually reads.
---
--- The legal set (from Geyser.MiniConsole:new) is: font, fontSize, wrapAt, autoWrap,
--- scrollBar, horizontalScrollBar, commandLine, plus color/fgColor/bgColor which are
--- applied by Geyser.Color.applyColors. Note it is `wrapAt`, NOT `wrapWidth` -- an unknown
--- field is silently ignored rather than raising, so a typo here costs you line wrapping
--- with no error to explain it.
--- @param spec table geometry and any overrides
function M.consoleCons(spec)
   local cons = {
      color     = M.consoleColour(),   -- accepts hex; applied via Geyser.Color
      fontSize  = M.font.size,
      wrapAt    = 40,
      scrollBar = false,
   }
   for key, value in pairs(spec or {}) do cons[key] = value end
   return cons
end

return M

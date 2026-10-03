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
   -- surfaces, darkest to lightest
   base      = "#0d1117",
   panel     = "#131a23",
   raised    = "#1b242f",
   border    = "#2a3644",
   borderLit = "#3d5166",

   -- text
   text      = "#c9d4e0",
   textDim   = "#7d8b9c",
   textBright = "#f0f6fc",

   -- accents
   health    = "#c2453e",
   mana      = "#3d7ec4",
   endurance = "#c98b2e",
   willpower = "#7b5cc4",
   experience = "#2e9962",

   balance   = "#4fb3d9",
   equilibrium = "#9b7fd4",

   affliction = "#d15c5c",
   defence   = "#5cb87a",
   warning   = "#d9a441",
   inactive  = "#3a4553",
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
   dcCache, dcbCache, dcHexCache = {}, {}, {}
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

-- A reload replaces this module; a timer the previous generation armed would run the old
-- painters against widgets the new one is about to rebuild. The new build paints anyway.
if emunah._persist and emunah._persist.paintTimer then
   killTimer(emunah._persist.paintTimer)
   emunah._persist.paintTimer = nil
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

--- A section header strip.
function M.headerStyle()
   return string.format([[
      background-color: %s;
      color: %s;
      border: 0px;
      border-bottom: 1px solid %s;
      qproperty-alignment: 'AlignLeft | AlignVCenter';
      padding-left: 6px;
      font-family: "%s";
      font-size: %dpt;
      font-weight: bold;
   ]], M.colour.raised, M.colour.textDim, M.colour.border, M.font.family, M.font.small)
end

--- Gauge front, tinted by resource. `shade` darkens the right-hand stop for a little
--- depth without needing an image.
function M.gaugeFront(resource)
   local colour = M.colour[resource] or M.colour.health
   return string.format([[
      background-color: qlineargradient(x1:0, y1:0, x2:0, y2:1,
         stop:0 %s, stop:1 %s);
      border-radius: 3px;
      border: 1px solid %s;
   ]], colour, M.shade(colour, 0.65), M.colour.border)
end

function M.gaugeBack()
   return string.format([[
      background-color: %s;
      border-radius: 3px;
      border: 1px solid %s;
   ]], M.colour.base, M.colour.border)
end

--- Multiply a hex colour's channels. Used for gradient stops so the palette stays one
--- list of base colours rather than a list of pairs.
--- @param hex string "#rrggbb"
--- @param factor number 0..1 darkens, >1 lightens
function M.shade(hex, factor)
   local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
   if not r then return hex end
   local function apply(channel)
      local value = math.floor(tonumber(channel, 16) * factor)
      if value < 0 then value = 0 end
      if value > 255 then value = 255 end
      return value
   end
   return string.format("#%02x%02x%02x", apply(r), apply(g), apply(b))
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

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
}

--- RGB triples for decho/cecho, derived from the hex above so there is one source.
--- @param name string a key in M.colour
--- @return number, number, number
function M.rgb(name)
   local hex = M.colour[name] or M.colour.text
   local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
   return tonumber(r, 16) or 0, tonumber(g, 16) or 0, tonumber(b, 16) or 0
end

--- A decho colour prefix, e.g. theme.dc("health") .. "text"
function M.dc(name)
   local r, g, b = M.rgb(name)
   return string.format("<%d,%d,%d>", r, g, b)
end

--- A decho background prefix.
function M.dcb(name)
   local r, g, b = M.rgb(name)
   return string.format("<:%d,%d,%d>", r, g, b)
end

M.font = {
   family = "Ubuntu Mono",   -- Mudlet ships this; falls back gracefully
   size   = 10,
   small  = 9,
}

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

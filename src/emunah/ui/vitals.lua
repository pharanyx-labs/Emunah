--- The vitals strip: target health, own health, mana, endurance, willpower, balances and
--- class stats.
---
--- Lives in the full-width container at the very bottom of the window, directly under the
--- last line of game text -- so it sits immediately above the prompt, where your eyes
--- already are while fighting. A vitals panel you have to look away to read is a vitals
--- panel you check too late. The target's health belongs in that same eyeline for the same
--- reason -- it used to live in a side column (ui/roompanel.lua), which meant glancing away
--- from the exact spot the rest of combat state lives in.
---
--- Three rows:
---   row 0   target health bar, full width (what you are fighting, not what you have)
---   row 1   HP | MP | EP | WP gauges, side by side
---   row 2   BALANCE | EQUILIBRIUM lights, cure-vector availability, XP, class stats
---
--- Rows 1 and 2 are driven by the `emunah.vitals` event, which fires once per prompt --
--- fast enough to feel live and cheap enough to be free. Row 0 is driven by its own target
--- events (see the registration at the bottom of this file) since a target changes
--- independently of your own prompt.
---
--- Balance and equilibrium are shown as hard on/off lights rather than countdown bars:
--- they come from Char.Vitals and are exact, so an animation would imply a countdown we do
--- not actually have. The cure vectors beside them *are* timed estimates, and are coloured
--- to say so -- green ready, grey recovering, red blocked by an affliction.

local M = {}

local util   = emunah.util
local theme  = emunah.ui.theme
local layout = emunah.ui.layout

M.widgets = {}

local RESOURCES = {
   { key = "hp", label = "H", colour = "health"    },
   { key = "mp", label = "M", colour = "mana"      },
   { key = "ep", label = "E", colour = "endurance" },
   { key = "wp", label = "W", colour = "willpower" },
}

--- Cure vectors shown as availability lights.
local VECTORS = { "herb", "salve", "elixir", "smoke", "focus" }

-- A few pixels of top margin before row 0, not zero: right up against the container's
-- top edge, the target gauge was sitting on top of (and hiding) the game console's own
-- input line just above it. Reported from play.
local ROW0_Y, ROW0_H = 8, 18
local ROW1_Y, ROW1_H = 28, 22
local ROW2_Y, ROW2_H = 52, 20

local function available()
   return layout.container("bottom") ~= nil and type(Geyser) == "table"
end

--- Percentage-width column helper, so the strip divides evenly at any window size.
local function column(index, count, gap)
   gap = gap or 0.5
   local width = (100 - gap * (count + 1)) / count
   local x = gap + (index - 1) * (width + gap)
   return string.format("%.2f%%", x), string.format("%.2f%%", width)
end

function M.build()
   if not available() then return false end
   local parent = layout.container("bottom")

   M.widgets = {}

   -- Row 0: the target's health, directly above your own vitals -- what you are fighting
   -- belongs in the same glance as what you have left to fight it with. Stops at the map's
   -- left edge rather than running the full window width: it used to run under the
   -- right-hand column too, which read as far longer than it needed to be for a single
   -- number.
   local targetWidth = string.format("%d%%", 100 - layout.percentOf(layout.WIDTH_RIGHT) - 1)
   M.widgets.target = Geyser.Gauge:new({
      name = "emunah.target",
      x = 4, y = ROW0_Y, width = targetWidth, height = ROW0_H,
   }, parent)
   M.widgets.target.front:setStyleSheet(theme.gaugeFront("affliction"))
   M.widgets.target.back:setStyleSheet(theme.gaugeBack())
   M.widgets.target.text:setStyleSheet(string.format([[
      color: %s; font-family: "%s"; font-size: %dpt;
      qproperty-alignment: 'AlignCenter';
   ]], theme.colour.textBright, theme.font.family, theme.font.small))

   -- Row 1: the four resource gauges, side by side.
   for index, resource in ipairs(RESOURCES) do
      local x, width = column(index, #RESOURCES)
      local gauge = Geyser.Gauge:new({
         name = "emunah.gauge." .. resource.key,
         x = x, y = ROW1_Y, width = width, height = ROW1_H,
      }, parent)

      gauge.front:setStyleSheet(theme.gaugeFront(resource.colour))
      gauge.back:setStyleSheet(theme.gaugeBack())
      gauge.text:setStyleSheet(string.format([[
         color: %s;
         font-family: "%s";
         font-size: %dpt;
         qproperty-alignment: 'AlignCenter';
      ]], theme.colour.textBright, theme.font.family, theme.font.small))

      M.widgets[resource.key] = gauge
   end

   -- Row 2: balance lights, cure vectors, experience, class stats.
   M.widgets.balance = Geyser.Label:new({
      name = "emunah.balance",
      x = "0.5%", y = ROW2_Y, width = "11%", height = ROW2_H,
   }, parent)

   M.widgets.equilibrium = Geyser.Label:new({
      name = "emunah.equilibrium",
      x = "12%", y = ROW2_Y, width = "13%", height = ROW2_H,
   }, parent)

   M.widgets.vectors = Geyser.Label:new({
      name = "emunah.vectors",
      x = "25.5%", y = ROW2_Y, width = "31%", height = ROW2_H,
   }, parent)
   M.widgets.vectors:setStyleSheet(theme.panelStyle({ background = theme.colour.base, margin = 0 }))

   M.widgets.xp = Geyser.Gauge:new({
      name = "emunah.gauge.xp",
      x = "57%", y = ROW2_Y, width = "16%", height = ROW2_H,
   }, parent)
   M.widgets.xp.front:setStyleSheet(theme.gaugeFront("experience"))
   M.widgets.xp.back:setStyleSheet(theme.gaugeBack())
   M.widgets.xp.text:setStyleSheet(string.format([[
      color: %s; font-family: "%s"; font-size: %dpt;
      qproperty-alignment: 'AlignCenter';
   ]], theme.colour.textBright, theme.font.family, theme.font.small - 1))

   M.widgets.stats = Geyser.Label:new({
      name = "emunah.stats",
      x = "73.5%", y = ROW2_Y, width = "26%", height = ROW2_H,
   }, parent)
   M.widgets.stats:setStyleSheet(theme.panelStyle({ background = theme.colour.base, margin = 0 }))

   -- The widgets are brand new, unstyled and empty; the caches describe the ones they
   -- replaced. Without this the first update() after a rebuild compares equal and draws
   -- nothing, and the strip comes up blank.
   M.forgetLights()

   M.update()
   M.updateTarget()
   return true
end

--- Refresh the target health bar. Separate from M.update() because a target changes on
--- its own events (see the registration below), not on the per-prompt `emunah.vitals`
--- tick the rest of this strip is driven by.
function M.updateTarget()
   local gauge = M.widgets.target
   local ire = emunah.gmcp.ire
   if not gauge or not ire then return end

   if not ire.hasTarget() then
      gauge:setValue(0, 100, "no target")
      gauge.front:setStyleSheet(theme.gaugeFront("inactive"))
      return
   end

   local health = ire.targetHealth()
   local label = ire.target.description or ire.target.id or "target"

   if health then
      gauge.front:setStyleSheet(string.format([[
         background-color: %s; border-radius: 3px; border: 1px solid %s;
      ]], theme.forPercent(health), theme.colour.border))
      -- hpperc can arrive fractional; floor before %d.
      gauge:setValue(health, 100, string.format("%s  %d%%", label, math.floor(health)))
   else
      gauge.front:setStyleSheet(theme.gaugeFront("inactive"))
      gauge:setValue(100, 100, label)
   end
end

--- Stylesheets for the on/off lights, built once per (colour, state) pair.
---
--- setStyleSheet() makes Qt re-parse the sheet and re-lay-out the widget, and light() used to
--- call it for BAL and for EQ on every prompt regardless of whether either had changed --
--- four Qt reparses a second for two booleans that flip maybe twice a second. The sheet text
--- depends only on the colour name and the on/off state, both of which come from a fixed
--- set, so there is nothing to recompute.
local lightStyles = {}

local function lightStyle(colourName, on)
   local key = colourName .. (on and ":on" or ":off")
   local sheet = lightStyles[key]
   if sheet then return sheet end

   local colour = on and theme.colour[colourName] or theme.colour.inactive
   sheet = string.format([[
      background-color: %s;
      border: 1px solid %s;
      border-radius: 3px;
      color: %s;
      font-family: "%s";
      font-size: %dpt;
      font-weight: bold;
      qproperty-alignment: 'AlignCenter';
   ]], on and theme.shade(colour, 0.35) or theme.colour.panel,
       on and colour or theme.colour.border,
       on and theme.colour.textBright or theme.colour.textDim,
       theme.font.family, theme.font.small)
   lightStyles[key] = sheet
   return sheet
end

--- What each light was last drawn as, so an unchanged one is left alone entirely.
local lightState = {}

--- An on/off indicator label.
local function light(widget, label, on, colourName)
   if not widget then return end
   on = on and true or false
   if lightState[label] == on then return end
   lightState[label] = on

   widget:setStyleSheet(lightStyle(colourName, on))
   widget:echo(label)
end

--- Last body drawn into the vectors and stats labels. Both are redrawn far more often than
--- their contents change -- the vectors label on every timer expiry, the stats label on
--- every prompt -- and a decho of a string identical to what is displayed is a Qt rich-text
--- parse for no visible effect.
local lastVectors, lastStats = nil, nil

--- The three-letter abbreviation for a vector, built once each.
--- `vector:sub(1, 3):upper()` is two string allocations, inside a loop that runs five times
--- per repaint, for a fixed set of names.
local vectorLabels = setmetatable({}, {
   __index = function(self, vector)
      local label = vector:sub(1, 3):upper()
      self[vector] = label
      return label
   end,
})

local function vectorLabel(vector)
   return vectorLabels[vector]
end

--- Forget the drawn state of the lights and labels, so the next update() redraws them.
---
--- Called from M.build(), which is defined ABOVE this point -- hence a field on M rather
--- than a local, since a local is only in scope for what follows it. By the time build()
--- actually runs, at the bottom of this file, the assignment here has happened.
function M.forgetLights()
   lightState = {}
   lastVectors, lastStats = nil, nil
end

function M.update()
   local vitals = emunah.gmcp.vitals
   if not vitals or not M.widgets.hp then return end

   for _, resource in ipairs(RESOURCES) do
      local gauge = M.widgets[resource.key]
      if gauge then
         local current = vitals[resource.key] or 0
         local max     = vitals["max" .. resource.key] or 0
         -- Compact labels: the strip is wide but short, and "H 3,200/4,000" reads as
         -- fast as the spelled-out version at a glance.
         gauge:setValue(current, max > 0 and max or 1,
            string.format("<b>%s</b> %s/%s", resource.label, util.comma(current), util.comma(max)))
      end
   end

   if M.widgets.xp then
      -- nl arrives fractional ("43.7"). string.format("%d", 43.7) is a hard error on
      -- Lua 5.3+ and silently truncates on 5.1, so floor it rather than rely on either.
      local nl = vitals.nl or 0
      M.widgets.xp:setValue(nl, 100, string.format("XP %d%%", math.floor(nl)))
   end

   light(M.widgets.balance, "BAL", vitals.bal, "balance")
   light(M.widgets.equilibrium, "EQ", vitals.eq, "equilibrium")

   M.updateVectors()
   M.updateStats()
end

--- The three-letter vector lights. Its own function because it is the ONLY part of this
--- strip that depends on the cure timers, and `emunah.timer.expired` used to redraw the
--- whole strip -- gauges, labels, class stats and all -- on every balance recovery, which in
--- a fight is several times a second on top of the per-prompt update.
function M.updateVectors()
   local widget = M.widgets.vectors
   if not widget then return end

   -- Cure vectors: green ready, grey recovering, red blocked by an affliction.
   local parts = {}
   for index, vector in ipairs(VECTORS) do
      local colour
      if emunah.have.blockedBy(vector) then
         colour = theme.dc("affliction")
      elseif emunah.have.balance(vector) then
         colour = theme.dc("defence")
      else
         colour = theme.dc("inactive")
      end
      -- Abbreviated to three letters so five vectors fit one line.
      parts[index] = colour .. vectorLabel(vector)
   end

   local body = table.concat(parts, theme.dc("border") .. " ")
   if body == lastVectors then return end
   lastVectors = body
   widget:decho(body)
end

--- Class stats from charstats. Priest shows Devotion; Monk shows Kai and Stance.
--- One line, so only the values that fit are shown.
function M.updateStats()
   local widget = M.widgets.stats
   local vitals = emunah.gmcp.vitals
   if not widget or not vitals then return end

   local body
   local keys = util.keys(vitals.stats)
   if #keys == 0 then
      body = theme.dc("textDim") .. "no class stats"
   else
      local parts = {}
      for index, key in ipairs(keys) do
         local value = vitals.stats[key]
         if type(value) == "boolean" then value = value and "yes" or "no" end
         parts[index] = string.format("%s%s %s%s",
            theme.dc("textDim"), key, theme.dc("textBright"), tostring(value))
      end
      body = table.concat(parts, theme.dc("border") .. " ")
   end

   if body == lastStats then return end
   lastStats = body
   widget:decho(body)
end

emunah.event.register("emunah.vitals", function() M.update() end, "ui.vitals")
emunah.event.register("emunah.ui.built", function() M.build() end, "ui.vitals")

-- Vector lights depend on timers, which have no vitals event of their own.
--
-- ONLY the vector lights. This used to call M.update(), redrawing the entire strip -- four
-- resource gauges, the XP gauge, both balance lights and the class stats -- on every cure
-- timer lapsing, which in a fight is several times a second on top of the per-prompt
-- update. Nothing else on the strip reads a timer.
emunah.event.register("emunah.timer.expired", function() M.updateVectors() end, "ui.vitals")

emunah.event.registerAll({
   "emunah.target",
   "emunah.target.info",
}, function() M.updateTarget() end, "ui.vitals")

M.build()

return M

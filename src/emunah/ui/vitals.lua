--- The vitals strip: health, mana, endurance, willpower, balances and class stats.
---
--- Lives in the full-width container at the very bottom of the window, directly under the
--- last line of game text -- so it sits immediately above the prompt, where your eyes
--- already are while fighting. A vitals panel you have to look away to read is a vitals
--- panel you check too late.
---
--- Two rows:
---   row 1   HP | MP | EP | WP gauges, side by side
---   row 2   BALANCE | EQUILIBRIUM lights, cure-vector availability, XP, class stats
---
--- Everything is driven by the `emunah.vitals` event, which fires once per prompt. That
--- is fast enough to feel live and cheap enough to be free.
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

local ROW1_Y, ROW1_H = 2, 22
local ROW2_Y, ROW2_H = 26, 20

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

   M.update()
   return true
end

--- An on/off indicator label.
local function light(widget, label, on, colourName)
   if not widget then return end
   local colour = on and theme.colour[colourName] or theme.colour.inactive
   widget:setStyleSheet(string.format([[
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
       theme.font.family, theme.font.small))
   widget:echo(label)
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

   -- Cure vectors: green ready, grey recovering, red blocked by an affliction.
   if M.widgets.vectors then
      local parts = {}
      for _, vector in ipairs(VECTORS) do
         local blocker = emunah.have.blockedBy(vector)
         local ready   = emunah.have.balance(vector)
         local colour
         if blocker then
            colour = theme.dc("affliction")
         elseif ready then
            colour = theme.dc("defence")
         else
            colour = theme.dc("inactive")
         end
         -- Abbreviated to three letters so five vectors fit one line.
         parts[#parts + 1] = colour .. vector:sub(1, 3):upper()
      end
      M.widgets.vectors:decho(table.concat(parts, theme.dc("border") .. " "))
   end

   -- Class stats from charstats. Priest shows Devotion; Monk shows Kai and Stance.
   -- One line, so only the values that fit are shown.
   if M.widgets.stats then
      local keys = util.keys(vitals.stats)
      if #keys == 0 then
         M.widgets.stats:decho(theme.dc("textDim") .. "no class stats")
      else
         local parts = {}
         for _, key in ipairs(keys) do
            local value = vitals.stats[key]
            if type(value) == "boolean" then value = value and "yes" or "no" end
            parts[#parts + 1] = string.format("%s%s %s%s",
               theme.dc("textDim"), key, theme.dc("textBright"), tostring(value))
         end
         M.widgets.stats:decho(table.concat(parts, theme.dc("border") .. " "))
      end
   end
end

emunah.event.register("emunah.vitals", function() M.update() end, "ui.vitals")
emunah.event.register("emunah.ui.built", function() M.build() end, "ui.vitals")
-- Vector lights depend on timers, which have no vitals event of their own.
emunah.event.register("emunah.timer.expired", function() M.update() end, "ui.vitals")

M.build()

return M

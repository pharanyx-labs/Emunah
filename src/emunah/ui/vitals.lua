--- The combat HUD: the full-width strip at the very bottom of the window.
---
--- It sits directly under the last line of game text, immediately above the prompt, where
--- your eyes already are while fighting. A vitals panel you have to look away to read is a
--- vitals panel you check too late.
---
---   row 1   TARGET health bar                | status: what is running, what is in flight
---   row 2   HP | MP | EP | WP, each with its change since the last prompt
---   row 3   BAL EQ | every curing balance     | XP | class stats
---
--- THE BALANCE STRIP is the HUD's reason to exist. Each cell is one balance, in one of five
--- states, by colour and by mark:
---
---   ready        green, a tick
---   in flight    blue, an arrow: a command was sent on it and the game has not answered
---   recovering   grey, the seconds left (the game's own figure where it states one, the
---                fallback estimate otherwise -- see curelist.lua)
---   locked       red, a cross: an affliction shuts it (afflist.blocks)
---   absent       dim: there is nothing to use (no tree tattoo inked)
---
--- Bal and eq are exact, from Char.Vitals. The countdowns are kept live by theme's coarse
--- clock, only while something is counting.
---
--- Everything here is painted after the packet (theme.later), and nothing is redrawn that
--- has not changed: each gauge remembers what it last showed, and each label goes through
--- theme.paintLabel.

local M = {}

local util   = emunah.util
local theme  = emunah.ui.theme
local layout = emunah.ui.layout

M.widgets = {}

local RESOURCES = {
   { key = "hp", label = "HP", colour = "health"    },
   { key = "mp", label = "MP", colour = "mana"      },
   { key = "ep", label = "EP", colour = "endurance" },
   { key = "wp", label = "WP", colour = "willpower" },
}

--- The curing balances, left to right, and what each cell is called.
local VECTORS = {
   { key = "herb",      label = "HERB"  },
   { key = "salve",     label = "SALVE" },
   { key = "elixir",    label = "SIP"   },
   { key = "purgative", label = "PURG"  },
   { key = "smoke",     label = "SMOKE" },
   { key = "focus",     label = "FOCUS" },
   { key = "moss",      label = "MOSS"  },
   { key = "tree",      label = "TREE"  },
}

-- Rows, in pixels from the top of the strip.
-- Rows HANG FROM THE BOTTOM EDGE, not the top. The strip sits on Mudlet's command line, and
-- with the rows at the top any slack in the strip's height opened up between the balance row
-- and where you type -- reported from play as "a large gap between where I type and the
-- bal/eq/herb/salve" row. Anchored at the bottom, the balance row is the one right above the
-- input, and any slack goes above the target bar instead. Negative y is Geyser's "from the
-- bottom edge".
local ROW3_H, ROW2_H, ROW1_H = 22, 24, 22
local GAP = 4
local ROW3_Y = string.format("-%dpx", ROW3_H + 2)
local ROW2_Y = string.format("-%dpx", ROW3_H + 2 + GAP + ROW2_H)
local ROW1_Y = string.format("-%dpx", ROW3_H + 2 + GAP + ROW2_H + GAP + ROW1_H)

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

local function gauge(name, x, y, width, height, colour, parent)
   local widget = Geyser.Gauge:new({ name = name, x = x, y = y, width = width, height = height }, parent)
   widget.front:setStyleSheet(theme.gaugeFront(colour))
   widget.back:setStyleSheet(theme.gaugeBack(colour))
   widget.text:setStyleSheet(theme.captionStyle())
   return widget
end

local function label(name, x, y, width, height, parent, align)
   local widget = Geyser.Label:new({ name = name, x = x, y = y, width = width, height = height }, parent)
   widget:setStyleSheet(string.format([[
      background-color: %s; border: 1px solid %s; border-radius: 3px;
      color: %s; font-family: "%s"; font-size: %dpt;
      qproperty-alignment: '%s'; padding-left: 4px; padding-right: 4px;
   ]], theme.colour.base, theme.colour.border, theme.colour.text,
       theme.font.family, theme.font.small, align or "AlignLeft | AlignVCenter"))
   return widget
end

function M.build()
   if not available() then return false end
   local parent = layout.container("bottom")
   M.widgets = {}

   -- Row 1: the target, and the system's own state beside it.
   M.widgets.target = gauge("emunah.target", "0.5%", ROW1_Y, "60%", ROW1_H, "affliction", parent)
   M.widgets.status = label("emunah.status", "61%", ROW1_Y, "38.5%", ROW1_H, parent)

   -- Row 2: the four resources.
   for index, resource in ipairs(RESOURCES) do
      local x, width = column(index, #RESOURCES)
      M.widgets[resource.key] = gauge("emunah.gauge." .. resource.key, x, ROW2_Y, width, ROW2_H,
         resource.colour, parent)
   end

   -- Row 3: balances, experience, class stats.
   M.widgets.balances = label("emunah.balances", "0.5%", ROW3_Y, "68%", ROW3_H, parent)
   M.widgets.xp = gauge("emunah.gauge.xp", "69%", ROW3_Y, "11%", ROW3_H, "experience", parent)
   M.widgets.stats = label("emunah.stats", "80.5%", ROW3_Y, "19%", ROW3_H, parent)

   M.forgetLights()
   M.update()
   M.updateTarget()
   M.updateStatus()
   return true
end

-- ---------------------------------------------------------------------------
-- gauges
-- ---------------------------------------------------------------------------

--- What each gauge last showed. setValue is a resize and a rich-text echo under Mudlet,
--- and on a quiet prompt nothing it shows has moved.
local gaugeShown = {}

local function setGauge(key, widget, current, max, text)
   local signature = current .. "/" .. max .. "/" .. text
   if gaugeShown[key] == signature then return end
   gaugeShown[key] = signature
   widget:setValue(current, max, text)
end

--- Forget what the lights, gauges and labels show, so the next update redraws them all.
--- Called by M.build(): the widgets are brand new.
function M.forgetLights()
   gaugeShown = {}
   for _, key in ipairs({ "status", "balances", "stats", "target" }) do
      theme.forgetPainted("hud." .. key)
   end
end

--- "HP  3,200 / 4,000  80%  ▼120"
local function resourceText(vitals, resource)
   local key = resource.key
   local current, max = vitals[key] or 0, vitals["max" .. key] or 0
   local head = theme.span("textBright", resource.label, true) .. "&nbsp;&nbsp;"

   -- Recklessness reports hp and mp at maximum whatever the truth (vitals.LIARS). Showing
   -- the number would show the lie.
   if vitals.trusted and not vitals.trusted(key) then
      return head .. theme.span("warning", "unknown (the feed is lying)")
   end

   local pct = max > 0 and math.floor(current * 100 / max + 0.5) or 0
   -- Bright while healthy: it sits on the gauge's own fill, and a green on orange or blue is
   -- harder to read than the number is worth. Amber and red only when it matters.
   local text = head .. string.format("%s / %s&nbsp;&nbsp;", util.comma(current), util.comma(max))
      .. theme.span(pct >= 66 and "textBright" or theme.forPercent(pct), pct .. "%", true)

   local before = vitals.last and vitals.last[key]
   if before and max > 0 then
      local delta = current - before
      if delta < 0 then
         text = text .. "&nbsp;&nbsp;" .. theme.span("affliction", "&#9660;" .. util.comma(-delta))
      elseif delta > 0 then
         text = text .. "&nbsp;&nbsp;" .. theme.span("defence", "&#9650;" .. util.comma(delta))
      end
   end
   return text
end

function M.updateGauges()
   local vitals = emunah.gmcp.vitals
   if not vitals or not M.widgets.hp then return end

   for _, resource in ipairs(RESOURCES) do
      local widget = M.widgets[resource.key]
      if widget then
         local max = vitals["max" .. resource.key] or 0
         setGauge(resource.key, widget, vitals[resource.key] or 0, max > 0 and max or 1,
            resourceText(vitals, resource))
      end
   end

   if M.widgets.xp then
      -- nl arrives fractional ("43.7"); floor before %d.
      local nl = vitals.nl or 0
      setGauge("xp", M.widgets.xp, nl, 100, string.format("XP %d%%", math.floor(nl)))
   end
end

-- ---------------------------------------------------------------------------
-- the balance strip
-- ---------------------------------------------------------------------------

local CELL = '<td align="center" style="background-color:%s">&nbsp;%s&nbsp;</td>'

--- One cell: a palette colour for its state, the label, and the mark or the seconds.
---
--- Memoised on all three: the strip is rebuilt on every prompt, a cell's markup depends on
--- nothing else, and the set of distinct cells is small -- eight labels, five states, and a
--- countdown that only takes tenths of a second.
local cellCache = {}

local function cell(colourName, text, filled)
   local key = colourName .. (filled and "\1" or "\0") .. text
   local hit = cellCache[key]
   if hit then return hit end
   local colour = theme.hex(colourName)
   local background = filled and theme.shade(colour, 0.26) or theme.colour.panel
   hit = string.format(CELL, background, theme.span(colourName, text, filled))
   cellCache[key] = hit
   return hit
end

local TICK, ARROW, CROSS, DASH = "&#10003;", "&#8250;", "&#10005;", "&#8211;"

--- A bal/eq cell. Exact from Char.Vitals; the seconds come from the timer the command that
--- spent it armed ("Balance used: 3.2s."), when there is one.
local function physical(labelText, up, timer, colourName)
   if up then return cell(colourName, labelText .. " " .. TICK, true), false end
   local left = emunah.timers.remaining(timer)
   if left > 0 then return cell("textDim", string.format("%s %.1f", labelText, left), false), true end
   return cell("textDim", labelText .. " " .. DASH, false), false
end

local function curing(vector)
   local have, queue = emunah.have, emunah.queue
   if vector.key == "tree" and not have.def("tree") then
      return cell("inactive", vector.label .. " " .. DASH, false), false
   end
   if queue.heldBy(vector.key) then return cell("affliction", vector.label .. " " .. CROSS, true), false end
   if queue.awaiting(vector.key) then return cell("accent", vector.label .. " " .. ARROW, true), false end
   local left = emunah.timers.remaining("cure." .. vector.key)
   if left > 0 then return cell("textDim", string.format("%s %.1f", vector.label, left), false), true end
   return cell("defence", vector.label .. " " .. TICK, true), false
end

local cells = {}

--- Repaint the balance strip. Returns whether anything on it is counting down.
function M.updateBalances()
   local widget = M.widgets.balances
   local vitals = emunah.gmcp.vitals
   if not widget or not vitals then return false end

   local live, counting = false, false
   local n = 1
   cells[1] = '<table cellspacing="2" cellpadding="0"><tr>'
   n = n + 1
   cells[n], counting = physical("BAL", vitals.bal, "attack.balance", "balance")
   live = live or counting
   n = n + 1
   cells[n], counting = physical("EQ", vitals.eq, "cure.equilibrium", "equilibrium")
   live = live or counting
   n = n + 1
   cells[n] = '<td>&nbsp;</td>'
   for _, vector in ipairs(VECTORS) do
      n = n + 1
      cells[n], counting = curing(vector)
      live = live or counting
   end
   n = n + 1
   cells[n] = "</tr></table>"

   theme.paintLabel(widget, "hud.balances", table.concat(cells, "", 1, n))
   return live
end

--- Kept for anything that called the old name: the vector lights are the balance strip.
M.updateVectors = M.updateBalances

-- ---------------------------------------------------------------------------
-- status, stats, target
-- ---------------------------------------------------------------------------

--- What is switched on, and what has been sent and not yet answered.
function M.updateStatus()
   local widget = M.widgets.status
   if not widget then return end

   local function mode(on, text)
      return theme.pill(on and "defence" or "inactive", text)
   end

   local engine = emunah.curing and emunah.curing.engine
   local keepup = emunah.curing and emunah.curing.defkeepup
   local parts = {
      mode(engine and engine.enabled, "CURE"),
      mode(keepup and keepup.enabled, "DEFS"),
      mode(emunah.bashing and emunah.bashing.enabled, "BASH"),
   }
   local pvp = emunah.pvp
   if pvp and pvp.enabled then
      parts[#parts + 1] = theme.pill("affliction", "PVP " .. theme.esc(tostring(pvp.target or "?"):upper()))
   end

   local act = emunah.act
   if act and act.backoffUntil and util.now() < act.backoffUntil then
      parts[#parts + 1] = theme.pill("warning", "RATE LIMITED")
   end
   local vitals = emunah.gmcp.vitals
   if vitals and vitals.dead then parts[#parts + 1] = theme.pill("affliction", "DEAD") end

   -- In flight: the commands the game has not answered yet, newest balance first.
   local flying = {}
   for vector, entry in pairs(emunah.queue.snapshot()) do
      if entry.inFlight and vector ~= "free" then flying[#flying + 1] = theme.esc(entry.inFlight) end
   end
   table.sort(flying)
   local html = table.concat(parts, "&nbsp;")
   if #flying > 0 then
      html = html .. "&nbsp;&nbsp;" .. theme.span("accent", "&#8250; " .. table.concat(flying, ", "))
   end

   theme.paintLabel(widget, "hud.status", html)
end

--- Class stats from charstats: Devotion for a Priest, Kai and Stance for a Monk.
function M.updateStats()
   local widget = M.widgets.stats
   local vitals = emunah.gmcp.vitals
   if not widget or not vitals then return end

   local keys = util.keys(vitals.stats)
   table.sort(keys)
   local html
   if #keys == 0 then
      html = theme.span("textDim", "no class stats")
   else
      local parts = {}
      for index, key in ipairs(keys) do
         local value = vitals.stats[key]
         if type(value) == "boolean" then value = value and "yes" or "no" end
         parts[index] = theme.span("textDim", theme.esc(key)) .. "&nbsp;"
            .. theme.span("textBright", theme.esc(tostring(value)), true)
      end
      html = table.concat(parts, "&nbsp;&nbsp;")
   end
   theme.paintLabel(widget, "hud.stats", html)
end

--- The target's health bar. Its own events, not the per-prompt one: a target changes
--- independently of your own prompt.
function M.updateTarget()
   local widget = M.widgets.target
   local ire = emunah.gmcp.ire
   if not widget or not ire then return end

   if not ire.hasTarget() then
      setGauge("target", widget, 0, 100, theme.span("textDim", "no target"))
      return
   end

   local health = ire.targetHealth()
   local name = theme.esc(ire.target.description or ire.target.id or "target")
   local id = ire.target.id and theme.span("textDim", "&nbsp;#" .. theme.esc(ire.target.id)) or ""
   if health then
      -- hpperc can arrive fractional; floor before %d.
      local pct = math.floor(health)
      setGauge("target", widget, health, 100,
         theme.span("textBright", name, true) .. id .. "&nbsp;&nbsp;"
            .. theme.span(theme.forPercent(pct), pct .. "%", true))
   else
      setGauge("target", widget, 100, 100, theme.span("textBright", name, true) .. id)
   end
end

--- Everything driven by a prompt.
function M.update()
   M.updateGauges()
   if M.updateBalances() then theme.wakeClock() end
   M.updateStatus()
   M.updateStats()
end

theme.ticking("hud", function() return M.updateBalances() end)

emunah.event.register("emunah.vitals", function() theme.later("vitals", M.update) end, "ui.vitals")
emunah.event.register("emunah.ui.built", function() M.build() end, "ui.vitals")

-- A balance spent or recovered on its own timer has no prompt behind it, and a lock comes and
-- goes with an affliction. Only the strip: nothing else on the HUD reads either.
emunah.event.registerAll({
   "emunah.timer.started", "emunah.timer.expired",
   "emunah.affliction.tracked", "emunah.affliction.cured", "emunah.afflictions.list",
}, function()
   theme.later("vitals.balances", function()
      if M.updateBalances() then theme.wakeClock() end
   end)
end, "ui.vitals")

emunah.event.registerAll({
   "emunah.curing.enabled", "emunah.curing.disabled",
   "emunah.defkeepup.enabled", "emunah.defkeepup.disabled",
   "emunah.bashing.started", "emunah.bashing.stopped",
   "emunah.pvp.started", "emunah.pvp.stopped", "emunah.pvp.target",
   "emunah.rateLimited", "emunah.character.died", "emunah.character.revived",
}, function() theme.later("vitals.status", M.updateStatus) end, "ui.vitals")

emunah.event.registerAll({
   "emunah.target",
   "emunah.target.info",
}, function() theme.later("vitals.target", M.updateTarget) end, "ui.vitals")

M.build()

return M

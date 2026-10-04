--- Alert windows: a framed popup over the game console for something that must be seen now.
---
--- One window per key, raised, updated in place, closed by a click or after its duration.
--- Rich text, so a list of rows lines up as a table. Used by presences.lua for hostiles the
--- angel senses; anything else that needs the same can call it the same way:
---
---     emunah.ui.alert.show("key", "Title", { { "cell", "cell" }, ... }, { duration = 15 })
---
--- Mudlet has no `visWarn()`: it is not part of Mudlet's API and nothing in Emunah defined
--- one. This is that window.

local M = {}

local theme = emunah.ui.theme

--- key -> { widget, rows }
M.open = {}

local ROW_PX, CHROME_PX, WIDTH_PX = 18, 44, 560

local function available()
   return type(Geyser) == "table" and Geyser.Label ~= nil
end

local function timers()
   emunah._persist = emunah._persist or {}
   emunah._persist.alertTimers = emunah._persist.alertTimers or {}
   return emunah._persist.alertTimers
end

-- A reload replaces this module; a close the previous generation armed would act on a
-- window this one is about to own.
for _, id in pairs(timers()) do killTimer(id) end
emunah._persist.alertTimers = {}

local function body(title, rows)
   local html = {
      '<p style="margin:0 0 6px 0">',
      theme.span("warning", "&#9888;&nbsp;" .. theme.esc(title), true),
      theme.span("textDim", "&nbsp;&nbsp;click to dismiss"),
      "</p><table cellspacing=\"0\" cellpadding=\"2\" width=\"100%\">",
   }
   for _, row in ipairs(rows) do
      html[#html + 1] = string.format(
         '<tr><td>%s</td><td>%s</td><td>%s</td><td align="right">%s</td></tr>',
         theme.span("affliction", theme.esc(row[1] or ""), true),
         theme.span("warning", theme.esc(row[2] or "")),
         theme.span("text", theme.esc(row[3] or "")),
         theme.span("textDim", theme.esc(row[4] or "")))
   end
   html[#html + 1] = "</table>"
   return table.concat(html)
end

--- Where the window goes: centred over the game console, near its top.
local function geometry(rowCount)
   local width, height = getMainWindowSize()
   local layout = emunah.ui.layout
   local left, right = 0, width
   if layout then
      left = width * layout.percentOf(layout.WIDTH_LEFT) / 100
      right = width - width * layout.percentOf(layout.WIDTH_RIGHT) / 100
   end
   local w = math.min(WIDTH_PX, math.floor(right - left - 40))
   local h = CHROME_PX + rowCount * ROW_PX
   local x = math.floor((left + right) / 2 - w / 2)
   local y = math.floor(height * 0.08)
   return x, y, w, h
end

function M.isOpen(key)
   return M.open[key] ~= nil
end

function M.close(key)
   local entry = M.open[key]
   if not entry then return false end
   pcall(function() entry.widget:hide() end)
   M.open[key] = nil
   local id = timers()[key]
   if id then killTimer(id) timers()[key] = nil end
   return true
end

--- Redraw an open window's contents without raising it again or restarting its clock.
function M.update(key, title, rows)
   local entry = M.open[key]
   if not entry then return false end
   local x, y, w, h = geometry(#rows)
   pcall(function() entry.widget:resize(w, h) end)
   pcall(function() entry.widget:move(x, y) end)
   entry.widget:echo(body(title, rows))
   return true
end

--- Raise a window, or replace what an open one says. `opts.duration`: seconds before it
--- closes by itself; omitted, it stays until clicked.
function M.show(key, title, rows, opts)
   if not available() then return nil end
   opts = opts or {}
   local x, y, w, h = geometry(#rows)
   local entry = M.open[key]
   if not entry then
      local widget = Geyser.Label:new({
         name = "emunah.alert." .. key, x = x, y = y, width = w, height = h,
      })
      widget:setStyleSheet(string.format([[
         background-color: %s;
         border: 2px solid %s;
         border-radius: 6px;
         color: %s;
         font-family: "%s";
         font-size: %dpt;
         qproperty-alignment: 'AlignLeft | AlignTop';
         padding: 8px 10px;
      ]], theme.colour.panel, theme.colour.affliction, theme.colour.text,
          theme.font.family, theme.font.size))
      widget:setClickCallback(function() M.close(key) end)
      entry = { widget = widget }
      M.open[key] = entry
   end
   entry.widget:show()
   if type(raiseWindow) == "function" then pcall(raiseWindow, "emunah.alert." .. key) end
   M.update(key, title, rows)

   local id = timers()[key]
   if id then killTimer(id) timers()[key] = nil end
   if opts.duration and opts.duration > 0 then
      timers()[key] = tempTimer(opts.duration, function()
         timers()[key] = nil
         M.close(key)
      end)
   end
   return entry.widget
end

return M

--- Render the interface to an HTML page, so a UI change can be looked at without Mudlet.
---
--- Runs the real UI code against the mock with a scripted mid-fight state, then lays every
--- widget out from its own geometry (resolved the way Geyser resolves it), its own
--- stylesheet and its own content. Rich-text labels are close to what Qt draws; consoles
--- are their decho converted to spans. The map and the game console are placeholders.
---
--- Usage: lua5.1 test/ui_preview.lua [out.html] [width] [height]
---        chromium --headless --screenshot=ui.png --window-size=1920,1080 file://$PWD/ui.html
---
--- An approximation, not a pixel-exact one: Qt's rich text and a browser differ in small
--- ways (line height, table padding). Good for layout, density and colour; check the real
--- thing in Mudlet before calling a change done.

local ROOT = (arg and arg[0] or ""):match("^(.*)/test/ui_preview%.lua$") or "."
package.path = ROOT .. "/test/?.lua;" .. package.path

local OUT = arg and arg[1] or "ui-preview.html"
local WIDTH = tonumber(arg and arg[2]) or 1920
local HEIGHT = tonumber(arg and arg[3]) or 1080

local mock = require("mock_mudlet")
mock.install(ROOT)
_G.getMainWindowSize = function() return WIDTH, HEIGHT end
_G.EMUNAH_ROOT = ROOT
dofile(ROOT .. "/src/emunah.lua")
mock.installGeyser()
emunah.ui.layout.build()

-- ---------------------------------------------------------------------------
-- A fight in progress
-- ---------------------------------------------------------------------------

local engine = emunah.curing.engine
engine.enabled = true
emunah.curing.defkeepup.enabled = true

mock.feed("Char.Vitals", { hp = "3580", maxhp = "5400", mp = "4100", maxmp = "4800",
   ep = "21000", maxep = "24000", wp = "17600", maxwp = "20000", nl = "62.4", bal = "1", eq = "1",
   charstats = { "Bleed: 0", "Devotion: 87%" } })

mock.feed("Room.Info", { num = 6814, name = "Before the Temple of the Sun", area = "Cyrene",
   exits = { n = 1, ne = 2, e = 3, s = 4, w = 5, u = 6 }, details = { "shop" } })
emunah.namedb.iff("Zalydd", "enemy")
emunah.namedb.iff("Anzerloi", "ally")
mock.feed("Room.Players", {
   { name = "Zalydd", fullname = "Zalydd, the Unbroken Spear" },
   { name = "Anzerloi", fullname = "Anzerloi, Sentinel" },
   { name = "Meldia", fullname = "Meldia" },
})
mock.feed("Char.Items.List", { location = "room", items = {
   { id = "1", name = "a sewer rat", attrib = "m" },
   { id = "2", name = "a sewer rat", attrib = "m" },
   { id = "3", name = "a crazed dervish", attrib = "m" },
   { id = "4", name = "the corpse of a sewer rat", attrib = "td" },
   { id = "5", name = "a gold sovereign", attrib = "t" },
   { id = "6", name = "a gold sovereign", attrib = "t" },
   { id = "7", name = "a gold sovereign", attrib = "t" },
   { id = "8", name = "a battered wooden chest", attrib = "c" },
   { id = "9", name = "a monolith sigil", attrib = "" },
} })
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "20", name = "an epidermal salve", attrib = "" },
   { id = "21", name = "some kelp", attrib = "" },
} })
mock.feed("IRE.Rift.List", { { name = "bloodroot", amount = "120" }, { name = "goldenseal", amount = "80" } })

mock.feed("Char.Defences.List", {
   { name = "rebounding" }, { name = "speed" }, { name = "levitating" }, { name = "insomnia" },
   { name = "temperance" }, { name = "deathsight" }, { name = "mindseye" }, { name = "deafness" },
   { name = "poisonresist" }, { name = "thirdeye" },
})
emunah.curing.defkeepup.setMode("cloak", "keepup")
emunah.curing.defkeepup.setMode("blind", "keepup")

mock.feed("Char.Afflictions.Add", { name = "anorexia", cure = "APPLY EPIDERMAL", desc = "" })
mock.feed("Char.Afflictions.Add", { name = "asthma", cure = "EAT KELP", desc = "" })
mock.feed("Char.Afflictions.Add", { name = "paralysis", cure = "EAT BLOODROOT", desc = "" })
mock.feed("Char.Afflictions.Add", { name = "stupidity", cure = "EAT GOLDENSEAL", desc = "" })
engine.addText("clumsiness")
mock.feed("Char.Vitals", { hp = "3120", maxhp = "5400", bal = "0", eq = "1" })
emunah.curing.detect.textPrompt()
mock.advance(1.4)
emunah.timers.start("attack.balance", 1.7)

mock.feed("IRE.Target.Set", "118223")
mock.feed("IRE.Target.Info", { id = "118223", short_desc = "a crazed dervish", hpperc = "42" })

for _, line in ipairs({
   { channel = "ct", text = "(Cyrene): Anzerloi says, \"Dervishes at the temple steps.\"" },
   { channel = "tell", text = "Meldia tells you, \"Need a hand with those?\"" },
   { channel = "say", text = "Zalydd says, \"You'll regret coming here.\"" },
   { channel = "market", text = "(Market): Lokri says, \"Selling 50 bloodroot, cheap.\"" },
}) do mock.feed("Comm.Channel.Text", line) end
if emunah.ui.chyron and emunah.ui.chyron.send then
   emunah.ui.chyron.send("Zalydd has entered the room.", "warning")
end

mock.advance(0)

-- ---------------------------------------------------------------------------
-- Geometry, the way Geyser resolves it
-- ---------------------------------------------------------------------------

local function resolve(value, size, offset, isSize)
   if value == nil then return isSize and size or 0 end
   if type(value) == "number" then
      if value < 0 then return isSize and (size - offset + value) or (size + value) end
      return value
   end
   local text = tostring(value)
   local negative = text:sub(1, 1) == "-"
   if negative then text = text:sub(2) end
   local number = tonumber(text:match("^([%d%.]+)")) or 0
   local px = text:find("%%") and (size * number / 100) or number
   if negative then
      return isSize and (size - offset - px) or (size - px)
   end
   return px
end

local frames = {}

local function frame(widget)
   if frames[widget] then return frames[widget] end
   local parent = widget.parent
   local px, py, pw, ph = 0, 0, WIDTH, HEIGHT
   if parent then
      local f = frame(parent)
      px, py, pw, ph = f.ix, f.iy, f.iw, f.ih
   end
   local cons = widget.cons or {}
   local x = resolve(cons.x, pw, 0, false)
   local y = resolve(cons.y, ph, 0, false)
   local w = resolve(cons.width, pw, x, true)
   local h = resolve(cons.height, ph, y, true)
   local f = { x = px + x, y = py + y, w = w, h = h }
   -- An Adjustable.Container's children sit inside its padding.
   local pad = widget.kind == "adjustable" and (cons.padding or 4) or 0
   f.ix, f.iy, f.iw, f.ih = f.x + pad, f.y + pad, w - 2 * pad, h - 2 * pad
   frames[widget] = f
   return f
end

-- ---------------------------------------------------------------------------
-- Qt stylesheet and decho, as CSS and HTML
-- ---------------------------------------------------------------------------

local function css(sheet)
   if not sheet then return "" end
   sheet = sheet:gsub("qlineargradient%(%s*x1:0,%s*y1:0,%s*x2:0,%s*y2:1,%s*stop:0%s*([#%w]+),%s*stop:1%s*([#%w]+)%)",
      "linear-gradient(to bottom, %1, %2)")
   sheet = sheet:gsub("background%-color:%s*linear%-gradient", "background: linear-gradient")
   local align = sheet:match("qproperty%-alignment:%s*'([^']+)'")
   sheet = sheet:gsub("qproperty%-alignment:[^;]*;", "")
   if align then
      local horizontal = align:find("AlignCenter") and "center"
         or align:find("AlignRight") and "flex-end" or "flex-start"
      local vertical = align:find("AlignTop") and "flex-start"
         or (align:find("AlignVCenter") or align:find("AlignCenter")) and "center" or "center"
      sheet = sheet .. string.format(";display:flex;justify-content:%s;align-items:%s;", horizontal, vertical)
   end
   -- Double quotes would end the style attribute this is written into. The fallback is
   -- for a machine without Mudlet's bundled font.
   sheet = sheet:gsub('font%-family:%s*"([^"]+)"', "font-family:'%1','DejaVu Sans Mono',monospace")
   return (sheet:gsub("%s+", " "))
end

local function esc(text)
   return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function decho(text)
   local out, open = {}, 0
   local position = 1
   while true do
      local s, e, a, b, c, d = text:find("<(:?)(%d+),(%d+),(%d+)>", position)
      if not s then break end
      out[#out + 1] = esc(text:sub(position, s - 1))
      if a == ":" then
         out[#out + 1] = string.format('<span style="background:rgb(%s,%s,%s)">', b, c, d)
      else
         out[#out + 1] = string.format('<span style="color:rgb(%s,%s,%s)">', b, c, d)
      end
      open = open + 1
      position = e + 1
   end
   out[#out + 1] = esc(text:sub(position))
   out[#out + 1] = string.rep("</span>", open)
   return table.concat(out)
end

local theme = emunah.ui.theme
local html = {}
local function add(text) html[#html + 1] = text end

add(string.format([[<!doctype html><html><head><meta charset="utf-8"><style>
body { margin:0; width:%dpx; height:%dpx; background:%s; position:relative; overflow:hidden;
       font-family:"Ubuntu Mono","DejaVu Sans Mono",monospace; color:%s; }
div.w { position:absolute; box-sizing:border-box; overflow:hidden; }
table { border-collapse:separate; font-size:inherit; }
td { white-space:nowrap; }
.console { white-space:pre-wrap; line-height:1.25; }
</style></head><body>]], WIDTH, HEIGHT, "#000000", theme.colour.text))

-- The game console, between the borders the layout sets.
local layout = emunah.ui.layout
local left = WIDTH * layout.percentOf(layout.WIDTH_LEFT) / 100
local right = WIDTH * layout.percentOf(layout.WIDTH_RIGHT) / 100
local top = HEIGHT * layout.percentOf(layout.HEIGHT_TOP) / 100
local bottom = HEIGHT * layout.percentOf(layout.HEIGHT_BOTTOM) / 100
add(string.format('<div class="w console" style="left:%dpx;top:%dpx;width:%dpx;height:%dpx;padding:6px;font-size:13px;color:#c0c0c0;display:flex;flex-direction:column;justify-content:flex-end">%s</div>',
   left, top, WIDTH - left - right, HEIGHT - top - bottom, esc([[
Before the Temple of the Sun.
Broad marble steps climb toward a colonnade of white pillars, each banded in beaten gold.
A crazed dervish is here, whirling. Two sewer rats scurry about. A battered wooden chest
rests against a pillar. Zalydd, Anzerloi and Meldia are here.
You see exits leading north, northeast, east, south, west and up.
3580h, 4100m, 21000e, 17600w ex-
Zalydd jabs you with a needle.
You eat a bloodroot leaf.
Your muscles unlock; you are no longer paralysed.
3120h, 4100m, 21000e, 17600w e-]])))

-- Widgets, parents before children so children draw on top.
local ordered = {}
for _, widget in pairs(mock.widgets) do ordered[#ordered + 1] = widget end
local function depth(widget)
   local d = 0
   while widget.parent do d = d + 1 widget = widget.parent end
   return d
end
table.sort(ordered, function(a, b)
   local da, db = depth(a), depth(b)
   if da ~= db then return da < db end
   return a.name < b.name
end)

for _, widget in ipairs(ordered) do
   local kind = widget.kind
   local shown = widget.shown ~= false
   local inGauge = widget.parent and widget.parent.kind == "gauge"
   if shown and not inGauge then
      local f = frame(widget)
      local box = string.format("left:%dpx;top:%dpx;width:%dpx;height:%dpx;", f.x, f.y, f.w, f.h)
      if kind == "adjustable" then
         add(string.format('<div class="w" style="%s%s"><div style="position:absolute;left:8px;top:2px;font-size:10px;color:%s">%s</div></div>',
            box, css(widget.cons.adjLabelstyle), widget.cons.titleTxtColor or "#888", esc(widget.cons.titleText or "")))
      elseif kind == "label" then
         -- A label written with decho carries <r,g,b> tags; one written with echo, rich text.
         local contents = widget.contents or ""
         if contents:find("<:?%d+,%d+,%d+>") then contents = decho(contents) end
         -- One block inside the flex box, as Qt lays a label's rich text out top to bottom.
         add(string.format('<div class="w" style="%s%s"><div style="width:100%%">%s</div></div>', box, css(widget.style), contents))
      elseif kind == "miniconsole" then
         local size = widget.cons.fontSize or theme.font.size
         add(string.format('<div class="w console" style="%sbackground:%s;font-size:%dpt;padding:2px 4px">%s</div>',
            box, widget.cons.color or theme.colour.base, size, decho(widget.contents or "")))
      elseif kind == "gauge" then
         local value = widget.value or { current = 0, max = 1, text = "" }
         local fraction = math.max(0, math.min(1, (tonumber(value.current) or 0) / math.max(tonumber(value.max) or 1, 1)))
         add(string.format('<div class="w" style="%s%s"></div>', box, css(widget.back.style)))
         if fraction > 0 then
            add(string.format('<div class="w" style="left:%dpx;top:%dpx;width:%dpx;height:%dpx;%s"></div>',
               f.x, f.y, f.w * fraction, f.h, css(widget.front.style)))
         end
         add(string.format('<div class="w" style="%s%s">%s</div>', box, css(widget.text.style), value.text or ""))
      elseif kind == "mapper" then
         add(string.format('<div class="w" style="%sbackground:#06090c;border:1px solid %s;display:flex;align-items:center;justify-content:center;color:#3a4553;font-size:12px">mapper</div>',
            box, theme.colour.border))
      end
   end
end

add("</body></html>")

local file = assert(io.open(OUT, "w"))
file:write(table.concat(html, "\n"))
file:close()
print("wrote " .. OUT)

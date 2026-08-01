--- Room, items and target panel.
---
--- Occupies the BOTTOM half of the right-hand column, below the chat console (both read
--- layout.CHAT_SPLIT so they cannot drift into overlapping).
---
--- Shows where you are, who the game admits is here, what is on the ground, and what you
--- are targeting.
---
--- Room items
--- ----------
--- gmcp/items.lua has always tracked room contents, but nothing rendered them -- so `ih`
--- would list four items in the game window while the panel showed none. They are
--- displayed here, and are worth having on screen: items appear and vanish without any
--- message you would notice mid-fight, and Char.Items.Add/Remove is how you learn a corpse
--- dropped loot, or that someone just put something down.
---
--- The player list carries a caveat worth remembering: Room.Players omits anyone
--- shrouded, hidden or phased, so it is "players the game will admit to", never "players
--- in the room". Do not use it to decide a room is empty.

local M = {}

local util   = emunah.util
local theme  = emunah.ui.theme
local layout = emunah.ui.layout

M.widgets = {}

--- Height reserved at the bottom of the panel for the target gauge.
M.TARGET_HEIGHT = 18

local function available()
   return layout.container("right") ~= nil and type(Geyser) == "table"
end

function M.build()
   if not available() then return false end
   local parent = layout.container("right")

   -- Fills the right container from just below the chat console down to its foot. The
   -- container itself now stops above the map region (see ui/layout.lua), so anchoring to
   -- the container bottom is correct and cannot collide with the map.
   -- See ui/theme.lua consoleColour(): MiniConsoles take a background colour, not a
   -- stylesheet.
   local top = string.format("%d%%", layout.percentOf(layout.CHAT_SPLIT) + 1)

   M.widgets.room = Geyser.MiniConsole:new(theme.consoleCons({
      name = "emunah.room",
      x = 4, y = top, width = "-8px",
      height = string.format("-%dpx", M.TARGET_HEIGHT + 8),
      fontSize = theme.font.small,
      wrapAt = 42,
   }), parent)

   -- Target health bar, pinned to the foot of the container.
   M.widgets.target = Geyser.Gauge:new({
      name = "emunah.target",
      x = 4, y = string.format("-%dpx", M.TARGET_HEIGHT + 4),
      width = "-8px", height = M.TARGET_HEIGHT,
   }, parent)
   M.widgets.target.front:setStyleSheet(theme.gaugeFront("affliction"))
   M.widgets.target.back:setStyleSheet(theme.gaugeBack())
   M.widgets.target.text:setStyleSheet(string.format([[
      color: %s; font-family: "%s"; font-size: %dpt;
      qproperty-alignment: 'AlignCenter';
   ]], theme.colour.textBright, theme.font.family, theme.font.small))

   M.update()
   return true
end

--- Strip Achaea's leading article so a list of items reads cleanly in a narrow panel.
--- "a small wooden sign" -> "small wooden sign".
local function trimArticle(name)
   return (tostring(name or ""):gsub("^[Aa]n?%s+", ""):gsub("^[Tt]he%s+", ""))
end

--- One clickable, toggleable line for a room denizen. Colour reflects the CURRENT wanted
--- state -- not-wanted is dimmed to textDim regardless of the caller's default colour --
--- so the panel doubles as an at-a-glance answer to "what is this loop actually going to
--- attack" without opening `emunah mobs`. Uses dechoLink (theme.dc() emits decimal-tuple
--- colour tags, the "d" family, not the named "c" family cecho/cechoLink expect).
function M.echoDenizen(console, name, wantedColour)
   local den = emunah.denizens
   local area = den.area()
   local wanted = den.wanted(name, area)
   local colour = wanted and wantedColour or theme.dc("textDim")
   local mark = wanted and "*" or " "
   local text = string.format("%s%s %s\n", colour, mark, trimArticle(name))
   -- Re-render the panel after toggling so the click's effect is visible immediately,
   -- not just on the next unrelated room-panel update.
   local command = string.format(
      "emunah.denizens.toggleWanted(%q, %q); emunah.ui.roompanel.update()", name, tostring(area))
   local hint = wanted and "Click to stop killing this." or "Click to allow killing this."
   console:dechoLink(text, command, hint, true)
end

function M.update()
   local room = emunah.gmcp.room
   local console = M.widgets.room
   if not console or not room then return end

   console:clear()

   console:decho(string.format("%s%s\n", theme.dc("textBright"), room.name or "unknown"))
   console:decho(string.format("%s%s%s\n",
      theme.dc("textDim"), room.area or "", room.num and (" #" .. room.num) or ""))

   local exits = room.exitList()
   console:decho(string.format("%sexits %s%s\n",
      theme.dc("textDim"), theme.dc("balance"),
      #exits > 0 and table.concat(exits, " ") or "none"))

   if room.hasDetail("shop") or room.hasDetail("bank") then
      local details = {}
      for _, detail in ipairs(room.details) do details[#details + 1] = detail end
      console:decho(string.format("%s%s\n", theme.dc("experience"), table.concat(details, " ")))
   end

   local players = room.playerNames()
   if #players > 0 then
      console:decho(string.format("%shere %s%s\n",
         theme.dc("textDim"), theme.dc("warning"), table.concat(players, ", ")))
   end

   -- Room items.
   local items = emunah.gmcp.items
   if items then
      local here = items.at("room")
      if #here > 0 then
         console:decho(string.format("\n%sitems %s(%d)\n",
            theme.dc("textDim"), theme.dc("border"), #here))
         for _, item in ipairs(here) do
            local attrib = items.attrib(item)
            -- Colour by what the item IS: creatures are what you are about to fight,
            -- corpses and containers are what you are about to loot.
            local colour = theme.dc("text")
            if attrib.monster then
               colour = theme.dc("affliction")
            elseif attrib.dead then
               colour = theme.dc("warning")
            elseif attrib.container then
               colour = theme.dc("experience")
            elseif attrib.takeable then
               colour = theme.dc("defence")
            end

            if attrib.monster and not attrib.dead then
               M.echoDenizen(console, item.name, colour)
            else
               console:decho(string.format("%s  %s\n", colour, trimArticle(item.name)))
            end
         end
      end
   end

   M.updateTarget()
end

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
      -- hpperc can arrive fractional; floor before %d (see ui/vitals.lua).
      gauge:setValue(health, 100, string.format("%s  %d%%", label, math.floor(health)))
   else
      gauge.front:setStyleSheet(theme.gaugeFront("inactive"))
      gauge:setValue(100, 100, label)
   end
end

emunah.event.registerAll({
   "emunah.room",
   "emunah.room.players",
   "emunah.room.playerEntered",
   "emunah.room.playerLeft",
   -- Item events: this is what makes the room list live. Without these the panel would
   -- only refresh when you moved, and an item dropped at your feet would never appear.
   "emunah.items.list",
   "emunah.items.added",
   "emunah.items.removed",
   "emunah.items.updated",
}, function() M.update() end, "ui.roompanel")

emunah.event.registerAll({
   "emunah.target",
   "emunah.target.info",
}, function() M.updateTarget() end, "ui.roompanel")

emunah.event.register("emunah.ui.built", function() M.build() end, "ui.roompanel")

M.build()

return M

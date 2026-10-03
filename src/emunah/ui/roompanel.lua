--- Room and items panel.
---
--- The top section of the left-hand column (see ui/layout.lua's LEFT_SECTIONS): where you
--- are, who the game admits is here, what you could fight, and what is on the ground.
---
--- Grouped rather than listed. The room is the one panel whose length the game decides,
--- and five copies of "a rat" in a row, or eleven coins one per line, push everything below
--- them out of sight. People, denizens and items each get a heading with a count, and
--- identical items collapse to one row with a multiplier.
---
--- Room items
--- ----------
--- gmcp/items.lua has always tracked room contents. They are worth having on screen: items
--- appear and vanish without any message you would notice mid-fight, and Char.Items.Add/
--- Remove is how you learn a corpse dropped loot, or that someone just put something down.
---
--- The player list carries a caveat worth remembering: Room.Players omits anyone
--- shrouded, hidden or phased, so it is "players the game will admit to", never "players
--- in the room". Do not use it to decide a room is empty.

local M = {}

local util   = emunah.util
local theme  = emunah.ui.theme
local layout = emunah.ui.layout

M.widgets = {}

local function available()
   return layout.container("left") ~= nil and type(Geyser) == "table"
end

function M.build()
   if not available() then return false end
   local spec = layout.leftSection("room")
   local section = layout.section(layout.container("left"), {
      key = spec.key, title = spec.title, y = spec.y, height = spec.height,
      body = "console", cons = { fontSize = theme.font.small, wrapAt = 44 },
   })
   if not section then return false end
   M.widgets.room, M.widgets.header = section.body, section.header

   -- The console is brand new and empty, so whatever signature the last paint recorded
   -- describes a widget that no longer exists. Without this the first update() after a
   -- rebuild compares equal and draws nothing, and the panel comes up blank.
   M.forgetPainted()

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
--- The text, click command and hint for one denizen row.
local function denizenRow(name, wantedColour)
   local den = emunah.denizens
   local area = den.area()
   local wanted = den.wanted(name, area)
   local colour = wanted and wantedColour or theme.dc("textDim")
   -- A filled dot is "will be attacked", a hollow one "left alone".
   local mark = wanted and "\226\151\143" or "\226\151\139"
   local text = string.format("  %s%s %s\n", colour, mark, trimArticle(name))
   -- Re-render the panel after toggling so the click's effect is visible immediately,
   -- not just on the next unrelated room-panel update.
   local command = string.format(
      "emunah.denizens.toggleWanted(%q, %q); emunah.ui.roompanel.update()", name, tostring(area))
   local hint = wanted and "Click to stop killing this." or "Click to allow killing this."
   return text, command, hint
end

--- Draw one clickable denizen row straight to a console. Kept because it is the public shape
--- this module has always exposed; M.update() goes through M.queueDenizen() instead so the
--- row can take part in the change comparison.
function M.echoDenizen(console, name, wantedColour)
   local text, command, hint = denizenRow(name, wantedColour)
   console:dechoLink(text, command, hint, true)
end

-- THE PANEL IS BUILT BEFORE ANY OF IT IS DRAWN.
--
-- This repaints on eight events, four of which are item events -- so every Char.Items.Add
-- rebuilt the whole panel, and a restock pulling five herbs did it five times. Each rebuild
-- was a clear() plus one decho per line.
--
-- Two changes, and the split below is what makes both possible. The panel is rendered into a
-- list of segments first; then:
--
--   * if the render is byte-identical to what is already on screen, NOTHING is drawn. That
--     is the common case in a burst -- four of those five item events do not change what the
--     room shows -- and it costs a string build and a compare instead of a repaint.
--
--   * otherwise the segments are drawn, with runs of plain text concatenated into single
--     decho calls.
--
-- A LINK CANNOT BE CONCATENATED: dechoLink() binds a Lua callback to the run of text it
-- draws, so a clickable denizen has to be its own call. Hence segments rather than one
-- string -- everything between the links still collapses.
local segments, segmentCount = {}, 0

local function plain(text)
   segmentCount = segmentCount + 1
   segments[segmentCount] = text
end

local function link(text, command, hint)
   segmentCount = segmentCount + 1
   segments[segmentCount] = { text = text, command = command, hint = hint }
end

--- A string that changes whenever anything drawn would change -- link targets included, so a
--- denizen whose wanted-state was toggled repaints even though its text is the same length.
local function signature()
   local parts = {}
   for index = 1, segmentCount do
      local segment = segments[index]
      if type(segment) == "table" then
         parts[index] = "\1" .. segment.text .. "\1" .. segment.command
      else
         parts[index] = segment
      end
   end
   return table.concat(parts)
end

local lastSignature = nil

--- Draw the built segments, coalescing runs of plain text.
local function draw(console)
   console:clear()
   local run, runCount = {}, 0
   for index = 1, segmentCount do
      local segment = segments[index]
      if type(segment) == "table" then
         if runCount > 0 then
            console:decho(table.concat(run, "", 1, runCount))
            runCount = 0
         end
         console:dechoLink(segment.text, segment.command, segment.hint, true)
      else
         runCount = runCount + 1
         run[runCount] = segment
      end
   end
   if runCount > 0 then console:decho(table.concat(run, "", 1, runCount)) end
end

--- Add one clickable denizen row to the panel being built.
function M.queueDenizen(name, wantedColour)
   link(denizenRow(name, wantedColour))
end

--- Forget what is on screen, so the next update() always draws. Called when the console is
--- rebuilt: the widget is new and empty whatever the signature says.
function M.forgetPainted()
   lastSignature = nil
end

--- A dim heading inside the panel, with a count.
local function heading(label, count)
   plain(string.format("\n%s%s %s%d\n", theme.dc("textDim"), label, theme.dc("border"), count))
end

function M.update()
   local room = emunah.gmcp.room
   local console = M.widgets.room
   if not console or not room then return end

   segmentCount = 0

   layout.header("room", M.widgets.header, "Room", room.area or "", "textDim")

   plain(string.format("%s%s\n", theme.dc("textBright"), room.name or "unknown"))

   local where = {}
   if room.num then where[#where + 1] = theme.dc("textDim") .. "#" .. room.num end
   if room.hasDetail("shop") or room.hasDetail("bank") then
      for _, detail in ipairs(room.details) do
         where[#where + 1] = theme.dc("experience") .. detail
      end
   end
   if #where > 0 then
      plain(table.concat(where, theme.dc("border") .. "  \194\183  ") .. "\n")
   end

   local exits = room.exitList()
   plain(string.format("%sexits  %s%s\n",
      theme.dc("textDim"), theme.dc("balance"),
      #exits > 0 and table.concat(exits, " ") or (theme.dc("border") .. "none")))

   -- Short names, not the honorific fullname -- there is one line to work with here.
   -- Coloured per ui/names.lua's own policy (enemy/ally/city) so the panel agrees with
   -- how the same name would be highlighted if it scrolled past in the game text, rather
   -- than running its own separate opinion. `names` is read here rather than captured at
   -- module scope: ui/names.lua loads after ui/roompanel.lua (it renders the name
   -- database, so it has to follow it -- see emunah.lua's MANIFEST), so a top-level local
   -- would have captured nil.
   local players = room.playerShortNames()
   if #players > 0 then
      heading("people", #players)
      local names = emunah.ui.names
      local parts = {}
      for _, name in ipairs(players) do
         local style = names and names.styleFor(name)
         local colour = (style and style.colour) and theme.dcHex(style.colour) or theme.dc("warning")
         parts[#parts + 1] = colour .. name
      end
      plain("  " .. table.concat(parts, theme.dc("textDim") .. ", ") .. "\n")
   end

   local items = emunah.gmcp.items
   if items then
      local here = items.at("room")
      local denizens, loot = {}, {}
      for _, item in ipairs(here) do
         local attrib = items.attrib(item)
         if attrib.monster and not attrib.dead then
            denizens[#denizens + 1] = item
         else
            loot[#loot + 1] = { item = item, attrib = attrib }
         end
      end

      -- Denizens one row each, never grouped: each row is its own click target, and the
      -- wanted mark is per name.
      if #denizens > 0 then
         heading("denizens", #denizens)
         for _, item in ipairs(denizens) do
            M.queueDenizen(item.name, theme.dc("affliction"))
         end
      end

      -- Everything else grouped by name, in first-seen order. Colour by what the item IS:
      -- corpses and containers are what you are about to loot.
      if #loot > 0 then
         heading("items", #loot)
         local order, groups = {}, {}
         for _, entry in ipairs(loot) do
            local name = trimArticle(entry.item.name)
            local group = groups[name]
            if not group then
               group = { name = name, count = 0, attrib = entry.attrib }
               groups[name] = group
               order[#order + 1] = group
            end
            group.count = group.count + 1
         end
         for _, group in ipairs(order) do
            local attrib = group.attrib
            local colour = theme.dc("text")
            if attrib.dead then
               colour = theme.dc("warning")
            elseif attrib.container then
               colour = theme.dc("experience")
            elseif attrib.takeable then
               colour = theme.dc("defence")
            end
            local times = group.count > 1
               and string.format("%s%d\195\151 ", theme.dc("textDim"), group.count) or ""
            plain(string.format("  %s%s%s\n", times, colour, group.name))
         end
      end
   end

   -- Nothing on screen would change, so nothing is drawn. See the note above `segments`.
   local rendered = signature()
   if rendered == lastSignature then return end
   lastSignature = rendered

   draw(console)
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
}, function() theme.later("roompanel", M.update) end, "ui.roompanel")   -- after the packet: theme.later()

emunah.event.register("emunah.ui.built", function() M.build() end, "ui.roompanel")

M.build()

return M

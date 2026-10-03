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

--- Characters per line in the room console.
M.WRAP = 44

function M.build()
   if not available() then return false end
   local spec = layout.leftSection("room")
   local section = layout.section(layout.container("left"), {
      key = spec.key, title = spec.title, y = spec.y, height = spec.height,
      body = "console", cons = { fontSize = theme.font.small, wrapAt = M.WRAP },
      refresh = function() M.update() end,
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

--- Characters on screen, not bytes: "×" and "▪" are two and three bytes of UTF-8.
local function displayWidth(text)
   local n = 0
   for _ in tostring(text):gmatch("[^\128-\191]") do n = n + 1 end
   return n
end

--- A heading inside the panel: the label in its own colour and capitals, the count, and a
--- rule to the edge. People, mobiles and items have to read as three different things at a
--- glance -- reported from play that items and mobiles were not clear apart -- so each gets
--- its own colour here and its own mark on every row below it.
local RULE = string.rep("\226\148\128", 40)   -- "─"

local function heading(label, count, colourName)
   plain(string.format("\n%s%s %s%d %s%s\n",
      theme.dc(colourName or "textDim"), label, theme.dc("textBright"), count,
      theme.dc("border"), RULE:sub(1, 3 * math.max(2, 28 - #label - #tostring(count)))))
end

function M.update()
   local room = emunah.gmcp.room
   local console = M.widgets.room
   if not console or not room then return end

   segmentCount = 0
   local singleRows, pairedRows = 0, 0

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
      heading("PEOPLE", #players, "warning")
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

      -- Mobiles one row each, never grouped: each row is its own click target, and the
      -- wanted mark is per name.
      if #denizens > 0 then
         heading("MOBILES", #denizens, "affliction")
         for _, item in ipairs(denizens) do
            M.queueDenizen(item.name, theme.dc("affliction"))
         end
      end

      -- Everything else grouped by name, in first-seen order. Colour by what the item IS:
      -- corpses and containers are what you are about to loot.
      if #loot > 0 then
         heading("ITEMS", #loot, "experience")
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
         -- Two to a line when the left column is short of room (layout.reflow()) -- but only
         -- two that each fit in half a line. A longer name takes a line of its own: cutting
         -- it short would hide exactly what this is for.
         local half = math.floor(M.WRAP / 2) - 4
         local cells, widths = {}, {}
         for index, group in ipairs(order) do
            local attrib = group.attrib
            local colour = theme.dc("text")
            if attrib.dead then
               colour = theme.dc("warning")
            elseif attrib.container then
               colour = theme.dc("experience")
            elseif attrib.takeable then
               colour = theme.dc("defence")
            end
            local text = (group.count > 1 and (group.count .. "\195\151 ") or "") .. group.name
            -- A square for a thing, where a mobile has a dot.
            cells[index] = string.format("  %s\226\150\170 %s%s", theme.dc("border"), colour, text)
            widths[index] = displayWidth(text)
         end

         -- Which items share a line, two-up: consecutive pairs where both fit.
         local function rows(twoUp)
            local out, index = {}, 1
            while index <= #cells do
               if twoUp and cells[index + 1] and widths[index] <= half and widths[index + 1] <= half then
                  out[#out + 1] = { index, index + 1 }
                  index = index + 2
               else
                  out[#out + 1] = { index }
                  index = index + 1
               end
            end
            return out
         end

         singleRows, pairedRows = #cells, #rows(true)
         for _, row in ipairs(rows(layout.compact("room") >= 2)) do
            if row[2] then
               plain(cells[row[1]] .. string.rep(" ", half + 2 - widths[row[1]]) .. cells[row[2]] .. "\n")
            else
               plain(cells[row[1]] .. "\n")
            end
         end
      end
   end

   -- Report the lines this takes, both ways, so the column can be sized to show all of it.
   local lines = 0
   for index = 1, segmentCount do
      local segment = segments[index]
      local text = type(segment) == "table" and segment.text or segment
      for _ in text:gmatch("\n") do lines = lines + 1 end
   end
   if layout.compact("room") >= 2 then
      layout.need("room", { lines - pairedRows + singleRows, lines })
   else
      layout.need("room", { lines, lines - singleRows + pairedRows })
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

--- Afflictions and defences panel.
---
--- The two lists no longer share a container. Afflictions sits at the BOTTOM of the
--- left-hand column, below ui/roompanel.lua's room/items console -- at about half its
--- former height, since urgency-sorted text is dense and does not need the room the room
--- panel does. Defences sits at the bottom of the right-hand column, below chat, in the
--- slot the room panel used to occupy (see ui/layout.lua's diagram). They are built
--- together here because both read the same GMCP-derived state and the split is purely
--- about which read affects which console.
---
--- Afflictions are ordered by *curing urgency* rather than by onset time, and annotated
--- with the vector that will cure them -- during a fight the useful question is never
--- "what do I have", it is "what is the system about to do about it, and on which
--- balance". A list that answers only the first question looks informative and tells you
--- nothing you can act on.
---
--- Colour carries the source of each affliction: server-confirmed afflictions are shown
--- solid, trigger-detected ones dimmer. That distinction matters because they have
--- genuinely different reliability, and hiding it would make a desync impossible to spot.

local M = {}

local util  = emunah.util
local theme = emunah.ui.theme
local layout = emunah.ui.layout

M.widgets = {}

--- Height of the afflictions console, as a fraction of the left column -- about half its
--- former height (it used to own the top 57% of the whole column; text this dense does
--- not need more than this). ui/roompanel.lua reads this same constant to size the room
--- console that now sits above it, so the two cannot drift apart.
M.AFFLICTIONS_HEIGHT = "28%"

local function available()
   return layout.container("left") ~= nil and layout.container("right") ~= nil
      and type(Geyser) == "table"
end

--- Afflictions own the bottom of the left column, below the room/items console (see
--- ui/roompanel.lua, which reads this same height so the two cannot drift apart).
--- Defences own the bottom of the right column, below chat (see ui/chat.lua, which reads
--- layout.CHAT_SPLIT the same way).
function M.build()
   if not available() then return false end

   M.widgets = {}

   -- No setStyleSheet on these: Geyser.MiniConsole does not have it. Background comes
   -- from the `color` field via theme.consoleCons(); the border is the container's.
   local afflictionsTop = string.format("%d%%", 100 - layout.percentOf(M.AFFLICTIONS_HEIGHT))
   M.widgets.afflictions = Geyser.MiniConsole:new(theme.consoleCons({
      name = "emunah.afflictions",
      x = 4, y = afflictionsTop, width = "-8px", height = "-4px",
      wrapAt = 34,
   }), layout.container("left"))

   -- Wider than afflictions' wrapAt: defences render in three columns (see M.update()),
   -- and the right column is itself wider than the left (WIDTH_RIGHT > WIDTH_LEFT), so a
   -- narrower wrap would clip or misalign the grid.
   local defencesTop = string.format("%d%%", layout.percentOf(layout.CHAT_SPLIT) + 1)
   M.widgets.defences = Geyser.MiniConsole:new(theme.consoleCons({
      name = "emunah.defences",
      x = 4, y = defencesTop, width = "-8px", height = "-4px",
      wrapAt = 60,
   }), layout.container("right"))

   -- The consoles are brand new and empty; whatever theme.paint() last recorded describes
   -- the widgets that were just replaced, so it has to go or the first paint is skipped and
   -- the panels come up blank.
   theme.forgetPainted("affpanel.afflictions")
   theme.forgetPainted("affpanel.defences")

   M.update()
   return true
end

--- Most urgent cure vector for an affliction, and its rank.
local function urgency(name)
   local afflist = emunah.curing.afflist
   local bestVector, bestRank
   for _, vector in ipairs(afflist.vectorsFor(name)) do
      local rank = afflist.priority(name, vector)
      if rank and (not bestRank or rank < bestRank) then
         bestVector, bestRank = vector, rank
      end
   end
   return bestVector, bestRank
end

-- Both halves below build their whole body into a table and hand it to theme.paint() in one
-- piece. This used to be a decho per affliction row and a decho per defence CELL -- with a
-- full defence list that is thirty-odd separate Qt rich-text parses for one repaint, and the
-- panel repaints on six different events, several times a second in a fight.
--
-- `out` is reused across calls rather than allocated per repaint, for the same reason: this
-- is one of the most frequently re-entered functions in the UI.
local out = {}

function M.update()
   if not M.widgets.afflictions then return end

   local engine  = emunah.curing.engine
   local deflist = emunah.curing.deflist

   -- Afflictions that are actually a defence held on purpose (blindness/deafness under
   -- keep-up) are not something to cure -- engine.curableCount() and resolve() already
   -- skip them for that reason. The panel is meant to show what needs fixing, so it has
   -- to apply the same filter or it shows a defence working as usual as if it were a
   -- problem.
   local tracked = {}
   for _, record in ipairs(engine and engine.list() or {}) do
      if not deflist.deliberate(record.name) then
         tracked[#tracked + 1] = record
      end
   end

   local n = 0
   n = n + 1
   out[n] = string.format("%safflictions %s(%d)\n",
      theme.dc("textDim"), theme.dc("border"), math.floor(#tracked))

   if #tracked == 0 then
      n = n + 1
      out[n] = theme.dc("defence") .. "  clear\n"
   else
      -- Sort by urgency, unrankable afflictions last.
      local rows = {}
      for _, record in ipairs(tracked) do
         local vector, rank = urgency(record.name)
         rows[#rows + 1] = {
            name = record.name, vector = vector, rank = rank or 9999,
            source = record.source, age = emunah.util.now() - record.since,
         }
      end
      table.sort(rows, function(a, b)
         if a.rank ~= b.rank then return a.rank < b.rank end
         return a.name < b.name
      end)

      for _, row in ipairs(rows) do
         -- Trigger-sourced afflictions are dimmer: they are less certain than the
         -- server's own list and the display should not pretend otherwise.
         local nameColour = row.source == "gmcp"
            and theme.dc("affliction")
            or theme.dc("warning")

         local vectorText = row.vector
            and string.format("%s%s", theme.dc("textDim"), row.vector)
            or string.format("%sno cure", theme.dc("border"))

         n = n + 1
         out[n] = string.format("%s  %-18s %s %s%.0fs\n",
            nameColour, row.name, vectorText, theme.dc("border"), row.age)
      end
   end

   theme.paint(M.widgets.afflictions, "affpanel.afflictions", table.concat(out, "", 1, n))

   -- Defences.
   local defences = emunah.gmcp.defences
   local keepup   = emunah.curing.defkeepup
   local console2 = M.widgets.defences
   if not console2 or not defences then return end

   local active  = defences.list()
   local missing = keepup and keepup.missing() or {}

   -- A defence listed MISSING while keep-up is switched off is not a fault being reported,
   -- it is a job nobody is doing -- and the panel said the same thing for both. Reported
   -- from play: `emunah defs add inspiration`, then it sat red in this panel indefinitely.
   local keepingUp = keepup and keepup.enabled
   n = 1
   out[1] = string.format("%sdefences %s(%d up)%s\n",
      theme.dc("textDim"), theme.dc("border"), #active,
      (not keepingUp and #missing > 0) and (theme.dc("warning") .. "  keep-up off") or "")

   -- One combined, colour-coded grid instead of two separate lists with status text: the
   -- colour already says "required but not up" vs "up", and dropping the "MISSING"/"not
   -- raised" text is what buys the room for three columns -- with the full defence list a
   -- single column ran taller than the space above the map and the bottom of it was
   -- unreadable.
   local rows = {}
   for _, name in ipairs(missing) do
      rows[#rows + 1] = { name = name, colour = theme.dc("warning") }
   end
   for _, record in ipairs(active) do
      rows[#rows + 1] = { name = record.name, colour = theme.dc("defence") }
   end

   local COLUMNS, COL_WIDTH = 3, 15
   for index, row in ipairs(rows) do
      local prefix = (index % COLUMNS == 1) and "  " or ""
      n = n + 1
      out[n] = string.format("%s%s%-" .. COL_WIDTH .. "s", prefix, row.colour, row.name)
      if index % COLUMNS == 0 then
         n = n + 1
         out[n] = "\n"
      end
   end
   if #rows % COLUMNS ~= 0 then
      n = n + 1
      out[n] = "\n"
   end

   theme.paint(console2, "affpanel.defences", table.concat(out, "", 1, n))
end

emunah.event.registerAll({
   "emunah.affliction.tracked",
   "emunah.affliction.cured",
   "emunah.afflictions.list",
   "emunah.defences.list",
   "emunah.defence.added",
   "emunah.defence.lost",
}, function() M.update() end, "ui.affpanel")

emunah.event.register("emunah.ui.built", function() M.build() end, "ui.affpanel")

M.build()

return M

--- Afflictions and defences panel.
---
--- Two lists in the right-hand container. Afflictions are ordered by *curing urgency*
--- rather than by onset time, and annotated with the vector that will cure them -- during
--- a fight the useful question is never "what do I have", it is "what is the system about
--- to do about it, and on which balance". A list that answers only the first question
--- looks informative and tells you nothing you can act on.
---
--- Colour carries the source of each affliction: server-confirmed afflictions are shown
--- solid, trigger-detected ones dimmer. That distinction matters because they have
--- genuinely different reliability, and hiding it would make a desync impossible to spot.

local M = {}

local util  = emunah.util
local theme = emunah.ui.theme
local layout = emunah.ui.layout

M.widgets = {}

local function available()
   return layout.container("left") ~= nil and type(Geyser) == "table"
end

--- Afflictions and defences own the whole left column: afflictions on top (they change
--- fastest and matter most), defences below.
function M.build()
   if not available() then return false end
   local parent = layout.container("left")

   M.widgets = {}

   -- No setStyleSheet on these: Geyser.MiniConsole does not have it. Background comes
   -- from the `color` field via theme.consoleCons(); the border is the container's.
   M.widgets.afflictions = Geyser.MiniConsole:new(theme.consoleCons({
      name = "emunah.afflictions",
      x = 4, y = 4, width = "-8px", height = "57%",
      wrapAt = 34,
   }), parent)

   M.widgets.defences = Geyser.MiniConsole:new(theme.consoleCons({
      name = "emunah.defences",
      x = 4, y = "59%", width = "-8px", height = "-4px",
      wrapAt = 34,
   }), parent)

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

function M.update()
   if not M.widgets.afflictions then return end

   local engine = emunah.curing.engine
   local console = M.widgets.afflictions
   console:clear()

   local tracked = engine and engine.list() or {}

   console:decho(string.format("%safflictions %s(%d)\n",
      theme.dc("textDim"), theme.dc("border"), math.floor(#tracked)))

   if #tracked == 0 then
      console:decho(theme.dc("defence") .. "  clear\n")
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

         console:decho(string.format("%s  %-18s %s %s%.0fs\n",
            nameColour, row.name, vectorText, theme.dc("border"), row.age))
      end
   end

   -- Defences.
   local defences = emunah.gmcp.defences
   local keepup   = emunah.curing.defkeepup
   local console2 = M.widgets.defences
   if not console2 or not defences then return end
   console2:clear()

   local active  = defences.list()
   local missing = keepup and keepup.missing() or {}

   console2:decho(string.format("%sdefences %s(%d up)\n",
      theme.dc("textDim"), theme.dc("border"), #active))

   for _, name in ipairs(missing) do
      console2:decho(string.format("%s  %-20s %sMISSING\n",
         theme.dc("warning"), name, theme.dc("affliction")))
   end

   for _, record in ipairs(active) do
      console2:decho(string.format("%s  %s\n", theme.dc("defence"), record.name))
   end
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

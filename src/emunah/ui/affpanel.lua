--- Afflictions and defences: the middle and bottom sections of the left-hand column.
---
--- AFFLICTIONS answers the question that matters in a fight. It isn't "what do I have", it's
--- "what is the system doing about it". Each row is one affliction, in curing order, with:
---
---   source   a filled dot when the server reports it, hollow when only a trigger has (on
---            probation: engine.TEXT_CONFIRM). They differ in reliability, and hiding that
---            would make a desync impossible to spot.
---   cure     what will cure it: the herb, salve or command the engine would send.
---   status   curing   sent, waiting for the game to answer
---            next     everything is ready: it goes out on this prompt
---            1.4s     its balance is recovering, and this is how long
---            locked   its only way is shut by another affliction, named
---            the reason the engine refused it (engine.refusals) -- "in the rift", "no
---            tattoo" -- since a refusal you cannot see looks exactly like a hang
---
--- No age column: in a column this narrow it cost the status its room, and the status is the
--- part that says whether anything is wrong.
---
--- Above the rows: the incapacitating states (prone, stunned, asleep, unconscious), as
--- pills, because each one holds every command. Below them: every curing vector currently
--- shut and by what -- a lock, read off in one line.
---
--- DEFENCES lists the defences `emset defs` has switched on, and only those, filed under what
--- raises them -- Elixirs, Herbs, Salves, then each skillset by the server's name for it
--- (deflist.raisedBy()) -- alphabetically, three to a row. Green up, yellow down on defup, red
--- down on keepup.
---
--- Both are Labels drawing rich text (see ui/theme.lua for why), each painted in one call and
--- not at all when unchanged, after the packet (theme.later).

local M = {}

local util   = emunah.util
local theme  = emunah.ui.theme
local layout = emunah.ui.layout

M.widgets = {}

--- Curing vectors that can be shut by an affliction, in the order the lock line reads them.
local LOCKABLE = { "herb", "salve", "smoke", "focus", "elixir", "purgative", "moss", "tree" }

--- What each vector is called on screen. `elixir` is the health/mana sip.
local VECTOR_NAME = {
   herb = "herb", salve = "salve", smoke = "smoke", focus = "focus", elixir = "sip",
   purgative = "purgative", moss = "moss", tree = "tree", special = "free", writhe = "writhe",
}

local function available()
   return layout.container("left") ~= nil and type(Geyser) == "table"
end

function M.build()
   if not available() then return false end
   M.widgets = {}

   for _, key in ipairs({ "afflictions", "defences" }) do
      local spec = layout.leftSection(key)
      local section = layout.section(layout.container("left"), {
         key = key, title = spec.title, y = spec.y, height = spec.height, body = "label",
         refresh = function() M.update() end,
      })
      if section then
         M.widgets[key] = section.body
         M.widgets[key .. "Header"] = section.header
      end
   end

   M.update()
   return true
end

--- Most urgent cure vector for an affliction, and its rank -- the engine's own, situational
--- rules included (curing/situations.lua), so the rows read in the order cures go out.
local function urgency(name)
   local afflist = emunah.curing.afflist
   local situations = emunah.curing.situations
   if situations and situations.held(name) then return nil, nil end
   local bestVector, bestRank
   for _, vector in ipairs(afflist.vectorsFor(name)) do
      local rank = afflist.priority(name, vector)
      if rank and situations then rank = situations.rank(name, vector) or rank end
      if rank and (not bestRank or rank < bestRank) then
         bestVector, bestRank = vector, rank
      end
   end
   return bestVector, bestRank
end

--- What will cure it, as a word or two: the item for an item cure, else the command.
local function cureText(name, vector)
   local afflist  = emunah.curing.afflist
   local curelist = emunah.curing.curelist
   if afflist.isWrithe(name) then return "writhe" end
   if not vector then return nil end
   local option = afflist.curesVia(name, vector)[1]
   if not option then return VECTOR_NAME[vector] or vector end
   local command, item = curelist.command(option)
   return item or command or VECTOR_NAME[vector] or vector
end

--- Status cell for one affliction, and whether it is counting down.
--- @param place number|nil this row's place among the rows waiting on the same vector: the
---   balance is one, so only the first shows the countdown, and the rest their place in line
local function status(name, vector, place)
   local engine = emunah.curing.engine
   local queue  = emunah.queue
   local have   = emunah.have
   local afflist = emunah.curing.afflist

   if afflist.isWrithe(name) then
      if queue.awaiting("writhe") then return theme.span("accent", "writhing"), false end
      local left = emunah.timers.remaining("writhe.busy")
      if left > 0 then return theme.span("textDim", string.format("%.1fs", left)), true end
      return theme.span("defence", "next"), false
   end

   local situations = emunah.curing.situations
   local heldBy = situations and situations.held(name)
   if heldBy then return theme.span("textDim", "held: " .. theme.esc(heldBy)), false end

   if not vector then return theme.span("textDim", "no cure"), false end

   local flight = queue.awaiting(vector)
   if flight and flight.tag == name then return theme.span("accent", "curing"), false end

   local blocker = queue.heldBy(vector)
   if blocker then return theme.span("affliction", "&#10005; " .. theme.esc(blocker)), false end

   local refusal = engine and engine.refusals and engine.refusals[name]
   if refusal then return theme.span("warning", theme.esc(refusal)), false end

   -- When the balance is EXPECTED back (have.expectedIn), not when the fallback net would
   -- give up waiting for it. Once per vector: every herb row showing the same "herb 2.4s"
   -- read as ten timers when there is one balance.
   local left = have.expectedIn(vector)
   if left then
      local label = VECTOR_NAME[vector] or vector
      if place and place > 1 then
         return theme.span("textDim", string.format("%s #%d", label, place)), false
      end
      if left > 0 then
         return theme.span("textDim", string.format("%s %.1fs", label, left)), true
      end
      return theme.span("textDim", label .. " due"), true
   end
   if flight then return theme.span("textDim", VECTOR_NAME[vector] .. " busy"), false end

   if not engine.enabled then return theme.span("textDim", "curing off"), false end
   return theme.span("defence", "next"), false
end

--- The incapacitating states, as pills. Each one holds every command (core/act.lua).
local function statePills()
   local detect = emunah.curing.detect
   if not detect then return nil end
   local pills = {}
   if detect.stunned then pills[#pills + 1] = theme.pill("affliction", "STUNNED") end
   if detect.unconscious then pills[#pills + 1] = theme.pill("affliction", "UNCONSCIOUS") end
   if detect.asleep then
      pills[#pills + 1] = theme.pill(detect.voluntary and "textDim" or "affliction", "ASLEEP")
   end
   if detect.prone then pills[#pills + 1] = theme.pill("warning", "PRONE") end
   if detect.armsBalanced and not detect.armsBalanced() then
      pills[#pills + 1] = theme.pill("warning", "ARM OFF BAL")
   end
   if #pills == 0 then return nil end
   return table.concat(pills, "&nbsp;")
end

--- Every lockable vector currently shut, grouped by what shuts it: "anorexia: herb sip
--- purgative moss" reads as the one problem it is, where a list per vector repeats it.
local function lockLine()
   local order, byBlocker = {}, {}
   for _, vector in ipairs(LOCKABLE) do
      local blocker = emunah.queue.heldBy(vector)
      if blocker then
         local list = byBlocker[blocker]
         if not list then
            list = {}
            byBlocker[blocker] = list
            order[#order + 1] = blocker
         end
         list[#list + 1] = VECTOR_NAME[vector]
      end
   end
   if #order == 0 then return nil, 0 end
   local lines = {}
   for index, blocker in ipairs(order) do
      lines[index] = theme.span("affliction", "&#10005; " .. theme.esc(blocker), true)
         .. theme.span("textDim", "&nbsp; shuts " .. table.concat(byBlocker[blocker], ", "))
   end
   return table.concat(lines, "<br>"), #order
end

local rows, html = {}, {}
--- vector -> rows painted so far that wait on it. Reused across repaints.
local placed = {}

--- Repaint the afflictions section. Returns whether anything on it is counting.
local function updateAfflictions()
   local body = M.widgets.afflictions
   if not body then return false end

   local engine  = emunah.curing.engine
   local deflist = emunah.curing.deflist
   local live = false

   -- Defences held on purpose (blind/deaf under keep-up) are not something to cure; the
   -- engine skips them, and the panel agrees rather than flagging a working defence.
   local count = 0
   for _, record in ipairs(engine and engine.list() or {}) do
      if not deflist.deliberate(record.name) then
         local vector, rank = urgency(record.name)
         count = count + 1
         local row = rows[count] or {}
         rows[count] = row
         row.name, row.vector, row.rank = record.name, vector, rank or 9999
         row.source = record.source
      end
   end
   for index = count + 1, #rows do rows[index] = nil end
   table.sort(rows, function(a, b)
      if a.rank ~= b.rank then return a.rank < b.rank end
      return a.name < b.name
   end)

   local n = 0
   local pills = statePills()
   if pills then
      n = n + 1
      html[n] = '<p style="margin:0 0 4px 0">' .. pills .. "</p>"
   end

   -- Nothing to list: the title bar already reads "clear", and the body saying it again
   -- under it was reported as a duplicate (2026-10-04). The body stays empty.
   if count > 0 then
      n = n + 1
      html[n] = '<table width="100%" cellspacing="0" cellpadding="1">'
      for vector in pairs(placed) do placed[vector] = nil end
      for index = 1, count do
         local row = rows[index]
         -- Only a report from the imported trigger package is on probation.
         local confirmed = row.source ~= "text"
         local dot = confirmed and "&#9679;" or "&#9675;"
         local cure = cureText(row.name, row.vector)
         local place
         if row.vector then
            placed[row.vector] = (placed[row.vector] or 0) + 1
            place = placed[row.vector]
         end
         local state, counting = status(row.name, row.vector, place)
         live = live or counting
         n = n + 1
         html[n] = string.format(
            '<tr><td width="10">%s</td><td>%s</td><td>%s</td><td align="right">%s</td></tr>',
            theme.span(confirmed and "affliction" or "warning", dot),
            theme.span(confirmed and "textBright" or "warning", theme.esc(row.name)),
            cure and theme.span("textDim", theme.esc(cure)) or "",
            state)
      end
      n = n + 1
      html[n] = "</table>"
   end

   local locks, lockLines = lockLine()
   if locks then
      n = n + 1
      html[n] = '<p style="margin:4px 0 0 0">' .. locks .. "</p>"
   end

   -- Every row, the pills and the lock lines: the column is sized to show all of them.
   layout.need("afflictions", { (pills and 1 or 0) + math.max(count, 1) + lockLines })

   layout.header("afflictions", M.widgets.afflictionsHeader, "Afflictions",
      count > 0 and tostring(count) or "clear", count > 0 and "affliction" or "defence")
   theme.paintLabel(body, "body.afflictions", table.concat(html, "", 1, n))
   return live
end

--- Where a category's heading sorts: the items first, in the order you would reach for them,
--- then the skillsets alphabetically, then what nothing could place.
local CATEGORY_RANK = { Elixirs = 1, Herbs = 2, Minerals = 3, Salves = 4, Pipes = 5,
                        Abilities = 98, Other = 99 }

local function categoryBefore(a, b)
   local ra, rb = CATEGORY_RANK[a] or 50, CATEGORY_RANK[b] or 50
   if ra ~= rb then return ra < rb end
   return a < b
end

--- One defence's cell: its dot and name.
---
---   green   up, by Char.Defences or its own lines (deflist.isUp)
---   yellow  down, and on defup: raised once a session, so down is not a fault
---   red     down, and on keepup: something that should be standing is not. Bright red on a
---           red wash, the one thing on the panel meant to catch the eye.
---
--- The same glyph and no bold in every state, so a change of state never changes a cell's
--- width and wraps its row (the user, 2026-10-18: "they jump around a lot").
local function defenceCell(entry)
   if entry.up then
      return theme.span("defence", "&#9679; ") .. theme.span("text", theme.esc(entry.name))
   end
   if entry.mode == "keepup" then
      local colour = theme.hex("alarm")
      return string.format('<span style="background-color:%s; color:%s">&#9675; %s</span>',
         theme.shade(colour, 0.28), colour, theme.esc(entry.name))
   end
   return theme.span("warning", "&#9675; " .. theme.esc(entry.name))
end

--- name -> its heading, the first time it is filed. deflist.raisedBy() follows what is in
--- hand -- a herb defence moves to Minerals when only the mineral is left -- and a row
--- changing heading moved every row below it. Forgotten when the answer can genuinely
--- change: the skill index arriving (Abilities -> the skillset), `emset defs` (a custom
--- command), a disconnect.
local headings = {}
local function heading(name)
   local category = headings[name]
   if not category then
      category = emunah.curing.deflist.raisedBy(name)
      headings[name] = category
   end
   return category
end
emunah.event.registerAll({ "emunah.skills.list", "emunah.defkeepup.changed", "sysDisconnectionEvent" },
   function() headings = {} end, "ui.affpanel")

--- The defences `emset defs` has switched on, and nothing else, filed by category
--- (deflist.raisedBy()), alphabetically within each.
---
--- ONLY WHAT IS SWITCHED ON (the user, 2026-10-18). Listing whatever Char.Defences reported
--- meant a row for every passing defence, and the rows came and went with them. The set now
--- changes only when `emset defs` does; a defence going up or down recolours its cell and
--- moves nothing.
--- @return table categories in display order, table category -> entries, number up
local function groupDefences(modes)
   local deflist = emunah.curing.deflist
   local byCategory, order = {}, {}
   local upCount = 0
   for name, mode in pairs(modes) do
      local category = heading(name)
      local list = byCategory[category]
      if not list then
         list = {}
         byCategory[category] = list
         order[#order + 1] = category
      end
      local up = deflist.isUp(name)
      if up then upCount = upCount + 1 end
      list[#list + 1] = { name = name, up = up, mode = mode }
   end
   table.sort(order, categoryBefore)
   for _, category in ipairs(order) do
      table.sort(byCategory[category], function(a, b) return a.name < b.name end)
   end
   return order, byCategory, upCount
end

--- Repaint the defences section.
local function updateDefences()
   local body = M.widgets.defences
   local keepup = emunah.curing.defkeepup
   if not body or not keepup then return end

   local modes = keepup.modes()
   local order, byCategory, upCount = groupDefences(modes)
   local total, down = 0, 0
   for _, category in ipairs(order) do
      for _, entry in ipairs(byCategory[category]) do
         total = total + 1
         if not entry.up and entry.mode == "keepup" then down = down + 1 end
      end
   end

   -- A defence missing while keep-up is OFF is not a fault, it is a job nobody is doing.
   -- Reported from play: `emunah defs add inspiration`, then it sat red indefinitely.
   local summary = string.format("%d/%d up", upCount, total)
   local summaryColour = "defence"
   if down > 0 then
      summary = summary .. string.format(" \194\183 %d down", down)
      summaryColour = "alarm"
      if not keepup.enabled then summary = summary .. " \194\183 keep-up off" end
   end
   layout.header("defences", M.widgets.defencesHeader, "Defences", summary, summaryColour)

   -- THREE A ROW, ALWAYS (the user, 2026-10-18: "it's taking up too much room"). It used to
   -- offer layout.reflow() one, two or three a row and took one whenever the column had
   -- room, which made it the tallest section on the left. One density now, so the section
   -- is sized to exactly its rows and its height moves only when `emset defs` does. Each
   -- category's heading is a line of its own.
   local columns = 3
   local lines = 0
   for _, category in ipairs(order) do
      lines = lines + 1 + math.ceil(#byCategory[category] / columns)
   end
   layout.need("defences", { math.max(1, lines) })

   local n = 0
   if #order == 0 then
      n = 1
      html[1] = theme.span("textDim", "none -- `emset defs add` to list one")
   else
      n = 1
      html[1] = '<table width="100%" cellspacing="0" cellpadding="0">'
      local width = math.floor(100 / columns)
      for _, category in ipairs(order) do
         local entries = byCategory[category]
         n = n + 1
         html[n] = string.format('<tr><td colspan="%d">%s</td></tr>', columns,
            theme.span("accent", theme.esc(category)))
         for index = 1, #entries, columns do
            local row = {}
            for offset = 0, columns - 1 do
               local entry = entries[index + offset]
               row[#row + 1] = string.format('<td width="%d%%">%s</td>', width,
                  entry and defenceCell(entry) or "")
            end
            n = n + 1
            html[n] = "<tr>" .. table.concat(row) .. "</tr>"
         end
      end
      n = n + 1
      html[n] = "</table>"
   end
   theme.paintLabel(body, "body.defences", table.concat(html, "", 1, n))
end

function M.update()
   local live = updateAfflictions()
   updateDefences()
   if live then theme.wakeClock() end
end

theme.ticking("affpanel", function() return updateAfflictions() end)

emunah.event.registerAll({
   "emunah.affliction.tracked",
   "emunah.affliction.cured",
   "emunah.afflictions.list",
   "emunah.defences.list",
   "emunah.defence.added",
   "emunah.defence.lost",
   "emunah.recovered",
   "emunah.curing.enabled",
   "emunah.curing.disabled",
   "emunah.defkeepup.enabled",
   "emunah.defkeepup.disabled",
   "emunah.defkeepup.changed",
   -- The skill index names an ability's skillset, which is a defence's heading.
   "emunah.skills.list",
}, function() theme.later("affpanel", M.update) end, "ui.affpanel")   -- after the packet: theme.later()

-- A cure sent, answered or refused changes a row's status with no affliction event at all.
emunah.event.registerAll({ "emunah.timer.started", "emunah.timer.expired" }, function()
   theme.later("affpanel", M.update)
end, "ui.affpanel")

emunah.event.register("emunah.ui.built", function() M.build() end, "ui.affpanel")

M.build()

return M

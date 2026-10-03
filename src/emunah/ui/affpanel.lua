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
--- DEFENCES lists what keep-up is owed first, then what is up.
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
      })
      if section then
         M.widgets[key] = section.body
         M.widgets[key .. "Header"] = section.header
      end
   end

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
local function status(name, vector)
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

   if not vector then return theme.span("textDim", "no cure"), false end

   local flight = queue.awaiting(vector)
   if flight and flight.tag == name then return theme.span("accent", "curing"), false end

   local blocker = queue.heldBy(vector)
   if blocker then return theme.span("affliction", "&#10005; " .. theme.esc(blocker)), false end

   local refusal = engine and engine.refusals and engine.refusals[name]
   if refusal then return theme.span("warning", theme.esc(refusal)), false end

   local left = emunah.timers.remaining("cure." .. vector)
   if left > 0 then return theme.span("textDim", string.format("%s %.1fs", VECTOR_NAME[vector] or vector, left)), true end
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
   if #order == 0 then return nil end
   local lines = {}
   for index, blocker in ipairs(order) do
      lines[index] = theme.span("affliction", "&#10005; " .. theme.esc(blocker), true)
         .. theme.span("textDim", "&nbsp; shuts " .. table.concat(byBlocker[blocker], ", "))
   end
   return table.concat(lines, "<br>")
end

local rows, html = {}, {}

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

   if count == 0 then
      n = n + 1
      html[n] = theme.span("defence", "&#10004; clear")
   else
      n = n + 1
      html[n] = '<table width="100%" cellspacing="0" cellpadding="1">'
      for index = 1, count do
         local row = rows[index]
         -- Only a report from the imported trigger package is on probation.
         local confirmed = row.source ~= "text"
         local dot = confirmed and "&#9679;" or "&#9675;"
         local cure = cureText(row.name, row.vector)
         local state, counting = status(row.name, row.vector)
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

   local locks = lockLine()
   if locks then
      n = n + 1
      html[n] = '<p style="margin:4px 0 0 0">' .. locks .. "</p>"
   end

   layout.header("afflictions", M.widgets.afflictionsHeader, "Afflictions",
      count > 0 and tostring(count) or "clear", count > 0 and "affliction" or "defence")
   theme.paintLabel(body, "body.afflictions", table.concat(html, "", 1, n))
   return live
end

--- Repaint the defences section.
local function updateDefences()
   local body = M.widgets.defences
   local defences = emunah.gmcp.defences
   if not body or not defences then return end

   local keepup = emunah.curing.defkeepup
   local active  = defences.list()
   local missing = keepup and keepup.missing() or {}
   local keepingUp = keepup and keepup.enabled

   -- A defence missing while keep-up is OFF is not a fault, it is a job nobody is doing.
   -- Reported from play: `emunah defs add inspiration`, then it sat red indefinitely.
   local summary = string.format("%d up", #active)
   local summaryColour = "defence"
   if #missing > 0 then
      summary = summary .. string.format(" \194\183 %d down", #missing)
      summaryColour = "warning"
   end
   if not keepingUp and #missing > 0 then summary = summary .. " \194\183 keep-up off" end
   layout.header("defences", M.widgets.defencesHeader, "Defences", summary, summaryColour)

   -- Owed first, in the warning colour (dim when nobody is raising them), then what is up.
   local cells = {}
   for _, name in ipairs(missing) do
      cells[#cells + 1] = theme.span(keepingUp and "warning" or "textDim", "&#9675; " .. theme.esc(name))
   end
   for _, record in ipairs(active) do
      cells[#cells + 1] = theme.span("defence", "&#9679; ") .. theme.span("text", theme.esc(record.name))
   end

   local n = 0
   if #cells == 0 then
      n = 1
      html[1] = theme.span("textDim", "none")
   else
      n = 1
      html[1] = '<table width="100%" cellspacing="0" cellpadding="0">'
      local COLUMNS = 2
      for index = 1, #cells, COLUMNS do
         n = n + 1
         html[n] = string.format('<tr><td width="50%%">%s</td><td>%s</td></tr>',
            cells[index], cells[index + 1] or "")
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
}, function() theme.later("affpanel", M.update) end, "ui.affpanel")   -- after the packet: theme.later()

-- A cure sent, answered or refused changes a row's status with no affliction event at all.
emunah.event.registerAll({ "emunah.timer.started", "emunah.timer.expired" }, function()
   theme.later("affpanel", M.update)
end, "ui.affpanel")

emunah.event.register("emunah.ui.built", function() M.build() end, "ui.affpanel")

M.build()

return M

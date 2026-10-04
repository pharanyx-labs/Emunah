--- IR, parsed and redrawn as a table, with what is kept in hand beside each herb.
---
--- The game's listing (2026-10-04, 19:17:20.62):
---
---   Glancing into your rift, you see:
---   ------------------------------------------------------------------------------
---   Herbs
---   [  158] ash                    [  983] bayberry               [  185] bellwort
---   ...
---   [  341] myrrh gum              ...
---   Elixirs
---   [  800] frost                  [ 1600] health                 [  600] immunity
---   Salves / Inks / Reagent
---   ...
---   ------------------------------------------------------------------------------
---
--- What replaces it (the user, 2026-10-04: "improve the output of 'ir' ... and a toggle for
--- each so that i can add or remove it to the ones we keep x amount of in our hands"): one
--- row per herb with how many are in the rift, how many are in hand, and how many are kept
--- there, which a click changes; then the other sections as they were, in a box.
---
---   +------------------+-------+------+-------------------------------------------+
---   | Herb             |  Rift | Hand | Keep in hand                              |
---   +------------------+-------+------+-------------------------------------------+
---   | ash              |   158 |    2 | [x] 2  [-] [+]                            |
---   | cohosh           |   914 |    0 | [ ]                                       |
---   +------------------+-------+------+-------------------------------------------+
---   | ELIXIRS                                                                     |
---   | frost 800  health 1600  immunity 600 ...                                    |
---
--- The keep column is the restocker's own (curing/engine.lua: stockTarget, setStock), so
--- what it shows is what is pulled. A click redraws the table under the old one, as the
--- `emset defs` grid does.
---
--- HOW THE GAME'S LINES GO is elist.lua's way: ui/gag.lua hides each line and deletes it
--- once the packet is done, and the table is drawn after the closing rule. Only a listing
--- asked for with IR is touched.

local M = {}

local theme = emunah.ui.theme

--- How long after IR goes out its header is believed.
M.WINDOW = 10

M.WIDTH = 79

local NAME_W, RIFT_W, HAND_W = 16, 5, 4
local KEEP_W = M.WIDTH - (2 + NAME_W + 3 + RIFT_W + 3 + HAND_W + 3 + 2)
local INNER_W = M.WIDTH - 4

--- Sections whose items are eaten or smoked, and so can be kept in hand. "Herbs" is from the
--- listing above; "Minerals" is assumed to be what a minerals user sees, and has not been.
M.KEEPABLE = { herbs = true, minerals = true }

--- The listing being read, from its header to its closing rule or the next prompt.
local listing = nil

--- The last listing drawn, so a click can draw it again with the new setting.
M.last = nil

local function trim(text)
   return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

--- Every "[  158] ash" on one line of the listing, or nil if the line has none.
function M.parse(line)
   local items = {}
   for count, name in tostring(line or ""):gmatch("%[%s*(%d+)%]%s+([^%[]+)") do
      items[#items + 1] = { count = tonumber(count), name = trim(name) }
   end
   return #items > 0 and items or nil
end

--- The word the restocker and OUTR use: "myrrh gum" -> "myrrh".
function M.key(name)
   return (tostring(name):lower():match("^(%S+)")) or ""
end

-- ---------------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------------

local function dc(key) return theme.dc(key) end
local function edge(text) return dc("textDim") .. text end

local function fit(text, width)
   text = tostring(text)
   if #text > width then return text:sub(1, width) end
   return text .. string.rep(" ", width - #text)
end

local RULE4 = "+" .. string.rep("-", NAME_W + 2) .. "+" .. string.rep("-", RIFT_W + 2) .. "+"
   .. string.rep("-", HAND_W + 2) .. "+" .. string.rep("-", KEEP_W + 2) .. "+"
local RULE1 = "+" .. string.rep("-", M.WIDTH - 2) .. "+"

--- A line is a list of segments: plain markup, or { text, link, hint } for a click.
local function wide(colour, text)
   return { edge("| ") .. dc(colour) .. fit(text, INNER_W) .. edge(" |") }
end

local function click(text, colour, source, hint)
   return { text = dc(colour) .. text, link = source .. " emunah.riftlist.redraw()", hint = hint }
end

--- The keep cell for one herb: a box to keep it or not, the number, and - / + to change it.
local function keepCell(item)
   local engine = emunah.curing.engine
   local target = engine.stockTarget(item)
   local quoted = string.format("%q", item)
   local cell, used = {}, 0
   if target > 0 then
      cell[#cell + 1] = click("[x]", "defence", "emunah.curing.engine.setStock(" .. quoted .. ", 0)",
         "Stop keeping " .. item .. " in hand")
      local number = " " .. tostring(target) .. "  "
      cell[#cell + 1] = dc("textBright") .. number
      cell[#cell + 1] = click("[-]", "textDim",
         "emunah.curing.engine.setStock(" .. quoted .. ", " .. (target - 1) .. ")",
         target == 1 and ("Stop keeping " .. item .. " in hand") or ("Keep " .. (target - 1)))
      cell[#cell + 1] = " "
      cell[#cell + 1] = click("[+]", "textDim",
         "emunah.curing.engine.setStock(" .. quoted .. ", " .. (target + 1) .. ")",
         "Keep " .. (target + 1))
      used = 3 + #number + 3 + 1 + 3
   else
      -- Back to the default where there is one (every cure herb has), so a toggle off and on
      -- again lands where it started.
      local again = (engine.isCureItem(item) or engine.STOCK_DEFAULTS[item]) and "nil" or "1"
      cell[#cell + 1] = click("[ ]", "textDim",
         "emunah.curing.engine.setStock(" .. quoted .. ", " .. again .. ")",
         "Keep " .. item .. " in hand")
      used = 3
      if engine.isCureItem(item) then
         -- Taken off by hand: cures read "in the rift, not in hand" and wait for none.
         local note = "  cures need it in hand"
         cell[#cell + 1] = dc("warning") .. note
         used = used + #note
      end
   end
   cell[#cell + 1] = string.rep(" ", math.max(0, KEEP_W - used))
   return cell
end

local function herbRow(entry)
   local item = M.key(entry.name)
   local target = emunah.curing.engine.stockTarget(item)
   local held = emunah.have.quantity(item)
   local handColour = "textDim"
   if target > 0 then handColour = held >= target and "defence" or "warning" end
   local line = {
      edge("| ") .. dc(target > 0 and "text" or "textDim") .. fit(entry.name, NAME_W) .. edge(" | ")
         .. dc("text") .. string.format("%" .. RIFT_W .. "d", entry.count) .. edge(" | ")
         .. dc(handColour) .. string.format("%" .. HAND_W .. "d", held) .. edge(" | "),
   }
   for _, segment in ipairs(keepCell(item)) do line[#line + 1] = segment end
   line[#line + 1] = edge(" |")
   return line
end

--- Lay "name count" pieces across lines no wider than `width`.
local function wrapped(items)
   local lines, markup, used = {}, "", 0
   for _, entry in ipairs(items) do
      local width = #entry.name + 1 + #tostring(entry.count)
      local gap = used > 0 and 2 or 0
      if used > 0 and used + gap + width > INNER_W then
         lines[#lines + 1] = { edge("| ") .. markup .. string.rep(" ", INNER_W - used) .. edge(" |") }
         markup, used, gap = "", 0, 0
      end
      markup = markup .. string.rep(" ", gap) .. dc("textDim") .. entry.name .. " "
         .. dc("text") .. tostring(entry.count)
      used = used + gap + width
   end
   if used > 0 then
      lines[#lines + 1] = { edge("| ") .. markup .. string.rep(" ", INNER_W - used) .. edge(" |") }
   end
   return lines
end

--- The table, as lines of segments.
function M.render(sections)
   local out = {}
   local function add(line) out[#out + 1] = line end
   local headed = false
   for _, section in ipairs(sections) do
      if M.KEEPABLE[section.title:lower()] then
         -- The section above ended on this same rule.
         if not headed then add({ edge(RULE4) }) end
         add({ edge("| ") .. dc("text") .. fit(section.title:sub(1, -2), NAME_W) .. edge(" | ")
            .. dc("text") .. string.format("%" .. RIFT_W .. "s", "Rift") .. edge(" | ")
            .. dc("text") .. string.format("%" .. HAND_W .. "s", "Hand") .. edge(" | ")
            .. dc("text") .. fit("Keep in hand", KEEP_W) .. edge(" |") })
         add({ edge(RULE4) })
         for _, entry in ipairs(section.items) do add(herbRow(entry)) end
         add({ edge(RULE4) })
         headed = true
      end
   end
   local others = false
   for _, section in ipairs(sections) do
      if not M.KEEPABLE[section.title:lower()] and #section.items > 0 then
         if not others and not headed then add({ edge(RULE1) }) end
         others = true
         add(wide("accent", section.title:upper()))
         for _, line in ipairs(wrapped(section.items)) do add(line) end
         add({ edge(RULE1) })
      end
   end
   if #out == 0 then
      add({ edge(RULE1) })
      add(wide("textDim", "Your rift is empty."))
      add({ edge(RULE1) })
   end
   return out
end

--- Echo the table: decho for markup, dechoLink for a click.
function M.draw(sections)
   M.last = sections
   for _, line in ipairs(M.render(sections)) do
      decho("\n")
      for _, segment in ipairs(line) do
         if type(segment) == "table" then
            dechoLink(segment.text, segment.link, segment.hint, true)
         else
            decho(segment)
         end
      end
   end
   decho("\n")
end

--- After a click: the table again, under the old one, with the new setting.
function M.redraw()
   if M.last then M.draw(M.last) end
end

-- ---------------------------------------------------------------------------
-- reading the game's listing
-- ---------------------------------------------------------------------------

--- Did we just ask for one? Bare IR or INFO RIFT; `IR <item>` answers differently.
local function asked()
   local outgoing = emunah.outgoing
   return outgoing ~= nil and (outgoing.sentRecently("^ir$", M.WINDOW)
      or outgoing.sentRecently("^info rift$", M.WINDOW))
end

local function hide() emunah.ui.gag.current() end

local function finish()
   local sections = listing.sections
   listing = nil
   if #sections > 0 then M.draw(sections) end
end

function M.onHeader()
   if not asked() then return end
   listing = { rules = 0, sections = {} }
   hide()
end

function M.onRule()
   if not listing then return end
   hide()
   listing.rules = listing.rules + 1
   if listing.rules >= 2 then finish() end
end

--- Every line while a listing is open: a section title or a row of items. A prompt before
--- the closing rule still draws what was read.
function M.onLine()
   if not listing then return end
   if type(isPrompt) == "function" and isPrompt() then
      finish()
      return
   end
   if listing.rules ~= 1 then return end
   local line = getCurrentLine()
   local items = M.parse(line)
   if items then
      local section = listing.sections[#listing.sections]
      if not section then
         section = { title = "Items", items = {} }
         listing.sections[1] = section
      end
      for _, entry in ipairs(items) do section.items[#section.items + 1] = entry end
      hide()
   elseif line:match("^%a[%a ]*$") then
      listing.sections[#listing.sections + 1] = { title = trim(line), items = {} }
      hide()
   end
end

-- ---------------------------------------------------------------------------
-- triggers
-- ---------------------------------------------------------------------------

do
   emunah._persist = emunah._persist or {}
   for _, id in ipairs(emunah._persist.riftlistTriggers or {}) do killTrigger(id) end
   emunah._persist.riftlistTriggers = {}
   local function keep(id)
      if id then table.insert(emunah._persist.riftlistTriggers, id) end
   end

   keep(tempRegexTrigger([[^Glancing into your rift, you see:$]], function() M.onHeader() end))
   -- No `{n,}`: the test mock translates PCRE to Lua patterns, which lack it (pipes.lua).
   keep(tempRegexTrigger([[^[-][-][-][-][-][-][-][-][-][-]+\s*$]], function() M.onRule() end))
   keep(tempRegexTrigger([[^]], function() M.onLine() end))
end

return M

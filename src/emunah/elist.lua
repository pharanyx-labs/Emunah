--- ELIST, restyled where it stands, with a total per fluid underneath.
---
--- The game's listing (2026-10-04, 09:14:10.52):
---
---   Vial                          Fluid                          Sips     Months
---   -------------------------------------------------------------------------------
---   Pinewood vial41028            an elixir of health            149      88
---   Vial477753                    an elixir of mana              42       88
---   Vial676646                    empty                          0        88
---   -------------------------------------------------------------------------------
---
--- Each row is coloured by what it holds (health red, mana blue, the other elixirs
--- violet, salves amber, an empty vial greyed out), its sips by how many are left, and
--- the header and rules recede. Under the closing rule, one line per kind totals the
--- sips of every vial holding each fluid -- what you actually want to know before a fight.
---
--- COLOUR ONLY, NEVER deleteLine() OR replace(). ELIST arrives as one packet, and deleting
--- inside it is the bug that brought this module about: ih.lua relinked the bare-vial rows
--- by deleting them, which fused one onto the row above and shifted it a column. A gag
--- that deletes after the packet (pipes.lua) is safe, but it draws the rows blank for a
--- moment before they collapse -- the flash reported for pipes. Colouring changes nothing
--- Mudlet is still parsing, and the summary is an echo after the last rule, as shop.lua
--- prints its buy lines.

local M = {}

local theme = emunah.ui.theme

--- Sips at or under this are drawn as running low. Vials hold 200 when full (every full
--- one in the listing above), so this is a quarter.
M.LOW = 50

--- How long after an ELIST goes out its header is believed. Only the colouring depends
--- on it, but a listing nobody asked for is not ours to restyle.
M.WINDOW = 10

--- How wide the summary may run before it wraps, matching the listing's rule.
M.WIDTH = 79

--- The listing being drawn, from its header to its closing rule or the next prompt.
local listing = nil

local function trim(text)
   return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

--- What a fluid is, for colour and grouping: palette key, group, and a short name.
---   "an elixir of health"    -> health,      elixirs, "health"
---   "a salve of restoration" -> endurance,   salves,  "restoration"
---   "a caloric salve"        -> endurance,   salves,  "caloric"
---   "empty"                  -> inactive,    nil,     "empty"
function M.kind(fluid)
   fluid = trim(fluid):lower()
   if fluid == "empty" or fluid == "" then return "inactive", nil, "empty" end
   local short = fluid:gsub("^an?%s+", "")
   if short:find("^elixir of ") then
      short = short:gsub("^elixir of ", "")
      if short == "health" then return "health", "elixirs", short end
      if short == "mana" then return "mana", "elixirs", short end
      return "equilibrium", "elixirs", short
   end
   if short:find("salve") then
      short = short:gsub("^salve of ", ""):gsub("%s+salve$", "")
      return "endurance", "salves", short
   end
   return "text", "other", short
end

--- One row, or nil if the line is not one. The vial ends at its number, and the last two
--- columns are numbers, so a long name squeezing the gaps to one space still parses.
function M.parse(line)
   local vial, fluid, sips, months =
      tostring(line or ""):match("^(%S.-%d+)%s+(.-)%s+(%d+)%s+(%d+)%s*$")
   if not vial or fluid == "" then return nil end
   return { vial = vial, fluid = fluid, sips = tonumber(sips), months = tonumber(months) }
end

--- Colour a run of the current line, by 1-based position. A run not found is skipped.
local function paint(from, length, key, bold)
   if not from or length <= 0 then return end
   if selectSection(from - 1, length) == false then return end
   setFgColor(theme.rgb(key))
   setBold(bold == true)
end

local function sipsColour(sips)
   if sips <= 0 then return "affliction" end
   if sips <= M.LOW then return "warning" end
   return "textBright"
end

local function styleRow(line, row)
   local key = M.kind(row.fluid)
   local empty = key == "inactive"
   paint(1, #row.vial, empty and "inactive" or "textDim")
   local at = line:find(row.fluid, #row.vial + 1, true)
   paint(at, #row.fluid, key, not empty)
   local sipsText, monthsText = tostring(row.sips), tostring(row.months)
   local sipsAt = at and line:find(sipsText, at + #row.fluid, true)
   paint(sipsAt, #sipsText, empty and "inactive" or sipsColour(row.sips), row.sips <= M.LOW)
   local monthsAt = sipsAt and line:find(monthsText, sipsAt + #sipsText, true)
   paint(monthsAt, #monthsText, "inactive")
   deselect()
end

--- The summary lines, in decho markup: one per group, wrapped at M.WIDTH.
function M.summary(rows)
   local groups, order, empties = {}, {}, {}
   for _, row in ipairs(rows) do
      local key, group, short = M.kind(row.fluid)
      if not group then
         empties[#empties + 1] = row.vial
      else
         local g = groups[group]
         if not g then
            g = { totals = {}, order = {}, keys = {} }
            groups[group] = g
            order[#order + 1] = group
         end
         if not g.totals[short] then
            g.totals[short] = 0
            g.order[#g.order + 1] = short
            g.keys[short] = key
         end
         g.totals[short] = g.totals[short] + row.sips
      end
   end

   local lines = {}
   local label = function(text) return theme.dc("textDim") .. string.format("  %-9s", text) end
   local indent = string.rep(" ", 11)
   for _, group in ipairs(order) do
      local g = groups[group]
      local line, width = label(group), 11
      for _, short in ipairs(g.order) do
         local total = g.totals[short]
         local plain = string.format("%s %d", short, total)
         if width > 11 and width + 2 + #plain > M.WIDTH then
            lines[#lines + 1] = line
            line, width = indent, 11
         end
         if width > 11 then line, width = line .. "  ", width + 2 end
         line = line .. theme.dc(g.keys[short]) .. short .. " "
            .. theme.dc(sipsColour(total)) .. tostring(total)
         width = width + #plain
      end
      lines[#lines + 1] = line
   end
   if #empties > 0 then
      lines[#lines + 1] = label("empty") .. theme.dc("inactive") .. table.concat(empties, "  ")
   end
   return lines
end

--- Did we just ask for one?
local function asked()
   local outgoing = emunah.outgoing
   return outgoing ~= nil and outgoing.sentRecently("^elist", M.WINDOW)
end

function M.onHeader()
   if not asked() then return end
   listing = { rules = 0, rows = {} }
   if selectCurrentLine() ~= false then
      setFgColor(theme.rgb("accent"))
      setBold(true)
      deselect()
   end
end

function M.onRule()
   if not listing then return end
   if selectCurrentLine() ~= false then
      setFgColor(theme.rgb("border"))
      deselect()
   end
   listing.rules = listing.rules + 1
   if listing.rules < 2 then return end
   local rows = listing.rows
   listing = nil
   if #rows == 0 then return end
   decho("\n" .. table.concat(M.summary(rows), "\n") .. "<r>")
end

--- Every line: a row while a listing is open, and the prompt that ends one regardless.
function M.onLine()
   if not listing then return end
   if type(isPrompt) == "function" and isPrompt() then
      listing = nil
      return
   end
   if listing.rules ~= 1 then return end
   local line = getCurrentLine()
   local row = M.parse(line)
   if not row then return end
   listing.rows[#listing.rows + 1] = row
   styleRow(line, row)
end

-- ---------------------------------------------------------------------------
-- triggers
-- ---------------------------------------------------------------------------

do
   emunah._persist = emunah._persist or {}
   for _, id in ipairs(emunah._persist.elistTriggers or {}) do killTrigger(id) end
   emunah._persist.elistTriggers = {}
   local function keep(id)
      if id then table.insert(emunah._persist.elistTriggers, id) end
   end

   keep(tempRegexTrigger([[^Vial\s+Fluid\s+Sips\s+Months\s*$]], function() M.onHeader() end))
   -- No `{n,}`: the test mock translates PCRE to Lua patterns, which lack it (pipes.lua).
   keep(tempRegexTrigger([[^[-][-][-][-][-][-][-][-][-][-]+\s*$]], function() M.onRule() end))
   keep(tempRegexTrigger([[^]], function() M.onLine() end))
end

return M

--- ELIST, parsed and redrawn as a bordered table, one row per fluid.
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
--- What replaces it (the user, 2026-10-04): health and mana in their own section, then the
--- other elixirs, then salves, then the empty vials. Each fluid's TOTAL is green, yellow
--- under 500 sips, red under 100. Totals, not single vials: a vial holds 200 when full,
--- so a per-vial number could never reach 500 and would always read yellow.
---
---   +--------------+-------+------------------------------------------------------+
---   | Fluid        |  Sips | Vials                                                |
---   +--------------+-------+------------------------------------------------------+
---   | HEALTH & MANA                                                               |
---   +--------------+-------+------------------------------------------------------+
---   | health       |   188 | vial41028 149  vial418713 39                         |
---   ...
---   | EMPTY                                                                       |
---   +-----------------------------------------------------------------------------+
---   | vial676646                                                                  |
---   +-----------------------------------------------------------------------------+
---
--- Months is left out: what it counts down to has not been established.
---
--- HOW THE GAME'S LINES GO. ELIST arrives as one packet, so nothing is deleted inside it:
--- ui/gag.lua hides each line and deletes it once the packet is done, and the table is
--- echoed after the closing rule. Only lines that parse as rows are hidden, so anything
--- else arriving in the middle is still shown.

local M = {}

local theme = emunah.ui.theme

--- A fluid's total under this is red, and under M.YELLOW yellow; green otherwise.
M.RED = 100
M.YELLOW = 500

--- How long after an ELIST goes out its header is believed. A listing nobody asked for is
--- left as it came.
M.WINDOW = 10

--- The table's width, matching the game's rule.
M.WIDTH = 79

local FLUID_W, SIPS_W = 12, 5
local VIALS_W = M.WIDTH - (2 + FLUID_W + 3 + SIPS_W + 3 + 2)
local INNER_W = M.WIDTH - 4

--- The listing being read, from its header to its closing rule or the next prompt.
local listing = nil

local function trim(text)
   return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

--- What a fluid is: palette key, section, and a short name.
---   "an elixir of health"    -> health,      vitals,  "health"
---   "an elixir of frost"     -> equilibrium, elixirs, "frost"
---   "a salve of restoration" -> endurance,   salves,  "restoration"
---   "a caloric salve"        -> endurance,   salves,  "caloric"
---   "empty"                  -> inactive,    empty,   "empty"
function M.kind(fluid)
   fluid = trim(fluid):lower()
   if fluid == "empty" or fluid == "" then return "inactive", "empty", "empty" end
   local short = fluid:gsub("^an?%s+", "")
   if short:find("^elixir of ") then
      short = short:gsub("^elixir of ", "")
      if short == "health" then return "health", "vitals", short end
      if short == "mana" then return "mana", "vitals", short end
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

--- The vial as you would name it in a command: "Pinewood vial41028" -> "vial41028".
function M.token(vial)
   return (tostring(vial):match("(%S+)$") or tostring(vial)):lower()
end

function M.totalColour(total)
   if total < M.RED then return "affliction" end
   if total < M.YELLOW then return "warning" end
   return "defence"
end

-- ---------------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------------

M.SECTIONS = {
   { id = "vitals",  title = "HEALTH & MANA" },
   { id = "elixirs", title = "ELIXIRS" },
   { id = "salves",  title = "SALVES" },
   { id = "other",   title = "OTHER" },
}

local function dc(key) return theme.dc(key) end
local function edge(text) return dc("textDim") .. text end

local function fit(text, width)
   text = tostring(text)
   if #text > width then return text:sub(1, width) end
   return text .. string.rep(" ", width - #text)
end

local RULE3 = "+" .. string.rep("-", FLUID_W + 2) .. "+" .. string.rep("-", SIPS_W + 2) .. "+"
   .. string.rep("-", VIALS_W + 2) .. "+"
local RULE1 = "+" .. string.rep("-", M.WIDTH - 2) .. "+"

local function wide(colour, text)
   return edge("| ") .. dc(colour) .. fit(text, INNER_W) .. edge(" |")
end

local function row(fluidKey, fluid, totalKey, total, vials, vialsWidth)
   return edge("| ") .. dc(fluidKey) .. fit(fluid, FLUID_W) .. edge(" | ")
      .. dc(totalKey) .. string.format("%" .. SIPS_W .. "s", total) .. edge(" | ")
      .. vials .. string.rep(" ", VIALS_W - vialsWidth) .. edge(" |")
end

--- Lay out "token sips" pieces across lines no wider than `width`: { {markup, width}, ... }.
local function wrap(pieces, width)
   local lines, markup, used = {}, "", 0
   for _, piece in ipairs(pieces) do
      local gap = used > 0 and 2 or 0
      if used > 0 and used + gap + piece.width > width then
         lines[#lines + 1] = { markup, used }
         markup, used, gap = "", 0, 0
      end
      markup = markup .. string.rep(" ", gap) .. piece.markup
      used = used + gap + piece.width
   end
   lines[#lines + 1] = { markup, used }
   return lines
end

--- The table, as decho lines.
function M.render(rows)
   local fluids, empties = {}, {}
   for _, entry in ipairs(rows) do
      local key, section, short = M.kind(entry.fluid)
      if section == "empty" then
         empties[#empties + 1] = M.token(entry.vial)
      else
         local fluid = fluids[short]
         if not fluid then
            fluid = { name = short, key = key, section = section, total = 0, vials = {} }
            fluids[short] = fluid
         end
         fluid.total = fluid.total + entry.sips
         fluid.vials[#fluid.vials + 1] = { token = M.token(entry.vial), sips = entry.sips }
      end
   end

   local out = {
      edge(RULE3),
      edge("| ") .. dc("text") .. fit("Fluid", FLUID_W) .. edge(" | ") .. dc("text")
         .. string.format("%" .. SIPS_W .. "s", "Sips") .. edge(" | ") .. dc("text")
         .. fit("Vials", VIALS_W) .. edge(" |"),
      edge(RULE3),
   }

   for _, section in ipairs(M.SECTIONS) do
      local list = {}
      for _, fluid in pairs(fluids) do
         if fluid.section == section.id then list[#list + 1] = fluid end
      end
      -- Health before mana; the rest alphabetical.
      table.sort(list, function(a, b)
         if section.id == "vitals" then return a.name == "health" and b.name ~= "health" end
         return a.name < b.name
      end)
      if #list > 0 then
         out[#out + 1] = wide("accent", section.title)
         out[#out + 1] = edge(RULE3)
         for _, fluid in ipairs(list) do
            local pieces = {}
            for _, vial in ipairs(fluid.vials) do
               pieces[#pieces + 1] = {
                  markup = dc("textDim") .. vial.token .. " " .. dc("text") .. tostring(vial.sips),
                  width = #vial.token + 1 + #tostring(vial.sips),
               }
            end
            for index, line in ipairs(wrap(pieces, VIALS_W)) do
               if index == 1 then
                  out[#out + 1] = row(fluid.key, fluid.name, M.totalColour(fluid.total),
                     tostring(fluid.total), line[1], line[2])
               else
                  out[#out + 1] = row("text", "", "text", "", line[1], line[2])
               end
            end
         end
         out[#out + 1] = edge(RULE3)
      end
   end

   if #empties > 0 then
      out[#out + 1] = wide("accent", "EMPTY")
      out[#out + 1] = edge(RULE1)
      local pieces = {}
      for _, token in ipairs(empties) do
         pieces[#pieces + 1] = { markup = dc("inactive") .. token, width = #token }
      end
      for _, line in ipairs(wrap(pieces, INNER_W)) do
         out[#out + 1] = edge("| ") .. line[1] .. string.rep(" ", INNER_W - line[2]) .. edge(" |")
      end
      out[#out + 1] = edge(RULE1)
   end

   if #rows == 0 then
      out[#out + 1] = wide("textDim", "No vials.")
      out[#out + 1] = edge(RULE1)
   end
   return out
end

-- ---------------------------------------------------------------------------
-- reading the game's listing
-- ---------------------------------------------------------------------------

--- Did we just ask for one?
local function asked()
   local outgoing = emunah.outgoing
   return outgoing ~= nil and outgoing.sentRecently("^elist", M.WINDOW)
end

local function hide() emunah.ui.gag.current() end

local function draw(rows)
   decho("\n" .. table.concat(M.render(rows), "\n"))
end

function M.onHeader()
   if not asked() then return end
   listing = { rules = 0, rows = {} }
   hide()
end

function M.onRule()
   if not listing then return end
   hide()
   listing.rules = listing.rules + 1
   if listing.rules < 2 then return end
   local rows = listing.rows
   listing = nil
   draw(rows)
end

--- Every line: a row while a listing is open. A prompt before the closing rule still
--- draws what was read, rather than leaving hidden rows with nothing in their place.
function M.onLine()
   if not listing then return end
   if type(isPrompt) == "function" and isPrompt() then
      local rows = listing.rows
      listing = nil
      if #rows > 0 then draw(rows) end
      return
   end
   if listing.rules ~= 1 then return end
   local row = M.parse(getCurrentLine())
   if not row then return end
   listing.rows[#listing.rows + 1] = row
   hide()
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

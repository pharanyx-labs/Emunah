--- Name highlighting: make the roster visible in the scroll.
---
--- The name database knows who is an enemy. That is worth very little if reading it means
--- typing a command -- the moment it matters is the moment a name goes past in a room
--- description or a shout, and you have about a second. So the database is rendered into
--- the game text itself: known names take on colour and weight in place.
---
--- WHAT COLOUR MEANS AND WHAT WEIGHT MEANS
--- ---------------------------------------
--- Two channels, two different jobs, and keeping them separate is the whole point:
---
---   COLOUR answers "where do they stand relative to me" -- enemy, ally, or which city.
---   WEIGHT answers "is there something about this person" -- a Dragon, a Mark, infamy,
---          or an importance you set yourself.
---
--- They stack. A Mhaldorian Dragon who is also enemied to your city reads as enemy-red and
--- bold and underlined, and each of those three is independently recoverable by eye.
---
--- Red is our city's enemy list alone (CITY ENEMIES, namedb.setCityEnemies). Every other
--- enemy is underlined in its ordinary colour. A
--- scheme that folded them into one colour ramp would make the common case (an ordinary
--- citizen of a hostile city) and the rare one (a Dragon Mark) look alike, which is the
--- opposite of what a highlighter is for.
---
--- WHY A LINE SCAN RATHER THAN A TRIGGER PER NAME
--- ----------------------------------------------
--- The obvious build is one trigger per known name, created as the database grows. That
--- gives Mudlet a few hundred regexes to run against every line, and it has to be torn down
--- and rebuilt whenever anyone is added. One trigger that fires on "line contains a
--- capitalised word" and then asks the database about each candidate is a single hash
--- lookup per word, and needs no maintenance at all -- adding a person to the database
--- highlights them on the very next line with no re-registration.
---
--- Crucially, a candidate is only ever styled if it is ALREADY a record. This never invents
--- a person out of a capitalised noun at the start of a sentence.

local M = {}

local util  = emunah.util
local theme = emunah.ui.theme

--- Colour per city. Cosmetic only -- see the provenance note on namedb.CITIES. An
--- unrecognised city simply falls through to the neutral tone, so nothing depends on this
--- list being complete or on the city names being spelled the way we expect.
M.cityColour = {
   ashtan    = "#8a6ea8",
   cyrene    = "#4f9dd9",
   eleusis   = "#4f9e5c",
   hashan    = "#a05fa8",
   mhaldor   = "#b4463f",
   targossas = "#d1a13c",
}

--- Our city's enemies: the one red. Darker than the theme's affliction red, which reads
--- as an alarm on every line it touches ("only have city enemies in red. make the red
--- darker, too", the user, 2026-10-04).
M.CITY_ENEMY = "#b3261e"

--- Tones that are not a city. Pulled from the theme so a retheme moves these with it.
local function tone(name)
   return theme.colour[name]
end

-- ---------------------------------------------------------------------------
-- policy
-- ---------------------------------------------------------------------------

--- How a name should be drawn, or nil for "leave it alone".
---
--- Returning nil rather than an empty style matters: an empty style would still cost a
--- selectString and a format call per occurrence, on every line, for every name we have
--- deliberately decided not to mark.
--- @return table|nil { colour = "#rrggbb", bold, italic, underline }
function M.styleFor(name)
   local ndb = emunah.namedb
   if not ndb then return nil end

   local person = ndb.get(name)
   if not person then return nil end

   -- Never our own name. It is on almost every line we care about, and highlighting it
   -- turns the one signal we want into noise.
   if ndb.isSelf(name) then return nil end

   -- The opt-out. `emunah names ignore <person>` sets this, for the ally whose name is a
   -- common word or the shopkeeper you see forty times an hour.
   if person.highlight == false then return nil end

   local standing = ndb.relationship(name)
   local style = {}

   -- RED IS OUR CITY'S ENEMY LIST, and nothing else (the user, 2026-10-04). Any other enemy
   -- -- marked by you, a house or order enemy, a citizen of somewhere marked hostile -- keeps
   -- its ordinary colour and is underlined, below.
   if person.cityenemy then
      style.colour = M.CITY_ENEMY
      style.bold = true
   elseif standing == "ally" then
      style.colour = tone("defence")
   else
      -- Neutral: the city carries the information, when we know it and when the user wants
      -- strangers tinted at all. Otherwise a dim tone, which still distinguishes "this is
      -- a person I have a record of" from ordinary prose.
      local city = person.city and tostring(person.city):lower()
      if emunah.config.get("names.cityTint", true) and city and M.cityColour[city] then
         style.colour = M.cityColour[city]
      else
         style.colour = tone("textDim")
      end
   end

   -- Weight, stacked on top of whatever colour was chosen above.
   if standing == "enemy" then style.underline = true end
   if person.dragon then style.bold = true end
   if person.mark then style.underline = true end
   if ndb.isInfamous(name) then style.italic = true end
   if (person.importance or 0) > 0 then style.bold = true end

   return style
end

-- ---------------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------------

--- Apply a style to the currently selected text.
---
--- Every attribute is set explicitly, including the ones that are off. Mudlet's format
--- calls are sticky against the selection, and leaving `setBold` unsaid on a name that is
--- not bold inherits whatever the game's own ANSI left behind -- which shows up as an
--- ordinary citizen rendering bold in the middle of a combat message and reading, at a
--- glance, exactly like the Dragon two lines up.
local function draw(style)
   if style.colour then
      local r, g, b = style.colour:match("^#(%x%x)(%x%x)(%x%x)$")
      if r then setFgColor(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)) end
   end
   setBold(style.bold == true)
   setItalics(style.italic == true)
   setUnderline(style.underline == true)
end

--- Style every known name on the line that just arrived.
---
--- Occurrences are counted as we go, because selectString's second argument is an ordinal:
--- styling the second "Malefactor" on a line means asking for occurrence 2, and passing 1
--- again would restyle the first and leave the second plain.
function M.onLine()
   if not M.enabled then return 0 end

   local ndb = emunah.namedb
   if not ndb or ndb.count() == 0 then return 0 end

   local ok, line = pcall(getCurrentLine)
   if not ok or type(line) ~= "string" or line == "" then return 0 end

   local occurrence, styled = {}, 0
   local links = emunah.config.get("names.enemyLinks", true) ~= false
   for _, name in ipairs(ndb.findNames(line)) do
      occurrence[name] = (occurrence[name] or 0) + 1
      local style = M.styleFor(name)
      if style then
         if selectString(name, occurrence[name]) > -1 then
            draw(style)
            -- AN ENEMY'S NAME IS A LINK to their record (the user, 2026-10-04: "the option
            -- to left click the names of enemies that will report their ndb entry"). The
            -- same report as `emset whois`. After draw(): the link is added to the text as
            -- styled, not in place of the style.
            if links and type(setLink) == "function"
               and (ndb.isDeclaredEnemy(name) or ndb.relationship(name) == "enemy") then
               setLink(string.format("emunah.commands.handlers.whois(%q)", name),
                  "What the name database knows about " .. name)
            end
            styled = styled + 1
         end
      end
   end

   -- Always, even when nothing was styled: a selection left standing is applied to
   -- whatever the next format call touches.
   deselect()
   return styled
end

-- ---------------------------------------------------------------------------
-- control
-- ---------------------------------------------------------------------------

M.enabled = emunah.config.get("names.enabled", true)

function M.start()
   M.enabled = true
   emunah.config.set("names.enabled", true)
   emunah.log.info("Name highlighting <ansi_light_green>on<ansi_yellow>.")
end

function M.stop()
   M.enabled = false
   emunah.config.set("names.enabled", false)
   emunah.log.info("Name highlighting <ansi_light_red>off<ansi_yellow>.")
end

function M.toggle()
   if M.enabled then M.stop() else M.start() end
   return M.enabled
end

--- Keep a name out of the highlighter without forgetting anything else about them.
function M.ignore(name, ignored)
   local ndb = emunah.namedb
   if not ndb.known(name) then return false, "not in the database" end
   return ndb.set(name, "highlight", ignored == false and true or false)
end

--- Everyone currently opted out.
function M.ignored()
   local out = {}
   for _, person in pairs(emunah.namedb.people) do
      if person.highlight == false then out[#out + 1] = person.name end
   end
   table.sort(out)
   return out
end

-- ---------------------------------------------------------------------------
-- the trigger
-- ---------------------------------------------------------------------------
--
-- Tracked on _persist and killed before re-registering, for the same reason as ih.lua and
-- commands.lua: Mudlet keeps a tempRegexTrigger alive for the life of the profile, so a
-- reload without this would leave three copies restyling every line.

local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.nameTriggers = emunah._persist.nameTriggers or {}
   return emunah._persist.nameTriggers
end

function M.killAll()
   local n = 0
   for _, id in ipairs(registry()) do
      if killTrigger(id) then n = n + 1 end
   end
   emunah._persist.nameTriggers = {}
   return n
end

--- WHY THE PATTERN IS THE ROSTER AND NOT "[A-Z][a-z]"
--- --------------------------------------------------
--- It used to be `[A-Z][a-z]` -- "contains a capitalised word" -- on the reasoning that it
--- is the cheapest pre-filter Mudlet can apply and that a hash lookup per word is nothing.
--- Both halves are true and the conclusion was still wrong, because the pre-filter does not
--- filter: in Achaea essentially every line of room description, combat text and channel
--- output contains a capitalised word. So the Lua callback ran on every line, and it was
--- not free -- `pcall(getCurrentLine)` plus `findNames()`'s `%a+` walk measured **5.1 us
--- per line**. At the 30-60 lines a busy room produces per combat round that is real
--- milliseconds, spent on the UI thread, at the exact moment the character is being locked.
---
--- The header above argues against "one trigger per known name", and it is still right:
--- a few hundred separate regexes is a lot of state to tear down and rebuild. But ONE regex
--- listing every name is a different thing entirely -- it is still a single pattern for
--- Mudlet to run, still matched in C++ before any Lua runs, and now the callback fires only
--- on lines that genuinely mention somebody.
---
--- NO WORD BOUNDARIES, deliberately. The trigger is only ever a pre-filter; `onLine()` calls
--- `findNames()`, which splits on `%a+` and checks the database, and THAT is what decides
--- what gets styled. So a substring hit ("Sartan" inside "Sartanic") costs one wasted
--- callback that styles nothing, and is not a correctness problem -- whereas getting `\b`
--- semantics right across PCRE and the test mock's Lua-pattern translation is a real one.
M.PATTERN = nil

--- Longest pattern we will hand a single trigger before splitting across several.
---
--- PCRE copes with far more than this, but a runaway pattern is the kind of thing that
--- fails at registration time with no error we can see, and several triggers cost the same
--- as one when none of them match.
M.MAX_PATTERN = 4000

--- The roster as regex alternatives.
---
--- Only `%a+` names are included, and that loses nothing: `findNames()` can only ever
--- return a word matching `%a+` in the first place, so a record whose name is not
--- alphabetic was already unhighlightable. It also means no name needs escaping, which is
--- what makes building a regex out of user data safe here.
local function alternatives()
   local ndb = emunah.namedb
   if not ndb then return {} end

   local names = {}
   for _, person in pairs(ndb.people) do
      local name = tostring(person.name or "")
      if name:match("^%a+$") then names[#names + 1] = name end
   end
   -- Sorted so the pattern is stable across rebuilds: an unstable pattern makes a
   -- registration bug look intermittent.
   table.sort(names)
   return names
end

--- Which generation of the roster the live triggers were built from. Compared rather than
--- timed -- see namedb.generation.
local built = nil

--- How many triggers are currently live. Held here rather than read back from registry(),
--- because the no-op path below runs once per prompt and registry() lazily builds two table
--- lookups and an `or {}` every time it is asked.
local liveTriggers = 0

--- (Re)build the triggers from the current roster. Safe to call repeatedly; it does nothing
--- when the roster has not changed since the last build.
--- @param force boolean|nil rebuild even if the generation matches
--- @return number triggers registered
function M.rebuild(force)
   local ndb = emunah.namedb
   local generation = ndb and ndb.generation or 0
   if not force and built == generation then return liveTriggers end

   M.killAll()
   built = generation
   liveTriggers = 0

   local names = alternatives()
   if #names == 0 then
      -- An empty roster gets NO trigger at all, rather than one that cannot match. This is
      -- the common case for a fresh install, and it should cost exactly nothing.
      M.PATTERN = nil
      return 0
   end

   local chunks, current, length = {}, {}, 0
   for _, name in ipairs(names) do
      if length > 0 and length + #name + 1 > M.MAX_PATTERN then
         chunks[#chunks + 1] = table.concat(current, "|")
         current, length = {}, 0
      end
      current[#current + 1] = name
      length = length + #name + 1
   end
   if #current > 0 then chunks[#chunks + 1] = table.concat(current, "|") end

   for _, chunk in ipairs(chunks) do
      local id = tempRegexTrigger("(?:" .. chunk .. ")", function() M.onLine() end)
      if id then
         table.insert(registry(), id)
         liveTriggers = liveTriggers + 1
      end
   end

   -- Kept for `emunah names` and for the tests; the first chunk is representative.
   M.PATTERN = chunks[1]
   return liveTriggers
end

M.killAll()
M.rebuild(true)

--- Rebuild when the roster changes.
---
--- On the tick rather than at the mutation site, and that is the point: `ndb learn` records
--- everyone online in one burst, and a rebuild per record would tear down and re-register
--- the triggers fifty times for one command. A generation compare is an integer test, which
--- is affordable once per prompt in a way that killTrigger/tempRegexTrigger is not.
emunah.event.register("emunah.tick", function() M.rebuild() end, "ui.names")

return M

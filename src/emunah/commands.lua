--- Aliases: the user-facing command surface.
---
--- One dispatcher under a single `emunah` prefix, rather than a scatter of top-level
--- aliases. Two reasons: Achaea has a large command vocabulary of its own and colliding
--- with it is easy, and a single entry point means `emunah` with no arguments can list
--- everything the system can do -- which is the only documentation most people will read.
---
--- Aliases are registered through tempAlias and tracked on _persist, so a reload replaces
--- them rather than stacking duplicates. (A duplicated alias in Mudlet fires once per
--- copy, so `emunah cure on` after three reloads would toggle curing three times and end
--- up off.)

local M = {}

local util = emunah.util
local log  = emunah.log

local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.commandAliases = emunah._persist.commandAliases or {}
   return emunah._persist.commandAliases
end

local function killAll()
   local reg = registry()
   for _, id in ipairs(reg) do killAlias(id) end
   emunah._persist.commandAliases = {}
end

-- ---------------------------------------------------------------------------
-- output helpers
-- ---------------------------------------------------------------------------
--
-- One dialect for every report: decho and the theme palette, not Mudlet's sixteen fixed
-- `<ansi_*>` names. This file used to carry both -- `header`/`row`/`flag` on `cecho` for
-- most handlers, `ndbTitle`/`ndbGrid` on `decho` for the name database and defence grid --
-- which meant two different title-bar styles and two different colour systems depending on
-- which command you typed. `header`/`row`/`flag` are now themselves built on the same
-- primitives as `ndbTitle`/`ndbGrid`, so every handler in this file shares one look; the
-- theme/decho helpers are declared first so the handlers below can call them.

local NDB_WIDTH = 68

local function theme() return emunah.ui.theme end

--- decho colour prefix for a hex string, rather than for a palette key.
local function hexdc(hex)
   local r, g, b = tostring(hex):match("^#(%x%x)(%x%x)(%x%x)$")
   if not r then return theme().dc("text") end
   return string.format("<%d,%d,%d>", tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
end

local function dim(text)   return theme().dc("textDim") .. tostring(text) end
local function faint(text) return theme().dc("inactive") .. tostring(text) end

local function ndbRule(width)
   decho("\n  " .. faint(string.rep("-", width or NDB_WIDTH)))
end

local function ndbTitle(text, right)
   local pad = NDB_WIDTH - #text - #(right or "") - 3
   if pad < 1 then pad = 1 end
   decho(string.format("\n  %s%s %s %s%s",
      theme().dc("borderLit"), "--", theme().dc("textBright") .. text,
      faint(string.rep("-", pad)),
      right and (" " .. theme().dc("textDim") .. right) or ""))
end

--- "4m", "3d" -- a duration at the scale a roster cares about, which is days, not the
--- tenths of a second util.duration() is tuned for.
local function span(seconds)
   if not seconds then return "never" end
   if seconds < 90 then return string.format("%ds", math.floor(seconds)) end
   if seconds < 5400 then return string.format("%dm", math.floor(seconds / 60)) end
   if seconds < 172800 then return string.format("%dh", math.floor(seconds / 3600)) end
   return string.format("%dd", math.floor(seconds / 86400))
end

local function ago(when)
   if not when then return "never" end
   return span(emunah.util.now() - when)
end

--- Lay out label/value pairs two to a line.
---
--- Two columns rather than one: a full record is twenty-odd fields, and a single column
--- makes the dossier longer than a screen -- at which point the top has scrolled away by
--- the time you have read the bottom, which defeats the point of gathering it in one place.
--- Nothing is dropped for being unknown; a dash for "we never found out" is itself
--- information, and a field that silently vanished would read as one we never had.
local function ndbGrid(rows)
   for index = 1, #rows, 2 do
      local left, right = rows[index], rows[index + 1]
      local line = string.format("%s%-12s%s%-16s",
         theme().dc("textDim"), left[1],
         left[3] or theme().dc("text"), tostring(left[2]):sub(1, 15))
      if right then
         line = line .. string.format("%s%-12s%s%s",
            theme().dc("textDim"), right[1],
            right[3] or theme().dc("text"), tostring(right[2]))
      end
      decho("\n  " .. line)
   end
end

--- A report title. Delegates to `ndbTitle` directly -- same dashed bar, same bright text,
--- every handler's report opens the same way.
local function header(text)
   ndbTitle(text)
end

--- Maps the handful of semantic colours `row()` was ever called with under the old
--- `<ansi_*>` names to their theme-palette equivalent, so every one of this file's ~100
--- `row(...)` call sites keeps working unchanged.
local ROW_COLOUR = {
   ["ansi_light_green"] = "defence",     -- on / up / good
   ["ansi_light_red"]   = "affliction",  -- off / missing / bad
   ["ansi_yellow"]      = "warning",
   ["ansi_cyan"]        = "balance",
   ["ansi_light_black"] = "textDim",
   ["reset"]            = "text",
}

--- A single label/value line. `colour` is optional and accepts either a theme palette key
--- directly or one of the legacy `<ansi_*>` names via `ROW_COLOUR`, so existing call sites
--- did not need to change.
local function row(label, value, colour)
   local key = colour and (ROW_COLOUR[colour] or colour) or "text"
   decho(string.format("\n  %s%-18s%s %s%s",
      theme().dc("textDim"), label, theme().dc("text"), theme().dc(key), tostring(value)))
end

--- "on"/"off" in the same green/red as everywhere else, as a decho fragment ready to drop
--- into a `row()` value -- `row("curing", flag(engine.enabled))`.
local function flag(value)
   return value and (theme().dc("defence") .. "on") or (theme().dc("affliction") .. "off")
end

-- ---------------------------------------------------------------------------
-- commands
-- ---------------------------------------------------------------------------

M.handlers = {}

M.handlers.status = function()
   header("Emunah " .. (emunah._version or "?"))
   -- gmcp/init.lua is published AS emunah.gmcp, so its fields hang off that directly.
   row("character", emunah.gmcp.character or emunah.gmcp.status.name() or "-")
   row("class", emunah.gmcp.status.class() or "-")
   row("curing", flag(emunah.curing.engine.enabled))
   row("defence keep-up", flag(emunah.curing.defkeepup.enabled))
   row("UI", flag(emunah.config.get("ui.enabled", true)))
   row("cure method", emunah.config.get("curing.method", "herbs"))
   row("afflictions tracked", emunah.curing.engine.count())
   row("skills indexed", emunah.gmcp.skills.complete and
      (#emunah.gmcp.skills.all() .. " abilities") or "pending")
   row("inventory", emunah.gmcp.items.count("inv") .. " items")
   row("log level", emunah.log.level)

   -- THE SAFETY FLOORS, stated plainly and together.
   --
   -- These live in three places -- bashing, pvp, and watch's shared `critical` -- and a
   -- floor set to 0 is OFF, silently. A fight was observed running down to 23% health and
   -- stopping on watch's critical rather than on the bashing floor, which is exactly what a
   -- `bashing.stopBelowHealth` of 0 looks like from the outside and is indistinguishable
   -- from a bug unless you can see all three numbers at once.
   local function floor(label, value)
      local number = tonumber(value) or 0
      row(label, number > 0 and (number .. "%") or "OFF",
         number > 0 and "reset" or "ansi_light_red")
   end
   floor("stop: bashing", emunah.config.get("bashing.stopBelowHealth", 50))
   floor("stop: pvp", emunah.config.get("pvp.stopBelowHealth", 60))
   floor("stop: critical", emunah.watch and emunah.watch.config
      and emunah.config.get("watch.critical", emunah.watch.config.critical))
end

M.handlers.cure = function(arg)
   if arg == "on" then emunah.curing.engine.start(); emunah.config.save()
   elseif arg == "off" then emunah.curing.engine.stop(); emunah.config.save()
   else
      -- Bare or unmatched shows the status, same rule `defs` follows: mutation always
      -- needs an explicit on/off, so a typo here cannot flip curing off mid-fight. This
      -- used to be `else emunah.curing.engine.toggle() end` -- any argument that was not
      -- exactly "on" or "off", including none at all in some call shapes, silently toggled.
      if arg then
         log.warn("Unknown: emset cure %s. Try `emset cure on|off`.", tostring(arg))
      end
      local engine = emunah.curing.engine
      header("Curing")
      row("status", flag(engine.enabled))
      row("tracked", engine.count())
      decho("\n  " .. faint("emset cure on|off -- emset affs for what is tracked"))
   end
end

--- `pp`: pause or resume curing AND defence keep-up together. A cure engine paused with
--- keep-up still raising defences (or the reverse) is not actually the fight paused, it is
--- half paused -- so this drives both from the curing engine's state rather than letting
--- them drift independently. "Resuming" is defined as "either one is currently off": that
--- way one call always lands on a clean, fully-on or fully-off state, regardless of how
--- `! cure` or `! defs` may have left them individually.
M.handlers.pause = function()
   local engine = emunah.curing.engine
   local keepup = emunah.curing.defkeepup
   -- Both modules log their own "X on."/"X off." when called directly (see engine.start()
   -- and keepup.start()), which is right for `emunah cure on` and `emunah defs on` typed on
   -- their own. `pp` moves both at once, so it silences their individual lines and prints
   -- one summary instead -- two lines and a banner for one keypress was noise, not
   -- confirmation. The banner in ui/echo.lua is unaffected: it listens for the same
   -- curing.*/defkeepup.* events, which still fire.
   if engine.enabled and keepup.enabled then
      engine.stop(true)
      keepup.stop(true)
      log.info("<ansi_light_red>Paused<ansi_yellow>.")
   else
      engine.start(true)
      keepup.start(true)
      log.info("<ansi_light_green>Resumed<ansi_yellow>.")
   end
   emunah.config.save()
end

M.handlers.defs = function(arg, rest)
   local keepup = emunah.curing.defkeepup
   if arg == "on" then keepup.start(); emunah.config.save()
   elseif arg == "off" then keepup.stop(); emunah.config.save()
   elseif arg == "add" and rest then
      -- `emunah defs add <name>` for anything already known, or
      -- `emunah defs add <name> <command>` to supply one -- the form tattoos need, where
      -- the Char.Defences name has to be read from the game rather than assumed.
      local name, command = rest:match("^(%S+)%s+(.+)$")
      keepup.add(name or rest, command)
   elseif arg == "names" then
      -- What Char.Defences actually calls things. The answer to every "I raised it and it
      -- never appeared" -- the game has been reporting the real name all along.
      header("Char.Defences reports " .. #emunah.gmcp.defences.names() .. " defences")
      local unclaimed = util.set(keepup.unclaimed())
      for _, name in ipairs(emunah.gmcp.defences.names()) do
         row(name, unclaimed[name] and "not paired with any command" or "known",
            unclaimed[name] and "ansi_yellow" or "ansi_light_green")
      end
      cecho("\n  <ansi_light_black>An unpaired name that you know how to raise: "
         .. "emunah defs add <name> <command><reset>")
      return
   elseif arg == "mode" and rest then
      -- Explicit rather than an optional trailing argument on `add`, which already takes a
      -- free-form command and could not tell a mode from the first word of one.
      local name, mode = rest:match("^(%S+)%s+(%S+)$")
      if not name then
         log.warn("Usage: emset defs mode <name> defup|keepup|off")
         return
      end
      mode = mode:lower()
      if mode == "off" or mode == "none" then mode = nil end
      keepup.setMode(name, mode)
      log.info("%s: %s.", name, mode or "off")
   elseif arg == "remove" or arg == "drop" then keepup.drop(rest)
   else
      -- An unrecognised subcommand shows the same report as bare `emunah defs` rather than
      -- silently mutating anything -- this used to fall through to keepup.toggle(), so a
      -- typo like `emunah defs sttaus` flipped defence keep-up on or off with no warning.
      if arg and arg ~= "list" then
         log.warn("Unknown: emunah defs %s. Try `emunah defs`, `... on|off`, `... add <name>`, "
            .. "`... mode <name> defup|keepup|off`, `... names`, `... remove <name>`.",
            tostring(arg))
      end
      header("Defences (" .. (keepup.enabled and "on" or "off") .. ")")
      local wanted = keepup.wanted()
      if #wanted == 0 then
         cecho("\n  <ansi_light_black>nothing configured -- try `emdefs` for the grid, "
            .. "or: emunah defs add rebounding<reset>")
      end
      -- Say it where the red text is, not only in the header. A list of defences marked
      -- MISSING while the thing that raises them is switched off reads as a fault in the
      -- raising, which is exactly how it was reported. Same warning, and the same reason
      -- for it, as the one `emunah affs` prints when curing is off.
      if #wanted > 0 and not keepup.enabled then
         cecho("\n  <ansi_light_red>defences are OFF<reset> <ansi_light_black>-- "
            .. "`emunah defs on`. Nothing below is being raised.<reset>")
      end
      for _, name in ipairs(wanted) do
         local state = keepup.state(name)
         -- A satisfied defup entry is neither up nor owed anything, and calling it MISSING
         -- would be wrong in the one mode where a lapse is deliberately ignored.
         local status
         if state.up then status = "up"
         elseif state.mode == "defup" and state.satisfied then status = "done (lapsed)"
         else status = "MISSING" end
         -- Name and mode padded here rather than left to row()'s single 18-wide column,
              -- which the two of them together overrun.
         row(string.format("%-16s %-8s", name, "[" .. tostring(state.mode) .. "]"), status,
            status == "up" and "ansi_light_green"
            or status == "MISSING" and "ansi_light_red" or "ansi_light_black")
      end
   end
end

--- The keep-up grid: every defence we know how to raise, as clickable toggles.
---
--- Three states per defence, not two, and that is the point of building this rather than
--- printing a list. A checkbox alone answers "did I ask for this", which is the least
--- interesting of the three questions -- the others being whether it is actually up right
--- now, and whether we hold a command capable of raising it at all. A defence sitting
--- wanted-but-unraisable looks identical to one that is merely down, and stays that way
--- forever.
---
---   [ ] off     not wanted
---   [o] defup   raise it once if it is missing, then leave it alone
---   [x] keepup  raise it whenever it is missing, indefinitely
---   [-] faint   we have no command for it; asking for it would achieve nothing
---
--- and the NAME is coloured by what is actually true right now: green up, red wanted but
--- down, dim down.
---
--- Clicking re-renders rather than editing in place: Mudlet's main console has no
--- addressable cells, and a fresh grid under the old one is what every other clickable view
--- in this codebase does (see ih.lua, ui/roompanel.lua).
M.handlers.keepup = function()
   local keepup = emunah.curing.defkeepup
   local names  = keepup.known()

   ndbTitle("defences", keepup.enabled and "ON" or "OFF")
   if not keepup.enabled then
      decho("\n  " .. theme().dc("affliction") .. "defences are OFF"
         .. faint(" -- nothing below is being raised. "))
      dechoLink(theme().dc("defence") .. "[turn it on]",
         "emunah.curing.defkeepup.start() emunah.config.save() "
         .. "emunah.curing.defkeepup.nudge() "
         .. "emunah.commands.handlers.keepup()", "Start raising these defences", true)
   end

   local COLUMNS, column = 3, 0
   for _, name in ipairs(names) do
      local state = keepup.state(name)

      -- THE BOX IS THE MODE, THE NAME IS THE TRUTH. Two questions, two channels: what did
      -- you ask for, and what is actually up. Folding them together would make "I asked for
      -- this and it is not up" -- the only state anything is owed about -- look the same as
      -- "I never asked for it".
      local box, boxColour
      if not state.raisable then
         box, boxColour = "-", theme().dc("inactive")
      elseif state.mode == "defup" then
         box, boxColour = "o", theme().dc("warning")
      elseif state.mode == "keepup" then
         box, boxColour = "x", theme().dc("defence")
      else
         box, boxColour = " ", theme().dc("textDim")
      end

      local nameColour_
      if state.up then
         nameColour_ = theme().dc("defence")
      elseif state.mode and state.blockedBy then
         -- Wanted, down, and waiting on something else -- which is not the same problem as
         -- "wanted and not going up", and should not read like it.
         nameColour_ = theme().dc("warning")
      elseif state.mode == "defup" and state.satisfied then
         -- Done, not owed anything further -- the `emunah defs list` text view already
         -- draws this distinction ("done (lapsed)"); the grid did not, so a satisfied defup
         -- entry (an ordinary lapsed one, or an unconfirmable one-shot like `bliss`) looked
         -- identical to one that had never been raised at all.
         nameColour_ = theme().dc("textDim")
      elseif state.mode and state.raisable then
         nameColour_ = theme().dc("affliction")
      else
         nameColour_ = theme().dc("textDim")
      end

      if column == 0 then decho("\n  ") end
      -- The whole cell is the link, checkbox included: a three-character click target is
      -- an unkind one, and the name beside it is what the eye is already on.
      dechoLink(string.format("%s[%s] %s%-20s", boxColour, box, nameColour_, name:sub(1, 20)),
         -- Cycle, ask for a prompt so the change is acted on now rather than whenever the
         -- game next says something, then redraw.
         string.format("emunah.curing.defkeepup.cycle(%q) "
            .. "emunah.curing.defkeepup.nudge() "
            .. "emunah.commands.handlers.keepup()", name),
         state.raisable
            and (({ [""] = "Raise " .. name .. " once (defup)",
                    defup  = "Keep " .. name .. " up (keepup)",
                    keepup = "Stop raising " .. name })[state.mode or ""]
                 .. "  (" .. tostring(state.command) .. ")"
                 -- Say when the command has not been checked against a live
                 -- Char.Defences: "it never goes up" is a likelier outcome for those, and
                 -- the tooltip should not hide it.
                 .. (state.blockedBy
                     and ("  -- waiting for " .. state.blockedBy
                          .. ", without which you cannot see or hear") or "")
                 .. (state.source == "imported" and "  [unverified]" or "")
                 .. (state.unconfirmable
                     and "  [never shows as up -- Char.Defences has no line for it]" or ""))
            -- Say why it is inert rather than offering a toggle that cannot help.
            or (name .. ": no command known. `emunah defs add " .. name .. " <command>`"),
         true)

      column = (column + 1) % COLUMNS
   end

   decho("\n\n  " .. faint("click cycles:  [ ] off  ->  [o] defup (raise once)  ->  "
      .. "[x] keepup  ->  off"))
   decho("\n  " .. faint("[-] no command known.  Name: green up now, red wanted but down, "
      .. "dim down"))
   decho("\n  " .. faint("emunah defs on|off  |  emunah defs add <name> <command> "
      .. "corrects a name that never appears"))
end

M.handlers.affs = function()
   local engine = emunah.curing.engine
   header("Afflictions (" .. engine.count() .. ")")
   local tracked = engine.list()
   if #tracked == 0 then
      cecho("\n  <ansi_light_green>clear<reset>")
      return
   end
   if not engine.enabled then
      cecho("\n  <ansi_light_red>curing is OFF<reset> <ansi_light_black>-- "
         .. "`emunah cure on`. Nothing below is being acted on.<reset>")
   end
   for _, record in ipairs(tracked) do
      local vectors = table.concat(emunah.curing.afflist.vectorsFor(record.name), ", ")
      row(record.name, string.format("%s  [%s, %.0fs]",
         vectors ~= "" and vectors or "no known cure", record.source,
         emunah.util.now() - record.since))
      -- The reason it is still here, when there is one. An affliction with a cure that
      -- cannot currently be performed looks exactly like one being ignored.
      local refusal = engine.refusals[record.name]
      if refusal then
         cecho(string.format("\n  %-18s <ansi_light_red>%s<reset>", "", refusal))
      elseif vectors == "" then
         cecho(string.format("\n  %-18s <ansi_yellow>%s<reset>", "",
            "no cure defined -- it will sit here until it wears off"))
      end
   end
end

--- Chat diagnostics: which half is working.
---
--- Capture and rendering are separate modules so they fail independently, which only helps
--- if you can see which one went. "Chat stopped" is the same symptom for three different
--- causes -- the game stopped sending, the console broke, or no console was ever built --
--- and this distinguishes them in one line.
M.handlers.chat = function(arg)
   local comm = emunah.gmcp.comm
   local chat = emunah.ui.chat

   if arg == "rebuild" then
      chat.rebuilt = false
      local ok, built = pcall(chat.build)
      log.info("Chat rebuild: %s", (ok and built) and "ok" or "failed")
      return
   end

   header("Chat")
   row("captured", string.format("%d message%s", #comm.history,
      #comm.history == 1 and "" or "s"))
   local last = comm.history[#comm.history]
   row("last captured", last and (os.date("%H:%M:%S", last.at) .. "  [" .. last.tab .. "] "
      .. (last.talker or "")) or "(nothing yet)")
   row("render mode", chat.mode,
      chat.mode == "none" and "ansi_light_red" or "ansi_light_green")
   row("console", chat.console and "present" or "MISSING",
      chat.console and "ansi_light_green" or "ansi_light_red")
   if chat.broken then row("state", "NOT ACCEPTING OUTPUT", "ansi_light_red") end
   if (chat.dropped or 0) > 0 then
      row("dropped", tostring(chat.dropped) .. " (captured, never rendered)", "ansi_yellow")
   end

   cecho("\n  <ansi_light_black>Messages captured but not shown means the window; "
      .. "nothing captured means the feed.<reset>")
   cecho("\n  <ansi_light_black>emunah chat rebuild -- rebuild just the chat console.<reset>")
end

-- ---------------------------------------------------------------------------
-- the name database
-- ---------------------------------------------------------------------------
--
-- This section draws with decho and the theme palette rather than the `<ansi_*>` names the
-- rest of the file uses. That is deliberate, and it is the one place in the command surface
-- where it happens: a roster is read at a glance under time pressure, and sixteen ANSI
-- colours cannot give six cities six distinguishable tints. The theme already carries a
-- palette; this borrows it so a retheme moves the roster too.
--
-- The visual grammar, which every view below shares:
--
--   a GLYPH column says standing        x enemy   + ally   . neutral   @ you
--   COLOUR says the same thing again for enemies and allies, and says CITY for everyone
--     else, matching what the highlighter does to the same name in the game text
--   a FLAG cluster says what is unusual  D dragon   M mark   i<n> infamy   !<n> importance
--
-- Saying standing twice, in glyph and in colour, is not redundancy: the glyph survives a
-- colourblind reader and a monochrome log, and the colour is what is actually legible at
-- speed.


local STANDING = {
   enemy   = { glyph = "x", colour = "affliction", label = "enemy"   },
   ally    = { glyph = "+", colour = "defence",    label = "ally"    },
   neutral = { glyph = ".", colour = "textDim",    label = "neutral" },
   self    = { glyph = "@", colour = "textBright", label = "you"     },
}

--- The colour a name is drawn in -- the same decision the highlighter makes, so a name
--- reads identically in the roster and in the scroll.
local function nameColour(name)
   local style = emunah.ui.names and emunah.ui.names.styleFor(name)
   if style and style.colour then return hexdc(style.colour) end
   local standing = STANDING[emunah.namedb.relationship(name)] or STANDING.neutral
   return theme().dc(standing.colour)
end




--- The compact flag cluster. Empty when there is nothing unusual, which is most people --
--- an always-present column of dashes would be noise in exactly the place the eye should
--- find nothing.
local function flags(person)
   local ndb = emunah.namedb
   local out = {}
   if person.dragon then out[#out + 1] = "D" end
   if person.mark then out[#out + 1] = "M" end
   local infamy = ndb.infamy(person.name)
   if infamy >= 2 then out[#out + 1] = "i" .. infamy end
   if (person.importance or 0) > 0 then out[#out + 1] = "!" .. person.importance end
   if person.immortal then out[#out + 1] = "IMM" end
   return table.concat(out, " ")
end

--- One roster line. The name is a link, because the roster's whole job is to be the thing
--- you scan before picking one person to read properly.
local function ndbLine(person)
   local ndb = emunah.namedb
   local standing = STANDING[ndb.relationship(person.name)] or STANDING.neutral

   decho(string.format("\n  %s%s ", theme().dc(standing.colour), standing.glyph))
   dechoLink(nameColour(person.name) .. string.format("%-14s", person.name:sub(1, 14)),
      "emunah whois " .. person.name, "Read the dossier on " .. person.name, true)
   decho(string.format("%s%-13s %s%-11s %s%-13s %s%s",
      theme().dc("text"),      (person.class or "-"):sub(1, 13),
      theme().dc("textDim"),   (person.city or "-"):sub(1, 11),
      theme().dc("inactive"),  (person.house or "-"):sub(1, 13),
      theme().dc("warning"),   flags(person)))
end

--- A labelled bar. Used by `stats`; the bar is drawn in the city's own colour, which turns
--- the population breakdown into the same visual language as everything else.
local function ndbBar(label, count, most, colour)
   local width = most > 0 and math.floor((count / most) * 28) or 0
   decho(string.format("\n  %s%-18s %s%4d  %s%s",
      theme().dc("textDim"), tostring(label):sub(1, 18),
      theme().dc("text"), count,
      colour or theme().dc("borderLit"), string.rep("=", width)))
end

--- Anything destructive asks twice, and the second ask has to name a number. `forget all`
--- on a database somebody has curated for a month is not recoverable, and a confirmation
--- that says "are you sure" without saying how much is at stake is not a confirmation.
--- See `util.confirm()` for the shared repeat-within-window mechanism.

--- The filtered-roster verbs, as data: verb -> the filter it builds.
local ROSTERS = {
   all      = {},
   ally     = { relationship = "ally" },
   allies   = { relationship = "ally" },
   enemy    = { relationship = "enemy" },
   enemies  = { relationship = "enemy" },
   neutral  = { relationship = "neutral" },
   dragons  = { dragon = true },
   marks    = { mark = true },
   infamous = { infamous = true },
}

local function ndbRoster(filter, title)
   local ndb = emunah.namedb
   local people = ndb.list(filter)

   ndbTitle(title or "roster", string.format("%d of %d", #people, ndb.count()))
   if #people == 0 then
      decho("\n  " .. dim("nobody matches. `emunah ndb capture` explains where records "
         .. "come from."))
      return
   end
   for _, person in ipairs(people) do ndbLine(person) end
   decho("\n  " .. faint("x enemy  + ally  . neutral   D dragon  M mark  i infamy  "
      .. "!importance"))
end

--- The name database: who is a person, and what are they.
M.handlers.ndb = function(arg, rest)
   local ndb = emunah.namedb
   arg = arg and arg:lower() or nil

   -- --- reading -----------------------------------------------------------

   if arg == nil or ROSTERS[arg] then
      ndbRoster(ROSTERS[arg or "all"], arg or "roster")
      return
   end

   if (arg == "city" or arg == "house" or arg == "order" or arg == "class") and rest then
      ndbRoster({ [arg] = rest }, arg .. " " .. rest)
      return
   end

   if arg == "here" then
      local here = ndb.here()
      ndbTitle("in the room", tostring(#here))
      if #here == 0 then decho("\n  " .. dim("nobody but you")) return end
      for _, person in ipairs(here) do
         local record = ndb.get(person.name)
         if record then
            ndbLine(record)
         else
            -- In the room but not in the database at all. Says so plainly rather than
            -- rendering a row of dashes that looks like a record with nothing in it.
            decho(string.format("\n  %s? %s%-14s %s",
               theme().dc("warning"), theme().dc("text"), person.name:sub(1, 14),
               dim("not recorded")))
         end
      end
      return
   end

   if arg == "stats" then
      local s = ndb.stats()
      ndbTitle("population", tostring(s.total) .. " known")

      local most = math.max(s.standing.ally, s.standing.enemy, s.standing.neutral, 1)
      ndbBar("ally", s.standing.ally, most, theme().dc("defence"))
      ndbBar("enemy", s.standing.enemy, most, theme().dc("affliction"))
      ndbBar("neutral", s.standing.neutral, most, theme().dc("inactive"))

      local cities, top = emunah.util.keys(s.cities), 0
      for _, city in ipairs(cities) do top = math.max(top, s.cities[city]) end
      if #cities > 0 then
         ndbRule()
         for _, city in ipairs(cities) do
            ndbBar(city, s.cities[city], top,
               hexdc(emunah.ui.names.cityColour[city:lower()] or theme().colour.borderLit))
         end
      end

      ndbRule()
      -- The gaps, stated as loudly as the totals. A database is only as good as what it
      -- does NOT know, and that number is invisible in every other view.
      decho(string.format("\n  %s%-18s %s%4d unknown city, %d unknown class",
         theme().dc("textDim"), "gaps", theme().dc("warning"), s.unknownCity, s.unknownClass))
      decho(string.format("\n  %s%-18s %s%d dragons, %d marks, %d infamous, %d with notes",
         theme().dc("textDim"), "of note", theme().dc("text"),
         s.dragons, s.marks, s.infamous, s.noted))

      local hostiles = ndb.hostiles()
      if #hostiles > 0 then
         ndbRule()
         for _, org in ipairs(hostiles) do
            decho(string.format("\n  %s%-18s %s%s",
               theme().dc("textDim"), "hostile " .. org.kind,
               theme().dc("affliction"), org.name))
         end
      end
      return
   end

   if arg == "fields" then
      ndbTitle("settable fields", "emunah ndb set <person> <field> <value>")
      for _, spec in ipairs(ndb.FIELDS) do
         decho(string.format("\n  %s%-12s %s%-7s %s%s",
            theme().dc("text"), spec.name,
            theme().dc("inactive"), spec.type,
            theme().dc("textDim"), spec.help or ""))
      end
      return
   end

   if arg == "capture" and (rest == "on" or rest == "off") then
      ndb.capture.setEnabled(rest == "on")
      emunah.config.save()
      log.info("Reading CW, CLWHO, QW and angel reports is %s.", rest)
      return
   end

   if arg == "capture" then
      -- Where records come from, and -- the part that matters -- exactly what each source
      -- we have NOT built is waiting on. See namedb.lua's header for why guessing at that
      -- text is the one thing this project will not do.
      ndbTitle("data sources", ndb.capture.enabled and "reading" or "NOT READING")
      for _, source in ipairs(ndb.sources) do
         decho(string.format("\n  %s%-10s %s%s",
            source.implemented and theme().dc("defence") or theme().dc("warning"),
            source.implemented and "live" or "waiting",
            theme().dc("text"), source.what))
         decho(string.format("\n  %s%-10s %s%s", "", "", dim("gives "), dim(source.gives)))
         if source.needs then
            decho("\n  " .. string.rep(" ", 11) .. theme().dc("warning") .. "needs: "
               .. source.needs)
         end
      end
      local capture = ndb.capture
      ndbRule()
      decho(string.format("\n  %s%-12s %s%d read, %d resolved, %d recorded",
         theme().dc("textDim"), "listings", theme().dc("text"),
         capture.counters.lines, capture.counters.resolved, capture.counters.records))

      -- The honorifics we could not turn into a name, shown rather than swallowed. This is
      -- the list that says whether the resolver is actually working, and a capture layer
      -- that hid its failures would look perfect while quietly recording nobody.
      local stuck = emunah.util.keys(capture.unresolved)
      if #stuck > 0 then
         decho(string.format("\n  %s%-12s %s%d", theme().dc("textDim"), "unresolved",
            theme().dc("warning"), #stuck))
         for index, fullname in ipairs(stuck) do
            if index > 8 then
               decho("\n  " .. faint(string.format("   ... and %d more", #stuck - 8)))
               break
            end
            decho("\n    " .. faint(fullname))
         end
      end

      decho("\n  " .. faint("paste the text into docs/game/help/ and the pattern "
         .. "follows from it"))
      return
   end

   if arg == "path" then
      ndbTitle("storage")
      decho("\n  " .. theme().dc("text") .. ndb.path)
      decho("\n  " .. dim(string.format("%d records, written on every change", ndb.count())))
      return
   end

   -- `ndb show <person>` is the same dossier as `emunah whois <person>`. Two spellings for
   -- one view because they are reached from different places: `whois` is what you type
   -- about a name that just walked in, `ndb show` is what you type when you are already
   -- inside the database.
   if (arg == "show" or arg == "who" or arg == "whois") and rest then
      M.handlers.whois(rest)
      return
   end

   -- --- the web API --------------------------------------------------------

   if arg == "api" then
      if rest == "on" or rest == "off" then
         ndb.api.enabled = (rest == "on")
         log.info("The Achaea web API is %s.", rest)
         return
      end
      local status = ndb.api.status()
      ndbTitle("achaea web API", status.enabled and "ON" or "OFF")
      decho("\n  " .. dim(ndb.api.HOST))
      ndbGrid({
         { "transport", status.transport },
         { "queued",    status.queued },
         { "cached",    status.cached },
         { "online",    status.online
                          and (status.online .. " (" .. span(status.onlineAge) .. " old)")
                          or "not fetched" },
         { "fetched",   status.counters.ok },
         { "not found", status.counters.missing },
         { "failed",    status.counters.failed },
         { "from cache", status.counters.served },
      })
      decho("\n  " .. faint("emunah ndb api on|off  |  ndb refresh <person>|all  "
         .. "|  ndb online"))
      return
   end

   if arg == "refresh" then
      if not rest or rest:lower() == "all" then
         local queued = 0
         for _, person in ipairs(ndb.list()) do
            if ndb.api.enrich(person.name, nil, true) then queued = queued + 1 end
         end
         log.info("Queued %d lookups, one per second. `emunah ndb api` to watch.", queued)
         return
      end
      ndb.api.enrich(rest, function(person, written, why)
         if person then
            log.info("%s: %d fields from the web API.", person.name, written)
         else
            log.warn("Could not refresh %s: %s", rest, tostring(why))
         end
      end, true)
      return
   end

   if arg == "online" then
      ndb.api.roster(function(online)
         local names = emunah.util.keys(online)
         ndbTitle("online now", tostring(#names))
         local known, unknown = {}, {}
         for _, id in ipairs(names) do
            local canonical = online[id]
            if ndb.known(canonical) then known[#known + 1] = canonical
            else unknown[#unknown + 1] = canonical end
         end
         if #known > 0 then
            decho("\n  " .. dim("known  ") .. theme().dc("text")
               .. table.concat(known, ", "))
         end
         if #unknown > 0 then
            decho("\n  " .. dim("new    ") .. theme().dc("warning")
               .. table.concat(unknown, ", "))
            decho("\n  " .. faint("`emunah ndb learn` records and looks up every "
               .. "name above"))
         end
      end, function(why)
         log.error("Could not reach the web API: %s", tostring(why))
      end, true)
      return
   end

   if arg == "learn" then
      ndb.api.roster(function(online)
         local queued = 0
         for _, canonical in pairs(online) do
            if not ndb.isSelf(canonical) then
               ndb.seen(canonical)
               if ndb.api.enrich(canonical) then queued = queued + 1 end
            end
         end
         log.info("Recorded everyone online; %d queued for lookup.", queued)
      end, function(why)
         log.error("Could not reach the web API: %s", tostring(why))
      end, true)
      return
   end

   -- --- writing -----------------------------------------------------------

   if arg == "set" and rest then
      local name, field, value = rest:match("^(%S+)%s+(%S+)%s*(.*)$")
      if not name then
         log.warn("Usage: emset ndb set <person> <field> <value> -- `emset ndb fields`")
         return
      end
      local ok, why = ndb.set(name, field, value)
      if ok then
         log.info("%s: %s = %s", ndb.get(name).name, field,
            value ~= "" and value or "(cleared)")
      else
         log.warn("%s", tostring(why))
      end
      return
   end

   if arg == "note" and rest then
      local name, text = rest:match("^(%S+)%s+(.+)$")
      if not name then log.warn("Usage: emset ndb note <person> <text>") return end
      ndb.note(name, text)
      log.info("Noted against %s.", ndb.get(name).name)
      return
   end

   if arg == "unnote" and rest then
      local name, index = rest:match("^(%S+)%s*(%d*)$")
      if index == "" then
         -- Dropping every note against someone is as destructive as `ndb forget all`, just
         -- scoped to one person -- ask twice here too, via the same confirm helper.
         local existing = ndb.get(name)
         local count = #ndb.notes(name)
         if count > 0 and not util.confirm("ndb.unnoteAll." .. (existing.name or name):lower()) then
            log.warn("This will drop every note against %s (%d of them). Repeat within 15s "
               .. "to confirm.", existing.name or name, count)
            return
         end
      end
      local ok, why = ndb.unnote(name, index ~= "" and index or nil)
      log.info(ok and ("Dropped %s from %s."):format(
         index ~= "" and ("note " .. index) or "every note", name) or tostring(why))
      return
   end

   if arg == "hostile" then
      if not rest then
         local hostiles = ndb.hostiles()
         ndbTitle("hostile organisations", tostring(#hostiles))
         if #hostiles == 0 then
            decho("\n  " .. dim("none -- everyone outside your own city reads as neutral"))
         end
         for _, org in ipairs(hostiles) do
            decho(string.format("\n  %s%-8s %s%s",
               theme().dc("textDim"), org.kind, theme().dc("affliction"), org.name))
         end
         decho("\n  " .. faint("emunah ndb hostile city Mhaldor | "
            .. "emunah ndb hostile off city Mhaldor"))
         return
      end

      local off = rest:match("^off%s+(.+)$")
      local kind, org = (off or rest):match("^(%S+)%s+(.+)$")
      local ok, why = ndb.setHostile(kind, org, not off)
      log.info(ok and ("%s %s is %s."):format(kind, org, off and "no longer hostile"
         or "hostile") or tostring(why))
      return
   end

   if arg == "forget" and rest then
      if rest:lower() == "all" then
         if util.confirm("ndb.forgetAll") then
            log.warn("Forgot %d people.", ndb.forgetAll())
         else
            log.warn("This will forget %d people, including %d notes you wrote. "
               .. "Repeat within 15s to confirm.", ndb.count(), ndb.stats().noted)
         end
         return
      end
      log.info(ndb.forget(rest) and ("Forgot %s."):format(rest)
         or ("%s was not in the database."):format(rest))
      return
   end

   if arg == "prune" then
      local removed, names = ndb.prune(rest and tonumber(rest) or nil)
      log.info("Pruned %d records carrying nothing but a name%s.", removed,
         rest and (" and unseen for " .. rest .. " days") or "")
      if removed > 0 and removed <= 20 then
         log.info("  %s", table.concat(names, ", "))
      end
      return
   end

   -- --- moving it around ---------------------------------------------------

   if arg == "export" then
      local fields, path = nil, rest
      local list, remainder = (rest or ""):match("^fields%s+(%S+)%s*(.*)$")
      if list then
         fields = emunah.util.split(list, ",")
         path = remainder ~= "" and remainder or nil
      end
      local ok, where = ndb.exportFile(path, { fields = fields, notes = fields == nil })
      if ok then
         log.info("Exported %d records to %s%s.", ndb.count(), where,
            fields and (" (" .. table.concat(fields, ", ") .. " only, no notes)") or "")
      else
         log.error("Export failed: %s", tostring(where))
      end
      return
   end

   if arg == "import" and rest then
      local ok, added, updated = ndb.importFile(rest)
      if ok then
         log.info("Imported: %d new, %d fields filled in. Your own declarations and notes "
            .. "were left alone.", added, updated)
      else
         log.error("Import failed: %s", tostring(added))
      end
      return
   end

   log.warn("Unknown: emunah ndb %s. Try `emunah ndb`, `... stats`, `... fields`, "
      .. "`... capture`.", tostring(arg))
end

--- Why someone stands where they stand. A derived answer nobody can trace is one nobody
--- trusts, and the trace is three words.
local function because(person, standing)
   if person.iff and person.iff ~= "auto" then return "declared by you" end
   if person.cityenemy or person.houseenemy or person.orderenemy then
      local which = {}
      if person.cityenemy then which[#which + 1] = "city" end
      if person.houseenemy then which[#which + 1] = "house" end
      if person.orderenemy then which[#which + 1] = "order" end
      return "enemied to your " .. table.concat(which, ", ")
   end
   if standing == "ally" then return "shares your organisation" end
   if standing == "enemy" then return "in an organisation you marked hostile" end
   return "nothing on record places them for or against you"
end

--- Everything known about one person, as a card.
---
--- The dossier is the one view worth the vertical space: it is read once, about one person,
--- usually because something is about to happen. Everything else in this section is a
--- scanning view, and the split is deliberate -- a roster that tried to show this much per
--- row would show four people per screen.
M.handlers.whois = function(arg)
   if not arg then log.warn("Usage: emset whois <person>") return end
   local ndb = emunah.namedb
   local person = ndb.get(arg)
   if not person then
      log.info("%s is not in the name database. Trying the web API...", arg)
      -- Not being in the database is not the same as not existing, and the API can settle
      -- it in one request. This is the single most common way a record gets created by
      -- hand, so it happens without the user having to know a second command.
      ndb.api.enrich(arg, function(record)
         if record then
            log.info("Found %s. `emunah whois %s`.", record.name, record.name)
         else
            log.warn("The web API does not know a character called %s.", arg)
         end
      end)
      return
   end

   local relation = ndb.relationship(person.name)
   local standing = STANDING[relation] or STANDING.neutral
   local function or_(value, fallback) return value ~= nil and value or (fallback or "-") end

   ndbTitle(person.name, standing.label:upper())
   if person.fullname and person.fullname ~= person.name then
      decho("\n  " .. theme().dc("text") .. person.fullname)
   end

   decho(string.format("\n  %s%-12s%s%-16s%s",
      theme().dc("textDim"), "standing",
      theme().dc(standing.colour), standing.label,
      faint("(" .. because(person, relation) .. ")")))

   ndbRule()
   ndbGrid({
      { "class",     or_(person.class) },
      { "city",      or_(person.city) .. (person.cityrank and person.cityrank > 0
                       and ("  CR" .. person.cityrank) or ""), nameColour(person.name) },
      { "house",     or_(person.house) },
      { "order",     or_(person.order) },
      { "clan",      or_(person.clan) },
      { "level",     or_(person.level) },
      { "xp rank",   or_(person.xprank) },
      { "explorer",  or_(person.explorerrank) },
      { "mob kills", or_(person.mobkills) },
      { "pk",        or_(person.playerkills) },
      -- Might is a ratio against US, not a 0-100 statistic: 510% means five times over.
      { "might",     person.might and (person.might .. "% of yours") or "-" },
      { "importance", or_(person.importance, "0") },
      { "race",      or_(person.race) },
      { "age",       or_(person.age) },
      { "honours",   or_(person.deeds) },
   })
   if person.credibility then
      decho("\n  " .. theme().dc("textDim") .. "credible    "
         .. theme().dc("text") .. person.credibility)
   end
   if person.motto then
      decho("\n  " .. theme().dc("textDim") .. "motto       "
         .. theme().dc("text") .. "'" .. person.motto .. "'")
   end

   -- The flags, on their own line and in the warning tone: these are the facts that change
   -- how you treat someone on sight, and burying them in the grid above would lose them.
   local marks = {}
   if person.dragon then marks[#marks + 1] = "Dragon" end
   if person.mark then
      marks[#marks + 1] = "Mark of " .. emunah.util.capitalise(tostring(person.mark))
   end
   if ndb.infamy(person.name) >= 1 then
      marks[#marks + 1] = "infamy " .. ndb.infamy(person.name)
   end
   if person.immortal then marks[#marks + 1] = "Immortal" end
   for _, org in ipairs({ "city", "house", "order" }) do
      if person[org .. "enemy"] then marks[#marks + 1] = org .. " enemy" end
   end
   if #marks > 0 then
      decho("\n  " .. theme().dc("warning") .. table.concat(marks, faint("   ")))
   end

   -- Where they were, last time anything told us. The most perishable thing in the record
   -- and often the only one that matters, so it gets its own line with an explicit age.
   if person.sensed then
      ndbRule()
      decho(string.format("\n  %s%-12s%s%s%s",
         theme().dc("textDim"), "last sensed", theme().dc("text"),
         person.sensed.where or "?",
         person.sensed.health and string.format("   %d hp / %d mp",
            person.sensed.health, person.sensed.mana or 0) or ""))
      decho(faint("   " .. ago(person.sensed.at) .. " ago"))
   end

   -- What HONOURS said that nobody has established the meaning of -- "He is one of The
   -- Dauntless.", "She is a Dominion in Mhaldor." Shown verbatim, under a heading that says
   -- so. The alternative to displaying these is guessing at them or losing them, and this
   -- is neither.
   if person.honours and #person.honours > 0 then
      ndbRule()
      decho("\n  " .. faint("from HONOURS, not interpreted:"))
      for _, line in ipairs(person.honours) do
         decho("\n    " .. theme().dc("textDim") .. line)
      end
   end

   local notes = ndb.notes(person.name)
   if #notes > 0 then
      ndbRule()
      for index, note in ipairs(notes) do
         decho(string.format("\n  %s%-2d %s%s",
            theme().dc("inactive"), index, theme().dc("text"), note.text))
      end
   end

   ndbRule()
   -- Provenance. "The database says Mhaldor" and "the database said Mhaldor five weeks ago
   -- and has not been able to check since" are different claims, and only one of them is
   -- worth acting on.
   local freshness
   if not person.api then
      freshness = "never looked up"
   elseif person.api.ok then
      freshness = "web API " .. ago(person.api.at) .. " ago"
   else
      freshness = "web API failed " .. ago(person.api.at) .. " ago: "
         .. tostring(person.api.why)
   end
   decho(string.format("\n  %sseen %s ago%s   %s%s",
      theme().dc("textDim"), ago(person.seen),
      person.sightings and (", " .. person.sightings .. " time"
         .. (person.sightings == 1 and "" or "s")) or "",
      faint(freshness),
      person.highlight == false and faint("   [not highlighted]") or ""))
   decho("\n  " .. faint("emunah ndb note " .. person.name .. " <text>  |  emunah iff "
      .. person.name .. " ally|enemy|auto  |  emunah ndb refresh " .. person.name))
end

--- Declare a relationship. The one thing in the database that beats derivation.
M.handlers.iff = function(arg, rest)
   if not (arg and rest) then
      log.warn("Usage: emset iff <person> ally|enemy|auto")
      return
   end
   local ok, why = emunah.namedb.iff(arg, rest)
   if not ok then log.warn(tostring(why)) end
end

--- Name highlighting in the game text.
M.handlers.names = function(arg, rest)
   local names = emunah.ui.names
   arg = arg and arg:lower() or nil

   if arg == "on" then names.start() emunah.config.save() return end
   if arg == "off" then names.stop() emunah.config.save() return end

   if arg == "ignore" and rest then
      local ok, why = names.ignore(rest, true)
      log.info(ok and ("%s will not be highlighted."):format(rest) or tostring(why))
      emunah.config.save()
      return
   end

   if arg == "unignore" and rest then
      local ok, why = names.ignore(rest, false)
      log.info(ok and ("%s will be highlighted again."):format(rest) or tostring(why))
      return
   end

   if arg == "tint" and rest then
      emunah.config.set("names.cityTint", rest:lower() == "on")
      emunah.config.save()
      log.info("Neutral names are %s.", rest:lower() == "on"
         and "tinted by city" or "all one tone")
      return
   end

   ndbTitle("name highlighting", names.enabled and "ON" or "OFF")
   decho("\n  " .. dim("colour says standing or city; weight says what is unusual"))
   for _, entry in ipairs({
      { "enemy", "affliction", "bold" },
      { "ally", "defence" },
      { "neutral, city unknown", "textDim" },
   }) do
      decho(string.format("\n  %s%-24s %s",
         theme().dc(entry[2]), entry[1], faint(entry[3] or "")))
   end
   for _, city in ipairs(emunah.namedb.CITIES) do
      decho(string.format("\n  %s%-24s %s", hexdc(names.cityColour[city:lower()]), city,
         faint(emunah.config.get("names.cityTint", true) and "" or "(tint off)")))
   end
   ndbRule()
   decho("\n  " .. dim("bold   dragon, or an importance you set"))
   decho("\n  " .. dim("under  a Mark"))
   decho("\n  " .. dim("italic infamous"))

   local ignored = names.ignored()
   if #ignored > 0 then
      ndbRule()
      decho("\n  " .. dim("ignored: ") .. theme().dc("text") .. table.concat(ignored, ", "))
   end
   decho("\n  " .. faint("emunah names on|off | ignore <person> | unignore <person> "
      .. "| tint on|off"))
end

M.handlers.gmcp = function(arg)
   if arg == "refresh" then
      emunah.gmcp.refresh()
      log.info("Requested a full GMCP refresh.")
      return
   end
   header("GMCP state")
   display(emunah.gmcp.snapshot())
end

M.handlers.have = function(arg)
   if arg then
      -- Ad-hoc lookup: `emunah have kelp` answers the question the engine asks.
      header("have " .. arg)
      row("skill", emunah.have.skill(arg) and "yes" or "no")
      row("in inventory", emunah.have.item(arg))
      row("in rift", emunah.have.inRift(arg))
      row("defence up", emunah.have.def(arg) and "yes" or "no")
      return
   end
   header("Capabilities")
   local report = emunah.have.report()
   row("skills indexed", report.skillsIndexed and "yes" or "no")
   row("inventory items", report.inventory)
   row("rift entries", report.riftEntries)
   for vector, ready in pairs(report.balances) do
      local blocked = report.blocked[vector]
      row(vector, blocked and ("BLOCKED by " .. blocked) or (ready and "ready" or "recovering"),
         blocked and "ansi_light_red" or (ready and "ansi_light_green" or "ansi_yellow"))
   end
end

M.handlers.learn = function(arg)
   local detect = emunah.curing.detect
   if arg == "on" then detect.startLearning()
   elseif arg == "off" then detect.stopLearning()
   else detect.toggleLearning() end
end

M.handlers.affpop = function(arg)
   local detect = emunah.curing.detect
   if arg == "on" then detect.startWalk()
   elseif arg == "off" then detect.stopCapture()
   else detect.toggleWalk() end
end

M.handlers.detect = function()
   local coverage = emunah.curing.detect.coverage()
   header("Detection coverage")
   row("afflictions known", coverage.totalKnown)
   row("with gain patterns", coverage.withGain)
   row("with cure patterns", coverage.withCure)
   cecho("\n  <ansi_light_black>GMCP covers the rest. Use 'emunah learn on' to grow the pattern set.<reset>")
end

M.handlers.ui = function(arg, rest)
   if arg == "rebuild" then
      emunah.ui.layout.build()
      log.info("UI rebuilt.")
   elseif arg == "reset" then
      -- For a panel that is off-screen, zero-sized, or stuck hidden by saved state.
      emunah.ui.layout.reset()
   elseif arg == "show" then
      emunah.ui.layout.show()
      log.info("UI shown.")
   elseif arg == "map" then
      local map = emunah.ui.map
      -- Bare `emunah ui map` REPORTS rather than toggles. Toggling on a bare word is a
      -- trap: the natural thing to type when the map is missing is `emunah ui map`, and
      -- if that flipped the setting it would turn the map off and look like confirmation
      -- that it is broken.
      if rest == "on" then
         map.setEnabled(true)
      elseif rest == "off" then
         map.setEnabled(false)
      elseif rest == "centre" or rest == "center" then
         map.centre()
      elseif rest == "rebuild" then
         map.build(); map.show()
         log.info("Map rebuilt.")
      elseif rest == "float" then
         map.float()
      elseif rest == "embed" then
         map.embed()
      elseif rest == "raw" then
         map.raw()
      elseif rest and rest:match("^height%s") then
         map.setHeight(rest:match("^height%s+(%S+)"))
      else
         local d = map.diagnose()
         header("Map")
         row("setting ui.map", tostring(d.setting), d.setting and "ansi_light_green" or "ansi_light_red")
         row("Geyser", d.hasGeyser and "yes" or "no", d.hasGeyser and "reset" or "ansi_light_red")
         row("Geyser.Mapper", d.hasMapper and "yes" or "no", d.hasMapper and "reset" or "ansi_light_red")
         row("createMapper()", d.hasCreate and "yes" or "no", d.hasCreate and "reset" or "ansi_light_red")
         row("right container", d.hasContainer and "yes" or "no", d.hasContainer and "reset" or "ansi_light_red")
         row("widget created", d.widget and "yes" or "no", d.widget and "ansi_light_green" or "ansi_light_red")
         if d.widget then
            row("embedded", tostring(d.embedded), d.embedded and "reset" or "ansi_yellow")
            row("hidden", tostring(d.hidden), d.hidden and "ansi_light_red" or "reset")
            row("geometry", string.format("x=%s y=%s w=%s h=%s",
               tostring(d.x), tostring(d.y), tostring(d.width), tostring(d.height)))
         end
         if d.containerW then
            row("container", string.format("x=%s y=%s w=%s h=%s",
               tostring(d.containerX), tostring(d.containerY),
               tostring(d.containerW), tostring(d.containerH)))
         end

         -- The decisive line: a healthy widget over an empty database looks exactly like
         -- a widget that never appeared.
         local hasData = (d.rooms or 0) > 0
         row("areas in map", tostring(d.areas or "?"), hasData and "reset" or "ansi_light_red")
         row("rooms in map", tostring(d.rooms or "?"), hasData and "ansi_light_green" or "ansi_light_red")
         row("current room", tostring(d.currentRoom or "-"))
         row("room on map", tostring(d.currentRoomKnown),
            d.currentRoomKnown and "ansi_light_green" or "ansi_yellow")

         if not hasData then
            cecho("\n  <ansi_light_red>Your Mudlet map database is empty -- there is nothing to draw.<reset>")
            cecho("\n  <ansi_light_black>Download Achaea's map first; the widget itself is fine.<reset>")
         end
         local px = { emunah.ui.map.pixels() }
         row("raw px would be", string.format("x=%d y=%d w=%d h=%d", px[1], px[2], px[3], px[4]))
         row("region height", emunah.ui.layout.mapHeightPct() .. "% of window")
         cecho("\n  <ansi_light_black>emunah ui map height <n>|on|off|rebuild|centre|float|embed|raw<reset>")
         cecho("\n  <ansi_light_black>'raw'   calls createMapper directly, bypassing Geyser (decisive test)<reset>")
         cecho("\n  <ansi_light_black>'float' detaches it into its own dock widget<reset>")
      end
   else
      local enabled = emunah.ui.layout.toggle()
      log.toggled("UI", enabled)
   end
end

M.handlers.set = function(arg, rest)
   if not arg then
      header("Settings")
      display(emunah.config.data)
      return
   end
   if rest == nil then
      row(arg, tostring(emunah.config.get(arg, "(unset)")))
      return
   end
   -- Coerce the obvious types so `emunah set curing.confirmWait 1.5` stores a number.
   local value = rest
   if rest == "true" then value = true
   elseif rest == "false" then value = false
   elseif tonumber(rest) then value = tonumber(rest) end

   emunah.config.set(arg, value)
   emunah.config.save()
   log.info("%s = %s", arg, tostring(value))
end

M.handlers.prio = function(affliction, rest)
   if not affliction or not rest then
      log.warn("Usage: emset prio <affliction> <vector> <rank>")
      return
   end
   local vector, rank = rest:match("^(%S+)%s+(%d+)$")
   if not vector then
      log.warn("Usage: emset prio <affliction> <vector> <rank>")
      return
   end
   local priorities = emunah.config.get("priorities", {})
   priorities[affliction:lower()] = priorities[affliction:lower()] or {}
   priorities[affliction:lower()][vector] = tonumber(rank)
   emunah.config.set("priorities", priorities)
   emunah.config.save()
   log.info("%s via %s is now priority %s", affliction, vector, rank)
end

M.handlers.walk = function(arg, rest)
   local walker = emunah.walker
   if arg == "start" or arg == "area" then
      walker.start()
   elseif arg == "stop" then
      if not walker.stop("requested") then log.info("Walk was not running.") end
   elseif arg == "pause" then
      walker.pause()
   elseif arg == "resume" then
      walker.resume()
   elseif arg == "move" or arg == "next" then
      walker.move()
   elseif arg == "avoid" then
      if walker.avoidRoom(rest) then
         log.info("Avoiding room %s.", tostring(rest))
      end
   elseif arg == "unavoid" then
      walker.unavoidRoom(rest)
   elseif arg == "auto" then
      -- Exact match only. This used to be `walker.setAuto(rest ~= "off")`, so ANY argument
      -- other than the literal word "off" -- a typo, a stray word, even no argument at all
      -- -- silently turned auto-stepping on. Every other on/off pair in this file (cure,
      -- bash, pvp, keys, loot, pipes) already requires an exact match; this one now does too.
      if rest == "on" then walker.setAuto(true)
      elseif rest == "off" then walker.setAuto(false)
      else log.warn("Usage: emset walk auto on|off") end
   elseif arg == "delay" then
      walker.setDelay(rest)
   elseif arg == "return" then
      walker.config.returnToStart = not walker.config.returnToStart
      log.info("Return to start: %s", tostring(walker.config.returnToStart))
   else
      local report = walker.report()
      header("Walker")
      row("running", report.running and (report.paused and "paused" or "yes") or "no")
      row("area", tostring(report.area or "-"))
      row("remaining", report.remaining)
      row("visited", report.visited)
      row("unreachable", report.failed)
      row("avoided rooms", report.avoided)
      row("paced by", tostring(report.claimedBy or "itself"),
         report.claimedBy and "ansi_cyan" or "reset")
      row("auto-step", emunah.config.get("walker.auto", true) and "on" or "off",
         emunah.config.get("walker.auto", true) and "ansi_light_green" or "ansi_yellow")
      row("step delay", emunah.config.get("walker.stepDelay", 0.6) .. "s")
      if report.running then row("elapsed", util.duration(report.elapsed)) end
      cecho("\n  <ansi_light_black>emunah walk start|stop|pause|resume|move|auto on|off|delay <s>|avoid <id><reset>")
   end
end

M.handlers.debug = function(arg)
   if arg == "handlers" then
      header("Event handlers")
      display(emunah.event.list())
   elseif arg == "timers" then
      header("Timers")
      display(emunah.timers.list())
   elseif arg == "queue" then
      header("Queue")
      display(emunah.queue.snapshot())
   elseif arg == "gmcp" then
      emunah.log.traceGmcp = not emunah.log.traceGmcp
      log.toggled("GMCP tracing", emunah.log.traceGmcp,
         emunah.log.traceGmcp and " Every message sent and received." or nil)
   else
      local on = emunah.log.level ~= "debug"
      emunah.log.setLevel(on and "debug" or "info")
      log.toggled("Debug logging", on,
         on and " Includes every command sent to the game." or nil)
   end
end

--- Walk and kill: the two together, which is what "go hunting" means. Kept separate
--- underneath because each is useful alone (clear one room; explore without fighting).
M.handlers.hunt = function(arg)
   if arg == "off" or arg == "stop" then
      -- Both return false with no message when they were already stopped -- which is
      -- exactly the state a safety stop leaves them in. Without this, `emunah hunt off`
      -- issued after one had already fired produced no output at all, and read as the
      -- command having failed rather than there being nothing left to stop.
      local stoppedBash = emunah.bashing.stop("requested")
      local stoppedWalk = emunah.walker.stop("requested")
      if not stoppedBash and not stoppedWalk then
         log.info("Hunt was not running.")
      end
      return
   elseif arg and arg ~= "start" then
      -- Documented syntax is exactly `emset hunt [off]` (help.lua). Anything else used to
      -- fall through to the start branch below -- a typo like `emset hunt stpo` silently
      -- started bashing and walking instead of erroring, the same asymmetry `defs` and
      -- `walk auto` had: stopping required an exact word, starting accepted anything.
      log.warn("Unknown: emset hunt %s. Try `emset hunt` or `emset hunt off`.", tostring(arg))
      return
   end
   -- Walker first: bashing runs a tick as it starts, and that tick decides whether the
   -- room is clear and whether to hand movement on. With no walk running yet it has
   -- nothing to hand to.
   if not emunah.walker.enabled then
      if not emunah.walker.start() then return end
   end
   if not emunah.bashing.start() then
      emunah.walker.stop("bashing would not start")
   end
end

M.handlers.bash = function(arg, rest)
   local bash = emunah.bashing
   if arg == "on" or arg == "start" then bash.start()
   elseif arg == "off" or arg == "stop" then
      if not bash.stop("requested") then log.info("Bashing was not running.") end
   elseif arg == "attack" and rest then
      -- A quoted multi-word command is the natural thing to type, but the dispatcher never
      -- strips quotes (see M.dispatch) and Achaea itself treats a leading `"` as SAY
      -- shorthand. Confirmed live: `emunah bash attack "angel sear"` stored the quotes
      -- literally, so every attack went out as `"angel sear" <id>` and Achaea read it as
      -- `say Angel sear <id>` rather than the ability -- "You say, "Angel sear" 235781."
      -- Strip one matching pair before storing, so quoting or not both do the right thing.
      local command = rest:match('^"(.+)"$') or rest:match("^'(.+)'$") or rest
      emunah.config.set("bashing.attack", command); emunah.config.save()
      log.info("Attack command: %s", command)
   elseif arg == "balance" and rest then
      if rest ~= "eq" and rest ~= "bal" and rest ~= "both" then
         log.warn("Usage: emset bash balance eq|bal|both")
      else
         emunah.config.set("bashing.balance", rest); emunah.config.save()
         log.info("Attack uses: %s", rest)
      end
   elseif arg == "consumes" and rest then
      if rest ~= "eq" and rest ~= "bal" then
         log.warn("Usage: emset bash consumes eq|bal")
      else
         emunah.config.set("bashing.consumes", rest); emunah.config.save()
         log.info("Attack spends: %s", rest)
      end
   elseif arg == "health" and rest then
      emunah.config.set("bashing.stopBelowHealth", tonumber(rest) or 50); emunah.config.save()
      log.info("Stops below %s%% health.", rest)
   else
      local r = bash.report()
      header("Bashing")
      row("running", r.running and "yes" or "no", r.running and "ansi_light_green" or "reset")
      row("class module", tostring(r.classLoaded or "NONE"),
         r.classLoaded and "ansi_light_green" or "ansi_light_red")
      row("attack", r.attack .. " <replica>")
      row("costs", r.balance)
      row("spends", r.consumes)
      row("current target", tostring(r.target or "-"))
      row("target health", r.targetHealth and (r.targetHealth .. "%") or "-")
      -- nil means its health is not moving, which is the useful reading: the attack is
      -- wrong for this creature rather than merely slow.
      row("kill in", r.killIn and (r.killIn .. " more") or "unknown",
         r.killIn and "reset" or "ansi_yellow")
      row("here to kill", r.pending)
      row("killed", r.killed)
      row("attacks sent", r.attacks)
      row("damage dealt", r.dealt)
      row("damage taken", r.taken)
      row("rooms cleared", r.rooms)
      if r.running then row("elapsed", util.duration(r.elapsed)) end
      cecho("\n  <ansi_light_black>emunah bash on|off|attack <cmd>|balance eq|bal|both|consumes eq|bal|health <n><reset>")
      row("walker", emunah.walker.enabled and "running" or "stopped",
         emunah.walker.enabled and "ansi_light_green" or "ansi_yellow")
      row("room items", emunah.gmcp.items.roomFresh() and "current" or "WAITING",
         emunah.gmcp.items.roomFresh() and "ansi_light_green" or "ansi_yellow")
      cecho("\n  <ansi_light_black>emunah hunt  = walk + bash together<reset>")
   end
end

M.handlers.pvp = function(arg, rest)
   local pvp = emunah.pvp
   if arg == "on" or arg == "start" then pvp.start()
   elseif arg == "off" or arg == "stop" then pvp.stop("requested")
   elseif arg == "target" and rest then
      if rest == "off" or rest == "clear" or rest == "none" then
         pvp.clearTarget()
      else
         pvp.setTarget(rest)
      end
   elseif arg == "attack" and rest then
      emunah.config.set("pvp.attackAtAfflictions", tonumber(rest) or 2); emunah.config.save()
      log.info("Attack withheld until the opponent has %s+ tracked afflictions.", rest)
   else
      local r = pvp.report()
      header("PvP")
      row("running", r.running and "yes" or "no", r.running and "ansi_light_green" or "reset")
      row("class module", tostring(r.classLoaded or "NONE"),
         r.classLoaded and "ansi_light_green" or "ansi_light_red")
      row("target", tostring(r.target or "none -- set one with 'emunah pvp target <name>'"))
      if r.target then
         local afflictions = emunah.curing.detect.opponent.list(r.target)
         row("target afflictions", #afflictions > 0 and table.concat(afflictions, ", ") or "-")
      end
      row("attacks sent", r.attacks)
      row("verses recited", r.recited)
      if r.running then row("elapsed", util.duration(r.elapsed)) end
      local here = emunah.gmcp.room.playerNames()
      row("players here", #here > 0 and table.concat(here, ", ") or "-",
         "ansi_light_black")
      cecho("\n  <ansi_light_black>emunah pvp on|off|target <name>|target off|attack <n>  -- never auto-targets<reset>")
   end
end

M.handlers.loot = function(arg)
   if arg == "on" then emunah.loot.setEnabled(true)
   elseif arg == "off" then emunah.loot.setEnabled(false)
   elseif arg == "now" then
      local n = emunah.loot.sweep()
      log.info("Swept the room: %d item(s) taken.", n)
   else
      header("Loot")
      row("gold pickup", emunah.config.get("loot.gold", true) and "on" or "off",
         emunah.config.get("loot.gold", true) and "ansi_light_green" or "ansi_light_red")
      row("picked up", emunah.loot.stats.picked)
      cecho("\n  <ansi_light_black>emunah loot on|off|now<reset>")
   end
end

M.handlers.shop = function(arg, rest)
   local shop = emunah.shop
   if arg == "limit" then
      if rest == "off" or rest == nil then
         shop.setConfirmAbove(nil)
         log.info("Shop: confirm limit cleared.")
      else
         local gp = tonumber(rest)
         if not gp then
            log.warn("Usage: emset shop limit <gp>|off")
            return
         end
         shop.setConfirmAbove(gp)
         log.info("Shop: purchases over %dgp will be held rather than sent.", gp)
      end
   elseif arg == "spent" then
      header("Shop spending this session")
      row("total", shop.ledger.total .. "gp")
      row("purchases", shop.ledger.count)
      for _, entry in ipairs(shop.ledger.log) do
         row(entry.id, string.format("%s x%d -- %dgp (%s ago)",
            entry.desc, entry.qty, entry.cost, span(emunah.util.now() - entry.time)))
      end
   else
      -- Default: redraw the most recently seen shop, in case it scrolled off screen.
      -- `arg` doubles as an explicit proprietor name for `emunah shop <name>`.
      local name = arg or shop.current
      local items = shop.list(name)
      if #items == 0 then
         cecho("\n  <ansi_light_black>No shop seen yet this session -- stand in one and "
            .. "type WARES.<reset>")
         return
      end
      header(name or "Shop")
      local category = nil
      for _, item in ipairs(items) do
         if item.category ~= category then
            category = item.category
            if category then cecho("\n  <ansi_light_black>-- " .. category .. "<reset>") end
         end
         row(item.id, string.format("%s (%d in stock, %d%s%s)",
            item.desc, item.stock, item.price, item.currency, item.bulk and " ea" or ""))
      end
      cecho("\n  <ansi_light_black>emunah shop spent | emunah shop limit <gp>|off<reset>")
   end
end

M.handlers.pipes = function(arg)
   local pipes = emunah.pipes
   if arg == "on" then pipes.start()
   elseif arg == "off" then pipes.stop()
   elseif arg == "now" then pipes.poll(true, true)
   else
      local on = emunah.config.get("pipes.enabled", true) ~= false
      header("Pipes")
      row("keep-up", on and "on" or "off", on and "ansi_light_green" or "ansi_light_red")
      local list = pipes.list()
      if #list == 0 then
         row("state", "not seen yet -- 'emunah pipes now'")
      end
      for _, pipe in ipairs(list) do
         row(pipe.token, string.format("%-4s %-22s %d puffs",
            pipe.status, pipe.herb or pipe.contents, pipe.puffs),
            pipe.status == "lit" and "ansi_light_green" or "ansi_yellow")
      end
      cecho("\n  <ansi_light_black>emunah pipes on|off|now<reset>")
   end
end

M.handlers.mobs = function(arg, rest)
   local den = emunah.denizens
   local area = den.area()

   if arg == "add" and rest then
      den.add(rest, area); den.save()
      log.info("Added %q to %s.", rest, tostring(area))
   elseif (arg == "remove" or arg == "forget") and rest then
      log.info(den.remove(rest, area) and "Forgot %q." or "%q was not recorded.", rest)
   elseif arg == "skip" and rest then
      -- Keeps it recorded but off the kill list, so auto-record does not re-add it.
      log.info(den.setWanted(rest, false, area) and "Skipping %q." or "%q not recorded here.", rest)
   elseif arg == "kill" and rest then
      log.info(den.setWanted(rest, true, area) and "Will kill %q." or "%q not recorded here.", rest)
   elseif arg == "here" then
      header("Denizens here")
      local here = den.here()
      if #here == 0 then
         cecho("\n  <ansi_light_black>none (or none flagged as creatures by GMCP)<reset>")
      end
      for _, d in ipairs(here) do
         local state = den.isEngaged(d.id) and "  [done]" or ""
         local colour = "ansi_light_black"
         if den.wanted(d.name) then
            colour = den.isEngaged(d.id) and "ansi_yellow" or "ansi_light_green"
         end
         row(d.id, d.name .. state, colour)
      end
      cecho("\n  <ansi_light_black>left column is the REPLICA NUMBER -- target that, never the name<reset>")
      cecho("\n  <ansi_light_black>green = to kill, yellow = already dealt with, grey = skipped<reset>")
   elseif arg == "target" then
      if not den.target() then log.warn("Nothing here left to kill.") end
   elseif arg == "done" then
      -- Mark the current target dealt with so the next target() picks a different one.
      local t = den.next()
      if t then den.engage(t.id); log.info("Marked %s (%s) done.", t.name, t.id) end
   elseif arg == "reset" then
      den.clearEngaged()
      log.info("Cleared the dealt-with list for this room.")
   elseif arg == "areas" then
      header("Areas with recorded denizens")
      for _, name in ipairs(den.areaNames()) do
         row(name, #den.forArea(name) .. " kinds")
      end
   else
      header("Denizens -- " .. (area or "unknown area"))
      local list = den.forArea(area)
      if #list == 0 then
         cecho("\n  <ansi_light_black>nothing recorded here yet<reset>")
      end
      for _, entry in ipairs(list) do
         local hereNow = den.hereCount(entry.name)
         row(entry.name, string.format("killed %d%s%s",
            entry.killed or 0,
            hereNow > 0 and ("   here " .. hereNow) or "",
            entry.wanted == false and "   [skip]" or ""),
            entry.wanted == false and "ansi_light_black" or "ansi_light_green")
      end
      row("here now", den.count() .. " to kill")
      cecho("\n  <ansi_light_black>emunah mobs here|target|done|reset|add|skip|kill|forget|areas<reset>")
   end
end

M.handlers.keys = function(arg)
   local keys = emunah.keys
   if arg == "on" then keys.setEnabled(true)
   elseif arg == "off" then keys.setEnabled(false)
   elseif arg == "rebuild" then
      local ok = keys.build()
      local okActions = keys.buildActions()
      log.info("Numpad rebuild: %s (%d bindings). Action keys: %s (%d bindings).",
         ok and "ok" or "failed", keys.count(),
         okActions and "ok" or "failed", keys.actionCount())
   else
      header("Numpad movement (" ..
         (emunah.config.get("keys.numpad", true) and "on" or "off") .. ")")
      -- The count is the honest answer to "are my keys working", and zero with the
      -- setting on is the state that used to be invisible.
      local active = keys.count()
      row("bindings active", active, active == 0 and "ansi_light_red" or "ansi_light_green")
      if active == 0 and emunah.config.get("keys.numpad", true) then
         cecho("\n  <ansi_light_red>enabled but nothing is bound<reset> "
            .. "<ansi_light_black>-- emunah keys rebuild<reset>")
      end
      cecho("\n  <ansi_light_black>  7 nw    8 n     9 ne<reset>")
      cecho("\n  <ansi_light_black>  4 w     5 look  6 e<reset>")
      cecho("\n  <ansi_light_black>  1 sw    2 s     3 se<reset>")
      cecho("\n  <ansi_light_black>  0 in    . out   + up   - down<reset>")
      cecho("\n  <ansi_light_black>bound for both Num Lock states; a movement key stops the walker<reset>")
      cecho("\n  <ansi_light_black>emunah keys on|off|rebuild<reset>")
      -- Independent of the numpad toggle above -- see keys.buildActions().
      cecho(("\n  <ansi_light_black>action keys (%d bound): Ctrl+F5 reload, "
         .. "F11 hunt on, F12 hunt off<reset>"):format(keys.actionCount()))
   end
end

M.handlers.reload = function()
   emunahReload()
end

--- Bare `!` (or bare `emunah`): the thing most people actually see, most often, so it
--- stays short. The full reference used to be printed here instead -- forty-odd lines for
--- someone who typed nothing but the prefix -- which is what made it worth splitting.
---
--- Rendered from help.lua's data rather than a list kept here, because the list kept here
--- had already drifted from the commands it described and nothing could tell.
M.handlers.quick = function()
   emunah.help.renderQuick()
end

--- `! help` (or `emunah help`): everything, grouped by what it is for rather than one
--- alphabetical wall -- the flat version was the actual complaint this replaced.
--- `emunah chyron <text>`: queue an announcement on the scrolling strip at the top of the
--- console. The manual entry point to the same M.send() anything else in the codebase would
--- call programmatically -- see ui/chyron.lua.
M.handlers.chyron = function(arg, rest)
   if arg == "clear" then
      emunah.ui.chyron.clear()
      log.info("Chyron cleared.")
      return
   end
   local text = util.trim((arg or "") .. (rest and (" " .. rest) or ""))
   if text == "" then
      log.warn("Usage: emset chyron <text> | emset chyron clear")
      return
   end
   emunah.ui.chyron.send(text)
end

--- `! help` / `emunah help`: the same index `emhelp` prints.
---
--- Kept as a handler because it is what the system has always answered to, and because
--- `emunah help` reads better inside a script than `emhelp` does. It USED to be sixty-odd
--- lines of hardcoded `cecho` here -- forty-one entries against thirty-three handlers, with
--- no per-command detail, no settings at all, and no way for anything to notice when it
--- fell behind. See help.lua's header for what replaced it and why.
M.handlers.help = function(arg, rest)
   emunah.help.render(util.trim((arg or "") .. (rest and (" " .. rest) or "")))
end

-- ---------------------------------------------------------------------------
-- dispatch
-- ---------------------------------------------------------------------------

function M.dispatch(input)
   input = util.trim(input or "")
   if input == "" then
      M.handlers.quick()
      return
   end

   local command, remainder = input:match("^(%S+)%s*(.*)$")
   command = (command or ""):lower()
   remainder = util.trim(remainder)

   local handler = M.handlers[command]
   if not handler then
      log.warn("Unknown command %q. Try 'emunah' for the quick list, or 'emhelp' for everything.",
         command)
      return
   end

   -- Handlers take (first argument, everything after it).
   local first, rest = remainder:match("^(%S+)%s*(.*)$")
   rest = (rest and rest ~= "") and rest or nil

   local ok, err = pcall(handler, first, rest)
   if not ok then
      log.error("Command %q failed: %s", command, tostring(err))
   end
end

killAll()

-- tempAlias takes a PCRE REGEX, not a Lua pattern.
--
-- This is easy to get wrong because the rest of the codebase uses Lua patterns and they
-- look similar. `^emunah%s*(.*)$` is a valid Lua pattern but as a regex it means "emunah"
-- followed by a literal `%` and zero-or-more `s` -- so a bare `emunah` does not match, the
-- alias never fires, and the word is sent to the game, which replies "Emunah is not a
-- valid command". Whitespace is `\s` here, never `%s`.
table.insert(registry(), tempAlias([[^emunah\s*(.*)$]], function()
   M.dispatch(matches[2])
end))

-- `emset` is the short form of the same prefix. `!` USED to be, and is gone -- not
-- deprecated, removed, and the tests assert it now falls through to the game untouched.
--
-- Why a word rather than punctuation: `emset` sits in the `em` family this package already
-- owns -- `emhelp`, `emdefs`, `emreload`. Punctuation was a separate vocabulary that had to
-- be explained on its own ("`!` and `emunah` are the same thing"), and every document
-- describing a command had to pick one of the two. They picked differently, which is how the
-- in-game help came to say `!` while the website said `emunah`.
--
-- `emunah` remains the long form, and is what appears in comments, log lines and scripts.
-- `emset` is what you type.
--
-- NOT CONFIRMED FREE IN ACHAEA. `!` was checked against the game before being wired up (it
-- binds nothing there, unlike some MUD clients); `EMSET` has not been. If Achaea does claim
-- it, this is a one-line change -- and until it is confirmed, read a strange response to
-- `emset <something>` as this alias swallowing a real game command rather than as a bug in
-- the dispatcher.
--
-- Two aliases rather than one with an optional group, for the reason recorded at the pipes
-- aliases below: tempAlias takes a PCRE regex, but the test mock translates it to a Lua
-- pattern, and Lua patterns have no `(?:...)`.
table.insert(registry(), tempAlias([[^\s*emset\s+(.+)$]], function()
   M.dispatch(matches[2])
end))

table.insert(registry(), tempAlias([[^\s*emset\s*$]], function()
   M.dispatch("")
end))

-- `emhelp ...`, the command reference, without the prefix.
--
-- Its own alias rather than only `! help` because it is the one command someone types
-- BEFORE they know that `!` is the prefix -- and a help system you have to already know the
-- syntax of to reach is not much of one. Prefixed `em` rather than named `help` on its own
-- for the reason this whole file funnels through `emunah`: Achaea has a large command
-- vocabulary and HELP is very much part of it.
--
-- Two aliases rather than one with an optional group, for the reason recorded at the pipes
-- aliases below: tempAlias takes a PCRE regex, but the test mock translates it to a Lua
-- pattern, and Lua patterns have no `(?:...)`.
table.insert(registry(), tempAlias([[^\s*emhelp\s+(.+)$]], function()
   emunah.help.render(matches[2])
end))

table.insert(registry(), tempAlias([[^\s*emhelp\s*$]], function()
   emunah.help.render("")
end))

-- Short form for the thing you toggle most in a fight -- curing and defence keep-up
-- together (M.handlers.pause above). Used to be `ec` / curing alone; folded together
-- because pausing curing without pausing keep-up left defences still going up mid-pause.
table.insert(registry(), tempAlias("^pp$", function()
   M.handlers.pause()
end))

-- The defence grid, as one word. `emunah defs` remains the scriptable form; this is the one
-- you actually type, because the grid is a thing you sit and click at rather than a report
-- you read.
--
-- Prefixed `em` rather than named `defs` on its own: Achaea has a large command vocabulary
-- and colliding with it is easy, which is the whole reason commands.lua funnels through
-- `emunah` in the first place.
table.insert(registry(), tempAlias([[^\s*emdefs\s*$]], function()
   M.handlers.keepup()
end))

-- `ndb ...` without the prefix. The name database is consulted mid-fight, about a name that
-- just walked in, and five extra keystrokes at that moment is the difference between
-- looking someone up and not bothering. Everything `emunah ndb` accepts works here,
-- including `ndb show <person>`.
--
-- Two aliases rather than one with an optional group, for the reason recorded at the pipes
-- aliases below: tempAlias takes a PCRE regex, but the test mock translates it to a Lua
-- pattern, and Lua patterns have neither alternation nor `(?:...)`.
table.insert(registry(), tempAlias([[^\s*ndb\s+(.+)$]], function()
   M.dispatch("ndb " .. matches[2])
end))

table.insert(registry(), tempAlias([[^\s*ndb\s*$]], function()
   M.handlers.ndb()
end))

-- SLEEP, typed on its own.
--
-- The one place this file deliberately shadows an Achaea command rather than hiding behind
-- the `emunah` prefix -- because the collision IS the mechanism. The character has to sleep
-- from time to time, and being asleep is otherwise indistinguishable from an opponent
-- having put you there: same affliction, same GMCP payload, same blocked state. The only
-- evidence that a sleep was wanted is that you asked for it a moment earlier, and this is
-- where that evidence exists.
--
-- Anchored to SLEEP ALONE. `sleep` with an argument is a different command with different
-- consequences, and a system that swallowed those into a pass-through would be guessing at
-- syntax it has never seen. Anything that is not a bare SLEEP falls through to the game
-- untouched, as it should.
--
-- The command still goes to the game: this records intent, it does not replace the verb.
-- curing/detect decides what to do with that intent when (and only if) a sleep actually
-- lands -- see M.SLEEP_INTENT for why a refused SLEEP has to be able to lapse.
-- Pipe keep-up, as a bare command. `emunah pipes ...` does the same thing; this is the short
-- form for the one thing you actually toggle, in the same spirit as `pp`.
--
-- Three aliases rather than one with an optional group: tempAlias takes a PCRE regex, but
-- test/mock_mudlet.lua translates those to Lua patterns to match them, and Lua patterns have
-- neither alternation nor `(?:...)`. A single `^pipes(?:\s+(on|off))?$` would work in Mudlet
-- and silently match nothing in the tests.
table.insert(registry(), tempAlias([[^\s*pipes\s+on\s*$]], function()
   emunah.pipes.start()
end))

table.insert(registry(), tempAlias([[^\s*pipes\s+off\s*$]], function()
   emunah.pipes.stop()
end))

table.insert(registry(), tempAlias([[^\s*pipes\s*$]], function()
   M.handlers.pipes()
end))

-- The manna rite, as one word. Three commands with waits between them -- see manna.lua.
table.insert(registry(), tempAlias([[^\s*manna\s*$]], function()
   emunah.manna.start()
end))

-- Affliction corpus walk, as one word -- sends AFFLICTION LIST, answers MORE on its own,
-- then AFFLICTION SHOW <name> for every name it found, in the same spirit as `pp` and
-- `pipes`. `emunah affpop on|off` does the same thing. Three aliases rather than one with
-- an optional group, for the same reason as `pipes on|off` above.
table.insert(registry(), tempAlias([[^\s*affpop\s+on\s*$]], function()
   emunah.curing.detect.startWalk()
end))

table.insert(registry(), tempAlias([[^\s*affpop\s+off\s*$]], function()
   emunah.curing.detect.stopCapture()
end))

table.insert(registry(), tempAlias([[^\s*affpop\s*$]], function()
   emunah.curing.detect.toggleWalk()
end))

table.insert(registry(), tempAlias([[^\s*sleep\s*$]], function()
   local detect = emunah.curing and emunah.curing.detect
   if detect then detect.intendSleep() end
   send("sleep")
end))

-- Reflect whatever curing/keep-up state a fresh load (or a reload mid-session) actually
-- starts in. ui/echo.lua registers the ongoing on/off listeners itself, but it loads
-- before curing.engine and curing.defkeepup exist, so it cannot check their initial state
-- -- this file loads last, once everything it reads is guaranteed to be there.
emunah.ui.echo.refreshPauseBanner()

return M

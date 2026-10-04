--- Aliases: the user-facing command surface.
---
--- One dispatcher under a single `emunah` prefix, rather than a scatter of top-level
--- aliases. Two reasons: Achaea has a large command vocabulary of its own and colliding
--- with it is easy, and a single entry point means `emunah` with no arguments can list
--- everything the system can do -- which is the only documentation most people will read.
---
--- Aliases are registered through tempAlias and tracked on _persist, so a reload replaces
--- them rather than stacking duplicates. (A duplicated alias in Mudlet fires once per
--- copy, so `emset cure on` after three reloads would toggle curing three times and end
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

local function listAfflictions()
   local engine = emunah.curing.engine
   header("Afflictions (" .. engine.count() .. ")")
   local tracked = engine.list()
   if #tracked == 0 then
      cecho("\n  <ansi_light_green>clear<reset>")
      return
   end
   if not engine.enabled then
      cecho("\n  <ansi_light_red>curing is OFF<reset> <ansi_light_black>-- "
         .. "`emset curing on`. Nothing below is being acted on.<reset>")
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

--- `emset curing [on|off]`. Bare shows the state and what is tracked; mutation needs an
--- explicit on/off, so a typo cannot flip curing off mid-fight.
M.handlers.curing = function(arg)
   if arg == "on" then emunah.curing.engine.start(); emunah.config.save()
   elseif arg == "off" then emunah.curing.engine.stop(); emunah.config.save()
   else
      if arg then
         log.warn("Unknown: emset curing %s. Try `emset curing on|off`.", tostring(arg))
      end
      header("Curing")
      row("status", flag(emunah.curing.engine.enabled))
      listAfflictions()
      decho("\n  " .. faint("emset curing on|off  --  emhelp curing for everything else"))
   end
end

--- `emset keep [<herb> <n|off|default>]`: how many of a herb the restocker keeps in hand.
--- Bare lists what is kept. The same setting as the toggles under IR (riftlist.lua).
M.handlers.keep = function(item, rest)
   local engine = emunah.curing.engine
   if item then
      local value = rest and rest:lower() or nil
      local count
      if value == "off" then count = 0
      elseif value == "default" then count = nil
      else count = tonumber(value) end
      if not (value == "default" or (count and count >= 0)) then
         log.warn("Usage: emset keep <herb> <number|off|default>")
         return
      end
      item = item:lower()
      engine.setStock(item, count and math.floor(count) or nil)
      local target = engine.stockTarget(item)
      if target > 0 then
         log.info("Keeping %d %s in hand.", target, item)
      else
         log.info("Not keeping %s in hand.", item)
         if engine.isCureItem(item) then
            log.warn("%s cures afflictions, and a cure waits for one in hand.", item)
         end
      end
      return
   end
   header("Kept in hand")
   for _, name in ipairs(engine.stocked()) do
      local target, held = engine.stockTarget(name), emunah.have.quantity(name)
      row(name, string.format("%d of %d", held, target), held >= target and "defence" or "warning")
   end
   decho("\n  " .. faint("emset keep <herb> <number|off|default>  --  IR for every herb, with toggles"))
end

--- `pp`: pause or resume curing AND defence keep-up together. A cure engine paused with
--- keep-up still raising defences (or the reverse) is not actually the fight paused, it is
--- half paused -- so this drives both from the curing engine's state rather than letting
--- them drift independently. "Resuming" is defined as "either one is currently off": that
--- way one call always lands on a clean, fully-on or fully-off state, regardless of how
--- `! cure` or `! defs` may have left them individually.
M.handlers.pause = function()
   -- Stopped by QUIT (act.halt): the client did not close after all. Picking up again is
   -- what is wanted, not pausing curing on top of a system that is already sending nothing.
   if emunah.act.resume() then
      log.info("<ansi_light_green>Resumed<ansi_yellow> after QUIT.")
      return
   end
   local engine = emunah.curing.engine
   local keepup = emunah.curing.defkeepup
   -- Both modules log their own "X on."/"X off." when called directly (see engine.start()
   -- and keepup.start()), which is right for `emset cure on` and `emset defs on` typed on
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

--- The keep-up grid: every defence we know how to raise, as clickable toggles.
---
--- Three questions per defence, not one: did you ask for it, is it up right now, and do we
--- hold a command that can raise it. A checkbox alone answers only the first, and a defence
--- sitting wanted-but-unraisable looks identical to one that is merely down.
---
---   section   kept up / raised once / not raised   -- what you asked for
---   dot       the section again: green kept up, yellow raised once, dim not raised (all
---             alike, up or not)
---   name      red wanted but down, amber waiting on another defence
---   "-"       no command known; the tooltip says how to give it one
---
--- Clicking re-renders rather than editing in place: Mudlet's main console has no
--- addressable cells, and a fresh grid under the old one is what every other clickable view
--- in this codebase does (see ih.lua, ui/roompanel.lua).
local function defencesGrid()
   local keepup = emunah.curing.defkeepup
   local names  = keepup.known()

   -- THE SECTION AND THE DOT ARE THE MODE, THE NAME IS THE TRUTH. Grouped by what you
   -- asked for -- kept up, raised once, not raised -- so a toggle needs no legend (removed
   -- at the user's request, 2026-10-04). The dot is solid and coloured by the section:
   -- green kept up, yellow raised once (the user, 2026-10-04 -- a dot that followed "is it
   -- up" read as red on a defence just clicked into keep-up, and grey on a raised-once one
   -- already done, like bliss). Whether a wanted defence is actually down shows in its
   -- NAME: red down, amber waiting on another defence.
   -- Sileris, not `fangbarrier`: what you apply, not what the server calls it.
   local labels = emunah.curing.deflist.LABELS or {}
   local function label(name) return labels[name] or name end

   local sections = { keepup = {}, defup = {}, off = {} }
   local up, down = 0, 0
   for _, name in ipairs(names) do
      local state = keepup.state(name)
      local section = sections[state.mode or "off"] or sections.off
      section[#section + 1] = state
      if state.mode and state.up then up = up + 1
      elseif state.mode and state.raisable and not state.satisfied then down = down + 1 end
   end

   local summary = string.format("%d up  %s  %d down  %s  %s", up, "\194\183", down,
      "\194\183", keepup.enabled and "ON" or "OFF")
   ndbTitle("defences", summary)
   if not keepup.enabled then
      decho("\n  " .. theme().dc("affliction") .. "defences are OFF"
         .. faint(" -- nothing below is being raised. "))
      dechoLink(theme().dc("defence") .. "[turn it on]",
         "emunah.curing.defkeepup.start() emunah.config.save() "
         .. "emunah.curing.defkeepup.nudge() "
         .. "emunah.commands.handlers.defs()", "Start raising these defences", true)
   end

   local COLUMNS, WIDTH = 3, 20
   local DOT, NONE = "\226\151\143", "\194\183"

   local function text(t) return theme().dc("text") .. t end
   local function mark(state)
      if not state.raisable then return faint("-"), dim end
      local paint = text
      if state.mode and not state.up and not (state.mode == "defup" and state.satisfied) then
         paint = state.blockedBy and function(t) return theme().dc("warning") .. t end
            or function(t) return theme().dc("affliction") .. t end
      end
      if state.mode == "keepup" then return theme().dc("defence") .. DOT, paint end
      if state.mode == "defup" then return theme().dc("warning") .. DOT, paint end
      -- Not raised looks the same whether or not it happens to be up: a coat of sileris
      -- still on after being switched off read as a different grey from its neighbours
      -- (the user, 2026-10-04).
      return faint(NONE), dim
   end

   local function hint(state)
      local name = state.name
      if not state.raisable then
         return name .. ": no command known. `emset defs add " .. name .. " <command>`"
      end
      if labels[name] then name = labels[name] .. " (the game calls it " .. name .. ")" end
      return ({ [""] = "Raise " .. name .. " once",
                defup  = "Keep " .. name .. " up",
                keepup = "Stop raising " .. name })[state.mode or ""]
         .. "  (" .. tostring(state.command) .. ")"
         -- Say when the command has not been checked against a live Char.Defences:
         -- "it never goes up" is a likelier outcome for those.
         .. (state.blockedBy and ("  -- waiting for " .. state.blockedBy
               .. ", without which you cannot see or hear") or "")
         .. (state.source == "imported" and "  [unverified]" or "")
         .. (state.unconfirmable
               and "  [never shows as up -- Char.Defences has no line for it]" or "")
   end

   local function cells(label, list, cell)
      if #list == 0 then return end
      decho("\n\n  " .. theme().dc("borderLit") .. label)
      for index, item in ipairs(list) do
         if (index - 1) % COLUMNS == 0 then decho("\n    ") end
         cell(item)
      end
   end

   -- The whole cell is the link, dot included: a one-character click target is an unkind
   -- one. Clicking cycles off -> raise once -> keep up -> off, then redraws.
   local function defence(state)
      local dot, paint = mark(state)
      dechoLink(string.format("%s %s", dot, paint(string.format("%-" .. WIDTH .. "s",
            label(state.name):sub(1, WIDTH)))),
         string.format("emunah.curing.defkeepup.cycle(%q) "
            .. "emunah.curing.defkeepup.nudge() "
            .. "emunah.commands.handlers.defs()", state.name),
         hint(state), true)
   end

   for _, list in pairs(sections) do
      table.sort(list, function(a, b) return label(a.name) < label(b.name) end)
   end
   cells("kept up", sections.keepup, defence)
   cells("raised once", sections.defup, defence)
   cells("not raised", sections.off, defence)

   -- Pipe keep-up is its own module (`emset pipes`), not a defence, but relighting is what
   -- keeps rebounding and the other smoked defences raisable, and this grid is where the
   -- player looked for it: "i don't see the pipe relight toggle when i type emset defs".
   -- Two states, on or off -- the same switch as `emset pipes on|off`.
   --
   -- Riding keep-up sits beside it at the user's request (2026-10-04): the other upkeep that
   -- is not a defence. The same switch as `emset riding on|off`.
   local function toggle(on, name, command, offHint, onHint)
      dechoLink(string.format("%s %s", on and (theme().dc("defence") .. DOT) or faint(NONE),
            (on and theme().dc("text") or theme().dc("textDim"))
            .. string.format("%-" .. WIDTH .. "s", name)),
         command .. " emunah.config.save() emunah.commands.handlers.defs()",
         on and offHint or onHint, true)
   end
   local upkeep = {
      { on = emunah.config.get("pipes.enabled", true) ~= false, name = "pipe relight",
        command = "emunah.pipes.toggle()",
        off = "Stop refilling and relighting your pipes", onHint = "Keep your pipes filled and lit" },
      { on = emunah.riding and emunah.riding.keepupOn() or false, name = "riding",
        command = "emunah.riding.toggle()",
        off = "Stop vaulting back onto your mount",
        onHint = "Vault back onto your mount whenever you are off it and the balance is idle" },
   }
   cells("pipes & riding", upkeep, function(entry)
      toggle(entry.on, entry.name, entry.command, entry.off, entry.onHint)
   end)

   decho("\n")
   ndbRule()
end

M.handlers.defs = function(arg, rest)
   local keepup = emunah.curing.defkeepup
   if arg == "on" then keepup.start(); emunah.config.save()
   elseif arg == "off" then keepup.stop(); emunah.config.save()
   elseif arg == "add" and rest then
      -- `emset defs add <name>` for anything already known, or
      -- `emset defs add <name> <command>` to supply one -- the form tattoos need, where
      -- the Char.Defences name has to be read from the game rather than assumed.
      local name, command = rest:match("^(%S+)%s+(.+)$")
      keepup.add(name or rest, command)
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
      if arg then
         log.warn("Unknown: emset defs %s. Try `emset defs on|off|add|remove|mode`.",
            tostring(arg))
      end
      defencesGrid()
   end
end

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
            log.info("Found %s. `emset whois %s`.", record.name, record.name)
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
   decho("\n  " .. faint("emset iff " .. person.name .. " ally|enemy|auto"))
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

--- Mark an organisation hostile, so everyone in it is an enemy -- for highlighting, targeting
--- and the angel's presence alert. With no arguments, list what is marked.
---     emset hostile city mhaldor        emset hostile city mhaldor off
M.handlers.hostile = function(arg, rest)
   local ndb = emunah.namedb
   if not arg then
      local list = ndb.hostiles()
      if #list == 0 then
         log.info("No organisation is marked hostile. Usage: emset hostile city|house|order <name> [off]")
         return
      end
      local parts = {}
      for _, org in ipairs(list) do parts[#parts + 1] = org.name .. " (" .. org.kind .. ")" end
      log.info("Hostile: %s.", table.concat(parts, ", "))
      return
   end
   local org, off = tostring(rest or ""):match("^(.-)%s+(off)$")
   org = org or rest
   local ok, why = ndb.setHostile(arg, org, off == nil)
   if not ok then
      log.warn("%s. Usage: emset hostile city|house|order <name> [off]", tostring(why))
      return
   end
   ndb.save()
   log.info("%s %s is %s.", util.capitalise(tostring(org)), tostring(arg):lower(),
      off and "no longer hostile" or "hostile")
end

M.handlers.ui = function(arg, rest)
   if arg == "rebuild" then
      -- Rebuild from scratch: also the cure for a panel that is off-screen, zero-sized, or
      -- stuck hidden by saved state.
      emunah.ui.layout.reset()
      emunah.ui.layout.build()
      log.info("UI rebuilt.")
   elseif arg == "map" and (rest == "on" or rest == "off") then
      emunah.ui.map.setEnabled(rest == "on")
   else
      if arg then log.warn("Unknown: emset ui %s. Try `emset ui rebuild` or `emset ui map on|off`.",
         tostring(arg .. (rest and (" " .. rest) or ""))) end
      header("Interface")
      row("panels", flag(emunah.config.get("ui.enabled", true)))
      row("map", flag(emunah.config.get("ui.map", true)))
      decho("\n  " .. faint("emset ui rebuild  |  emset ui map on|off  --  emhelp interface"))
   end
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

M.handlers.walk = function(arg)
   local walker = emunah.walker
   if arg == "start" then
      walker.start()
   elseif arg == "stop" then
      if not walker.stop("requested") then log.info("Walk was not running.") end
   else
      if arg then log.warn("Unknown: emset walk %s. Try `emset walk start|stop`.", tostring(arg)) end
      local report = walker.report()
      header("Walker")
      row("running", report.running and (report.paused and "paused" or "yes") or "no")
      row("area", tostring(report.area or "-"))
      row("remaining", report.remaining)
      row("visited", report.visited)
      row("unreachable", report.failed)
      if report.running then row("elapsed", util.duration(report.elapsed)) end
      decho("\n  " .. faint("emset walk start|stop  --  emhelp hunting for its settings"))
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
   if arg == "retreat" then
      -- F12. Stop both WITHOUT the walker's return-to-start: that walk home could lead
      -- anywhere, and the point is to get three known rooms away and stay there.
      emunah.bashing.stop("retreat")
      emunah.walker.stop("retreat", true)
      emunah.walker.retreat(3)
      return
   elseif arg == "off" or arg == "stop" then
      -- Both return false with no message when they were already stopped -- which is
      -- exactly the state a safety stop leaves them in. Without this, `emset hunt off`
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
   -- BASHING WALKS THE AREA (2026-09-28: "when i type emset bash on, i also need it to walk
   -- through the area"). On and off are `hunt` and `hunt off`, so the two stay symmetric.
   if arg == "on" or arg == "start" then M.handlers.hunt()
   elseif arg == "off" or arg == "stop" then M.handlers.hunt("off")
   elseif arg == "attack" and rest then
      -- A quoted multi-word command is the natural thing to type, but the dispatcher never
      -- strips quotes (see M.dispatch) and Achaea itself treats a leading `"` as SAY
      -- shorthand. Confirmed live: `emset bash attack "angel sear"` stored the quotes
      -- literally, so every attack went out as `"angel sear" <id>` and Achaea read it as
      -- `say Angel sear <id>` rather than the ability -- "You say, "Angel sear" 235781."
      -- Strip one matching pair before storing, so quoting or not both do the right thing.
      local command = rest:match('^"(.+)"$') or rest:match("^'(.+)'$") or rest
      emunah.config.set("bashing.attack", command); emunah.config.save()
      log.info("Attack command: %s", command)
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
      decho("\n  " .. faint("emset bash on|off|attack <command>  --  emhelp hunting for its settings"))
      row("walker", emunah.walker.enabled and "running" or "stopped",
         emunah.walker.enabled and "ansi_light_green" or "ansi_yellow")
      row("room items", emunah.gmcp.items.roomFresh() and "current" or "WAITING",
         emunah.gmcp.items.roomFresh() and "ansi_light_green" or "ansi_yellow")
      decho("\n  " .. faint("emset hunt  = walk + bash together"))
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
   else
      local r = pvp.report()
      header("PvP")
      row("running", r.running and "yes" or "no", r.running and "ansi_light_green" or "reset")
      row("class module", tostring(r.classLoaded or "NONE"),
         r.classLoaded and "ansi_light_green" or "ansi_light_red")
      row("target", tostring(r.target or "none -- set one with 'emset pvp target <name>'"))
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
      decho("\n  " .. faint("emset pvp on|off|target <name>|target off  -- never auto-targets"))
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
      decho("\n  " .. faint("emset loot on|off|now  --  emhelp loot for its settings"))
   end
end

M.handlers.antitheft = function(arg)
   local antitheft = emunah.antitheft
   if arg == "on" then antitheft.setEnabled(true)
   elseif arg == "off" then antitheft.setEnabled(false)
   elseif arg == "now" then
      local n = antitheft.sweep()
      emunah.loot.stowGold()
      log.info("Put away: %d valuable(s), and any loose gold.", n)
   else
      local on = antitheft.enabled()
      header("Antitheft")
      row("status", on and "on" or "off", on and "ansi_light_green" or "ansi_light_red")
      local defences = emunah.gmcp.defences
      local selfish = defences and defences.has("selfishness")
      row("selfishness", (selfish and "up" or "down") .. ", keep-up "
         .. tostring(emunah.curing.defkeepup.mode("selfishness") or "off"),
         selfish and "ansi_light_green" or "ansi_light_red")
      local count = antitheft.packCount()
      row("pack", string.format("%s -- %s of %d items", tostring(emunah.loot.pack()),
         count and tostring(count) or "?", tonumber(emunah.config.get("pack.capacity", 50)) or 50))
      local sweep = antitheft.sweepList()
      row("kept in the pack", #sweep > 0 and table.concat(sweep, ", ") or "gold only")
      decho("\n  " .. faint("emset antitheft on|off|now  --  emhelp antitheft for its settings"))
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
         row("state", "not seen yet -- 'emset pipes now'")
      end
      for _, pipe in ipairs(list) do
         row(pipe.token, string.format("%-4s %-22s %d puffs",
            pipe.status, pipe.herb or pipe.contents, pipe.puffs),
            pipe.status == "lit" and "ansi_light_green" or "ansi_yellow")
      end
      decho("\n  " .. faint("emset pipes on|off|now  --  emhelp pipes for its settings"))
   end
end

M.handlers.riding = function(arg)
   local riding = emunah.riding
   if arg == "on" then riding.start(); emunah.config.save()
   elseif arg == "off" then riding.stop(); emunah.config.save()
   else
      local function yesNo(value, yes, no)
         if value == nil then return "not known" end
         return value and yes or no
      end
      local token = riding.mount()
      local here = riding.present()
      header("Riding")
      row("keep-up", riding.keepupOn() and "on" or "off",
         riding.keepupOn() and "ansi_light_green" or "ansi_light_red")
      row("mount", token or "none set")
      row("here", yesNo(here, "yes", "no"), here == false and "ansi_yellow" or nil)
      row("riding", yesNo(riding.riding(), "yes", "no"))
      if riding.riding() ~= true then
         row("following", yesNo(riding.following(), "yes", "no"))
      end
      local held = riding.keepupOn() and riding.vaultHeld()
      if held and riding.riding() ~= true then row("vault held", held) end
      decho("\n  " .. faint("emset riding on|off  --  emhelp riding for its settings"))
   end
end

M.handlers.reload = function()
   emunahReload()
end

--- `emset manna`: the manna rite -- three commands with waits between them (manna.lua).
M.handlers.manna = function()
   emunah.manna.start()
end

-- ---------------------------------------------------------------------------
-- settings: `emset <setting> [value]`
-- ---------------------------------------------------------------------------

--- Set, or show, one setting by its documented name, e.g. `emset curing.method minerals`.
---
--- One rule for every setting instead of a subcommand per setting: help.lua documents each
--- key, and anything documented can be set here. The reference system's `vconfig <option> <value>` in the
--- same spirit -- and emhelp <module> lists them with their current values, click to change.
function M.setting(key, value)
   local documented = emunah.help and emunah.help.setting(key)
   if not documented then
      log.warn("Unknown setting %q. `emhelp` lists the modules; each lists its settings.", key)
      return
   end
   if value == nil then
      row(key, tostring(emunah.config.get(key, documented.default)))
      return
   end
   -- Coerce the obvious types so `emset curing.confirmWait 1.5` stores a number.
   if value == "true" or value == "on" then value = true
   elseif value == "false" or value == "off" then value = false
   elseif tonumber(value) then value = tonumber(value)
   else value = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value end
   emunah.config.set(key, value)
   emunah.config.save()
   log.info("%s = %s", key, tostring(value))
end

-- ---------------------------------------------------------------------------
-- dispatch
-- ---------------------------------------------------------------------------

function M.dispatch(input)
   input = util.trim(input or "")
   if input == "" then
      M.handlers.status()
      return
   end

   local command, remainder = input:match("^(%S+)%s*(.*)$")
   remainder = util.trim(remainder)

   -- A dotted name is a setting, not a command.
   if command:find(".", 1, true) then
      M.setting(command, remainder ~= "" and remainder or nil)
      return
   end

   command = command:lower()
   local handler = M.handlers[command]
   if not handler then
      log.warn("Unknown command %q. `emset` shows status; `emhelp` lists everything.", command)
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

-- ONE PREFIX. Everything Emunah does is `emset ...`, and `emhelp` explains it. The bare
-- shortcuts (`emdefs`, `ndb`, `pipes`, `manna`, `affpop`) and the long `emunah` prefix are
-- gone (`pp` came back at the user's request, below): a second vocabulary for the same things is the kind of thing that made
-- the help hard to follow.
--
-- tempAlias takes a PCRE REGEX, not a Lua pattern: whitespace is `\s` here, never `%s`.
-- Two aliases rather than one with an optional group, because test/mock_mudlet.lua
-- translates regexes to Lua patterns, which have no `(?:...)`.
--
-- NOT CONFIRMED FREE IN ACHAEA. If the game ever claims EMSET, this is the line to change.
table.insert(registry(), tempAlias([[^\s*emset\s+(.+)$]], function()
   M.dispatch(matches[2])
end))

table.insert(registry(), tempAlias([[^\s*emset\s*$]], function()
   M.dispatch("")
end))

-- `emhelp [module]`: the modules, and each one's commands and settings. Its own word
-- because it is what someone types before they know anything else.
table.insert(registry(), tempAlias([[^\s*emhelp\s+(.+)$]], function()
   emunah.help.render(matches[2])
end))

table.insert(registry(), tempAlias([[^\s*emhelp\s*$]], function()
   emunah.help.render("")
end))

-- SLEEP, typed on its own. NOT a command: it records that this sleep was yours, so the
-- system does not WAKE you out of it (curing/detect's voluntary sleep), relaxes insomnia
-- first if it is up, and keeps keep-up from raising it again until you wake (the user,
-- 2026-10-04). See detect.goToSleep(). Anchored to a bare SLEEP; anything else falls
-- through untouched.
table.insert(registry(), tempAlias([[^\s*sleep\s*$]], function()
   local detect = emunah.curing and emunah.curing.detect
   if detect then detect.goToSleep() else send("sleep") end
end))

-- PP: pause or resume curing and defence keep-up together, the same as `emset pause`.
-- Asked for by the user (2026-10-04), and the fourth exception to one prefix: a pause is
-- the thing typed in a hurry.
table.insert(registry(), tempAlias([[^\s*pp\s*$]], function()
   M.handlers.pause()
end))

-- BUY by bare number: `buy 50 476321`, or `buy 476321` for one. Asked for by the user
-- (2026-10-04), and the third exception to one prefix. It cannot shadow a real BUY: HELP
-- SHOPS needs the full name ("tun115258", never "115258"), so a digits-only item is one the
-- game refuses anyway. shop.buyByNumber() fills in the name from the WARES listing.
table.insert(registry(), tempAlias([[^\s*buy\s+(\d+)\s+(\d+)\s*$]], function()
   emunah.shop.buyByNumber(matches[2], matches[3])
end))

table.insert(registry(), tempAlias([[^\s*buy\s+(\d+)\s*$]], function()
   emunah.shop.buyByNumber(1, matches[2])
end))

-- Reflect whatever curing/keep-up state a fresh load (or a reload mid-session) actually
-- starts in. ui/echo.lua registers the ongoing on/off listeners itself, but it loads
-- before curing.engine and curing.defkeepup exist, so it cannot check their initial state
-- -- this file loads last, once everything it reads is guaranteed to be there.
emunah.ui.echo.refreshPauseBanner()

return M

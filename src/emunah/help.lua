--- `emhelp`: everything Emunah does, one module at a time.
---
---   emhelp            the modules, each with what it does and whether it is on
---   emhelp <module>   one module: what it does, its `emset` commands, and every setting
---                     with its current value -- click a setting to change it
---
--- Modelled on the reference system's `vshow` / `vconfig`: one place to see the state of the system and
--- change it, rather than a reference to read and a separate set of commands to remember.
---
--- WHY THIS IS DATA AND NOT PRINT STATEMENTS
--- -----------------------------------------
--- The help that preceded this drifted from the code: commands undocumented, settings not
--- mentioned at all, removed commands still described. A table can be checked, and
--- test/run.lua does: every command handler is documented here, nothing is documented that
--- does not exist, every shipped setting is documented, and website/commands.html is
--- generated from this file (tools/build-commands-page.lua).
---
--- SHAPE
---   M.modules   ordered; each { id, title, summary, does, state, commands }
---     summary   one line, for the index
---     does      what the module does, in a few sentences -- the point of `emhelp <module>`
---     state     function returning true/false (on/off), or nil for modules with no switch
---     commands  { { syntax, summary, handler, alias } } -- handler is the
---               commands.lua key it dispatches to; alias a bare word outside `emset`
---   M.settings  every configuration key, with its module (topic), default and meaning

local M = {}

local theme = emunah.ui.theme

local function config(key, default)
   return emunah.config.get(key, default) ~= false
end

-- ---------------------------------------------------------------------------
-- modules
-- ---------------------------------------------------------------------------

M.modules = {

{ id = "system", title = "System", summary = "status, settings, reloading and debugging",
  does = "Emunah runs off GMCP: vitals, afflictions, defences, inventory and the room arrive "
      .. "from the game and everything else reacts to them once per prompt. Every command "
      .. "goes through one gate that knows when the game would refuse it -- stunned, asleep, "
      .. "unconscious, dead, off balance, prone, paralysed, entangled -- and holds it rather "
      .. "than wasting it. Death pauses everything until you are alive again. Settings are "
      .. "saved per profile.",
  commands = {
   { syntax = "emset", handler = "status",
     summary = "status: curing, defences, safety floors, what is tracked" },
   { syntax = "emset <setting> [value]",
     summary = "show or change any setting, e.g. `emset curing.method minerals`" },
   { syntax = "emhelp [module]",
     summary = "this help: the modules, or one module's commands and settings" },
   { syntax = "emset reload", handler = "reload",
     summary = "reload Emunah from disk, keeping its state" },
   { syntax = "emreload", alias = "emreload",
     summary = "the same, and still works if the command module failed to load" },
   { syntax = "emset debug", handler = "debug",
     summary = "debug log: every command sent, and every command held with the reason" },
   { syntax = "emset debug gmcp",
     summary = "trace every GMCP message in and out" },
   { syntax = "emset debug queue|timers|handlers",
     summary = "dump the action queue, the timers or the event handlers" },
  } },

{ id = "curing", title = "Curing", summary = "tracks afflictions and cures them on the right balance",
  state = function() return emunah.curing.engine.enabled end,
  does = "Tracks your afflictions from GMCP (and from EmunahTriggers.xml, with the reference system's "
      .. "anti-illusion) and cures them on the right balance: herbs, salves, elixirs, moss, "
      .. "smoking, FOCUS, the tree tattoo, COMPOSE, CONCENTRATE, CLOT and WRITHE. One cure "
      .. "per balance at a time, never inside a balance, never while something blocks it "
      .. "(anorexia, slickness, asthma, paralysis...). Follows the reference system's rules for what to cure "
      .. "first and when not to. Sips health and mana, eats moss, keeps cures pulled from "
      .. "the rift into your inventory, and wakes you from a sleep you did not choose.",
  commands = {
   { syntax = "emset curing", handler = "curing",
     summary = "on or off, and every affliction being tracked" },
   { syntax = "emset curing on|off",
     summary = "switch curing on or off" },
   { syntax = "emset pause", handler = "pause",
     summary = "pause or resume curing and defences together" },
   { syntax = "emset prio <affliction> <balance> <rank>", handler = "prio",
     summary = "cure an affliction sooner or later on one balance; lower is sooner" },
   { syntax = "sleep", alias = "sleep",
     summary = "SLEEP, marked as yours so Emunah does not wake you out of it" },
  } },

{ id = "defences", title = "Defences", summary = "raises the defences you choose and keeps them up",
  state = function() return emunah.curing.defkeepup.enabled end,
  does = "Raises the defences you choose and keeps them up. Each one is off, defup (raise "
      .. "it once) or keepup (raise it whenever it drops). Knows the command for the "
      .. "herb, salve, elixir and skill defences; tattoos and anything else can be taught. "
      .. "Never raises a defence that is already up, and never spends the balance while "
      .. "curing needs it.",
  commands = {
   { syntax = "emset defs", handler = "defs",
     summary = "the defence grid: click to cycle off / defup / keepup, and pipe relight on / off" },
   { syntax = "emset defs on|off",
     summary = "switch defence keep-up on or off" },
   { syntax = "emset defs add <name> [command]",
     summary = "keep a defence up, with the command that raises it if it is not known" },
   { syntax = "emset defs remove <name>",
     summary = "stop keeping a defence up" },
   { syntax = "emset defs mode <name> defup|keepup|off",
     summary = "raise it once, keep it up, or leave it alone" },
  } },

{ id = "pipes", title = "Pipes", summary = "keeps your pipes filled and lit",
  state = function() return config("pipes.enabled", true) end,
  does = "Keeps your pipes filled and lit so smoking cures are always ready: refills an "
      .. "empty pipe with the herb it holds, relights one that has gone out, and reads "
      .. "PIPELIST now and then to stay honest. PIPELIST and refills are hidden; a relight is "
      .. "shown. Also toggled from the `emset defs` grid.",
  commands = {
   { syntax = "emset pipes", handler = "pipes",
     summary = "each pipe: lit or out, what it holds, puffs left" },
   { syntax = "emset pipes on|off",
     summary = "switch pipe upkeep on or off" },
   { syntax = "emset pipes now",
     summary = "send PIPELIST now, and show it" },
  } },

{ id = "manna", title = "Manna", summary = "performs the manna rite",
  does = "Performs the manna rite: the three commands, with the waits between them, done "
      .. "for you once each is possible.",
  commands = {
   { syntax = "emset manna", handler = "manna",
     summary = "perform the manna rite" },
  } },

{ id = "hunting", title = "Hunting", summary = "bashing, and walking an area to clear it",
  state = function() return emunah.bashing.enabled or emunah.walker.enabled end,
  does = "Bashing and walking. Bashing attacks the denizens in the room, one at a time by "
      .. "replica number, on the balance and equilibrium your attack uses. The walker "
      .. "explores an area room by room. `hunt` runs both: clear a room, move on. Stops "
      .. "itself when health drops below its floor, when a player arrives, or when "
      .. "damage comes in too fast.",
  commands = {
   { syntax = "emset hunt [off]", handler = "hunt",
     summary = "walk and bash together; `off` stops both" },
   { syntax = "emset bash", handler = "bash",
     summary = "bashing: target, kills, damage, whether it is running" },
   { syntax = "emset bash on|off",
     summary = "bash the room you are in" },
   { syntax = "emset bash attack <command>",
     summary = "the attack, sent as `<command> <replica>`" },
   { syntax = "emset walk", handler = "walk",
     summary = "the walker: area, rooms left, visited" },
   { syntax = "emset walk start|stop",
     summary = "explore the current area, or stop" },
  } },

{ id = "pvp", title = "PvP", summary = "attacks the player you name, and no one else",
  state = function() return emunah.pvp.enabled end,
  does = "Attacks the player you name, and only that player: it never picks a target by "
      .. "itself. Tracks the afflictions you have given them. Stops below its health floor.",
  commands = {
   { syntax = "emset pvp", handler = "pvp",
     summary = "target, their afflictions, attacks sent" },
   { syntax = "emset pvp on|off",
     summary = "start or stop attacking the target" },
   { syntax = "emset pvp target <name>|off",
     summary = "choose the target, or clear it" },
  } },

{ id = "loot", title = "Loot & shop", summary = "picks up gold; asks before costly purchases",
  state = function() return config("loot.gold", true) end,
  does = "Picks up gold from the room after a kill and stows it. Shop purchases above a "
      .. "set price ask before buying.",
  commands = {
   { syntax = "emset loot", handler = "loot",
     summary = "whether gold pickup is on, and how much has been picked up" },
   { syntax = "emset loot on|off",
     summary = "switch gold pickup on or off" },
   { syntax = "emset loot now",
     summary = "sweep the room now" },
  } },

{ id = "people", title = "People", summary = "who everyone is, and ally/enemy highlighting",
  state = function() return config("names.enabled", true) end,
  does = "A database of everyone you have seen: city, house, class, and whether they are "
      .. "an ally or an enemy, filled from WHO lists, HONOURS and the Achaea web API. "
      .. "Names are highlighted in the game text by what they are to you.",
  commands = {
   { syntax = "emset whois <person>", handler = "whois",
     summary = "everything known about someone" },
   { syntax = "emset iff <person> ally|enemy|auto", handler = "iff",
     summary = "mark someone as an ally or an enemy, or go back to what their city says" },
  } },

{ id = "interface", title = "Interface", summary = "the panels, chat tabs and map",
  state = function() return config("ui.enabled", true) end,
  does = "The panels around the game text: vitals, afflictions, defences, chat tabs, the "
      .. "room and its people, your target, and the map.",
  commands = {
   { syntax = "emset ui", handler = "ui",
     summary = "whether the panels and the map are on" },
   { syntax = "emset ui rebuild",
     summary = "rebuild the panels; also fixes one that is missing or stuck" },
   { syntax = "emset ui map on|off",
     summary = "show or hide the map" },
  } },

}

-- ---------------------------------------------------------------------------
-- settings
-- ---------------------------------------------------------------------------

M.settings = {

-- core
{ key = "logLevel", default = "info", type = "string", topic = "system", shipped = true,
  detail = "debug, info, warn or error. `emset debug` toggles between info and debug." },
{ key = "schema", default = 9, type = "number", topic = "system", shipped = true,
  detail = "Config format version. Managed by the migrations; do not set this by hand." },

-- interface
{ key = "ui.enabled", default = true, type = "boolean", topic = "interface", shipped = true,
  detail = "Whether the panel interface is built at all." },
{ key = "ui.map", default = true, type = "boolean", topic = "interface", shipped = true },
{ key = "ui.mapHeight", default = 42, type = "number", unit = "% of window", topic = "interface",
  shipped = true, detail = "Clamped to 10-70." },
{ key = "ui.mapFloat", default = false, type = "boolean", topic = "interface", shipped = false,
  detail = "Detaches the map into its own window. `emset ui rebuild` after changing it." },
{ key = "ui.chatTabs", default = "Tells, City, House, Market, Says, Misc", type = "list",
  topic = "interface", shipped = true },
{ key = "ui.refresh", default = 0.2, type = "number", unit = "s", topic = "interface",
  shipped = true, detail = "How often balance countdowns redraw while one is running. "
       .. "0 turns the live countdowns off." },

-- curing
{ key = "curing.enabled", default = false, type = "boolean", topic = "curing", shipped = true,
  detail = "Off by default, deliberately. Curing is opt-in." },
{ key = "curing.method", default = "herbs", type = "string", topic = "curing", shipped = true,
  detail = "herbs or minerals. Changes which item every cure resolves to." },
{ key = "curing.confirmWait", default = 2.0, type = "number", unit = "s", topic = "curing",
  shipped = true, detail = "How long a sent cure holds its vector waiting for the game to "
       .. "confirm it, before the vector is re-armed." },
{ key = "curing.reconcileEvery", default = 20, type = "number", unit = "ticks",
  topic = "curing", shipped = true,
  detail = "How often the tracked list is reconciled against Char.Afflictions wholesale." },
{ key = "curing.healthThreshold", default = 80, type = "number", unit = "%", topic = "curing",
  shipped = true, detail = "Sip health below this." },
{ key = "curing.manaThreshold", default = 85, type = "number", unit = "%", topic = "curing",
  shipped = true },
{ key = "curing.iridThreshold", default = 68, type = "number", unit = "%", topic = "curing",
  shipped = true, detail = "Eat irid moss below this, on health or mana." },
{ key = "curing.handsThreshold", default = 50, type = "number", unit = "%", topic = "curing",
  shipped = true, detail = "PERFORM HANDS below this. Costs equilibrium, which attacking "
       .. "also spends, so this is set low on purpose." },
{ key = "curing.irid", default = true, type = "boolean", topic = "curing", shipped = false },
{ key = "curing.diag", default = true, type = "boolean", topic = "curing", shipped = false,
  detail = "Send DIAG when the affliction list is in doubt -- which is what answers `loki`, "
       .. "the one affliction GMCP does not report honestly." },
{ key = "curing.clotThreshold", default = 30, type = "number", topic = "curing",
  shipped = false, detail = "Bleeding above this is clotted." },
{ key = "curing.focusGuilt", default = false, type = "boolean", topic = "curing",
  shipped = false },
{ key = "curing.elixirConfirm", default = 7.0, type = "number", unit = "s", topic = "curing",
  shipped = false },
{ key = "curing.mossConfirm", default = 9.0, type = "number", unit = "s", topic = "curing",
  shipped = false },
{ key = "curing.riftConfirm", default = 1.5, type = "number", unit = "s", topic = "curing",
  shipped = false },
{ key = "curing.restock", default = true, type = "boolean", topic = "curing", shipped = false,
  detail = "Pull consumables out of the rift as they run low." },
{ key = "curing.restockEvery", default = 1, type = "number", unit = "ticks", topic = "curing",
  shipped = false, detail = "Every prompt by default. It used to be every tenth, which made "
       .. "each pull ten prompts apart for no benefit -- only one pull can be in flight "
       .. "anyway." },
{ key = "curing.restockSalves", default = false, type = "boolean", topic = "curing",
  shipped = false },
{ key = "curing.stockTarget", default = 1, type = "number", topic = "curing", shipped = false,
  detail = "How many of each consumable to keep in hand." },
{ key = "curing.recovery.<vector>", default = "per vector", type = "number", unit = "s",
  topic = "curing", shipped = false,
  detail = "Override the fallback recovery time for one vector, e.g. curing.recovery.herb." },
{ key = "curing.antiIllusion", default = true, type = "boolean", topic = "curing",
  shipped = false, detail = "The reference system's anti-illusion for EmunahTriggers.xml: reports wait for the "
       .. "prompt, and a block containing an illusion is discarded whole. Off applies each "
       .. "report the moment its line arrives." },
{ key = "curing.textConfirm", default = 2.0, type = "number", unit = "s", topic = "curing",
  shipped = false, detail = "How long an affliction reported by text waits for the server to "
       .. "confirm it before it is dropped as an illusion." },
{ key = "curing.focusMinMana", default = 35, type = "number", unit = "% of max",
  topic = "curing", shipped = false,
  detail = "FOCUS is held at or below this mana (the reference system's `manause`)." },
{ key = "priorities", default = "{}", type = "table", topic = "curing", shipped = true,
  detail = "Per-affliction, per-vector rank overrides. Written by `emset prio`." },

-- defences
{ key = "defences.enabled", default = false, type = "boolean", topic = "defences",
  shipped = true },
{ key = "defences.keepup", default = "{}", type = "table", topic = "defences", shipped = true,
  detail = "name -> \"defup\" or \"keepup\". Written by the defence grid." },
{ key = "defences.commands", default = "{}", type = "table", topic = "defences", shipped = false,
  detail = "name -> the command that raises it, for defences we ship no command for." },

-- walker
{ key = "walker.avoid", default = "{}", type = "table", topic = "hunting", shipped = true },
{ key = "walker.auto", default = true, type = "boolean", topic = "hunting", shipped = true },
{ key = "walker.stepDelay", default = 0.6, type = "number", unit = "s", topic = "hunting",
  shipped = true, detail = "0.1 to 30." },
{ key = "walker.returnToStart", default = true, type = "boolean", topic = "hunting",
  shipped = false, detail = "Toggled in-session by `emset walk return`; not persisted." },
{ key = "walker.stopBelowHealth", default = 40, type = "number", unit = "%", topic = "hunting",
  shipped = false },
{ key = "walker.stopOnPlayer", default = false, type = "boolean", topic = "hunting",
  shipped = false },
{ key = "walker.transitTimeout", default = 8.0, type = "number", unit = "s", topic = "hunting",
  shipped = false },

-- bashing
{ key = "bashing.attack", default = "angel sear", type = "string", topic = "hunting",
  shipped = true },
{ key = "bashing.balance", default = "both", type = "string", topic = "hunting", shipped = true,
  detail = "What the attack REQUIRES: eq, bal or both." },
{ key = "bashing.consumes", default = "eq", type = "string", topic = "hunting", shipped = true,
  detail = "What the attack SPENDS: eq or bal. Not the same question as `balance`." },
{ key = "bashing.stopBelowHealth", default = 50, type = "number", unit = "%", topic = "hunting",
  shipped = true, detail = "Zero disables the floor." },
{ key = "bashing.maxAttempts", default = 40, type = "number", topic = "hunting", shipped = true },
{ key = "bashing.walkWhenClear", default = true, type = "boolean", topic = "hunting",
  shipped = true },
{ key = "bashing.stopOnPlayer", default = false, type = "boolean", topic = "hunting",
  shipped = true },
{ key = "bashing.soloOnly", default = true, type = "boolean", topic = "hunting",
  shipped = false },
{ key = "bashing.resumeMargin", default = 10, type = "number", unit = "points",
  topic = "hunting", shipped = false,
  detail = "How far above the health floor to recover before resuming." },
{ key = "bashing.penitence", default = true, type = "boolean", topic = "hunting",
  shipped = false, detail = "Priest only." },
{ key = "bashing.desolation", default = true, type = "boolean", topic = "hunting",
  shipped = false, detail = "Priest only." },

-- pvp
{ key = "pvp.stopBelowHealth", default = 60, type = "number", unit = "%", topic = "pvp",
  shipped = true, detail = "Higher than the bashing floor on purpose." },
{ key = "pvp.verses", default = true, type = "boolean", topic = "pvp", shipped = false,
  detail = "Recite Zeal verses to apply afflictions." },
{ key = "pvp.attackAtAfflictions", default = 2, type = "number", topic = "pvp",
  shipped = false, detail = "Switch from afflicting to damage at this many stacked." },

-- watch
{ key = "watch.critical", default = 30, type = "number", unit = "%", topic = "hunting",
  shipped = false, detail = "The floor everything stops at. Zero disables it." },
{ key = "watch.damageSpike", default = 25, type = "number", unit = "%", topic = "hunting",
  shipped = false },
{ key = "watch.damageWindow", default = 10, type = "number", unit = "ticks", topic = "hunting",
  shipped = false },
{ key = "watch.damageSpikeBelow", default = 60, type = "number", unit = "%", topic = "hunting",
  shipped = false },
{ key = "watch.endurance", default = 15, type = "number", unit = "%", topic = "hunting",
  shipped = false },
{ key = "watch.willpower", default = 15, type = "number", unit = "%", topic = "hunting",
  shipped = false },
{ key = "watch.mana", default = 10, type = "number", unit = "%", topic = "hunting",
  shipped = false },
{ key = "watch.resource", default = 10, type = "number", unit = "%", topic = "hunting",
  shipped = false },

-- keys, denizens, loot, shop, pipes, namedb, names
{ key = "keys.numpad", default = true, type = "boolean", topic = "interface", shipped = true },
{ key = "denizens.autoRecord", default = true, type = "boolean", topic = "hunting",
  shipped = true },
{ key = "loot.gold", default = true, type = "boolean", topic = "loot", shipped = true },
{ key = "loot.aloneOnly", default = true, type = "boolean", topic = "loot",
  shipped = false, detail = "Only lift gold with nobody else in the room." },
{ key = "loot.ownKillsOnly", default = false, type = "boolean", topic = "loot",
  shipped = false },
{ key = "loot.noDenizens", default = true, type = "boolean", topic = "loot",
  shipped = false, detail = "Do not stop to loot while something is still alive." },
{ key = "loot.stowIn", default = "backpack452292", type = "string", topic = "loot",
  shipped = false, detail = "Where gold goes. This default is one character's backpack id "
       .. "and will not be yours." },
{ key = "shop.stowIn", default = "(caller's choice)", type = "string", topic = "loot",
  shipped = false },
{ key = "shop.confirmAbove", default = "(unset)", type = "number", unit = "gp",
  topic = "loot", shipped = false, detail = "Purchases above this price ask for confirmation." },
{ key = "pipes.enabled", default = true, type = "boolean", topic = "pipes", shipped = false },
{ key = "pipes.assign", default = "(unset)", type = "table", topic = "pipes",
  shipped = false, detail = "Which herb goes in which pipe." },
{ key = "pipes.poll", default = 0, type = "number", unit = "s", topic = "pipes",
  shipped = false, detail = "Re-check every pipe this often with PIPELIST. 0 (the default) "
     .. "asks only when the pipes are not known, e.g. after login or a reload." },
{ key = "namedb.capture", default = true, type = "boolean", topic = "people", shipped = true },
{ key = "namedb.autoFetch", default = true, type = "boolean", topic = "people",
  shipped = true, detail = "Look names up against the Achaea web API automatically." },
{ key = "names.enabled", default = true, type = "boolean", topic = "people", shipped = true },
{ key = "names.cityTint", default = true, type = "boolean", topic = "people", shipped = true },
}

-- ---------------------------------------------------------------------------
-- lookup
-- ---------------------------------------------------------------------------

function M.module(id)
   id = tostring(id or ""):lower()
   for _, module in ipairs(M.modules) do
      if module.id == id or module.title:lower() == id then return module end
   end
   return nil
end

--- Every command, flattened, with its module attached.
function M.commands()
   local out = {}
   for _, module in ipairs(M.modules) do
      for _, command in ipairs(module.commands) do
         out[#out + 1] = { command = command, module = module }
      end
   end
   return out
end

function M.setting(key)
   key = tostring(key or ""):lower()
   for _, spec in ipairs(M.settings) do
      if spec.key:lower() == key then return spec end
   end
   return nil
end

function M.settingsFor(moduleId)
   local out = {}
   for _, spec in ipairs(M.settings) do
      if spec.topic == moduleId then out[#out + 1] = spec end
   end
   return out
end

--- The module a word belongs to: a module name, a command word (`emhelp bash`), or a
--- setting (`emhelp curing.method`).
function M.lookup(word)
   word = tostring(word or ""):lower():gsub("^emset%s+", "")
   local module = M.module(word)
   if module then return module end
   local first = word:match("^(%S+)") or ""
   for _, row in ipairs(M.commands()) do
      local syntax = row.command.syntax:lower():gsub("^emset%s+", "")
      if (syntax:match("^(%S+)") or "") == first then return row.module end
   end
   local spec = M.setting(word)
   if spec then return M.module(spec.topic), spec end
   return nil
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

local WIDTH = 74

local function dim(text)    return theme.dc("textDim") .. tostring(text) end
local function faint(text)  return theme.dc("inactive") .. tostring(text) end
local function bright(text) return theme.dc("textBright") .. tostring(text) end

local function rule()
   decho("\n  " .. faint(string.rep("-", WIDTH)))
end

local function title(text, right)
   local pad = WIDTH - #text - #(right or "") - 4
   if pad < 1 then pad = 1 end
   decho(string.format("\n  %s-- %s %s%s",
      theme.dc("borderLit"), bright(text), faint(string.rep("-", pad)),
      right and (" " .. dim(right)) or ""))
end

--- Wrap a paragraph to the panel width, indented.
local function paragraph(text, indent, colour)
   indent = indent or "  "
   local limit = WIDTH - #indent
   local line, length = {}, 0
   decho("\n" .. indent .. (colour or theme.dc("text")))
   for word in tostring(text):gmatch("%S+") do
      if length > 0 and length + #word + 1 > limit then
         decho(table.concat(line, " "))
         decho("\n" .. indent .. (colour or theme.dc("text")))
         line, length = {}, 0
      end
      line[#line + 1] = word
      length = length + #word + 1
   end
   if #line > 0 then decho(table.concat(line, " ")) end
end

local function stateText(module)
   if not module.state then return "" end
   local ok, on = pcall(module.state)
   if not ok then return faint("?") end
   return on and theme.dc("defence") .. "on " or theme.dc("affliction") .. "off"
end

local function showValue(value)
   if value == nil then return "(unset)" end
   if type(value) == "table" then return "(list)" end
   return tostring(value)
end

--- `emhelp`: every module, whether it is on, and what it is for. Click one for its card.
function M.renderIndex()
   title("Emunah " .. (emunah._version or "?"), "emhelp <module>")
   decho("\n")
   for _, module in ipairs(M.modules) do
      decho("\n  ")
      dechoLink(string.format("%s%-11s", theme.dc("balance"), module.id),
         string.format("emunah.help.render(%q)", module.id), "Show " .. module.title, true)
      -- Padded as plain text: the colour codes would otherwise count towards the width.
      local state = "   "
      if module.state then
         local ok, on = pcall(module.state)
         state = not ok and faint("?  ") or on and theme.dc("defence") .. "on "
            or theme.dc("affliction") .. "off"
      end
      decho(state .. "  " .. dim(module.summary or ""))
   end
   rule()
   decho("\n  " .. faint("Every command is `emset ...`.  `emset` alone shows the status."))
end

--- `emhelp <module>`: what it does, its commands, and its settings -- live, clickable.
function M.renderModule(module, highlight)
   title(module.title, module.state and ("currently " .. (select(2, pcall(module.state))
      and "on" or "off")) or nil)
   paragraph(module.does, "  ", theme.dc("text"))

   decho("\n\n  " .. dim("commands"))
   -- The column fits the longest syntax in this module, so a long one pushes the summaries
   -- along together rather than running into its own.
   local width = 0
   for _, command in ipairs(module.commands) do width = math.max(width, #command.syntax) end
   for _, command in ipairs(module.commands) do
      decho(string.format("\n    %s%-" .. (width + 3) .. "s%s", theme.dc("balance"),
         command.syntax, dim(command.summary or "")))
   end

   local settings = M.settingsFor(module.id)
   if #settings > 0 then
      decho("\n\n  " .. dim("settings") .. faint("   click to change -- * differs from default"))
      for _, spec in ipairs(settings) do
         local current = emunah.config.get(spec.key)
         if current == nil then current = spec.default end
         local changed = tostring(current) ~= tostring(spec.default)
         decho("\n    " .. theme.dc("warning") .. (changed and "*" or " ") .. " ")
         -- A switch flips on a click; anything else puts `emset <key> ` on the command
         -- line to be finished -- the reference system's vconfig, clickable.
         if spec.type == "boolean" then
            dechoLink(string.format("%s%-30s", theme.dc("balance"), spec.key),
               string.format("emunah.commands.setting(%q, %q) emunah.help.render(%q)",
                  spec.key, tostring(not current), module.id),
               "Turn " .. (current and "off" or "on"), true)
         else
            dechoLink(string.format("%s%-30s", theme.dc("balance"), spec.key),
               string.format("printCmdLine(%q)", "emset " .. spec.key .. " "),
               "Set " .. spec.key, true)
         end
         decho(string.format("%s%-14s", changed and theme.dc("textBright") or theme.dc("text"),
            showValue(current) .. (spec.unit and (" " .. spec.unit) or "")))
         if spec.detail and (highlight == nil or highlight == spec) then
            paragraph(spec.detail, "        ", theme.dc("textDim"))
         end
      end
   end
   rule()
   decho("\n  ")
   dechoLink(faint("<- all modules"), "emunah.help.render('')", "emhelp", true)
end

--- `emhelp <args>`. The one function commands.lua calls.
function M.render(args)
   args = emunah.util.trim(args or "")
   if args == "" then return M.renderIndex() end
   local module, spec = M.lookup(args)
   if module then return M.renderModule(module, spec) end
   emunah.log.warn("No module or command called %q. `emhelp` lists them all.", args)
end

return M

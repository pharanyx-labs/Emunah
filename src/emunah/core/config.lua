--- Persistent settings.
---
--- Stored per Mudlet profile (getMudletHomeDir() is profile-specific), so two characters
--- in the same Mudlet installation keep separate priorities, defence lists and UI
--- positions without any extra work.

local M = {}

local util = emunah.util
local log  = emunah.log

local PATH = getMudletHomeDir() .. "/emunah-config.lua"

--- Defaults. Anything absent from the saved file falls back to these, so adding a new
--- setting in a later version does not require users to delete their config.
--- Bump when a shipped default was WRONG, not merely changed.
---
--- Changing DEFAULTS is not enough to fix a wrong one, and that is not obvious: a saved
--- config keeps its own copy, and `fill()` below only supplies keys that are ABSENT. A
--- reload does not even get that far -- M.data is restored wholesale from
--- emunah._persist. So a bad default, once written or once carried across a reload, is
--- permanent until something rewrites it. That is what MIGRATIONS is for.
local SCHEMA = 9

local MIGRATIONS = {
   -- bashing.balance shipped as "bal" long after smite was confirmed to need balance AND
   -- equilibrium. Nobody chose that value -- it was the default -- so correcting it is not
   -- overriding a preference. Left alone, canAttack() goes on ignoring equilibrium and
   -- three smites go into every penitence cooldown; see class/priest.lua.
   [1] = function(data)
      if data.bashing and data.bashing.balance == "bal" then
         data.bashing.balance = "both"
         return "bashing.balance: bal -> both (smite needs equilibrium too)"
      end
   end,

   -- The healing thresholds were raised from 65/40 to 80/85, and a saved config kept the
   -- old numbers -- fill() only supplies keys that are ABSENT, and any command that calls
   -- M.save() writes the whole table, so almost every profile has them stored.
   --
   -- The symptom is specific and quiet: sitting at 73% health with nothing happening,
   -- because 73 is above the 65 that is actually in force while the documentation, the
   -- README and the code all say 80. Only values that still match the old shipped defaults
   -- are moved; anything else was chosen and is left alone.
   [2] = function(data)
      if not data.curing then return end
      local moved = {}
      if data.curing.healthThreshold == 65 then
         data.curing.healthThreshold = 80
         moved[#moved + 1] = "health 65 -> 80"
      end
      if data.curing.manaThreshold == 40 then
         data.curing.manaThreshold = 85
         moved[#moved + 1] = "mana 40 -> 85"
      end
      if #moved > 0 then
         return "healing thresholds: " .. table.concat(moved, ", ")
      end
   end,

   -- `defences.keepup` was an ARRAY of names, and became a MAP of name -> mode when
   -- defences grew a defup mode alongside keepup. An existing list means exactly one thing
   -- -- keep all of these up -- so every entry converts to "keepup" and nobody's setup
   -- changes underneath them. Left unconverted, the array reads as an empty map and every
   -- defence anyone had configured would silently switch itself off.
   [3] = function(data)
      local list = data.defences and data.defences.keepup
      if type(list) ~= "table" or list[1] == nil then return end
      local modes = {}
      for _, name in ipairs(list) do modes[tostring(name):lower()] = "keepup" end
      data.defences.keepup = modes
      return "defences.keepup: " .. #list .. " entries moved to keepup mode"
   end,

   -- `venom` is the elixir; `poisonresist` is what Char.Defences calls the defence it
   -- grants. A saved entry under the elixir's name can never match, so keep-up raises it
   -- forever -- three elixirs and three balances before the attempt budget stops it. The
   -- mode is carried across so nobody has to notice and redo it.
   [4] = function(data)
      local modes = data.defences and data.defences.keepup
      if type(modes) ~= "table" or modes.venom == nil then return end
      modes.poisonresist = modes.poisonresist or modes.venom
      modes.venom = nil
      return "defences.keepup: venom -> poisonresist (the name Char.Defences uses)"
   end,

   -- Same bug, same fix, a session later: `blind` raises the defence but Char.Defences
   -- reports it as `blindness`. A saved entry under `blind` can never match, so keep-up
   -- raises it forever -- confirmed live, three raises of `eat bayberry` each answering
   -- "You are already blind" without ever registering, then the attempt budget stopping and
   -- naming `blindness` as an unclaimed Char.Defences name. See deflist.lua.
   [5] = function(data)
      local modes = data.defences and data.defences.keepup
      if type(modes) ~= "table" or modes.blind == nil then return end
      modes.blindness = modes.blindness or modes.blind
      modes.blind = nil
      return "defences.keepup: blind -> blindness (the name Char.Defences uses)"
   end,

   -- Confirmed live the same session as [5]: `deaf` raises the defence but Char.Defences
   -- reports it as `deafness` -- "Raised deaf 3 times and it never appeared in
   -- Char.Defences -- stopping", with `deafness` named as unclaimed. See deflist.lua.
   [6] = function(data)
      local modes = data.defences and data.defences.keepup
      if type(modes) ~= "table" or modes.deaf == nil then return end
      modes.deafness = modes.deafness or modes.deaf
      modes.deaf = nil
      return "defences.keepup: deaf -> deafness (the name Char.Defences uses)"
   end,

   -- Same family again: `levitation` is the elixir; Char.Defences reports the defence it
   -- grants as `levitating`. Confirmed live 18:20:50-18:21:03: three sips of the levitation
   -- elixir each answered "The elixir flows down your throat without effect", and the
   -- attempt budget's own diagnostic named `levitating` as unclaimed while DEF's own
   -- readout listed "You are walking on a small cushion of air." the whole time. See
   -- deflist.lua.
   [7] = function(data)
      local modes = data.defences and data.defences.keepup
      if type(modes) ~= "table" or modes.levitation == nil then return end
      modes.levitating = modes.levitating or modes.levitation
      modes.levitation = nil
      return "defences.keepup: levitation -> levitating (the name Char.Defences uses)"
   end,

   -- `immunity` is not a naming mismatch like the others above -- it IS `poisonresist`, the
   -- same defence venom grants. Confirmed live 18:28:28-18:28:48: it produces the exact DEF
   -- line poisonresist already shows, and sipping it while poisonresist was already up did
   -- not just waste the sip -- "As the antivenom ravages your system, you feel very unwell.
   -- You are confused as to the effects of the venom." An entry saved under `immunity` would
   -- keep sending a redundant, harmful dose forever. See deflist.lua.
   [8] = function(data)
      local modes = data.defences and data.defences.keepup
      if type(modes) ~= "table" or modes.immunity == nil then return end
      modes.poisonresist = modes.poisonresist or modes.immunity
      modes.immunity = nil
      return "defences.keepup: immunity -> poisonresist (the same defence venom grants)"
   end,

   -- Same family again: `frost` is the elixir; Char.Defences reports the defence it grants
   -- as `temperance`. Confirmed live 18:39:57.43-18:39:57.62: a sip answered "The elixir
   -- flows down your throat without effect", and the attempt budget's own diagnostic named
   -- `temperance` as unclaimed. See deflist.lua.
   [9] = function(data)
      local modes = data.defences and data.defences.keepup
      if type(modes) ~= "table" or modes.frost == nil then return end
      modes.temperance = modes.temperance or modes.frost
      modes.frost = nil
      return "defences.keepup: frost -> temperance (the name Char.Defences uses)"
   end,

   -- NOTE: bashing.attack moving from "smite" to "angel sear" is NOT a migration here, on
   -- purpose. Every entry above corrects a shipped default that was factually wrong --
   -- smite genuinely needed BOTH, the array genuinely became a map. Switching attacks is a
   -- deliberate strategy choice the user made (2026-08-04), not a bug, so an existing
   -- character keeps smite until it is changed on purpose: `emunah bash attack "angel sear"`
   -- and `emunah bash consumes eq`. Only a fresh config picks up the new default automatically.
}

local DEFAULTS = {
   logLevel  = "info",
   schema    = SCHEMA,

   ui = {
      enabled   = true,
      map       = true,
      mapHeight = 42,   -- percent of the window; `emset ui.mapHeight <n>`
      -- Adjustable.Container saves its own geometry; this is our own layout state.
      chatTabs = { "Tells", "City", "House", "Market", "Says", "Misc" },
   },

   curing = {
      enabled      = false,   -- opt in deliberately; never start curing on first load
      method       = "herbs", -- or "minerals" for Alchemists
      -- How long to wait for a cure confirmation before assuming it was lost and
      -- re-arming. Achaea round-trip is well under a second; 2s is forgiving without
      -- stalling a fight.
      confirmWait  = 2.0,
      -- Reconcile tracked afflictions against Char.Afflictions every N ticks.
      reconcileEvery = 20,
      -- Healing thresholds, as a percentage of the bar. Four sources, three resources:
      -- the elixir spends sip balance (health and mana share it, health first), irid moss
      -- its own balance, `perform hands` equilibrium. Only the elixir pair compete.
      healthThreshold = 80,
      manaThreshold   = 85,
      iridThreshold   = 68,
      handsThreshold  = 50,
   },

   defences = {
      enabled = false,
      keepup  = {},           -- defence names to restore when missing
   },

   walker = {
      avoid     = {},
      auto      = true,   -- step on its own; off hands pacing to a consumer
      stepDelay = 0.6,    -- seconds of quiet after a room change before stepping
   },

   keys = {
      numpad = true,
   },

   denizens = {
      autoRecord = true,   -- record denizens seen, per area; see denizens.lua
   },

   loot = {
      gold = true,
   },

   namedb = {
      -- Read CW, CLWHO, QW and the guardian angel's report; see namedb/capture.lua.
      capture   = true,
      -- Look a newly-seen name up on the Achaea web API. Off means the database still
      -- fills with names, just not with what they are.
      autoFetch = true,
   },

   names = {
      enabled  = true,   -- highlight known names in the game text
      -- Tint neutral strangers by their city. Off leaves every neutral the same dim tone,
      -- which some people prefer during a fight -- colour then means only enemy or ally.
      cityTint = true,
   },

   bashing = {
      attack          = "angel sear",  -- class attack command; target is appended
      -- What the attack REQUIRES to be present: "eq" | "bal" | "both".
      --
      -- THIS IS THE VALUE THAT WINS, not the fallback at the call site. M.get()
      -- returns whatever it finds here and only falls back when the key is ABSENT, so
      -- `config.get("bashing.balance", "both")` in class/priest.lua read "bal" and the
      -- fallback was dead code. Smite was confirmed to need BOTH at 09:09:41, but the
      -- default here was never moved with it -- so canAttack() never once consulted
      -- equilibrium, and three smites went into every penitence cooldown for as long as
      -- that was true (10:32:28, 10:45:48, 12:39:13, each spaced by the in-flight guard
      -- rather than by any balance). Angel Sear needs BOTH too (confirmed by the user,
      -- 2026-08-04), so this value carries over unchanged even though the attack itself did
      -- not.
      balance         = "both",
      -- Which ONE of the required resources the attack actually CONSUMES: "bal" | "eq".
      -- Smite required both but only ever spent balance; Sear requires both but only ever
      -- spends equilibrium (HELP SEAR: "Cooldown: 2.50 seconds of equilibrium", confirmed
      -- against balance too by the user, 2026-08-04) -- the mirror image. See
      -- class/priest.lua's M.attack for why arming the guard on the wrong one of these
      -- reopens the exact double-send bug it exists to close.
      consumes        = "eq",
      stopBelowHealth = 50,
      maxAttempts     = 40,       -- give up on a target that will not die
      walkWhenClear   = true,     -- hand back to the walker when the room is empty
      stopOnPlayer    = false,
   },

   pvp = {
      -- Higher than bashing's: a PvP loss costs more than a bashing one, and there is no
      -- "room is clear" backstop to catch a late stop the way there is in bashing.
      stopBelowHealth = 60,
   },

   -- Per-affliction priority overrides; the defaults live in curing/afflist.lua.
   priorities = {},
}

--- The shipped defaults, exposed so a test can assert against what actually ships rather
--- than against a value it set itself. See the note on `bashing.balance`.
M.DEFAULTS = DEFAULTS
M.SCHEMA   = SCHEMA

--- Apply any corrections this config predates. Idempotent: it runs on every load and every
--- reload, and does nothing once the stored schema has caught up.
--- @return boolean whether anything changed
function M.migrate(data)
   if type(data) ~= "table" then return false end
   local from = tonumber(data.schema) or 0
   if from >= SCHEMA then return false end

   local changed = false
   for version = from + 1, SCHEMA do
      local step = MIGRATIONS[version]
      local note = step and step(data)
      if note then
         changed = true
         log.warn("Config migrated -- %s", note)
      end
   end
   data.schema = SCHEMA
   return changed
end

M.data = util.copy(DEFAULTS)

--- Memoised path resolution: path -> { parent table, final key }.
---
--- WHY THIS IS MEMOISED. Splitting a path costs a gmatch, and gmatch allocates an iterator
--- on every call -- garbage produced in the one place that can least afford it. The curing
--- engine reads a couple of dozen settings per prompt (thresholds, confirm waits, every
--- feature switch, and the priority overrides once per tracked affliction per vector), and
--- settings change when a human types `emunah set`, which is to say almost never.
---
--- WHAT IS CACHED IS THE ROUTE, NOT THE ANSWER, and that distinction is the whole design.
--- Caching resolved VALUES looked obviously right and was wrong: anything that assigns into
--- M.data directly -- `M.data.bashing.balance = nil` -- changes the setting without
--- going through set(), and a value cache goes on answering with what it saw first. The
--- suite caught it immediately (the shipped-default assertions read nil through a stale
--- MISS), and a live version of that bug is a setting the user has changed that nothing
--- honours until the next reload.
---
--- Holding the parent table and re-reading the final key costs one extra hash lookup and
--- makes every leaf write visible, however it was made. Only REPLACING an intermediate table
--- can invalidate a cached route, and the three places that do -- set(), load(), reset() --
--- all call invalidate().
local cache = {}

--- A path that resolves through something that does not exist. Distinct from a cached nil,
--- which is simply a cache miss.
local MISS = {}

--- Drop the memo. Anything that REPLACES a table inside M.data has to call this;
--- assigning a leaf value does not need to.
function M.invalidate()
   cache = {}
end

--- Walk a dotted path to the table holding its final key.
--- @return table|nil parent, string|nil key
local function route(path)
   local node = M.data
   local key = nil
   for part in path:gmatch("[^.]+") do
      if key ~= nil then
         -- The previous part was not the last after all, so descend through it.
         if type(node) ~= "table" then return nil end
         node = node[key]
         if type(node) ~= "table" then return nil end
      end
      key = part
   end
   if key == nil or type(node) ~= "table" then return nil end
   return node, key
end

--- Read a dotted setting: config.get("curing.confirmWait")
function M.get(path, fallback)
   -- Only string paths are memoised; anything else is rare enough not to be worth a key.
   if type(path) ~= "string" then
      local node = M.data
      for part in tostring(path):gmatch("[^.]+") do
         if type(node) ~= "table" then return fallback end
         node = node[part]
         if node == nil then return fallback end
      end
      return node
   end

   local hit = cache[path]
   if hit == nil then
      local parent, key = route(path)
      hit = parent and { parent, key } or MISS
      cache[path] = hit
   end
   if hit == MISS then return fallback end

   local value = hit[1][hit[2]]
   if value == nil then return fallback end
   return value
end

--- Write a dotted setting. Does not save to disk; call config.save() for that.
function M.set(path, value)
   local parts = {}
   for part in tostring(path):gmatch("[^.]+") do parts[#parts + 1] = part end
   if #parts == 0 then return false end
   local node = M.data
   for i = 1, #parts - 1 do
      if type(node[parts[i]]) ~= "table" then node[parts[i]] = {} end
      node = node[parts[i]]
   end
   node[parts[#parts]] = value
   -- Wholesale, not just this path: writing "curing" replaces the table that
   -- "curing.confirmWait" resolves through, and writing a leaf can create the intermediate
   -- tables that other paths were previously missing through.
   M.invalidate()
   return true
end

function M.save()
   local ok, err = pcall(table.save, PATH, M.data)
   if not ok then
      log.error("Could not save settings: %s", tostring(err))
      return false
   end
   log.debug("Settings saved to %s", PATH)
   return true
end

--- Load from disk, filling any gaps from DEFAULTS so upgrades are non-breaking.
function M.load()
   local loaded = {}
   local file = io.open(PATH, "r")
   if file then
      file:close()
      local ok, err = pcall(table.load, PATH, loaded)
      if not ok then
         log.error("Settings file at %s is unreadable (%s); using defaults.", PATH, tostring(err))
         loaded = {}
      end
   end

   -- Recursive fill: missing keys take the default, present keys win.
   local function fill(target, defaults)
      for key, value in pairs(defaults) do
         if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            fill(target[key], value)
         elseif target[key] == nil then
            target[key] = value
         end
      end
   end
   -- BEFORE fill, not after. `schema` is itself a default, so filling first would stamp
   -- the current version onto a config that predates every migration and the whole
   -- mechanism would no-op on exactly the files it exists for.
   M.migrate(loaded)
   fill(loaded, DEFAULTS)

   M.data = loaded
   M.invalidate()
   log.setLevel(M.data.logLevel or "info")
   return M.data
end

function M.reset()
   M.data = util.copy(DEFAULTS)
   M.invalidate()
   log.setLevel(M.data.logLevel)
   return M.data
end

M.path = PATH

-- Reload behaviour.
--
-- A reload re-requires this module, so `M.data` is rebuilt from DEFAULTS every time
-- and the module table itself cannot carry settings forward -- the loader's assign()
-- replaces emunah.config wholesale. The settings therefore live on emunah._persist,
-- which the loader preserves verbatim, and the module table only ever holds a reference
-- to them. Without this, every reload would quietly discard unsaved priority changes.
emunah._persist = emunah._persist or {}

if emunah._persist.configData then
   M.data = emunah._persist.configData
   M.invalidate()
   -- A reload restores this table verbatim, which is exactly how a wrong default outlives
   -- the fix for it. Migrate here too, or `emreload` is the one path that never corrects.
   M.migrate(M.data)
   log.setLevel(M.data.logLevel or "info")
else
   M.load()
end

-- Keep the persistent reference pointing at whatever load()/reset() installed.
local function republish(fn)
   return function(...)
      local result = fn(...)
      emunah._persist.configData = M.data
      return result
   end
end
M.load  = republish(M.load)
M.reset = republish(M.reset)
emunah._persist.configData = M.data

return M

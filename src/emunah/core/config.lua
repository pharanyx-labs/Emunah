--- Persistent settings.
---
--- Stored per Mudlet profile (getMudletHomeDir() is profile-specific), so two characters
--- in the same Mudlet installation keep separate priorities, defence lists and UI
--- positions without any extra work.

local config = {}

local util = emunah.util
local log  = emunah.log

local PATH = getMudletHomeDir() .. "/emunah-config.lua"

--- Defaults. Anything absent from the saved file falls back to these, so adding a new
--- setting in a later version does not require users to delete their config.
--- Bump when a shipped default was WRONG, not merely changed.
---
--- Changing DEFAULTS is not enough to fix a wrong one, and that is not obvious: a saved
--- config keeps its own copy, and `fill()` below only supplies keys that are ABSENT. A
--- reload does not even get that far -- config.data is restored wholesale from
--- emunah._persist. So a bad default, once written or once carried across a reload, is
--- permanent until something rewrites it. That is what MIGRATIONS is for.
local SCHEMA = 1

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
}

local DEFAULTS = {
   logLevel  = "info",
   schema    = SCHEMA,

   ui = {
      enabled   = true,
      map       = true,
      mapHeight = 42,   -- percent of the window; `emunah ui map height <n>`
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
      autoRecord = true,   -- record denizens seen, per area; prune with 'emunah mobs skip'
   },

   loot = {
      gold = true,
   },

   bashing = {
      attack          = "smite",  -- class attack command; target is appended
      -- What the attack costs: "eq" | "bal" | "both".
      --
      -- THIS IS THE VALUE THAT WINS, not the fallback at the call site. config.get()
      -- returns whatever it finds here and only falls back when the key is ABSENT, so
      -- `config.get("bashing.balance", "both")` in class/priest.lua read "bal" and the
      -- fallback was dead code. Smite was confirmed to need BOTH at 09:09:41, but the
      -- default here was never moved with it -- so canAttack() never once consulted
      -- equilibrium, and three smites went into every penitence cooldown for as long as
      -- that was true (10:32:28, 10:45:48, 12:39:13, each spaced by the in-flight guard
      -- rather than by any balance).
      balance         = "both",
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
config.DEFAULTS = DEFAULTS
config.SCHEMA   = SCHEMA

--- Apply any corrections this config predates. Idempotent: it runs on every load and every
--- reload, and does nothing once the stored schema has caught up.
--- @return boolean whether anything changed
function config.migrate(data)
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

config.data = util.copy(DEFAULTS)

--- Read a dotted setting: config.get("curing.confirmWait")
function config.get(path, fallback)
   local node = config.data
   for part in tostring(path):gmatch("[^.]+") do
      if type(node) ~= "table" then return fallback end
      node = node[part]
      if node == nil then return fallback end
   end
   return node
end

--- Write a dotted setting. Does not save to disk; call config.save() for that.
function config.set(path, value)
   local parts = {}
   for part in tostring(path):gmatch("[^.]+") do parts[#parts + 1] = part end
   if #parts == 0 then return false end
   local node = config.data
   for i = 1, #parts - 1 do
      if type(node[parts[i]]) ~= "table" then node[parts[i]] = {} end
      node = node[parts[i]]
   end
   node[parts[#parts]] = value
   return true
end

function config.save()
   local ok, err = pcall(table.save, PATH, config.data)
   if not ok then
      log.error("Could not save settings: %s", tostring(err))
      return false
   end
   log.debug("Settings saved to %s", PATH)
   return true
end

--- Load from disk, filling any gaps from DEFAULTS so upgrades are non-breaking.
function config.load()
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
   config.migrate(loaded)
   fill(loaded, DEFAULTS)

   config.data = loaded
   log.setLevel(config.data.logLevel or "info")
   return config.data
end

function config.reset()
   config.data = util.copy(DEFAULTS)
   log.setLevel(config.data.logLevel)
   return config.data
end

config.path = PATH

-- Reload behaviour.
--
-- A reload re-requires this module, so `config.data` is rebuilt from DEFAULTS every time
-- and the module table itself cannot carry settings forward -- the loader's assign()
-- replaces emunah.config wholesale. The settings therefore live on emunah._persist,
-- which the loader preserves verbatim, and the module table only ever holds a reference
-- to them. Without this, every reload would quietly discard unsaved priority changes.
emunah._persist = emunah._persist or {}

if emunah._persist.configData then
   config.data = emunah._persist.configData
   -- A reload restores this table verbatim, which is exactly how a wrong default outlives
   -- the fix for it. Migrate here too, or `emreload` is the one path that never corrects.
   config.migrate(config.data)
   log.setLevel(config.data.logLevel or "info")
else
   config.load()
end

-- Keep the persistent reference pointing at whatever load()/reset() installed.
local function republish(fn)
   return function(...)
      local result = fn(...)
      emunah._persist.configData = config.data
      return result
   end
end
config.load  = republish(config.load)
config.reset = republish(config.reset)
emunah._persist.configData = config.data

return config

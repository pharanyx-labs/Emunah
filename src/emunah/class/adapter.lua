--- Class adapter.
---
--- STATUS: interface + auto-detection only. There is no offence module yet, because the
--- class has not been chosen.
---
--- You picked the Forestal / Monk / Priest / Bard archetype, which is six classes that
--- share a grouping and almost nothing mechanically: Monk tracks Kai and stance, Priest
--- tracks devotion, Bard runs vibes and voice balances, Druid and Sylvan run nature
--- spirits and vines, Sentinel runs beasts and traps. An "archetype offence module" would
--- be six half-modules, none of which works properly.
---
--- Everything else in Emunah is class-agnostic and works today. When you name the class,
--- implementing it means filling in the table below -- the rest of the system consumes it
--- through this interface and needs no changes.
---
--- THE INTERFACE
--- -------------
--- The system calls into the adapter, never the reverse, so a class module can be swapped
--- without touching the engine.
---
---   adapter.attack(target)      -- send the primary attack
---   adapter.canAttack()         -- balance/resource check before attacking
---   adapter.handleShield(t)     -- how this class breaks a shielded target
---   adapter.onTick(vitals)      -- per-prompt hook for class resources
---   adapter.stats()             -- named class resources for the UI
---
--- Anything left nil is simply not used.

local M = {}

local log = emunah.log

--- Skillsets that identify each class, used for auto-detection. Char.Skills.Groups gives
--- us these on login, so the system can tell you what you are without being told.
M.SKILLSET_TO_CLASS = {
   kaido       = "monk",
   telepathy   = "monk",
   devotion    = "priest",
   spirituality = "priest",
   voicecraft  = "bard",
   harmonics   = "bard",
   groves      = "druid",
   metamorphosis = "druid",
   nature      = "sylvan",
   elicit      = "sylvan",
   woodlore    = "sentinel",
   tracking    = "sentinel",
}

--- The active class module, or nil.
M.active = nil

--- Best guess at the character's class.
---
--- Char.Status.class is authoritative when present; skillset inference is the fallback,
--- since Status arrives later than Skills on some logins.
function M.detect()
   local fromStatus = emunah.gmcp.status.class()
   if fromStatus and fromStatus ~= "" then
      return tostring(fromStatus):lower()
   end

   local skills = emunah.gmcp.skills
   if skills then
      for skillset, class in pairs(M.SKILLSET_TO_CLASS) do
         if skills.hasGroup(skillset) then return class end
      end
   end
   return nil
end

--- Load a class module by name from emunah/class/<name>.lua, if one exists.
---
--- Uses dofile against an absolute path rather than require(). The loader extends
--- package.path only for the duration of its own run and restores it afterwards, so by
--- the time a class is detected -- which happens later, when Char.Skills completes --
--- require("emunah.class.priest") cannot find anything. The module would silently never
--- load and the bashing loop would report "no class module" forever.
function M.load(name)
   name = tostring(name or ""):lower()
   if name == "" then return false end

   local root = emunah._root
   if not root then
      log.debug("No checkout root recorded; cannot load class module %q.", name)
      return false
   end

   local path = string.format("%s/src/emunah/class/%s.lua", root, name)
   local file = io.open(path, "r")
   if not file then
      log.debug("No class module for %q (%s).", name, path)
      return false
   end
   file:close()

   local ok, module = pcall(dofile, path)
   if not ok or type(module) ~= "table" then
      log.error("Class module %q failed to load: %s", name, tostring(module))
      return false
   end

   M.active = module
   M.name = name
   log.info("Loaded class module: <ansi_cyan>%s<ansi_yellow>.", name)
   emunah.event.raise("class.loaded", name)
   return true
end

-- ---------------------------------------------------------------------------
-- interface passthroughs
--
-- Each returns a sensible no-op result when no class module is loaded, so callers do not
-- have to check first.
-- ---------------------------------------------------------------------------

function M.attack(target)
   if M.active and M.active.attack then return M.active.attack(target) end
   return false
end

function M.canAttack()
   if M.active and M.active.canAttack then return M.active.canAttack() end
   -- Without a class module, the honest generic answer: balance and equilibrium.
   local vitals = emunah.gmcp.vitals
   return vitals and vitals.bal and vitals.eq or false
end

function M.handleShield(target)
   if M.active and M.active.handleShield then return M.active.handleShield(target) end
   return false
end

function M.onTick(vitals)
   if M.active and M.active.onTick then return M.active.onTick(vitals) end
end

--- Named class resources for the vitals panel. With no class module this falls back to
--- whatever Char.Vitals.charstats already gives us, which for Monk and Priest is most of
--- what a class module would have surfaced anyway.
function M.stats()
   if M.active and M.active.stats then return M.active.stats() end
   local vitals = emunah.gmcp.vitals
   return vitals and vitals.stats or {}
end

-- ---------------------------------------------------------------------------

emunah.event.register("emunah.tick", function()
   local vitals = emunah.gmcp.vitals
   M.onTick(vitals)
end, "class")

--- Try to identify and load. Safe to call from more than one trigger: M.load() only
--- actually reloads when the detected class differs from what is already active, so
--- whichever signal arrives first wins and the other becomes a no-op.
local function tryDetect()
   local detected = M.detect()
   if not detected or detected == M.name then return end

   -- A change, rather than first detection, invalidates more than this module. The attack
   -- command, what it costs and the class resource are all configured per class, so an
   -- automated loop carrying on across the change would be sending the previous class's
   -- attack. Stop and say so rather than swap the module out underneath a running fight.
   local changing = M.name ~= nil
   if changing then
      log.warn("Class changed: <ansi_cyan>%s<ansi_yellow> -> <ansi_cyan>%s<ansi_yellow>.",
         M.name, detected)
   else
      log.info("Detected class: <ansi_cyan>%s<ansi_yellow>.", detected)
   end

   M.load(detected)

   if changing then
      if emunah.bashing and emunah.bashing.enabled then
         emunah.bashing.stop("class changed")
      end
      if emunah.pvp and emunah.pvp.enabled then
         emunah.pvp.stop("class changed")
      end
      log.warn("Check 'emset bash attack' -- the attack command is per class.")
   end
end

-- Two independent signals can tell us the class, and they do not arrive in a fixed order:
-- Char.Status.class is often the FASTER one (a single message), while the skill index
-- needs a full Groups -> per-group Get -> List round trip. Waiting on skills alone means a
-- command typed just after connecting -- "Detected class: Priest" already true from
-- Status, but the skill round trip still in flight -- fails with "No class module loaded"
-- even though the class was already knowable. React to whichever finishes first.
emunah.event.register("emunah.skills.complete", tryDetect, "class")
emunah.event.register("emunah.status", tryDetect, "class")

-- Both signals can ALREADY be sitting there by the time this module loads -- gmcp.status
-- and gmcp.skills load earlier in the manifest, and each fires its own "already have data"
-- event synchronously at ITS OWN load time (see the same pattern at the bottom of
-- gmcp/status.lua, gmcp/skills.lua, etc). On an emreload with an existing connection, that
-- means "emunah.status" can fire and finish BEFORE the two lines above ever register --
-- the listener is not late, the event already happened. Every other module in this tree
-- checks "is the answer already available" once at its own load time for exactly this
-- reason; this was the one place that only ever reacted to a future event.
tryDetect()

return M

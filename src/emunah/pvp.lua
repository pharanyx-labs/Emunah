--- PvP targeting.
---
--- The player-combat counterpart to bashing.lua, and deliberately NOT a retrofit of it.
--- bashing.lua's denizens.here()/next() auto-acquire the next monster because a bashing
--- loop is supposed to keep fighting on its own; that is exactly wrong for a player
--- target, where acquiring the wrong person automatically is a much worse failure than
--- acquiring nothing. So this module never picks a target itself -- `emunah pvp target
--- <name>` is the only way one is set.
---
--- Why not read Room.Players and go from there? gmcp/room.lua's own header says it best:
--- "the player list is not complete... anyone concealed generates no entry at all... never
--- treat as players in the room." A targeting loop built on that list would happily forget
--- an opponent who shrouds mid-fight, which is the opposite of what you want in PvP.
--- Targeting here is a name the user typed, full stop.
---
--- MUTUAL EXCLUSION WITH BASHING
--- -----------------------------
--- Fighting a denizen and a player on the same balance is not a thing. `M.start()` raises
--- `emunah.bashing.pause`, which bashing.lua already listens for and stops itself on; this
--- module listens for `emunah.bashing.started` (which bashing.lua already raises
--- unconditionally on every start) and stops itself in turn. Neither file has to know the
--- other exists beyond that shared event vocabulary.
---
--- WHAT THIS DOES NOT DO YET
--- -------------------------
--- No offensive-affliction sequencing -- `class.attack(target)` sends whatever single
--- attack the loaded class module knows, same as bashing. No detection of an opponent
--- fleeing or conceding -- a PvP session otherwise runs until you stop it or your own
--- health trips the safety threshold. Guessing either of those is exactly the kind of
--- plausible-but-wrong assertion the rest of this codebase avoids -- see curing/detect/
--- patterns.lua's header for the same principle applied to affliction messages.
---
--- What IS detected, because Achaea's own system messages for it are unambiguous: killing
--- your target ("You have slain <name>.") clears the target and stops the session, and
--- your own death ("You have been slain by...") stops it as an emergency safety measure --
--- there is nothing useful left to do with a dead character.

local M = {}

local log   = emunah.log
local event = emunah.event

M.enabled = false
M.target  = nil   -- opponent name (lower), or nil -- never auto-acquired
M.stats   = { attacks = 0, startedAt = 0 }

M.config = {
   -- Higher than bashing's default: a PvP loss is a worse outcome than a PvE one, and
   -- there is no "room is clear" backstop to fall back on if this fires late.
   stopBelowHealth = 60,
}

local function setting(key)
   local value = emunah.config.get("pvp." .. key)
   if value == nil then return M.config[key] end
   return value
end

-- ---------------------------------------------------------------------------
-- targeting
-- ---------------------------------------------------------------------------

--- The only way a target is ever set. Deliberately takes whatever name the user gives it
--- rather than validating against Room.Players -- that list can omit the very opponent you
--- are trying to target.
function M.setTarget(name)
   name = tostring(name or ""):lower()
   if name == "" then return false end

   -- AN ALLY IS NEVER A TARGET, and neither are we. Targeting here is already explicit --
   -- nothing auto-acquires -- so this is not protection against the loop picking wrongly,
   -- it is protection against a typo, a name resolved from game text, or a stale target
   -- surviving a change of allegiance. The name database is the one place that knows.
   local ndb = emunah.namedb
   if ndb and not ndb.attackable(name) then
      log.warn("Refusing to target <ansi_cyan>%s<ansi_yellow> -- %s. "
         .. "`emunah iff %s auto` if that is wrong.",
         name, ndb.relationship(name), name)
      return false
   end

   M.target = name

   local ire = emunah.gmcp.ire
   if ire and ire.setTarget then ire.setTarget(name) end

   log.info("PvP target: <ansi_cyan>%s<ansi_yellow>.", name)
   event.raise("pvp.target", name)
   return true
end

function M.clearTarget()
   M.target = nil
   event.raise("pvp.target", nil)
end

-- ---------------------------------------------------------------------------
-- control
-- ---------------------------------------------------------------------------

function M.start()
   if M.enabled then
      log.warn("Already in PvP mode. 'emunah pvp stop' first.")
      return false
   end

   local class = emunah.class
   if not (class and class.active and class.active.attack) then
      log.error("No class module loaded -- nothing knows how to attack.")
      log.error("Detected class: %s", tostring(emunah.gmcp.status.class() or "unknown"))
      return false
   end

   M.enabled = true
   M.stats = { attacks = 0, startedAt = emunah.util.now() }

   -- event.raise() prefixes with "emunah.", so this produces "emunah.bashing.pause" --
   -- exactly the raw name bashing.lua already registers a listener for.
   event.raise("bashing.pause")

   log.info("PvP <ansi_light_green>on<ansi_yellow>.")
   event.raise("pvp.started")
   return true
end

function M.stop(reason)
   if not M.enabled then return false end
   M.enabled = false

   local elapsed = emunah.util.now() - (M.stats.startedAt or emunah.util.now())
   log.info("PvP stopped: %d attack%s in %s%s.",
      M.stats.attacks, M.stats.attacks == 1 and "" or "s",
      emunah.util.duration(elapsed), reason and (" (" .. reason .. ")") or "")
   event.raise("pvp.stopped", reason)
   return true
end

function M.toggle()
   if M.enabled then M.stop("requested") else M.start() end
   return M.enabled
end

-- ---------------------------------------------------------------------------
-- the loop
-- ---------------------------------------------------------------------------

--- Should we stop for safety? Own health only -- see the module header for why this does
--- not also try to infer that the fight is over from the room's player list.
local function unsafe()
   local vitals = emunah.gmcp.vitals
   local threshold = tonumber(setting("stopBelowHealth")) or 60

   if vitals and threshold > 0 and vitals.percent.hp < threshold then
      return ("health below %d%%"):format(threshold)
   end

   local watched = emunah.watch and emunah.watch.unsafe()
   if watched then return watched end
   return nil
end

--- One pass. Driven by the prompt, like bashing.tick().
function M.tick()
   if not M.enabled then return end

   local reason = unsafe()
   if reason then
      M.stop(reason)
      return
   end

   if not M.target then return end

   local class = emunah.class
   if class.canAttack() then
      class.attack(M.target)
      M.stats.attacks = M.stats.attacks + 1
   end
end

--- Report, for `emunah pvp`.
function M.report()
   local elapsed = M.enabled and (emunah.util.now() - M.stats.startedAt) or 0
   return {
      running     = M.enabled,
      target      = M.target,
      attacks     = M.stats.attacks,
      elapsed     = elapsed,
      classLoaded = (emunah.class and emunah.class.name) or nil,
   }
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

event.register("emunah.tick", function() M.tick() end, "pvp")

-- Bashing and PvP must never run concurrently -- see the module header. event.raise()
-- prefixes with "emunah.", so this listens for what bashing.lua's event.raise("bashing.
-- started") actually produces: "emunah.bashing.started".
event.register("emunah.bashing.started", function()
   if M.enabled then M.stop("bashing started") end
end, "pvp")

event.register("sysDisconnectionEvent", function()
   if M.enabled then M.stop("disconnected") end
end, "pvp")

-- ---------------------------------------------------------------------------
-- death detection -- unambiguous system messages, not a guess
-- ---------------------------------------------------------------------------

local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.pvpTriggers = emunah._persist.pvpTriggers or {}
   return emunah._persist.pvpTriggers
end

local function killAllTriggers()
   local reg = registry()
   for _, id in ipairs(reg) do killTrigger(id) end
   emunah._persist.pvpTriggers = {}
end

killAllTriggers()

-- "You have slain <name>." is Achaea's own kill confirmation. Only acts when the slain
-- name matches the current target -- killing a denizen mid-bash should not be mistaken
-- for a PvP win (though the two loops are already mutually exclusive, so this is a second,
-- cheap layer of the same guarantee).
table.insert(registry(), tempRegexTrigger([[^You have slain (\w+)\.$]], function()
   local name = matches and matches[2] and matches[2]:lower()
   if not (M.enabled and name and M.target == name) then return end
   log.info("PvP target defeated.")
   M.clearTarget()
   M.stop("target defeated")
end))

-- Own death. Nothing useful left to do with a dead character -- stop rather than keep
-- sending attack commands into the void.
table.insert(registry(), tempRegexTrigger([[^You have been slain by]], function()
   if not M.enabled then return end
   M.stop("you died")
end))

return M

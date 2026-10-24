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
--- MODES AND LANES
--- ---------------
--- "Overwhelm my pvp opponent with a range of afflictions, damage, and finisher moves ...
--- set rules via f5-8 that will enter various pvp modes" (the user, 2026-10-15). The keys
--- are F1-F4 now (2026-10-22): F1 attack, F2 defence, F3 hinder, F4 finish. F12 turns
--- whichever is up off, and F1 again turns attack off (2026-10-23). Offence stays a mode, with no key of its own. Each tick, every
--- balance that is free -- prayer, balance,
--- equilibrium -- asks the class what this mode sends on it (class/priest_pvp.lua), and
--- sends it. Nothing here knows a Priest from any other class.
---
--- WHAT THIS DOES NOT DO YET
--- -------------------------
--- No detection of an opponent fleeing or conceding -- a PvP session otherwise runs until you stop it or your own
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
M.held    = nil   -- the locks holding the attack back, as shown, or nil
M.stats   = { attacks = 0, recited = 0, startedAt = 0, lanes = {} }

--- The modes. The first four are F1-F4. Offence has no key: it is what `emset pvp on`
--- starts in. What each sends is the class's (M.MODES there).
M.MODES = { "attack", "defence", "hinder", "finish", "offence" }

--- Opponents whose aura of rebounding turned our mace back, until it is seen going down.
M.rebounding = {}
--- Opponents behind an Alchemist's reflective barrier (tin), until it is seen shattering.
M.reflecting = {}

M.config = {
   -- Lowered from 60 by the user, 2026-10-15. A fight against a person is not over when it
   -- hurts, and stopping does not stop them hitting. It replaces watch.critical for PvP
   -- (see unsafe() below), which would otherwise stop it at 30 first.
   stopBelowHealth = 25,
   -- The mode a fresh session starts in. F1-F4 change it.
   mode = "offence",
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
         .. "`emset iff %s auto` if that is wrong.",
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
      log.warn("Already in PvP mode. 'emset pvp off' first.")
      return false
   end

   local class = emunah.class
   if not (class and class.active) then
      log.error("No class module loaded -- nothing knows how to attack.")
      log.error("Detected class: %s", tostring(emunah.gmcp.status.class() or "unknown"))
      return false
   end
   -- PvP is the class's PvP offence, never the hunt's attack (class/priest_pvp.lua). A
   -- class without one has no PvP here yet.
   if not class.active.pvpPlan then
      log.error("%s has no PvP offence yet.", tostring(class.name))
      return false
   end

   M.enabled = true
   M.stats = { attacks = 0, recited = 0, startedAt = emunah.util.now(), lanes = {} }

   -- A HUNT IS BASHING AND THE WALKER. The pause below stops bashing, which hands the walker
   -- its pacing back, and an unclaimed walker steps on by itself -- so PvP started with you
   -- still wandering the area. Stop the walk outright, without the walk home.
   local walker = emunah.walker
   if walker and walker.enabled then walker.stop("pvp", true) end

   -- event.raise() prefixes with "emunah.", so this produces "emunah.bashing.pause" --
   -- exactly the raw name bashing.lua already registers a listener for.
   event.raise("bashing.pause")

   log.info("PvP <ansi_light_green>on<ansi_yellow> (%s).", M.mode())
   if not M.target then
      log.warn("No target yet -- nothing is sent until 'emset pvp target <name>'.")
   end
   event.raise("pvp.started")
   return true
end

function M.stop(reason)
   if not M.enabled then return false end
   M.enabled = false
   M.held = nil
   M.closeAlert()

   local elapsed = emunah.util.now() - (M.stats.startedAt or emunah.util.now())
   -- Sent, not landed: a send the game refused is in these too.
   local verses = M.stats.recited or 0
   log.info("PvP stopped: %d attack%s and %d verse%s sent in %s%s.",
      M.stats.attacks, M.stats.attacks == 1 and "" or "s",
      verses, verses == 1 and "" or "s",
      emunah.util.duration(elapsed), reason and (" (" .. reason .. ")") or "")
   event.raise("pvp.stopped", reason)
   return true
end

function M.toggle()
   if M.enabled then M.stop("requested") else M.start() end
   return M.enabled
end

--- The mode in force.
function M.mode()
   local mode = emunah.config.get("pvp.mode", M.config.mode)
   for _, known in ipairs(M.MODES) do
      if known == mode then return mode end
   end
   return M.config.mode
end

--- Enter a mode (F1-F4, or `emset pvp mode`), turning PvP on if it is off.
function M.setMode(mode)
   mode = tostring(mode or ""):lower()
   local known = false
   for _, name in ipairs(M.MODES) do if name == mode then known = true end end
   if not known then
      log.warn("No PvP mode %q. Modes: %s.", mode, table.concat(M.MODES, ", "))
      return false
   end
   emunah.config.set("pvp.mode", mode); emunah.config.save()
   log.info("PvP mode: <ansi_light_green>%s<ansi_yellow>.", mode)
   event.raise("pvp.mode", mode)
   if not M.enabled then M.start() end
   M.now()
   return true
end

--- Act now, not on the next prompt. The loop runs on the prompt, and an idle fight has
--- none coming: F1 pressed with nothing happening sent nothing until the user typed a
--- command to bring a prompt (the user, 2026-10-23). So a heartbeat runs at once, on the
--- balances the last prompt left: the whole prompt, not just this loop, so the fight's
--- opening rites and the cures keep their turn ahead of the attack.
function M.now()
   if not (M.enabled and M.target) then return end
   local vitals = emunah.gmcp and emunah.gmcp.vitals
   if vitals and vitals.heartbeat then vitals.heartbeat() else emunah.act.batched(M.tick) end
end

--- `t <name>`: target them and put PvP on its fight footing, without attacking. "When i
--- type t <pvp target> have it enable pvp mode but not actually start it. then, when i hit
--- f1, it starts attacking them" (the user, 2026-10-23). A fresh session starts in defence,
--- which holds the attack while curing and keep-up run as they do in a fight. A session
--- already running keeps its mode, and turns on the new target at once.
function M.engage(name)
   if not M.setTarget(name) then return false end
   if M.enabled then
      M.now()
      return true
   end
   emunah.config.set("pvp.mode", "defence"); emunah.config.save()
   event.raise("pvp.mode", "defence")
   if not M.start() then return false end
   log.info("Holding. <ansi_light_green>F1<ansi_yellow> attacks %s; F3 hinders, F4 "
      .. "finishes.", emunah.util.capitalise(M.target))
   return true
end

--- F1: attack mode, or PvP off when attack is already running. "If i hit f1 to pvp
--- somebody and then press f1 again, you stop" (the user, 2026-10-23). F2-F4 only enter
--- their mode, replacing whichever was running.
function M.attackKey()
   if M.enabled and M.mode() == "attack" then return M.stop("F1") end
   return M.setMode("attack")
end

-- ---------------------------------------------------------------------------
-- the loop
-- ---------------------------------------------------------------------------

--- Should we stop for safety? Own state only -- see the module header for why this does
--- not also try to infer that the fight is over from the room's player list.
---
--- The health floor here REPLACES watch.critical rather than sitting beside it: at 30 that
--- would stop PvP before its own 25 was ever reached. And PvP is always fighting, so the
--- damage spike is advisory, for the reason watch.lua gives for denizens: stopping does not
--- stop the person hitting you.
local function unsafe()
   local vitals = emunah.gmcp.vitals
   local threshold = tonumber(setting("stopBelowHealth")) or 25

   if vitals and threshold > 0 and vitals.percent.hp < threshold then
      return ("health below %d%%"):format(threshold)
   end

   local watched = emunah.watch and emunah.watch.unsafe({ fighting = true, critical = 0 })
   if watched then return watched end
   return nil
end

--- The locks you are in (watch.locks()), or nil when none.
---
--- A lock holds the ATTACK, not the session: the attack sends straight past the cure queue
--- (see handsWanted() below), and the cures that break a lock -- standing, writhing,
--- concentrating, `perform hands` -- want the same balance and equilibrium. When it breaks,
--- the attack carries on. Verses are not held: prayer balance is shared with no cure.
local function locked()
   local watch = emunah.watch
   local locks = watch and watch.locks and watch.locks()
   if not locks or #locks == 0 then return nil end
   return table.concat(locks, ", ")
end

--- Is `perform hands` actually wanted right now?
---
--- The attack sends directly the instant its own resources are free (see class/priest.lua's
--- M.attack()), bypassing the priority queue `perform hands` and every other cure shares --
--- so an active PvP session attacking every tick can keep re-claiming equilibrium before the
--- queue ever gets a turn to send the heal it already wants. Mirrors curing.handsThreshold
--- exactly (see queueHealing() in curing/engine.lua) rather than inventing a second number
--- that could drift out of sync with it.
local function handsWanted()
   local vitals = emunah.gmcp.vitals
   if not vitals then return false end
   local handsAt = tonumber(emunah.config.get("curing.handsThreshold", 50)) or 50
   return vitals.trusted("hp") and vitals.percent.hp < handsAt
end

--- Their health as a percentage, when the game has said: IRE.Target.Info for the target we
--- set by name. Nothing else is believed -- not a guess from damage dealt. Nil until then.
function M.targetHealth()
   local ire = emunah.gmcp.ire
   local target = ire and ire.target
   if not (M.target and target and target.health) then return nil end
   if tostring(target.id or ""):lower() ~= M.target then return nil end
   return target.health
end

--- What the class decides on: the target as the game has confirmed it. Afflictions are the
--- opponent tracker's (landing, symptom and cure lines); nothing is assumed.
local function context(mode)
   local opponent = emunah.curing and emunah.curing.detect and emunah.curing.detect.opponent
   local afflictions = {}
   if opponent then
      for _, name in ipairs(opponent.list(M.target)) do afflictions[name] = true end
   end
   local active = emunah.class.active
   local locks, lockNeeds, blocked, defences = {}, {}, {}, {}
   if opponent and M.target then
      locks = opponent.lockProgress(M.target)
      lockNeeds = opponent.lockNeeds(M.target)
      blocked = opponent.blockedVectors(M.target)
      for _, name in ipairs(opponent.defenceList(M.target)) do defences[name] = true end
   end
   return {
      target      = M.target,
      mode        = mode,
      afflictions = afflictions,
      -- The locks they are in, what closing the hard and venom locks still needs (in that
      -- order), their curing routes shut and by what, and their defences seen going up.
      locks       = locks,
      lockNeeds   = lockNeeds,
      blocked     = blocked,
      defences    = defences,
      mana        = active and active.mana and active.mana(M.target) or nil,
      health      = M.targetHealth(),
      heresy      = emunah.have.def("heresy"),
      rebounding  = M.rebounding[M.target] == true,
      reflecting  = M.reflecting[M.target] == true,
   }
end

--- The lanes, in the order they are offered a turn.
M.LANES = { "prayer", "balance", "equilibrium" }

--- One pass. Driven by the prompt, like bashing.tick().
function M.tick()
   if not M.enabled then return end

   local reason = unsafe()
   if reason then
      M.stop(reason)
      return
   end

   if not M.target then return end

   local lock = locked()
   if lock ~= M.held then
      if lock then
         log.warn("Locked (%s): holding the attack for your cures.", lock)
      else
         log.info("Lock broken: attacking again.")
      end
      M.held = lock
   end

   -- EVERY FREE BALANCE, EVERY TICK. A verse and a mace blow, or a verse and an
   -- equilibrium move, go out on the same prompt: the verse needs both balances and spends
   -- neither, so it goes first, and the move after it arms what it spends as it leaves.
   --
   -- Balance and equilibrium sit out a lock (the cures that break it want them), and
   -- equilibrium sits out while `perform hands` is wanted. Prayer is shared with no cure.
   local active = emunah.class.active
   if not (active and active.pvpPlan) then return end
   local mode = M.mode()
   local ctx = context(mode)
   -- The lanes held this prompt, in the context too: a class that trades one lane for
   -- another (the Priest's offence sends the mace or an equilibrium move) must not give
   -- way to a lane that will not send.
   local hands = handsWanted()
   ctx.held = {
      balance     = lock ~= nil,
      equilibrium = lock ~= nil or hands,
   }
   M.updateAlert(ctx)
   -- One prompt, every free lane.
   if active.pvpDefer then active.pvpDefer(true) end
   for _, lane in ipairs(M.LANES) do
      local held = ctx.held[lane] == true
      if not held then
         local move, name = active.pvpPlan(mode, lane, ctx)
         if move and active.pvpSend(move, name, ctx) then
            -- A tick can run with a target set and start() never called (a test, a half
            -- session). The count is bookkeeping; it must not take the prompt down with it.
            if not M.stats then
               M.stats = { attacks = 0, recited = 0, startedAt = 0, lanes = {} }
            end
            M.stats.lanes = M.stats.lanes or {}
            M.stats.lanes[lane] = (M.stats.lanes[lane] or 0) + 1
            if lane == "prayer" then M.stats.recited = M.stats.recited + 1
            else M.stats.attacks = M.stats.attacks + 1 end
         end
      end
   end
end

--- THE KILL WINDOW, ON SCREEN. "Showing a gui alert when they are locked and also when they
--- are within absolve range or able to be judged" (the user, 2026-10-23). One window, rows
--- of what is open: the locks they are in, and the class's own kill rows (absolve, judge).
--- Raised when what is open changes; redrawn quietly when only a figure does; closed when
--- nothing is, or the fight ends. A click dismisses it until something new opens.
M.ALERT = "pvp.kill"
M.alertKinds = nil

local function alertWidget()
   return emunah.ui and emunah.ui.alert
end

function M.closeAlert()
   M.alertKinds = nil
   local alert = alertWidget()
   if alert then alert.close(M.ALERT) end
end

function M.updateAlert(ctx)
   local rows = {}
   if ctx.locks and #ctx.locks > 0 then
      rows[#rows + 1] = { "LOCKED", table.concat(ctx.locks, ", "), "they cannot cure out" }
   end
   local active = emunah.class.active
   if active and active.pvpKillRows then
      for _, row in ipairs(active.pvpKillRows(ctx)) do rows[#rows + 1] = row end
   end
   if #rows == 0 then
      if M.alertKinds then M.closeAlert() end
      return rows
   end
   local kinds = {}
   for _, row in ipairs(rows) do kinds[#kinds + 1] = row[1] .. ":" .. row[2] end
   kinds = table.concat(kinds, "|")
   local alert = alertWidget()
   if not alert then return rows end
   local title = ("Kill window: %s"):format(emunah.util.capitalise(ctx.target or ""))
   if kinds ~= M.alertKinds then
      M.alertKinds = kinds
      alert.show(M.ALERT, title, rows)
   elseif alert.isOpen(M.ALERT) then
      alert.update(M.ALERT, title, rows)
   end
   return rows
end

--- Report, for `emunah pvp`.
function M.report()
   local elapsed = M.enabled and (emunah.util.now() - M.stats.startedAt) or 0
   return {
      running     = M.enabled,
      target      = M.target,
      held        = M.held,
      mode        = M.mode(),
      rebounding  = M.target and M.rebounding[M.target] == true or false,
      reflecting  = M.target and M.reflecting[M.target] == true or false,
      attacks     = M.stats.attacks,
      recited     = M.stats.recited,
      elapsed     = elapsed,
      classLoaded = (emunah.class and emunah.class.name) or nil,
   }
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- on the prompt: what of a lock is on them
-- ---------------------------------------------------------------------------
--
-- The user, 2026-10-24: "start echoing the lock afflictions of my opponent onto the prompt
-- so i can see at a glance". The five a lock is made of, by the opponent tracker's odds: a
-- certain one plainly, a doubtful one with its chance, a gone one not at all; then any lock
-- they are in. Our own locks are watch.lua's "(lock: ...)".

M.LOCK_AFFLICTIONS = { "asthma", "slickness", "anorexia", "paralysis", "impatience" }
M.LOCK_WORDS = { slickness = "slick" }
--- Below this chance an affliction is left off the prompt.
M.PROMPT_FLOOR = 0.25

function M.lockTag()
   if not M.target or emunah.config.get("pvp.promptLocks", true) == false then return nil end
   local opponent = emunah.curing.detect and emunah.curing.detect.opponent
   if not (opponent and opponent.oddsFor) then return nil end
   local theme = emunah.ui.theme
   local odds = opponent.oddsFor(M.target)
   local parts = {}
   for _, affliction in ipairs(M.LOCK_AFFLICTIONS) do
      local chance = odds[affliction] or 0
      local word = M.LOCK_WORDS[affliction] or affliction
      if chance >= 1 then
         parts[#parts + 1] = theme.dc("affliction") .. word
      elseif chance >= M.PROMPT_FLOOR then
         parts[#parts + 1] = ("%s%s%s %d%%"):format(theme.dc("warning"), word,
            theme.dc("textDim"), math.floor(chance * 100 + 0.5))
      end
   end
   local locks = opponent.lockProgress(M.target)
   if #parts == 0 and #locks == 0 then return nil end
   local text = (" %s(%s%s%s: "):format(theme.dc("textDim"), theme.dc("accent"), M.target,
      theme.dc("textDim"))
   text = text .. (#parts > 0 and table.concat(parts, theme.dc("textDim") .. ", ")
      or theme.dc("textDim") .. "none")
   if #locks > 0 then
      text = text .. ("%s | %slocked: %s"):format(theme.dc("textDim"), theme.dc("danger"),
         table.concat(locks, ", "))
   end
   return text .. theme.dc("textDim") .. ")"
end

event.register("emunah.prompt", function()
   local tag = M.lockTag()
   if tag and type(decho) == "function" then decho(tag) end
end, "pvp-prompt")

event.register("emunah.tick", function() M.tick() end, "pvp")

-- A BALANCE BACK WITH NO PROMPT BEHIND IT. Curing and keep-up act on the lapse (engine.lua,
-- defkeepup.lua); the attack waited for the next prompt, which in a quiet exchange only
-- comes when somebody else acts. The lapse runs in a batch (timers.lua), after the cures'
-- own handlers, so a cure due on the same balance still goes first.
M.LAPSES = { ["attack.balance"] = true, ["cure.equilibrium"] = true, ["pvp.prayer"] = true }
event.register("emunah.timer.expired", function(_, name)
   if M.LAPSES[name] then M.tick() end
end, "pvp")

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

-- REBOUNDING, from both ends. Our mace turned back -- "The attack rebounds back onto you!"
-- (2026-10-15 13:58:03, a smite into Anzerloi's aura) -- marks the target, and their aura
-- going down clears it: "Anzerloi's aura of weapons rebounding disappears." (13:58:12).
-- The class reads it to raise heresy, which burns rebounding away (HELP HERESY), or to
-- hold the mace.
table.insert(registry(), tempRegexTrigger([[^The attack rebounds back onto you!$]], function()
   if M.enabled and M.target then M.rebounding[M.target] = true end
end))
table.insert(registry(), tempRegexTrigger(
   [[^(\w+)'s aura of weapons rebounding disappears\.$]], function()
      local name = matches and matches[2]
      if name then M.rebounding[name:lower()] = nil end
   end))

-- THE REFLECTIVE BARRIER, from the attacking end. Anzerloi's arena log of 2026-10-15, his
-- blows on an Alchemist (docs/game/alchemist.md): the first turned part of the damage back,
-- 477 of it, and the next broke the barrier and was turned back as well, 477 again --
--   The reflective barrier surrounding Sobriquet reflects part of your attack back at you.
--   As your attack falls, Sobriquet's reflective barrier shatters and reflects the attack.
-- The barrier is the reference system's `tin` defence ("You are protected by a reflective barrier."). Kept
-- for whoever we hit, target or not: an ally's target is often not ours yet.
table.insert(registry(), tempRegexTrigger(
   [[^The reflective barrier surrounding (\w+) reflects part of your attack back at you\.$]],
   function()
      local name = matches and matches[2] and matches[2]:lower()
      if not name or M.reflecting[name] then return end
      M.reflecting[name] = true
      log.info("%s is behind a reflective barrier: the next blow breaks it, and comes back "
         .. "to you too.", emunah.util.capitalise(name))
   end))
table.insert(registry(), tempRegexTrigger(
   [[^As your attack falls, (\w+)'s reflective barrier shatters and reflects the attack\.$]],
   function()
      local name = matches and matches[2]
      if name then M.reflecting[name:lower()] = nil end
   end))

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

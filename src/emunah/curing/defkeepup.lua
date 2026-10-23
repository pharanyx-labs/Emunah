--- Defence keep-up.
---
--- Restores defences that have dropped off, using the same queue as curing so the two
--- cannot fight over a balance.
---
--- This is a much easier problem than curing, and for one reason: Char.Defences is
--- genuinely complete. The game knows exactly which defences you have and tells you about
--- all of them, so there is no trigger layer, no reconciliation and no ambiguity -- if a
--- defence is not in the list, it is not up. Compare curing/engine.lua, where most of the
--- complexity exists to work around the fact that Char.Afflictions is not complete.
---
--- Keep-up always runs at a lower priority than curing. Re-raising a defence during a
--- fight is worth doing, but never at the cost of a cure.

local M = {}

local util    = emunah.util
local log     = emunah.log
local event   = emunah.event
local queue   = emunah.queue
local have    = emunah.have
local deflist = emunah.curing.deflist

--- Priority floor. Everything curing does uses ranks well below this, so keep-up can only
--- claim a vector no cure wanted this tick.
M.PRIORITY = 900

--- Still behind a cure (healing and DIAG are 0), but ahead of every other keep-up.
---
--- mindseye shares equilibrium with bliss, cloak and inspiration. Same priority, and
--- missing() is alphabetical, so the first one pushed keeps the slot: bliss, then cloak,
--- then inspiration, and mindseye waits. Watched at login 12:49:17-34. While it waited the
--- character was blind without mindseye, items.sighted() was false, and queueRestock()
--- therefore pulled nothing -- prerift started on the prompt after the user touched the
--- tattoo by hand. LOOK only reprints the darkness line. It does not restore sight.
M.SIGHT_PRIORITY = 850

M.enabled = false

--- Ask the game for a fresh prompt.
---
--- Keep-up only ever decides anything on a prompt-driven tick, because `emunah.tick` comes
--- from Char.Vitals. Toggling a defence changes what SHOULD be up, and without a new prompt
--- that change sits idle until the game happens to send something -- standing still out of
--- combat, that can be a long time, and it reads as the toggle not having worked.
---
--- A blank line costs nothing and produces one immediately.
function M.nudge()
   if not M.enabled or emunah.act.halted then return false end
   send("")
   return true
end

-- ---------------------------------------------------------------------------
-- Modes
-- ---------------------------------------------------------------------------
--
-- Two ways to want a defence, and the difference is entirely about what happens when it
-- LATER goes away:
--
--   "defup"   bring it up once. Satisfied the moment Char.Defences shows it, and a
--             subsequent expiry is ignored. This is the login pass -- get everything
--             standing, then leave it alone.
--   "keepup"  bring it up whenever it is missing, indefinitely.
--
-- Both raise identically; only re-raising differs. Note that defup is NOT "send the command
-- once and stop": a refused command has raised nothing, so it keeps trying within the same
-- three-attempt budget as keepup, and stops when the defence actually appears.

M.MODES = { "defup", "keepup" }

--- Which defences are wanted, and how. name -> "defup" | "keepup".
---
--- Stored as a MAP where it used to be an array of names. config.lua's migration 3 converts
--- an existing list, taking every entry as "keepup" -- that is what the old list meant, so
--- nobody's setup changes underneath them.
function M.modes()
   local stored = emunah.config.get("defences.keepup", {}) or {}
   -- Tolerate the old array shape in memory too. A reload restores config.data verbatim
   -- from _persist, so a profile can reach this function before the migration has been
   -- applied to the table this process is holding.
   if stored[1] ~= nil then
      local converted = {}
      for _, name in ipairs(stored) do converted[tostring(name):lower()] = "keepup" end
      return converted
   end
   return stored
end

--- The mode for one defence, or nil when it is switched off.
function M.mode(name)
   return M.modes()[deflist.canonical(name)]
end

--- Every defence currently switched on, in either mode, sorted.
function M.wanted()
   local out = {}
   for name in pairs(M.modes()) do out[#out + 1] = name end
   table.sort(out)
   return out
end

--- Defences in defup mode that have been seen up, so are done with.
---
--- In memory rather than in the config, deliberately: this is "I have already brought it up
--- this session", which is exactly the thing that should not survive a restart. A reload
--- clears it too, and re-running the defup pass after a reload is the right behaviour.
M.satisfied = {}

--- Set the mode, or switch a defence off with nil.
--- @return string|nil the mode now in force
function M.setMode(name, mode)
   -- Through the alias map, so `venom` configures `poisonresist` rather than creating a
   -- second entry for a name Char.Defences will never report.
   name = deflist.canonical(name)
   if name == "" then return nil end
   if mode ~= nil and mode ~= "defup" and mode ~= "keepup" then
      log.warn("Mode must be defup or keepup, not %q.", tostring(mode))
      return M.mode(name)
   end

   local modes = M.modes()
   modes[name] = mode
   emunah.config.set("defences.keepup", modes)
   emunah.config.save()

   -- Changing the mode is a fresh statement of intent, so it clears both the attempt
   -- history and any "already done" from a previous defup pass.
   M.resetBudget(name)
   M.satisfied[name] = nil
   -- The defences panel lists exactly what is switched on.
   event.raise("defkeepup.changed", name, mode)
   return mode
end

--- Cycle a defence: off -> defup -> keepup -> off. What a click does.
--- @return string|nil the mode now in force
function M.cycle(name)
   local current = M.mode(name)
   if current == nil then return M.setMode(name, "defup") end
   if current == "defup" then return M.setMode(name, "keepup") end
   return M.setMode(name, nil)
end

--- Start a defup pass again, forgetting what has already been brought up.
function M.redoDefup()
   M.satisfied = {}
   M.resetBudget()
   return true
end

--- What a defence looks like right now, for a display.
--- @return table { name, mode, up, raisable, satisfied, vector, command, source,
---   unconfirmable }
function M.state(name)
   name = deflist.canonical(name)
   local vector, command, _, _, unconfirmable = deflist.resolve(name)
   return {
      name      = name,
      mode      = M.mode(name),
      up        = deflist.isUp(name),
      -- False means we hold no command for it: it can sit switched on forever and nothing
      -- will ever go out. Worth showing, because it is indistinguishable from "keeps
      -- failing" otherwise.
      raisable  = command ~= nil,
      satisfied = M.satisfied[name] == true,
      -- The defence that must be up first, when it is not. `blind` and `deaf` without
      -- `mindseye` leave the character genuinely unable to see or hear.
      blockedBy = M.blockedBy(name),
      vector    = vector,
      command   = command,
      source    = deflist.source(name),
      -- Never shows `up`, whatever mode it is in -- Char.Defences produces no line for it
      -- at all. Worth surfacing so a display can say why rather than leave it looking like
      -- an ordinary MISSING that just never resolves.
      unconfirmable = unconfirmable == true,
   }
end

--- Every defence we know how to raise, plus anything switched on. Sorted.
function M.known()
   return deflist.known(M.wanted())
end

-- Thin delegates. The tables moved to deflist.lua, but "how do I raise X" is still a
-- reasonable question to ask the module that raises things, and every existing caller and
-- test asks it here.
function M.resolve(name) return deflist.resolve(name) end
function M.source(name)  return deflist.source(name)  end

--- Switch a defence on in a given mode, optionally pairing it with a command.
---
--- An explicit command can be supplied for anything deflist does not already know how to
--- raise -- `emunah defs add moss touch moss`. That matters for tattoos in particular: the
--- name Char.Defences reports is not something to guess at, because a wrong one means the
--- defence silently never goes up, and the command that raises it costs a full balance
--- whether or not it was needed. Read the real name from `emunah gmcp` and pair it here.
--- @param name string the name as Char.Defences reports it
--- @param command string|nil what raises it; omit for one deflist already knows
--- @param vector string|nil which balance that command spends; defaults to balance
--- @param mode string|nil "defup" or "keepup"; defaults to keepup
function M.add(name, command, vector, mode)
   name = deflist.canonical(name)
   if name == "" then return false end

   if command and command ~= "" then
      local custom = emunah.config.get("defences.commands", {}) or {}
      custom[name] = { command = command, vector = vector or "balance" }
      emunah.config.set("defences.commands", custom)
   end

   M.setMode(name, mode or "keepup")

   -- "Keeping up X" IS NOT TRUE WHILE KEEP-UP IS OFF, and it was said anyway.
   --
   -- `defences.enabled` ships false and `add` never touched it, so the whole sequence
   -- -- `emunah defs add inspiration` -> "Keeping up inspiration." -> nothing ever happens,
   -- and the roster and the UI both show it MISSING in red -- was reachable with no
   -- indication anywhere that the subsystem was switched off. Reported from play at
   -- 13:03:03.43. The list is maintained either way; only the claim was wrong.
   if not M.enabled then
      log.warn("Added <ansi_cyan>%s<ansi_yellow> (%s) -- but defences are "
         .. "<ansi_light_red>OFF<ansi_yellow>, so nothing will raise it. "
         .. "Turn them on with `emset defs on`.", name, mode or "keepup")
   else
      log.info("<ansi_cyan>%s<ansi_yellow>: %s.", name, mode or "keepup")
   end
   return true
end

function M.drop(name)
   name = deflist.canonical(name)
   if not M.mode(name) then return false end
   M.setMode(name, nil)
   log.info("No longer raising <ansi_cyan>%s<ansi_yellow>.", name)
   return true
end

-- ---------------------------------------------------------------------------
-- The attempt budget
-- ---------------------------------------------------------------------------
--
-- Raising a defence is not free and, for the ones that matter most, is not cheap: touching
-- a tattoo costs a full balance -- around four seconds -- and costs it whether or not the
-- attempt achieves anything. So a defence that never appears in Char.Defences after being
-- raised must not be retried forever. That happens for ordinary reasons: the configured
-- name does not match what the game reports, the ability is not trained, or the command is
-- refused for a reason nothing here models.
--
-- Retrying blind in that state does not fix it and does spend every balance the character
-- has, which in a fight is the character. The budget stops after a few attempts and says
-- what it stopped on. It resets the moment the defence actually appears, so a defence
-- stripped repeatedly in real combat is raised every time.

M.ATTEMPTS = 3

local attempts, warned = {}, {}

--- Defences we have already explained are waiting on a prerequisite. Only for saying it
--- once rather than on every prompt -- NOT the answer to "is it blocked", which is
--- computed below.
local blockedOn = {}

--- The darkness line has been seen and mindseye is not up yet. Kept until the touch lands
--- or the attempt budget stops it, so a skill index that was not ready on that prompt
--- still gets the raise, and so later ticks do not let bliss take equilibrium back.
local pendingSight = false

--- A RAISE IN FLIGHT IS NOT A MISSING DEFENCE. Some land well after the command: hawthorn's
--- deafness took 2.3s both times it was timed (eaten 14:18:55.28, "The aural world fades to
--- silence." 57.62; eaten 14:33:25.08, deaf 27.38, 2026-09-28). In that gap the item is
--- eaten and the defence not yet up, so keep-up read it as missing again: it said "no
--- hawthorn in hand" about the hawthorn it had just eaten, and with a second one in hand it
--- would have eaten that too. The herb's balance line frees the queue slot before the
--- defence lands, so the queue cannot guard this.
---
--- THE WAIT STARTS AT THE EAT, NOT THE SEND -- the reference system's model: `deaf.herb`
--- starts `waitingondeaf` (customwait = 6) from the eat line. Timing it from the send was
--- wrong the other way: at 14:37:23.71 `eat hawthorn` went out off equilibrium, the game
--- did not eat it until 30.52 (just after equilibrium at 30.15), and a window counted from
--- the send had run out by then.
M.RAISE_PENDING = 6.0

--- Longest to wait for the eat line itself before deciding the command was lost.
M.EAT_PENDING = 15.0

--- name -> { sent = time, vector = vector, eaten = time|nil } for item raises not yet seen to land, and for
--- raises that land well after their send (deflist.lands: speed), with `eaten` the send.
local raising = {}

--- name -> when a raise that holds no queue slot last went out (M.costless). The slot's
--- confirm wait is what stopped a second send before the answer; this is that wait for
--- raises sent without one.
local lastSent = {}

local function raisePending(name)
   local r = raising[name]
   if not r then return false end
   local now = util.now()
   if r.eaten then return now - r.eaten < (r.window or M.RAISE_PENDING) end
   return now - r.sent < M.EAT_PENDING
end

--- How long sileris (or quicksilver) takes to harden after the apply. Applied, it is not up
--- yet: keep-up must not apply a second one into the gap. The reference system waits 8s
--- (waitingforsileris, customwait = 8), but on 2026-10-15 it took 10.05s -- applied
--- 18:26:21.16, hardened 18:26:31.21 -- and at 8 the hardening fell outside the window and
--- was thrown away as an illusion, leaving the defence red. 12 covers it with room.
M.SILERIS_HARDEN = 12.0

-- The eat line starts the wait. Any "You eat ..." counts for every EATEN raise still
-- waiting on one: an item raise is at most one per vector in flight, and a line about
-- another herb only starts the wait a little early.
--
-- Eaten ones only. Login 2026-10-18 10:09: `apply sileris to body` went at 21.44, "You eat
-- an echinacea root." came at 22.02 and the apply line at 22.05, so the sileris took the
-- eat's 6s window rather than its 12s hardening, was applied again at 28, and hardened at
-- 38.88. A smoke waiting on rebounding (8.5s, the same login) is as exposed.
M.EATEN = { herb = true, moss = true }
do
   local id = tempRegexTrigger([[^You eat ]], function()
      local now = util.now()
      for _, r in pairs(raising) do
         if not r.eaten and M.EATEN[r.vector] and now - r.sent < M.EAT_PENDING then
            r.eaten = now
         end
      end
   end)
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
   end
end

-- SILERIS IS APPLIED, THEN HARDENS -- the reference system's "sileris/quicksilver start" and "finished"
-- triggers, verbatim. The apply line starts the wait the way an eat line does; the
-- hardening line (seen in play, 2026-10-04) is the defence landing, as `fangbarrier`. It is
-- believed only after an APPLY of ours (anti-illusion layer 5, curing/detect/init.lua).
do
   local function persist(id)
      if id then
         emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
         table.insert(emunah._persist.detectTriggers, id)
      end
   end
   for _, pattern in ipairs({
      [[^You apply a sileris berry to yourself\.$]],
      [[^You apply a quicksilver droplet to yourself\.$]],
   }) do
      persist(tempRegexTrigger(pattern, function()
         local r = raising.fangbarrier
         if r and not r.eaten then r.eaten, r.window = util.now(), M.SILERIS_HARDEN end
         -- The apply is the command's answer; the hardening, ten seconds on, is the
         -- defence's. Left to the confirm wait, the slot lapsed into "No confirmation for
         -- [salve] apply sileris to body -- re-arming." first (2026-10-23 10:01:06.91,
         -- hardened 16.93). The pending window above still holds a second apply.
         for _, vector in ipairs(queue.VECTORS) do
            local action = queue.awaiting(vector)
            if action and action.tag == "def:fangbarrier" then
               queue.confirm(vector)
               break
            end
         end
      end))
   end
   local function hardened()
      local outgoing = emunah.outgoing
      local detect = emunah.curing.detect
      if detect and detect.antiIllusion and detect.antiIllusion() and outgoing
         and not outgoing.sentRecently("^apply", M.SILERIS_HARDEN + 2) then
         detect.markIllusion("sileris hardening, but nothing was applied")
         return
      end
      raising.fangbarrier = nil
      M.resetBudget("fangbarrier")
      if M.mode("fangbarrier") == "defup" then M.satisfied.fangbarrier = true end
      -- Up on the line, as the reference system has it (defences.got("sileris")), whether or not
      -- Char.Defences says so too: the shell is on.
      local defences = emunah.gmcp.defences
      if defences and defences.got then defences.got("fangbarrier") end
   end
   for _, pattern in ipairs({
      [[^The sileris berry juice hardens into a supple purple shell\.$]],
      [[^The quicksilver hardens into a supple metallic shell\.$]],
   }) do
      persist(tempRegexTrigger(pattern, hardened))
   end
end

--- Which defence is holding this one back right now, or nil.
---
--- Computed rather than read from the cache above: the cache is written on a tick, so a
--- prerequisite that has just come up would still read as blocking until the next prompt --
--- and the grid would show a defence waiting on something that is plainly already there.
function M.blockedBy(name)
   name = deflist.canonical(name)
   local prerequisite = deflist.requires(name)
   if not prerequisite then return nil end
   local defences = emunah.gmcp.defences
   if defences and defences.has(prerequisite) then return nil end
   return prerequisite
end

--- Has this defence any attempts left?
--- Names Char.Defences is reporting that nothing in deflist claims.
---
--- When a raise works but the defence never appears, the name we asked for is not the name
--- the game uses -- and the game is already telling us the right one, in this list. Watched
--- live: `drink venom` succeeded ("your resistance to damage by poison increases", and DEF
--- then listed it), while keep-up went on raising `venom` because Char.Defences never used
--- that word. The answer was on screen the whole time and nothing put the two together.
--- @return table array of names
function M.unclaimed()
   local defences = emunah.gmcp.defences
   if not defences then return {} end

   local claimed = {}
   for _, name in ipairs(deflist.known()) do claimed[name] = true end

   local out = {}
   for _, name in ipairs(defences.names()) do
      if not claimed[name] then out[#out + 1] = name end
   end
   table.sort(out)
   return out
end

--- Raised however many times it takes: the mace, at all times (the user, 2026-10-23).
M.UNLIMITED = { trackmace = true }

--- Forget when a costless raise last went, so the next can go now: the mace picked up, its
--- wield due on the same prompt.
function M.clearSent(name)
   lastSent[deflist.canonical(name)] = nil
end

function M.withinBudget(name)
   -- Every other accessor here canonicalizes (mode, setMode, state, add, drop,
   -- blockedBy) so that the elixir's name and the defence's name are one budget, not two.
   -- This one did not, and it went unnoticed only because M.tick() always calls it with a
   -- name already canonical from M.wanted() -- an external caller asking by the elixir's
   -- own name (`withinBudget("frost")`, matching how `mode("frost")` already works) would
   -- silently consult an empty budget while `abandon()` had exhausted the real one.
   name = deflist.canonical(name)
   if M.UNLIMITED[name] then return true end
   if (attempts[name] or 0) < M.ATTEMPTS then return true end
   if not warned[name] then
      warned[name] = true
      -- trackmace, trackangel and bliss never appear in Char.Defences. Saying they
      -- failed to, and listing boartattoo/mosstattoo as the likely real name, sent the
      -- player to pair a tattoo to a defence that GMCP does not report at all.
      if deflist.SYNTHETIC and deflist.SYNTHETIC[name] then
         log.warn("Raised %s %d times and it still is not up -- stopping.",
            name, attempts[name])
         return false
      end
      log.warn("Raised %s %d times and it never appeared in Char.Defences -- stopping.",
         name, attempts[name])
      -- Narrow it down instead of sending them to go and look. A raise that worked leaves
      -- its defence sitting in Char.Defences under some other name, and that name is
      -- almost always one of these.
      local unclaimed = M.unclaimed()
      if #unclaimed > 0 then
         log.warn("  Char.Defences is reporting these, which nothing here claims: %s",
            table.concat(unclaimed, ", "))
         log.warn("  If one of them IS %s, pair them: emset defs add <that name> %s",
            name, tostring(select(2, deflist.resolve(name)) or "<command>"))
      end
   end
   return false
end

--- Give up on a defence without burning the remaining attempts.
---
--- For when the game has told us plainly that raising it achieved nothing -- not that it
--- failed, but that there was nothing to do. Retrying that is the one case where the budget
--- is not protection but delay.
function M.abandon(name, why)
   name = deflist.canonical(name)
   attempts[name] = M.ATTEMPTS
   if not warned[name] then
      warned[name] = true
      log.warn("Not raising %s again: %s", name, tostring(why))
      local unclaimed = M.unclaimed()
      if #unclaimed > 0 then
         log.warn("  Char.Defences is reporting these, which nothing here claims: %s",
            table.concat(unclaimed, ", "))
      end
   end
   return true
end

--- Forget the attempt history, for one defence or all of them.
function M.resetBudget(name)
   if name then
      attempts[name], warned[name], lastSent[name] = nil, nil, nil
   else
      attempts, warned, lastSent = {}, {}, {}
   end
end

-- A defence appearing is proof the command works, whatever it took to get there.
--
-- AND IT ANSWERS THE RAISE IN FLIGHT. Nothing did: every defence raised was followed, two
-- seconds later, by "No confirmation for [...] -- re-arming." -- twelve of them in one
-- defup after an arena defeat (2026-10-05 07:33:39-07:33:54: insomnia, levitation, cloak,
-- kola, vigilance, inspiration, venom, skullcap, mindseye, echinacea, frost, nightsight),
-- each one holding its slot for the whole confirm window after the game had already said
-- yes. Only the queue SLOT is freed here, never the balance: the balance has its own
-- announcement (see engine.lua's affliction.removed handler for the same split).
event.register("emunah.defence.added", function(_, name)
   name = tostring(name or ""):lower()
   M.resetBudget(name)
   -- The raise has landed, so its pending window is over. Left running, a sileris stripped
   -- the moment it hardened was not applied again until the window ran out.
   raising[name] = nil
   lastSent[name] = nil
   local tag = "def:" .. name
   for _, vector in ipairs(queue.VECTORS) do
      local action = queue.awaiting(vector)
      if action and action.tag == tag then
         queue.confirm(vector)
         break
      end
   end
end, "curing.defkeepup")

--- Which switched-on defences are currently missing AND still want raising.
---
--- The whole difference between the two modes lives here. A defup defence drops out of this
--- list for good once it has been seen up; a keepup one never does.
function M.missing()
   local out = {}
   for _, name in ipairs(M.wanted()) do
      if not deflist.isUp(name) and (M.mode(name) == "keepup" or not M.satisfied[name]) then
         out[#out + 1] = name
      end
   end
   return out
end

-- A defup defence that has appeared is done with: it was asked to bring the defence up
-- once, and it has. Recorded on the event rather than checked in missing(), because by the
-- time it expires it is no longer in Char.Defences and there would be nothing left to see.
event.register("emunah.defence.added", function(_, name)
   name = tostring(name or ""):lower()
   if M.mode(name) == "defup" then M.satisfied[name] = true end
end, "curing.defkeepup")

--- Note anything already up when a full list arrives -- a login, or a reconnect. Without
--- this, a defup pass would raise defences that were standing the whole time.
event.register("emunah.defences.list", function()
   local defences = emunah.gmcp.defences
   if not defences then return end
   for name in pairs(M.modes()) do
      if M.mode(name) == "defup" and defences.has(name) then M.satisfied[name] = true end
   end
end, "curing.defkeepup")

--- Queue `touch mindseye` ahead of other equilibrium keep-up.
---
--- Called from the darkness line (detect commits it on the prompt, before this tick) and
--- again from M.tick while that raise is still outstanding. Cures stay ahead of it: this
--- priority loses to perform hands and DIAG, and wins against bliss.
function M.queueMindseye()
   if deflist.isUp("mindseye") then
      pendingSight = false
      return false
   end
   local vector, command, needs = deflist.resolve("mindseye")
   if not vector or not command then
      -- The skill index has answered and this character has no mindseye. Stop asking.
      -- While the index is still loading, resolve() allows the command; that is the
      -- login window this retry exists for.
      local skills = emunah.gmcp.skills
      if skills and skills.complete then pendingSight = false end
      return false
   end
   if not M.withinBudget("mindseye") then
      pendingSight = false
      return false
   end
   -- One touch at a time. The prompt that saw the darkness line queues it, and this
   -- tick runs after that send: queueing another while the first is still in flight
   -- would spend a second 3s of equilibrium the moment the first one returned.
   local inflight = queue.awaiting(vector)
   if inflight and inflight.command == command then return false end
   return queue.push(vector, command, {
      priority = M.SIGHT_PRIORITY,
      tag      = "def:mindseye",
      needs    = needs,
      valid    = function() return not deflist.isUp("mindseye") end,
      confirm  = emunah.config.get("curing.confirmWait", 2.0),
      -- Spends equilibrium. The queue arms the guard from this, so a stale Char.Vitals
      -- cannot send wield or vault into "You must regain equilibrium first."
      -- (login 2026-10-17 11:26:34.91).
      spends   = "eq",
      onSent   = function()
         attempts.mindseye = (attempts.mindseye or 0) + 1
      end,
   })
end

--- A smoke of this herb was refused ("That pipe isn't lit."). The raise did not start,
--- so the pending window must not keep the defence down for the rest of it once the
--- pipe is burning again.
function M.smokeRefused(herb)
   herb = tostring(herb or ""):lower()
   if herb == "" then return end
   for name in pairs(raising) do
      local _, command, _, item = deflist.resolve(name)
      if item == herb or (command and command:find("^smoke%s+" .. herb .. "$")) then
         raising[name] = nil
      end
   end
end

--- "You are blind and can see nothing but darkness." Mindseye is what makes that
--- survivable, and prerift will not run until it is up.
function M.noteTrueBlind()
   pendingSight = true
   return M.queueMindseye()
end

--- Raises that spend nothing, so any number of them can go on one prompt: the free
--- vector, and the defence herbs and elixirs in deflist.COSTLESS. Sent straight through
--- act rather than queued. A queue slot holds one command, and the 2026-10-18 08:24 login
--- sent groundwatch, insomnia, nightsight, skywatch and treewatch across ten seconds
--- (20.95 to 31.38) one slot at a time, with `wield mace` holding the slot for seven.
function M.costless(name, vector)
   return vector == "free" or (deflist.COSTLESS and deflist.COSTLESS[name] == true)
end

--- Raise order: yours first (`emset defs order`), then the cheapest, so the most defences
--- are up soonest and the dearest goes last, where its own cost delays nothing. Bliss
--- (6.50s of equilibrium) went first, alphabetically, at the 08:24 login.
function M.order(names)
   local yours = {}
   for index, name in ipairs(emunah.config.get("defences.order", {}) or {}) do
      local canonical = deflist.canonical(name)
      if yours[canonical] == nil then yours[canonical] = index end
   end
   local cost = {}
   for _, name in ipairs(names) do cost[name] = deflist.cost(name) end
   table.sort(names, function(a, b)
      local ya, yb = yours[a] or math.huge, yours[b] or math.huge
      if ya ~= yb then return ya < yb end
      local ca, cb = cost[a], cost[b]
      if ca ~= cb then return ca < cb end
      return a < b
   end)
   return names
end

--- Set your raise order, or clear it with an empty list.
function M.setOrder(names)
   local out = {}
   for _, name in ipairs(names or {}) do
      local canonical = deflist.canonical(name)
      if canonical ~= "" then out[#out + 1] = canonical end
   end
   emunah.config.set("defences.order", #out > 0 and out or nil)
   emunah.config.save()
   return out
end

--- One pass. At most one queued raise per spending vector, at a priority no cure will lose
--- to, and every costless raise that can go.
function M.tick()
   if not M.enabled then return end
   -- At the login menu there is no character to keep defences on: act.send would refuse,
   -- but the hold messages below would still print there (2026-09-28, before login).
   local vitals = emunah.gmcp.vitals
   if vitals and vitals.live and not vitals.live() then return end
   -- DEFENCES is in flight or still waiting on equilibrium. That question is the
   -- equilibrium slot. A salve, a smoke, a herb and a free defence do not use it, and
   -- stopping the whole pass here left fangbarrier unraised for as long as the listing
   -- waited (a typed command, or equilibrium already spent). Equilibrium raises stay
   -- held: the list they would read is the stale one this check exists to replace.
   if M.checking then M.checkDefences() end

   -- Cures already ran this tick (the engine registers first) and hold whatever vector
   -- they took. Keep-up's priority loses to a cure still in that slot, and a vector the
   -- cure is not using -- a smoke while the herb is busy, a free defence while equilibrium
   -- is down -- still goes out. Stopping the whole pass here held those.
   local items = emunah.gmcp.items
   local blindWithoutSight = items and not items.sighted() and not deflist.isUp("mindseye")
   -- The darkness line is live information, not the stale list. A missing mindseye that
   -- only the pre-reload list claims can wait for DEFENCES with the other equilibrium raises.
   if pendingSight or (not M.checking and blindWithoutSight) then M.queueMindseye() end

   -- AFFLICTED, ONLY WHAT COSTS NOTHING. Cures come first, and a defence raised mid-lock is
   -- usually stripped again at once. A raise that takes a balance can still delay the next
   -- cure: bliss is 6.50s of the equilibrium `perform hands` wants. Deliberate defences
   -- (blind, deaf) are not counted -- see engine.curableCount -- or keep-up, mindseye
   -- included, would never run again once they were up.
   local engine = emunah.curing.engine
   local afflicted = engine and engine.enabled and engine.curableCount() > 0

   -- What already waits on balance -- a vault, a one-off of yours -- goes before keep-up
   -- chooses. Then the choice sees that balance spent and takes an equilibrium raise that
   -- does not need it, rather than one that would be refused behind it.
   queue.flushVector("balance")

   local firstFor, chosen = {}, {}
   for _, name in ipairs(M.order(M.missing())) do
      local vector, command, needs, item, unconfirmable = deflist.resolve(name)

      -- See M.tick: while DEFENCES is outstanding, equilibrium raises wait. Everything
      -- else still goes on the vector it actually uses.
      if M.checking and vector == "equilibrium" then
         vector, command = nil, nil
      end

      -- A PREREQUISITE THAT IS NOT UP BLOCKS THE RAISE ENTIRELY.
      --
      -- Not merely unhelpful: `blind` and `deaf` without `mindseye` leave the character
      -- genuinely unable to see or hear. Held rather than abandoned, and it costs no
      -- attempt -- the prerequisite going up is the ordinary way this resolves, and it may
      -- be a defence keep-up is about to raise on this very pass.
      local prerequisite = M.blockedBy(name)
      if prerequisite then
         if not blockedOn[name] then
            blockedOn[name] = prerequisite
            log.info("Not raising %s until %s is up -- without it you cannot see or hear.",
               name, prerequisite)
         end
         vector, command = nil, nil
      else
         blockedOn[name] = nil
      end

      -- NO HERB IN HAND, NO RAISE. Sending the eat anyway burns an attempt against
      -- "What do you want to eat?" before anything is cured. Watched at login, 17:03:45-48:
      -- `eat skullcap` refused three times in under three seconds while the rift still held
      -- 96 -- deathsight retired for the rest of the session. Held, not abandoned: the herb
      -- arriving in the pack is the ordinary way this resolves, and deathsight, insomnia
      -- and thirdeye are not raised until then.
      --
      -- Not announced. "Restocking should catch up" was a promise restock could not keep
      -- while blind without mindseye (queueRestock requires inventoryKnown, which requires
      -- sight), and it was the whole of what the player saw at 12:49:20. Silence here; the
      -- eat goes out on the tick the herb is actually in hand.
      --
      -- SMOKE NEEDS A LIT PIPE, NOT THE HERB IN HAND -- have.cure() draws the same
      -- distinction. Checking possession instead here would hold `rebounding` forever on a
      -- character who smokes from a pipe but does not also carry loose skullcap.
      -- Item raises only: the item is what vanishes before the defence lands. A tattoo or a
      -- skill is paced by its own balance and confirm wait.
      -- HELD FOR NOW (deflist.HOLDS): insomnia while going to sleep, say. Quiet, and no
      -- attempt spent -- the hold lifting is the ordinary way it resolves.
      if vector and command and deflist.held(name) then
         vector, command = nil, nil
      end

      if vector and command and raisePending(name) then
         vector, command = nil, nil
      end

      -- NOT KNOWING WHAT WE CARRY IS NOT CARRYING NOTHING -- the rule queueRestock() already
      -- follows. Straight after a reload Char.Items has not answered yet, and this said "no
      -- hawthorn in hand" (14:33:20.30) with a hawthorn in the pack, eaten four seconds later
      -- without a pull. Held quietly until Char.Items.Inv has answered. `inventoryListed`,
      -- not inventoryKnown(): the latter also asks for sight, a separate question.
      local items = emunah.gmcp.items
      if vector and command and item and vector ~= "smoke"
         and not (items and items.inventoryListed) then
         vector, command = nil, nil
      end

      if vector and command and item then
         local held = (vector == "smoke") and have.pipe(item) or (have.item(item) > 0)
         if not held then
            vector, command = nil, nil
         end
      end

      if vector and command and afflicted and vector ~= "free" then
         vector, command = nil, nil
      end

      if vector and command and M.costless(name, vector) then
         if M.withinBudget(name) then
            M.sendCostless(name, vector, command, needs, item, unconfirmable)
         end
      elseif vector and command and not chosen[vector] and M.withinBudget(name) then
         local raise = { name = name, vector = vector, command = command, needs = needs,
                         item = item, unconfirmable = unconfirmable }
         firstFor[vector] = firstFor[vector] or raise
         -- THE FIRST THAT CAN GO, NOT THE FIRST IN LINE. A raise held for a balance it needs
         -- kept the slot from one that could have gone: at 20.95 bliss waited on the vault's
         -- balance while equilibrium sat idle for 1.7s.
         local spends = (vector == "equilibrium") and "eq" or nil
         if queue.ready(vector) and emunah.act.can(needs, spends) then
            chosen[vector] = true
            M.queueRaise(raise, blindWithoutSight)
         end
      end
   end

   -- Nothing could go: the first in line holds the slot, as it always did, so the queue
   -- shows what is next and sends it the moment its balance is back.
   for vector, raise in pairs(firstFor) do
      if not chosen[vector] and not queue.pending(vector) then
         M.queueRaise(raise, blindWithoutSight)
      end
   end

   queue.flush()
end

--- Send a costless raise now. See M.costless.
function M.sendCostless(name, vector, command, needs, item, unconfirmable)
   local sent = lastSent[name]
   local wait = emunah.config.get("curing.confirmWait", 2.0)
   if sent and util.now() - sent < wait then return false end
   -- Still its vector's: a herb's balance taken by a cure, anorexia, paralysis for a drink.
   if vector ~= "free" and not queue.ready(vector) then return false end
   if not emunah.act.send(command, needs) then return false end
   lastSent[name] = util.now()
   attempts[name] = (attempts[name] or 0) + 1
   local lands = deflist.lands(name)
   if item then
      raising[name] = { sent = util.now(), vector = vector }
   elseif lands then
      raising[name] = { sent = util.now(), eaten = util.now(), window = lands }
   end
   if unconfirmable and M.mode(name) == "defup" then M.satisfied[name] = true end
   -- The drink line must not spend the sip balance for it (detect/patterns.lua).
   local detect = emunah.curing.detect
   if vector == "purgative" and detect and detect.costlessDrink then detect.costlessDrink(name) end
   return true
end

--- Queue a raise on its vector, taking the slot from keep-up's own earlier choice.
function M.queueRaise(raise, blindWithoutSight)
   local name, vector, command = raise.name, raise.vector, raise.command
   local needs, item, unconfirmable = raise.needs, raise.item, raise.unconfirmable
   -- mindseye, while the character cannot see, must beat its neighbours on this same
   -- vector. queueMindseye() may already hold the slot.
   local priority = M.PRIORITY
   if name == "mindseye" and (pendingSight or blindWithoutSight) then
      priority = M.SIGHT_PRIORITY
   end
   -- Keep-up's own pick from an earlier prompt gives way: equal priority keeps the slot,
   -- and the pick that could not go would hold it again.
   local waiting = queue.pending(vector)
   if waiting and waiting.priority >= M.PRIORITY and waiting.command ~= command
      and tostring(waiting.tag or ""):find("^def:") then
      queue.clear(vector)
   end
   local sentCommand = command
   return queue.push(vector, command, {
      priority = priority,
      tag      = "def:" .. name,
      -- Held rather than dropped when these are not met, so the raise goes out the
      -- moment they are -- and, critically, does NOT burn an attempt meanwhile.
      needs    = needs,
      -- The defence may come back on its own while this waits for a balance, and
      -- raising one that is already up costs the balance for nothing -- a full four
      -- seconds for a tattoo.
      -- A dynamic defence (trackmace) can change its mind while this sits in the
      -- slot: SUMMON queued, then "you have a mace in the land" means the send has
      -- to be CALL. isUp() alone would still let the summon go.
      valid    = function()
         if deflist.isUp(name) then return false end
         if deflist.held(name) then return false end
         -- The pipe can go out while this sits in the slot. Smoking it then is
         -- "That pipe isn't lit." (login 2026-10-18 05:00:40.38).
         if vector == "smoke" and item and not have.pipe(item) then return false end
         if deflist.DYNAMIC and deflist.DYNAMIC[name] then
            local _, commandNow = deflist.resolve(name)
            return commandNow == sentCommand
         end
         return true
      end,
      confirm  = emunah.config.get("curing.confirmWait", 2.0),
      -- Equilibrium defences spend equilibrium. Balance-vector defences do not all
      -- spend balance (summon is free when the mace already exists), so they arm
      -- nothing here; the ones that do say so themselves.
      spends   = (vector == "equilibrium") and "eq" or nil,
      onSent   = function()
         attempts[name] = (attempts[name] or 0) + 1
         if item then raising[name] = { sent = util.now(), vector = vector } end

         -- UNCONFIRMABLE: SATISFIED ON SEND, NOT ON Char.Defences. `bliss` produces no
         -- Char.Defences line ever, so the ordinary "defup done once confirmed" event
         -- listener below never fires for it -- waiting for that would mean waiting
         -- forever, and the defence would sit MISSING despite being genuinely up.
         -- Keepup mode is unaffected: `M.missing()` does not consult `satisfied` for
         -- keepup, so it is still bounded only by the ordinary attempt budget.
         if unconfirmable and M.mode(name) == "defup" then
            M.satisfied[name] = true
         end

         -- Equilibrium's guard is armed from `spends` before this runs. The game's
         -- "Equilibrium used: N.NNs." line replaces it with the real cost. Herb,
         -- smoke and the other timed vectors have no such line that the queue sees,
         -- so they keep their own fallback.
         if vector ~= "equilibrium" and vector ~= "balance" then
            have.spend(vector)
         end
      end,
   })
end

--- @param silent boolean|nil skip the "Defence keep-up on." line -- for a caller (`pp`) that
---   is about to print its own summary covering this and another module together
function M.start(silent)
   M.enabled = true
   emunah.config.set("defences.enabled", true)
   if not silent then log.info("Defence keep-up <ansi_light_green>on<ansi_yellow>.") end
   event.raise("defkeepup.enabled")
end

--- @param silent boolean|nil see M.start()
function M.stop(silent)
   M.enabled = false
   emunah.config.set("defences.enabled", false)
   if not silent then log.info("Defence keep-up <ansi_light_red>off<ansi_yellow>.") end
   event.raise("defkeepup.disabled")
end

--- Defences lost since the last prompt. See the defence.lost handler below.
local lostSinceTick = 0

event.register("emunah.tick", function()
   lostSinceTick = 0
   M.tick()
end, "curing.defkeepup")

-- A BALANCE BACK WITH NO PROMPT BEHIND IT. "Balance used: 1.0s." restarts the balance timer
-- when the line ARRIVES, so it outlasts the game's own balance by the round trip: at the
-- 2026-10-18 09:40 login the vault's ran to 33.06, the game gave balance back at 32.99,
-- and that prompt held everything that needed it. No prompt came again until 37.07, and
-- nothing else asked, so the watches, `wield mace` and selfishness waited four seconds.
--
-- And equilibrium, where the engine already acts on the lapse and sends keep-up's queued
-- raise by itself: hypersight and inspiration went out just before the game's "You have
-- recovered equilibrium." (their echoes sit on the prompt before it). Keep-up on the same
-- lapse, in the same line (timers.lua batches it), puts what only needs equilibrium in
-- front of the raise that spends it, rather than waiting a whole equilibrium behind it.
event.register("emunah.timer.expired", function(_, name)
   if name == "attack.balance" or name == "cure.equilibrium" then M.tick() end
end, "curing.defkeepup")

-- ---------------------------------------------------------------------------
-- after a reload: ask DEFENCES before raising anything
-- ---------------------------------------------------------------------------
--
-- A reload rebuilds the defence list from the last full Char.Defences.List, which predates
-- every change since (gmcp/defences.lua's applyDefListing). Raising defences off that stale
-- list is what sent `perform bliss` on every `emreload`. So after a reload, equilibrium
-- raises wait, DEFENCES goes out, and they resume once the listing has been read -- or
-- after M.CHECK_TIMEOUT, so a lost reply cannot stall them. A salve, smoke, herb or free
-- defence does not read that list to know its own balance, and still goes. DEFENCES costs
-- equilibrium (0.50s, docs/game/defences.md).

M.CHECK_TIMEOUT = 10.0
M.checking = false
local checkSent = false

--- How long to wait for the listing, counted from when DEFENCES goes out.
---
--- NOT FROM THE RELOAD. It used to start there, while DEFENCES itself waited for the next
--- prompt -- and an idle character gets no prompts. Ten quiet seconds after `emreload` and the
--- wait was over before DEFENCES had ever been sent; the first prompt after it (the user
--- spending a balance) found keep-up resumed on the stale list, and `perform bliss` went out
--- over a bliss that was up (reported 2026-10-16).
local function awaitListing()
   emunah.timers.start("defkeepup.check", M.CHECK_TIMEOUT, function()
      if M.checking then
         log.debug("No DEFENCES listing after %.0fs -- keep-up resumes anyway.", M.CHECK_TIMEOUT)
         M.checking, checkSent = false, false
      end
   end)
end

function M.checkDefences()
   if checkSent then return end
   if emunah.act.send("defences", { eq = true }) then
      checkSent = true
      awaitListing()
   end
end

--- The listing has been read (patterns.lua). Resume.
function M.defencesChecked()
   if not M.checking then return end
   M.checking, checkSent = false, false
   emunah.timers.stop("defkeepup.check")
   log.debug("DEFENCES read -- keep-up resumes.")
end

event.register("emunah.loaded", function(_, reloading)
   local vitals = emunah.gmcp and emunah.gmcp.vitals
   if not (reloading and vitals and vitals.maxhp > 0) then return end
   M.checking, checkSent = true, false
   emunah.timers.stop("defkeepup.check")
   -- Now, not on the next prompt: idle, that could be minutes away, and the listing's reply
   -- is itself what brings the prompt keep-up resumes on. Held (no equilibrium, stunned),
   -- the next tick tries again. The timeout starts when DEFENCES actually leaves, not here:
   -- starting it at the reload let it expire before the send, and the next prompt raised
   -- bliss off the stale list (2026-10-16).
   if M.enabled then M.checkDefences() end
end, "curing.defkeepup")

-- React immediately when a defence drops rather than waiting for the next tick; losing
-- rebounding mid-fight is worth a fast response.
--
-- ONE LOSS, NOT A BURST. An arena defeat removes every defence one Char.Defences.Remove at
-- a time, ahead of the death line and the vitals behind it (gmcp/vitals.lua, M.stale).
-- Answering each one sent the whole defup into the reset: levitation, nightsight, venom,
-- frost, mindseye, three herbs and a sileris apply went out before "You have been slain by
-- Erishka." (2026-10-23 10:00:48), the herbs were already in the rift, and three came back
-- "What do you want to eat?". The first loss since the prompt is answered now; the rest
-- wait for the prompt that closes them, which sees what is left.
event.register("emunah.defence.lost", function(_, name)
   -- Up and gone again: whatever was sent for it has been answered.
   lastSent[tostring(name or ""):lower()] = nil
   lostSinceTick = lostSinceTick + 1
   if not M.enabled then return end
   if not util.contains(M.wanted(), tostring(name):lower()) then return end
   if lostSinceTick > 1 then return end
   M.tick()
end, "curing.defkeepup")

M.enabled = emunah.config.get("defences.enabled", false) == true

return M

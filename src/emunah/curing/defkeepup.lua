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

--- name -> { sent = time, eaten = time|nil } for item raises not yet seen to land.
local raising = {}

local function raisePending(name)
   local r = raising[name]
   if not r then return false end
   local now = util.now()
   if r.eaten then return now - r.eaten < (r.window or M.RAISE_PENDING) end
   return now - r.sent < M.EAT_PENDING
end

--- How long sileris (or quicksilver) takes to harden after the apply [svof:
--- waitingforsileris, customwait = 8]. Applied, it is not up yet: keep-up must not apply a
--- second one into the gap.
M.SILERIS_HARDEN = 8.0

-- The eat line starts the wait. Any "You eat ..." counts for every raise still waiting on
-- one: an item raise is at most one per vector in flight, and a line about another herb
-- only starts the wait a little early.
do
   local id = tempRegexTrigger([[^You eat ]], function()
      local now = util.now()
      for _, r in pairs(raising) do
         if not r.eaten and now - r.sent < M.EAT_PENDING then r.eaten = now end
      end
   end)
   if id then
      emunah._persist.detectTriggers = emunah._persist.detectTriggers or {}
      table.insert(emunah._persist.detectTriggers, id)
   end
end

-- SILERIS IS APPLIED, THEN HARDENS -- svof's "sileris/quicksilver start" and "finished"
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

function M.withinBudget(name)
   -- Every other accessor here canonicalizes (mode, setMode, state, add, drop,
   -- blockedBy) so that the elixir's name and the defence's name are one budget, not two.
   -- This one did not, and it went unnoticed only because M.tick() always calls it with a
   -- name already canonical from M.wanted() -- an external caller asking by the elixir's
   -- own name (`withinBudget("frost")`, matching how `mode("frost")` already works) would
   -- silently consult an empty budget while `abandon()` had exhausted the real one.
   name = deflist.canonical(name)
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
      attempts[name], warned[name] = nil, nil
   else
      attempts, warned = {}, {}
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
      onSent   = function()
         attempts.mindseye = (attempts.mindseye or 0) + 1
         if emunah.gmcp.vitals and emunah.gmcp.vitals.spend then
            emunah.gmcp.vitals.spend("eq")
         end
      end,
   })
end

--- "You are blind and can see nothing but darkness." Mindseye is what makes that
--- survivable, and prerift will not run until it is up.
function M.noteTrueBlind()
   pendingSight = true
   return M.queueMindseye()
end

--- One pass. Queues at most one defence per vector, at a priority no cure will lose to.
function M.tick()
   if not M.enabled then return end
   -- At the login menu there is no character to keep defences on: act.send would refuse,
   -- but the hold messages below would still print there (2026-09-28, before login).
   local vitals = emunah.gmcp.vitals
   if vitals and vitals.live and not vitals.live() then return end
   if M.checking then return M.checkDefences() end

   -- Do not fight the curing engine for a balance while afflicted; cures come first, and
   -- a defence raised mid-lock is usually stripped again immediately. Deliberate defences
   -- held on purpose (blind/deaf) do not count: they sit in engine.count() permanently once
   -- up, and gating on the raw count here would mean keep-up -- including mindseye, which
   -- blind/deaf require -- never runs again for the rest of the session.
   local engine = emunah.curing.engine
   if engine and engine.enabled and engine.curableCount() > 0 then
      -- Still queue the touch. This tick's flush already happened in the curing engine,
      -- but the slot has to be mindseye's before the next prompt, not bliss's: the
      -- darkness line is tracked as an affliction for a couple of seconds and that used
      -- to make this function return before mindseye was ever considered.
      if pendingSight then M.queueMindseye() end
      return
   end

   local items = emunah.gmcp.items
   local blindWithoutSight = items and not items.sighted() and not deflist.isUp("mindseye")
   if pendingSight or blindWithoutSight then M.queueMindseye() end

   for _, name in ipairs(M.missing()) do
      local vector, command, needs, item, unconfirmable = deflist.resolve(name)

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

      if vector and command and item and raisePending(name) then
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

      if vector and command and M.withinBudget(name) then
         -- mindseye, while the character cannot see, must beat the alphabetical
         -- neighbours on this same vector. queueMindseye() may already hold the slot.
         local priority = M.PRIORITY
         if name == "mindseye" and (pendingSight or blindWithoutSight) then
            priority = M.SIGHT_PRIORITY
         end
         local sentCommand = command
         queue.push(vector, command, {
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
               if deflist.DYNAMIC and deflist.DYNAMIC[name] then
                  local _, commandNow = deflist.resolve(name)
                  return commandNow == sentCommand
               end
               return true
            end,
            confirm  = emunah.config.get("curing.confirmWait", 2.0),
            onSent   = function()
               attempts[name] = (attempts[name] or 0) + 1
               if item then raising[name] = { sent = util.now() } end

               -- UNCONFIRMABLE: SATISFIED ON SEND, NOT ON Char.Defences. `bliss` produces no
               -- Char.Defences line ever, so the ordinary "defup done once confirmed" event
               -- listener below never fires for it -- waiting for that would mean waiting
               -- forever, and the defence would sit MISSING despite being genuinely up.
               -- Keepup mode is unaffected: `M.missing()` does not consult `satisfied` for
               -- keepup, so it is still bounded only by the ordinary attempt budget.
               if unconfirmable and M.mode(name) == "defup" then
                  M.satisfied[name] = true
               end

               if vector == "equilibrium" then
                  -- HOLD THE VECTOR UNTIL THE GAME CONFIRMS THE COST.
                  --
                  -- Char.Vitals omits eq when it has not changed, so the next push -- fired
                  -- by something unrelated, like damage taken the same round -- can still
                  -- read eq=true and let a second raise go out into the gap. Exactly the
                  -- case vitals.spend() was written for, and it matters more here than for
                  -- the cheap defences: `perform inspiration` costs 3.50s of equilibrium,
                  -- so the window is wide.
                  --
                  -- Not a fixed cost timer -- the "Equilibrium used: N.NNs." trigger starts
                  -- `cure.equilibrium` from the game's own figure the moment it replies.
                  -- This only covers the round trip before that arrives.
                  emunah.gmcp.vitals.spend("eq")
               elseif vector ~= "balance" then
                  have.spend(vector)
               end
            end,
         })
      end
   end

   queue.flush()
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

event.register("emunah.tick", function()
   M.tick()
end, "curing.defkeepup")

-- ---------------------------------------------------------------------------
-- after a reload: ask DEFENCES before raising anything
-- ---------------------------------------------------------------------------
--
-- A reload rebuilds the defence list from the last full Char.Defences.List, which predates
-- every change since (gmcp/defences.lua's applyDefListing). Raising defences off that stale
-- list is what sent `perform bliss` on every `emreload`. So after a reload keep-up holds, sends
-- DEFENCES, and resumes once the listing has been read -- or after M.CHECK_TIMEOUT, so a
-- lost reply cannot stall it. DEFENCES costs equilibrium (0.50s, docs/game/defences.md).

M.CHECK_TIMEOUT = 10.0
M.checking = false
local checkSent = false

function M.checkDefences()
   if checkSent then return end
   if emunah.act.send("defences", { eq = true }) then
      checkSent = true
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
   emunah.timers.start("defkeepup.check", M.CHECK_TIMEOUT, function()
      if M.checking then
         log.debug("No DEFENCES listing after %.0fs -- keep-up resumes anyway.", M.CHECK_TIMEOUT)
         M.checking, checkSent = false, false
      end
   end)
end, "curing.defkeepup")

-- React immediately when a defence drops rather than waiting for the next tick; losing
-- rebounding mid-fight is worth a fast response.
event.register("emunah.defence.lost", function(_, name)
   if not M.enabled then return end
   if not util.contains(M.wanted(), tostring(name):lower()) then return end
   M.tick()
end, "curing.defkeepup")

M.enabled = emunah.config.get("defences.enabled", false) == true

return M

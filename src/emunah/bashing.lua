--- The bashing loop.
---
--- This is the consumer the walker was built for. It closes the loop:
---
---     walker arrives in a room
---       -> pick a denizen from the area kill list, by replica number
---       -> attack it whenever the class says an attack is possible
---       -> it dies (or leaves) -> mark it dealt with -> pick the next
---       -> nothing left to kill here -> tell the walker to move on
---
--- Every part of that already existed and was waiting for a driver: denizens.lua holds the
--- list and the targeting, class/adapter.lua holds the attack, walker.lua holds the
--- movement. This module is the ~200 lines that make them one behaviour.
---
--- HOW A KILL IS DETECTED
--- ----------------------
--- Not by parsing death messages, which vary per creature and per class. When something
--- dies, Achaea removes it from the room and (usually) adds a corpse -- so
--- Char.Items.Remove for the id we are attacking is the signal, and it is exactly as
--- reliable as the game's own item tracking. It also catches the cases a death trigger
--- would miss: the creature fleeing, being killed by someone else, or being dragged away.
--- All three mean the same thing to us -- stop attacking it and pick another.
---
--- SAFETY
--- ------
--- An unattended loop that cannot stop itself is how you feed a character to a denizen.
--- It halts on: health below a threshold, an unhandled shield, the class module refusing
--- to attack, a player arriving (optional), and disconnect. Manual movement stops the
--- walker, which stops this.

local M = {}

local log   = emunah.log
local event = emunah.event

M.enabled = false
M.target  = nil      -- replica number currently being attacked
M.stats   = { killed = 0, rooms = 0, startedAt = 0, attacks = 0, dealt = 0, taken = 0 }

--- Set only by the health-threshold branch of unsafe(). While true, maybeResume() watches
--- for health to climb back out and restarts bashing on its own -- see the comment there
--- for why this is scoped to exactly that one stop reason and no other.
M.awaitingHealthResume = false

--- Target health when we first saw it, and most recently, as percentages. Achaea reports
--- this per hit via IRE.Target.Info, which is a far better signal than counting attacks:
--- it says whether we are actually hurting the thing.
M.targetHealth = { first = nil, last = nil }

--- Targets already branded this room, so an amplifier that lasts is not re-applied.
---
--- Keyed by replica number, and populated from two directions: our own cast, and anyone
--- else's. An ally branding something we are about to brand is common when hunting near
--- another Priest, and the second brand achieves nothing.
M.penitent = {}

--- Record that a replica is already branded, whoever did it.
---
--- Deliberately tolerant of an id we have never targeted: an ally may brand something
--- before we ever pick it, and the point is to know before we spend the equilibrium.
function M.markPenitent(id)
   if not id then return false end
   M.penitent[tostring(id)] = true
   return true
end

function M.isPenitent(id)
   return id ~= nil and M.penitent[tostring(id)] == true
end

--- Attacks sent at the current target without it dying. Guards against a creature that
--- cannot be hurt by this attack (wrong damage type, immune, shielded) -- without a cap
--- the loop would attack a rock forever.
M.attemptsAtTarget = 0

M.config = {
   -- Stop entirely below this percentage of health. Deliberately higher than the walker's
   -- own threshold: the walker only has to stop moving, this has to stop fighting.
   stopBelowHealth = 50,
   -- Give up on a target after this many attacks that do not kill it.
   maxAttempts = 40,
   -- Move on when the room is clear.
   walkWhenClear = true,
   -- Never attack with another player in the room. On by default: being seen auto-killing
   -- is the thing most worth not doing.
   soloOnly = true,
   -- Percentage points ABOVE stopBelowHealth required before maybeResume() restarts
   -- bashing on its own. Never the same line that stopped us -- a fight that put you at
   -- 49% will put you there again on the very next hit, and resuming exactly on the
   -- boundary is how the loop flaps on and off mid-swing instead of settling.
   resumeMargin = 10,
}

local function setting(key)
   local value = emunah.config.get("bashing." .. key)
   if value == nil then return M.config[key] end
   return value
end

-- ---------------------------------------------------------------------------
-- control
-- ---------------------------------------------------------------------------

function M.start()
   if M.enabled then
      log.warn("Already bashing. 'emset bash off' first.")
      return false
   end

   local class = emunah.class
   if not (class and class.active and class.active.attack) then
      log.error("No class module loaded -- nothing knows how to attack.")
      log.error("Detected class: %s", tostring(emunah.gmcp.status.class() or "unknown"))
      return false
   end

   M.enabled = true
   M.target = nil
   M.attemptsAtTarget = 0
   M.movedFrom = nil
   M.lootHold = nil
   M.awaitingHealthResume = false
   M.stats = { killed = 0, rooms = 0, startedAt = emunah.util.now(), attacks = 0, dealt = 0, taken = 0 }

   -- Take over pacing. Otherwise the walker's own timer speedwalks us out of a room
   -- mid-fight and then straight through every populated room afterwards.
   if emunah.walker then emunah.walker.claim("bashing") end

   log.info("Bashing <ansi_light_green>on<ansi_yellow> (%s).",
      emunah.config.get("bashing.attack", "smite"))
   event.raise("bashing.started")

   M.tick()
   return true
end

--- @param reason string|nil why
--- @param halt boolean|nil also stop the walk, for stops that mean "things are going wrong"
function M.stop(reason, halt)
   -- Cleared unconditionally, ABOVE the "already stopped" guard below. `emunah hunt off`
   -- issued after a safety stop had already fired -- exactly the case this exists for --
   -- reaches this function with M.enabled already false, and a reset placed after the
   -- guard would never run for it: the pending resume would survive an explicit stop and
   -- fire anyway the next time health recovered. tick() re-arms this immediately afterward
   -- for the one reason that gets to resume itself -- see unsafe() and maybeResume().
   M.awaitingHealthResume = false

   if not M.enabled then return false end
   M.enabled = false
   M.target = nil

   if emunah.walker then
      if halt then
         -- A SAFETY STOP MUST NOT LEAVE US WALKING.
         --
         -- release() only hands pacing back, and an unclaimed walker resumes stepping on
         -- its own -- so stopping the fight actually STARTED the wandering. Confirmed live:
         -- the loop stopped at 27% lost, and then speedwalked through three more rooms
         -- while a wolverine chased and mauled us, unable to fight back because bashing was
         -- off. Walking away hurt, into unknown rooms, is worse than either fighting or
         -- standing still.
         emunah.walker.stop(reason, true)   -- emergency: no walk home either
         -- Still hand the claim back. stop() halts the walk but does not un-claim it, and a
         -- walker left claimed by a loop that is no longer running would refuse to
         -- self-drive ever again.
         emunah.walker.release("bashing")
      else
         -- Hand pacing back, so `emunah walk` alone still self-drives afterwards.
         emunah.walker.release("bashing")
      end
   end

   local elapsed = emunah.util.now() - (M.stats.startedAt or emunah.util.now())
   log.info("Bashing stopped: %d killed in %s%s.",
      M.stats.killed, emunah.util.duration(elapsed),
      reason and (" (" .. reason .. ")") or "")
   event.raise("bashing.stopped", reason)
   return true
end

function M.toggle()
   if M.enabled then M.stop("requested") else M.start() end
   return M.enabled
end

-- ---------------------------------------------------------------------------
-- the loop
-- ---------------------------------------------------------------------------

--- Should we stop for safety?
--- @return string|nil reason
--- @return boolean|nil resumable -- true only for the health-threshold case; every other
---   reason (a watched resource, a player arriving) stays a manual restart on purpose. See
---   maybeResume().
local function unsafe()
   local vitals = emunah.gmcp.vitals
   local threshold = tonumber(setting("stopBelowHealth")) or 50

   if vitals and threshold > 0 and vitals.percent.hp < threshold then
      return ("health below %d%%"):format(threshold), true
   end

   -- Everything that is not a flat health floor -- death, a damage spike, endurance,
   -- willpower, mana, the class resource -- lives in watch.lua so all three loops share one
   -- copy of the rules rather than each growing their own.
   local watched = emunah.watch and emunah.watch.unsafe()
   if watched then return watched end
   if emunah.config.get("bashing.stopOnPlayer", false)
      and emunah.gmcp.room.playerCount() > 0 then
      return "another player arrived"
   end
   return nil
end

--- Choose something to attack here.
local function acquire()
   local denizens = emunah.denizens
   local next_ = denizens.next()
   if not next_ then return nil end

   M.target = next_.id
   M.attemptsAtTarget = 0
   M.targetHealth = { first = nil, last = nil }

   -- Set the game's target too, so manual commands and any other script agree with us.
   local ire = emunah.gmcp.ire
   if ire and ire.setTarget then ire.setTarget(next_.id) end

   log.debug("Bashing target: %s (%s)", next_.name, next_.id)
   return next_
end

--- The room we have already asked the walker to leave, so we ask only once.
M.movedFrom = nil

--- How long to hold a cleared room for gold that is still on the floor.
---
--- Sized from what the wait is actually for: GET needs balance and equilibrium, the killing
--- blow has just spent both, and a smite's balance is 2.8s. A shorter bound would expire
--- before the thing it is waiting for could possibly happen, which is the same as not
--- waiting at all.
M.LOOT_WAIT = 4.0

--- Room we are holding for loot, and until when. Bounded on purpose -- see roomClear().
M.lootHold = nil

--- Room is clear: hand back to the walker, or stop.
---
--- Asking ONCE per room matters. tick() runs on every prompt, so an unguarded request
--- re-raises walker.move continuously while we are still travelling -- and each one
--- restarts the speedwalk from scratch. On a route the game will not let us walk (water
--- needing SWIM, a closed door) that becomes an unbounded loop: "Starting speedwalk from
--- 2397 to 2396" on every single prompt, forever.
local function roomClear()
   M.target = nil
   if not setting("walkWhenClear") then return end

   local walker = emunah.walker
   if not (walker and walker.enabled) then return end

   local here = emunah.gmcp.room and emunah.gmcp.room.num

   -- DO NOT WALK OUT ON GOLD WE ARE ABOUT TO PICK UP.
   --
   -- The room goes clear the moment the last denizen dies, and the gold from that kill
   -- lands at the same instant -- but GET costs the balance and equilibrium the killing
   -- blow just spent, so the first attempt is refused and the retry waits on
   -- `balance.gained`. Without this the walker left first and the retry fired in the next
   -- room, which is why a hunt finished with an empty pack and a trail of sovereigns
   -- behind it.
   --
   -- CHECKED BEFORE THE movedFrom GUARD, and that ordering is the whole point. Achaea
   -- normally sends the corpse, the spill and the prompt in one burst, so the gold is
   -- already on the floor by the time this runs -- but not always. When the denizen's
   -- removal and the prompt arrive first, the room is declared clear and movedFrom is set a
   -- moment BEFORE the gold appears, and a check sitting after that guard would never run
   -- again for this room. That is the case the bounded test covers.
   --
   -- BOUNDED, because the alternative is worse than losing the gold. loot.pending() already
   -- answers false for anything permanently refused, but a bound is what makes a
   -- miscategorised case cost four seconds instead of the rest of the session -- the same
   -- argument as the attempt budgets in curing/engine.lua and loot.stowGold().
   local loot = emunah.loot
   if loot and loot.pending and loot.pending() then
      local now = emunah.util.now()
      if not (M.lootHold and M.lootHold.room == here) then
         M.lootHold = { room = here, until_ = now + M.LOOT_WAIT }
      end
      if now < M.lootHold.until_ then
         -- Re-open the room. If it was already declared clear, the request to leave has to
         -- be made again once the gold is dealt with, or the hold would simply swallow it.
         -- No raise happens on this path, so this cannot become the speedwalk-restart loop
         -- the guard exists to prevent.
         M.movedFrom = nil
         return
      end
      log.debug("Gold still here after %.1fs -- moving on without it.", M.LOOT_WAIT)
   end
   M.lootHold = nil

   if M.movedFrom == here then
      -- ASKED ONCE AND STILL HERE, with the walker waiting on nothing: the request was lost.
      -- One ask per room is only safe if every ask is answered, and one was not. A step
      -- held for equilibrium after the last kill had its retry cancelled, and the hunt
      -- stood still for good (the 07:16:07 stall in Forest Watch, 2026-10-05; see
      -- walker.lua's onRoom). Asking again only while the walker is idle cannot restart a
      -- speedwalk, since one in progress is never idle.
      if not (walker.idle and walker.idle()) then return end
      log.debug("Still in room %s with the walker idle -- asking it to move again.",
         tostring(here))
      event.raise("walker.move")
      return
   end
   M.movedFrom = here

   M.stats.rooms = M.stats.rooms + 1
   -- The walker owns movement; we just say we are finished here.
   event.raise("walker.move")
end

--- One pass. Driven by the prompt (emunah.tick), so it runs exactly as often as the game
--- gives us new information -- no polling timer, no drift.
function M.tick()
   if not M.enabled then return end

   local reason, resumable = unsafe()
   if reason then
      M.stop(reason, true)   -- halt the walk too; see M.stop
      M.awaitingHealthResume = resumable == true
      return
   end

   -- Do nothing at all while the walker is between rooms.
   --
   -- Achaea volunteers a room's contents AHEAD of the Room.Info that says you have arrived
   -- (see gmcp/items.lua), so mid-speedwalk denizens.here() already describes the room in
   -- front of us. Acting on that meant attacking a creature we had not reached yet:
   -- confirmed live, "smite 19316" sent from a room containing nothing but a signpost,
   -- while pig 19316 stood in the room after it. Movement costs balance too, so the attack
   -- and the mapper's next step then raced for the same balance and one of them collected
   -- "You must regain balance first." -- which is what "we're still doing things when off
   -- balance" actually was.
   --
   -- The walker knows whether it is moving; message ordering only hints at it. Ask the
   -- thing that knows -- but ask it about POSITION, not about its own bookkeeping.
   --
   -- walker.nextRoom is only cleared on arriving at the exact target, so anything that
   -- ends a speedwalk somewhere else (a closed door, a route the mapper re-planned, a
   -- shove) leaves it set until the transit timeout lapses. Gating on the flag alone
   -- therefore froze the loop outright -- "it's pathing but not attacking anything" was
   -- this. Comparing where we ARE with where we are headed is self-healing: if those agree
   -- we have arrived, whatever the flag still says.
   local walker = emunah.walker
   if walker and walker.enabled and walker.nextRoom then
      local here = emunah.gmcp.room and tonumber(emunah.gmcp.room.num)
      if here ~= tonumber(walker.nextRoom) then return end
   end

   -- NEVER ATTACK IN FRONT OF ANOTHER PLAYER.
   --
   -- Unconditional while bashing runs, and separate from bashing.stopOnPlayer -- that one
   -- ends the session outright, which is a different call. This just refuses to swing.
   --
   -- We LEAVE rather than stand there waiting for them to go. Holding position in a room
   -- with someone else, doing nothing, is its own kind of conspicuous, and it would also
   -- deadlock the walk: the room can never be cleared, so the walker is never told to move
   -- and the hunt stops dead until they wander off.
   --
   -- gmcp.room excludes ourselves from the count; Achaea's raw Room.Players does not (see
   -- gmcp/room.lua), and getting that wrong here would mean never attacking anything.
   local room = emunah.gmcp.room
   if setting("soloOnly") ~= false and room and room.playerCount() > 0 then
      if M.target then
         log.debug("Not attacking -- %s is here.", table.concat(room.playerNames(), ", "))
      end
      M.target = nil
      if emunah.gmcp.items.roomFresh() then roomClear() end
      return
   end

   local denizens = emunah.denizens
   local class = emunah.class

   -- Target still valid? A target that has left the room is no longer ours.
   if M.target then
      local present = false
      for _, denizen in ipairs(denizens.here()) do
         if denizen.id == M.target then present = true break end
      end
      if not present then
         denizens.engage(M.target)
         M.target = nil
      end
   end

   if not M.target then
      if not acquire() then
         -- "Nothing to attack" and "the room's contents have not arrived yet" look
         -- identical from here, and confusing them is ruinous: the loop declares every
         -- room clear the instant it walks in and the walker marches through the whole
         -- area attacking nothing. Only move on once the item list actually describes
         -- THIS room.
         if emunah.gmcp.items.roomFresh() then
            roomClear()
         end
         return
      end
   end

   if M.attemptsAtTarget >= (tonumber(setting("maxAttempts")) or 40) then
      log.warn("Giving up on %s after %d attacks.", M.target, M.attemptsAtTarget)
      denizens.engage(M.target)
      M.target = nil
      return
   end

   -- Knocked down or stunned: an attack sent into either is rejected outright, and neither
   -- is a race worth retrying -- see core/act.lua, which owns those rules now. canAttack()
   -- consults it too; this early return exists so a blocked attack does not burn an entry
   -- from the attempts budget below and make us give up on a target we never actually hit.
   if not emunah.act.can({ standing = true }) then return end

   if class.canAttack() then
      -- Battlerage amplifier, checked first: unlike penitence it costs neither balance nor
      -- equilibrium, only its own 23s cooldown and rage, so there is no fight-length
      -- calculation to make -- just "is it ready, and is it aimed at an actual denizen".
      -- Nested inside canAttack() rather than run unconditionally so it lands exactly where
      -- it was asked for: right before the attack that would otherwise have gone out this
      -- tick. See priest.shouldDesolation().
      if class.active and class.active.shouldDesolation
         and denizens.isDenizen(M.target)
         and class.active.shouldDesolation(M.target) then
         if class.active.desolation(M.target) then
            log.debug("Desolation on %s.", M.target)
            return
         end
      end

      -- Amplify first, when the fight is long enough to repay it. This deliberately spends
      -- a turn that would otherwise be an attack -- penitence costs the same equilibrium
      -- smite does -- so it only happens once per target and only on the evidence of how
      -- the fight is actually going. See priest.shouldPenitence().
      --
      -- Two guards before it goes out, and they answer different questions.
      -- isPenitent() is "has anyone already branded this", which an ally hunting alongside
      -- us makes true without our knowing. isDenizen() is "is this actually a creature",
      -- checked against Achaea's own monster attribute rather than our kill list -- an
      -- offensive ability must never be aimed at a person because a name resolved wrongly
      -- or an id went stale.
      if class.active and class.active.shouldPenitence
         and not M.isPenitent(M.target)
         and denizens.isDenizen(M.target)
         and class.active.shouldPenitence(M.killIn()) then
         if class.active.penitence(M.target) then
            M.markPenitent(M.target)
            log.debug("Branding %s -- ~%d attacks left.", M.target, M.killIn() or -1)
            return
         end
      end

      class.attack(M.target)
      M.attemptsAtTarget = M.attemptsAtTarget + 1
      M.stats.attacks = M.stats.attacks + 1
   end
end

--- Something left the room. If it was our target, it died, fled, or was taken -- all of
--- which mean the same thing here.
local function onRemoved(_, location, item)
   if not M.enabled or location ~= "room" or not item then return end
   if item.id ~= M.target then return end

   emunah.denizens.engage(item.id)
   emunah.denizens.recordKill(item.name)
   M.stats.killed = M.stats.killed + 1
   M.target = nil
   M.attemptsAtTarget = 0
   M.targetHealth = { first = nil, last = nil }

   log.debug("Target gone (%d this session).", M.stats.killed)
   event.raise("bashing.killed", item.id, item.name)
end

--- Estimated attacks still needed to kill the current target, or nil when we cannot say.
---
--- Derived from how much of its health bar each of our attacks has actually removed, so it
--- reflects this fight rather than an assumption. Chiefly useful as an honest answer to
--- "is this working": a target whose health is not moving reports nil forever, which is the
--- signal that the attack is wrong for it rather than merely slow.
function M.killIn()
   local first, last = M.targetHealth.first, M.targetHealth.last
   if not (first and last) or M.attemptsAtTarget < 1 then return nil end
   local removed = first - last
   if removed <= 0 then return nil end
   local perAttack = removed / M.attemptsAtTarget
   return math.ceil(last / perAttack)
end

--- Report, for `emunah bash`.
function M.report()
   local elapsed = M.enabled and (emunah.util.now() - M.stats.startedAt) or 0
   return {
      running   = M.enabled,
      target    = M.target,
      attack    = emunah.config.get("bashing.attack", "angel sear"),
      -- Same default as priest.requirement(). It read "bal" here, so `emunah bash` reported
      -- a requirement the attack no longer uses -- exactly the wrong thing to be looking at
      -- when checking why an attack went out without equilibrium.
      balance   = emunah.config.get("bashing.balance", "both"),
      -- Same shape of trap as above, for the resource actually spent rather than required --
      -- see class/priest.lua's consumption().
      consumes  = emunah.config.get("bashing.consumes", "eq"),
      killed    = M.stats.killed,
      attacks   = M.stats.attacks,
      rooms     = M.stats.rooms,
      pending   = emunah.denizens.count(),
      dealt     = M.stats.dealt,
      taken     = M.stats.taken,
      targetHealth = M.targetHealth.last,
      killIn    = M.killIn(),
      elapsed   = elapsed,
      classLoaded = (emunah.class and emunah.class.name) or nil,
   }
end

--- Resume attacking on our own, once health has climbed back out past the margin -- but
--- only from OUR OWN health-triggered stop (M.awaitingHealthResume), and only if there is
--- still something here worth fighting.
---
--- Walking stays off regardless. This calls M.start(), never walker.start(): the walker
--- was told "never walk home in an emergency" for a reason (see M.stop), and a resume that
--- also started moving would undo that the moment the current room happened to be empty.
--- roomClear() already refuses to raise walker.move while walker.enabled is false, so even
--- an empty room here is harmless -- bashing just sits on, idle, rather than marching
--- anywhere -- but there is no reason to leave it on for nothing, so we do not resume at
--- all when the room already has nobody left to fight.
local function maybeResume()
   if M.enabled or not M.awaitingHealthResume then return end
   local vitals = emunah.gmcp.vitals
   if not vitals then return end

   local threshold = tonumber(setting("stopBelowHealth")) or 50
   local margin = tonumber(setting("resumeMargin")) or 10
   if vitals.percent.hp < threshold + margin then return end

   if #emunah.denizens.here() == 0 then
      -- Nothing left here to resume onto, and nothing will change that without walking,
      -- which this deliberately does not do. Stop watching rather than re-check forever.
      M.awaitingHealthResume = false
      return
   end

   M.awaitingHealthResume = false
   log.info("Health recovered above %d%% -- resuming.", threshold + margin)
   M.start()
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

-- The prompt drives everything.
--
-- ONE registration, not three. This module used to register three separate handlers on
-- `emunah.tick` -- the loop, the resume check, and the damage tally -- and every prompt paid
-- three dispatches to reach them. They are listed here in the order they were registered in
-- before, and that order is not cosmetic: maybeResume() can switch M.enabled back on, and
-- the damage tally reads that flag.
event.register("emunah.tick", function()
   M.tick()
   maybeResume()

   -- Damage taken, for the session report. vitals.damageTaken() has existed since the start
   -- and had no callers.
   if not M.enabled then return end
   local vitals = emunah.gmcp.vitals
   if vitals then M.stats.taken = M.stats.taken + vitals.damageTaken() end
end, "bashing")

-- ...except that the prompt is not enough on its own. Char.Vitals arrives when something
-- HAPPENS, so an attack that becomes possible during a quiet moment waits for the next
-- unrelated event to wake us. Measured live: balance came back at 06:54:12.97 and the smite
-- did not go out until 06:54:13.72, when the denizen's next hit finally produced a prompt.
-- Three quarters of a second per swing, for nothing. Our own cooldown lapsing is exactly
-- the signal that the wait is over, so act on it directly.
--
-- BOTH TIMERS, NOT JUST attack.balance. That was the whole guard while smite was the only
-- attack ever configured -- it always consumed balance, so attack.balance was always the
-- one that mattered. Angel Sear (the shipped default since 2026-08-04) consumes equilibrium
-- instead and guards cure.equilibrium (see class/priest.lua's consumption()), so listening
-- to attack.balance alone left the exact same stall this comment already describes, just on
-- the other resource: equilibrium came back, and the follow-on attack waited for whatever
-- unrelated event happened to produce the next prompt. Reported live, 2026-08-04.
event.register("emunah.timer.expired", function(_, name)
   if not M.enabled then return end
   if name == "attack.balance" or name == "cure.equilibrium" then M.tick() end
end, "bashing")

event.register("emunah.items.removed", onRemoved, "bashing")

-- Target health, straight from the game's own per-hit report.
event.register("emunah.target.info", function(_, id, health)
   if not (M.enabled and health and id and tostring(id) == tostring(M.target)) then return end
   if M.targetHealth.first == nil then M.targetHealth.first = health end
   M.targetHealth.last = health
end, "bashing")

event.register("emunah.damage.dealt", function(_, amount)
   if M.enabled then M.stats.dealt = M.stats.dealt + (tonumber(amount) or 0) end
end, "bashing")

-- Arriving somewhere new: forget the previous room's target and start on this one.
event.register("emunah.walker.arrived", function()
   if not M.enabled then return end
   -- Replica numbers are unique and never reused, so the brand memory is only meaningful
   -- for the room we are standing in.
   M.penitent = {}
   M.target = nil
   M.attemptsAtTarget = 0
   M.movedFrom = nil      -- a new room may need clearing and then leaving again
   M.lootHold = nil       -- the hold was about the room we have just left
end, "bashing")

-- The walk ending ends the hunt. Without this the loop kept ticking over an exhausted
-- route: every tick found the room clear, asked the walker to move, and the walker -- no
-- longer running -- ignored it, so `emunah hunt` never finished on its own and had to be
-- stopped by hand. Guarded on walkWhenClear because with that off, bashing is deliberately
-- independent of the walker and clearing one room by hand is a legitimate use.
event.register("emunah.walker.finished", function()
   if M.enabled and setting("walkWhenClear") then M.stop("the walk finished") end
end, "bashing")

event.register("sysDisconnectionEvent", function()
   if M.enabled then M.stop("disconnected") end
end, "bashing")

-- Curing takes precedence over offence: if the engine is fighting a lock, attacking into
-- it wastes the balance the cure needs.
-- DEATH PAUSES EVERYTHING, and a hunt does not come back on its own: revival puts you
-- somewhere else, naked, and walking back into the fight that killed you is the user's
-- call. `halt` so the walker stops too rather than wandering off without us.
event.register("emunah.character.died", function()
   if M.enabled then M.stop("died", true) end
end, "bashing")

event.register("emunah.bashing.pause", function()
   if M.enabled then M.stop("paused") end
end, "bashing")

return M

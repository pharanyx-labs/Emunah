--- Picking up what dies.
---
--- Gold spills from corpses when a denizen dies -- "A few golden sovereigns spill from the
--- corpse." -- and it stays on the ground until someone takes it. Over a 132-room hunt
--- that is a lot of sovereigns left behind.
---
--- DRIVEN BY GMCP, NOT BY THE MESSAGE
--- ----------------------------------
--- Char.Items.Add says when gold has landed in the room, so no pattern is needed for the
--- spill line: at 11:52:09 (2026-10-04) `some gold sovereigns` (attrib "t") arrived in the
--- room's list ahead of "A tiny pile of sovereigns spills from the corpse." It also covers
--- gold that arrives any other way -- a corpse someone else made, a pile dropped by a fleeing
--- denizen.
---
--- THE COMMAND IS `get gold`, the user's (2026-10-04), not `get <replica>`, and it takes
--- every pile in the room (the user, 2026-10-04). So one goes out for all of them.

local M = {}

local log   = emunah.log
local event = emunah.event

--- Item names that are money. Achaea's gold is "sovereigns" in every observed form
--- ("a few golden sovereigns", "a pile of gold sovereigns"), but `gold` is included so an
--- unusual phrasing is not silently walked past.
M.PATTERNS = { "sovereign", "gold coin", "golden crown" }

--- Replica numbers we have already tried to take, so a pile we cannot pick up (someone
--- else's, or out of reach) is not retried on every room list. `get gold` takes every pile,
--- so all of them are marked when it goes.
M.attempted = {}

--- Seconds to wait for a GET to land before the next. Covers the round trip, as STOW_GUARD
--- does for the PUT.
M.GET_GUARD = 1.5

M.stats = { picked = 0 }

--- How long after a kill of ours that gold is still considered ours, in seconds.
---
--- Achaea does not say who a pile belongs to, so the only honest link between a corpse and
--- a kill is that the spill follows the slaying within a moment. Generous enough to survive
--- a slow round trip, short enough that a pile appearing later -- someone else's kill, or
--- something dropped -- falls outside it.
M.CREDIT_WINDOW = 4.0

--- When our own kill last earned us the right to pick things up.
M.creditUntil = nil

local function enabled()
   return emunah.config.get("loot.gold", true) ~= false
end

--- Only take what fell from something we killed.
---
--- OFF BY DEFAULT, and it did not start that way. The original rule was that "A few golden
--- sovereigns spill from the corpse" looks identical whoever made the corpse, so taking only
--- our own kill's gold kept an automated character from hoovering up a stranger's loot.
---
--- The empty-room rule below now carries that concern instead, at the user's direction:
--- take any gold on the floor, provided nothing alive is in the room to have a claim on it.
--- Set `loot.ownKillsOnly true` to put the narrower rule back.
local function credited()
   if emunah.config.get("loot.ownKillsOnly", false) == false then return true end
   return M.creditUntil ~= nil and emunah.util.now() < M.creditUntil
end

--- Nobody else in the room.
---
--- Even our own kill's gold is not worth grabbing in front of someone, and picking things
--- off the floor while another player watches is exactly the behaviour that gets an
--- automated character noticed. gmcp.room excludes ourselves from the count (Achaea's
--- Room.Players does not -- see gmcp/room.lua).
local function alone()
   if emunah.config.get("loot.aloneOnly", true) == false then return true end
   local room = emunah.gmcp.room
   return not room or room.playerCount() == 0
end

--- Nothing left on the kill list in the room either.
---
--- GET costs balance AND equilibrium, which is precisely what a fight needs, and gold
--- appears at the moment a kill has just spent both. Stopping to pick it up while something
--- else is still to be fought trades an attack for a pile that is not going anywhere.
---
--- ONLY WHAT WE WOULD FIGHT COUNTS (the user, 2026-10-05: once everything on the kill list
--- is dead, take the gold). It used to be any denizen at all, and a creature we never attack
--- -- an elk, a shopkeeper -- then held the gold for as long as it stood there. A wanted
--- denizen we gave up on (bashing's maxAttempts) still counts: it is alive and may be
--- hitting us.
---
--- denizens.here() excludes corpses, which matters more here than anywhere else it is used:
--- the corpse the gold just spilled out of is in the room by definition, and counting it
--- would mean gold from a kill could never be picked up at all.
local function clear()
   if emunah.config.get("loot.noDenizens", true) == false then return true end
   local denizens = emunah.denizens
   if not denizens then return true end
   for _, denizen in ipairs(denizens.here()) do
      if denizens.wanted(denizen.name) then return false end
   end
   return true
end

--- Does this item look like money?
function M.isGold(name)
   name = tostring(name or ""):lower()
   for _, pattern in ipairs(M.PATTERNS) do
      if name:find(pattern, 1, true) then return true end
   end
   return false
end

--- Take a specific item by replica number.
function M.take(id, name)
   if not id then return false end
   id = tostring(id)
   if M.attempted[id] then return false end

   if not alone() then
      log.debug("Not picking up %s -- someone else is here.", tostring(name or id))
      return false
   end
   if not clear() then
      log.debug("Not picking up %s -- something on the kill list is still here.",
         tostring(name or id))
      return false
   end
   if not credited() then
      log.debug("Not picking up %s -- not from a kill of ours.", tostring(name or id))
      return false
   end

   -- GET costs balance and equilibrium as well as needing you upright, so it competes
   -- directly with attacking -- which is exactly when gold appears, since the pile arrives
   -- from a kill we just spent both on.
   --
   -- Do NOT mark attempted when we cannot act: nothing else is holding this pile for us.
   -- The balance and equilibrium events below re-sweep once they return, so a pile skipped
   -- mid-fight is picked up a moment later rather than lost for the rest of the visit.
   -- One GET in flight. A kill that drops two piles adds both at once, and the first `get
   -- gold` takes both.
   if emunah.timers.active("loot.get") then return false end
   if not emunah.act.send("get gold", { standing = true, bal = true, eq = true }) then
      return false
   end

   M.attempted[id] = true
   for _, item in ipairs(emunah.gmcp.items.at("room")) do
      if M.isGold(item.name) then M.attempted[tostring(item.id)] = true end
   end
   emunah.timers.start("loot.get", M.GET_GUARD, function() M.sweep() end)
   M.stats.picked = M.stats.picked + 1
   log.debug("Picking up %s (%s).", tostring(name or "item"), id)
   event.raise("loot.taken", id, name)
   return true
end

--- Is there gold here we still intend to take?
---
--- THE HUNT HAS TO WAIT FOR THIS, which is why it exists. GET costs balance and
--- equilibrium, and gold appears at the instant a kill has just spent both -- so the first
--- attempt at the pile is always refused, and the retry comes from `balance.gained` a
--- couple of seconds later. Meanwhile bashing declares the room clear on the very next
--- prompt and the walker leaves, so the retry fires in the room we have walked into and the
--- pile stays on the floor of the one we left. That is the whole bug: every kill's gold was
--- abandoned unless the balance happened to be back already.
---
--- ONLY TRANSIENT BLOCKERS COUNT. A pile we are never going to take -- someone else is
--- standing there, or `loot.ownKillsOnly` is on and this is not our kill -- returns false,
--- because holding the room for it would stall the hunt indefinitely. See the deadlock note
--- in bashing.lua's tick(): a room that can never be cleared is a walk that never resumes.
--- @return boolean
function M.pending()
   if not enabled() then return false end
   local items = emunah.gmcp.items
   if not items then return false end

   -- The permanent refusals, in the order M.take() applies them. Waiting changes none of
   -- them, so none of them is worth waiting on.
   --
   -- clear() belongs here even though the caller only asks when it has nothing left to
   -- attack, and it is the deadlock that matters: a wanted denizen bashing has given up on
   -- (maxAttempts) leaves the room unattackable and un-clear at the same time, so take()
   -- would refuse forever while the hunt sat there waiting for a pile it was never going
   -- to lift.
   if not alone() then return false end
   if not clear() then return false end
   if not credited() then return false end

   for _, item in ipairs(items.at("room")) do
      if M.isGold(item.name) and not M.attempted[tostring(item.id)] then return true end
   end
   return false
end

--- Sweep the room for anything worth taking.
function M.sweep()
   if not enabled() then return 0 end
   local items = emunah.gmcp.items
   if not items then return 0 end

   local taken = 0
   for _, item in ipairs(items.at("room")) do
      if M.isGold(item.name) and M.take(item.id, item.name) then
         taken = taken + 1
      end
   end
   return taken
end

-- ---------------------------------------------------------------------------
-- Stowing it
-- ---------------------------------------------------------------------------
--
-- Gold picked up goes straight into the pack. Driven by the gold ARRIVING IN INVENTORY
-- rather than by a delay after the GET, for the same reason the pickup is driven by
-- Char.Items rather than by the spill message: the game says when it has actually happened,
-- and a timer only guesses. A `put` sent before the `get` has landed is a command about
-- something we are not holding yet.

--- The container gold is stowed in. Its replica number, not its name -- `put gold in
--- backpack` is ambiguous the moment a second pack is involved, exactly as `get gold` is.
--- The fallback for `pack.id`, which is what every caller reads (see M.pack()).
M.STOW_IN = "backpack452292"

--- How many times to send the PUT with the gold still loose before stopping.
---
--- Same reasoning as the restocker's STOCK_ATTEMPTS in curing/engine.lua: the honest
--- response to "my model of this is wrong" is to stop and say what to check. The model here
--- is that gold in a container leaves the "inv" location (Char.Items tracks container
--- contents under "repNNN" separately -- see gmcp/items.lua), and it has NOT been verified
--- against a real payload. If it is wrong, this bounds the damage at three commands and a
--- log line naming the thing to look at, rather than a PUT on every balance forever.
M.STOW_ATTEMPTS = 3

--- How long to leave a PUT alone before sending another. Covers the round trip.
M.STOW_GUARD = 1.5

M.stowAttempts = 0
local stowWarned = false

--- The one pack: gold goes in, purchases come out, antitheft keeps it closed. nil only if
--- someone has set `pack.id` to nothing on purpose.
function M.pack()
   local container = tostring(emunah.config.get("pack.id", M.STOW_IN) or "")
   return container ~= "" and container or nil
end

local stowContainer = M.pack

--- How many loose piles of gold we are carrying, or nil if inventory is not known yet.
---
--- The nil is load-bearing. NOT KNOWING what we hold is not the same as holding nothing --
--- the trap that had the restocker pull nine ash against a target of three after a reload.
local function looseGold()
   local items = emunah.gmcp.items
   if not (items and items.inventoryKnown()) then return nil end
   local count = 0
   for _, item in ipairs(items.at("inv")) do
      if M.isGold(item.name) then count = count + 1 end
   end
   return count
end

--- Put whatever gold we are carrying into the pack.
function M.stowGold()
   if not enabled() then return false end
   local container = stowContainer()
   if not container then return false end

   -- GOLD TAKEN OUT TO PAY WITH IS NOT LOOSE GOLD. A purchase GETs exactly its price
   -- from the pack and BUYs straight after; the GET landing raised Char.Items.Add, this
   -- answered it with a PUT, and the gold went back in the pack -- reported from play as
   -- "gets the correct amount of gold, then tries to put gold in pack". The shop holds
   -- the gold until the purchase has had time to land, then hands back to this, so a
   -- refused BUY still ends with its gold in the pack.
   local shop = emunah.shop
   if shop and shop.paying and shop.paying() then return false end
   -- Nor is gold you took out yourself. See M.HOLD_TYPED.
   if emunah.timers.active("loot.hold") then return false end

   local loose = looseGold()
   if loose == nil then return false end

   if loose == 0 then
      -- It landed. The budget is per pile rather than per session, so this is where it
      -- resets -- otherwise three stows in one hunt would exhaust it and the fourth pile
      -- would sit in inventory with a warning about a problem that does not exist.
      M.stowAttempts, stowWarned = 0, false
      return false
   end

   if M.stowAttempts >= M.STOW_ATTEMPTS then
      if not stowWarned then
         stowWarned = true
         log.warn("Sent 'put gold in %s' %d times and the gold is still loose -- stopping. "
            .. "Check the pack is worn and that %s is its replica number.",
            container, M.stowAttempts, container)
      end
      return false
   end

   if not emunah.timers.ready("loot.stow") then return false end

   -- WHAT PUT COSTS HAS NEVER BEEN OBSERVED, so nothing is declared here. Guessing either
   -- way is worse than not guessing: a requirement it does not have holds the command back
   -- for no reason, and one it does have gets it refused. The retry wiring below is what
   -- makes the omission safe -- if the game refuses it for a balance, the next recovery
   -- sends it again, and STOW_ATTEMPTS stops that becoming a loop.
   if not emunah.act.send("put gold in " .. container, {}) then return false end

   M.stowAttempts = M.stowAttempts + 1
   emunah.timers.start("loot.stow", M.STOW_GUARD)
   return true
end

--- How long gold you fetched yourself stays in hand before it goes back in the pack.
---
--- `get 5 gold from pack452292`, typed, was answered with `put gold in backpack452292` in
--- the same packet (08:12:22.17 on 2026-10-04): the GET's Char.Items.Add looked like any
--- other gold arriving. Gold you take out is for something -- a GIVE, a payment -- so it is
--- left alone for this long, then put away if it is still loose. `loot.holdTyped`.
M.HOLD_TYPED = 30

event.register("emunah.sent", function(_, command, typed)
   if not typed or not command:find("^get%s.*gold") then return end
   local hold = tonumber(emunah.config.get("loot.holdTyped", M.HOLD_TYPED)) or M.HOLD_TYPED
   if hold <= 0 then return end
   emunah.timers.start("loot.hold", hold, function() M.stowGold() end)
end, "loot")

function M.setEnabled(value)
   emunah.config.set("loot.gold", value)
   emunah.config.save()
   log.info("Gold pickup %s.",
      value and "<ansi_light_green>on<ansi_yellow>" or "<ansi_light_red>off<ansi_yellow>")
   return value
end

function M.toggle()
   return M.setEnabled(not enabled())
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

--- Our own kill opens the window in which gold on the floor counts as ours. The slay
--- message is the only unambiguous statement that WE did it -- bashing's own kill event
--- also fires when a target merely leaves the room.
do
   emunah._persist = emunah._persist or {}
   for _, id in ipairs(emunah._persist.lootTriggers or {}) do killTrigger(id) end
   emunah._persist.lootTriggers = {}
   local id = tempRegexTrigger([[^You have slain ]], function()
      M.creditUntil = emunah.util.now() + M.CREDIT_WINDOW
      -- Anything already on the floor when we killed is fair game for this window too.
      M.sweep()
   end)
   if id then table.insert(emunah._persist.lootTriggers, id) end

   -- KEEP THE PACK ON. A removed pack is what silently breaks stowing: `put gold in
   -- backpack452292` against a pack on the floor is a different command with a different
   -- outcome, and the first sign of it would be gold quietly accumulating loose. So the
   -- removal message is answered directly rather than waiting for something to notice.
   --
   -- Through act.send() rather than a bare send(): the only things that hold it back are a
   -- stun, being asleep, and a rate limit -- all states in which the game would have thrown
   -- the command away anyway. Deliberately NOT retried; one removal, one WEAR, so a refusal
   -- cannot turn into a loop. If it is missed, M.stowGold()'s attempt budget is what says so.
   local wearId = tempRegexTrigger([[^You remove a canvas backpack\.$]], function()
      local container = stowContainer()
      if container then emunah.act.send("wear " .. container, {}) end
   end)
   if wearId then table.insert(emunah._persist.lootTriggers, wearId) end
end

--- Gold appearing in the room is the normal case: a corpse spills it and Achaea sends
--- Char.Items.Add.
event.register("emunah.items.added", function(_, location, item)
   if not enabled() or not item or not M.isGold(item.name) then return end
   if location == "room" then
      M.take(item.id, item.name)
   elseif location == "inv" then
      -- The GET landed. This is the moment the PUT is about something we actually hold.
      M.stowGold()
   end
end, "loot")

--- Gold LEAVING inventory is the game confirming the PUT worked, and it is the only
--- confirmation there is -- the pile turns up under the container's own "repNNN" location,
--- not in a message about the command. It is also where the attempt budget resets, which
--- is why this needs a handler of its own rather than being left to the next pile: without
--- it the budget only ever counts up, and the fourth stow of a hunt would be refused with a
--- warning about a problem that had already resolved itself three times.
event.register("emunah.items.removed", function(_, location, item)
   if not item or not M.isGold(item.name) then return end
   if location == "inv" then
      M.stowGold()
   elseif location == "room" then
      -- A GET landed (or someone else took it). It took every pile there was, so the
      -- others are already marked; only gold that landed behind it is left to sweep.
      emunah.timers.stop("loot.get")
      M.sweep()
   end
end, "loot")

--- A full room list can also carry gold we have not seen (walking into a room where
--- something already died). An inventory list is the equivalent for stowing: after a
--- reload or a login it is the first true statement about what we are carrying, and gold
--- already loose in the pack-less state should go in without waiting for the next pile.
event.register("emunah.items.list", function(_, location)
   if location == "room" then
      M.sweep()
   elseif location == "inv" then
      M.stowGold()
   end
end, "loot")

--- Leaving a room makes the attempted set meaningless -- replica numbers are unique, and
--- keeping them would grow without bound over a long hunt.
event.register("emunah.room", function()
   M.attempted = {}
end, "loot")

--- Anything skipped above (see M.take()) is worth another try the moment the thing that
--- blocked it comes back: standing up, a stun passing, or either of the balances that GET
--- costs. Gold appears precisely when both are spent, so without these a pile would wait
--- for the next unrelated room event.
for _, moment in ipairs({ "recovered", "balance.gained", "equilibrium.gained" }) do
   event.register("emunah." .. moment, function()
      M.sweep()
      -- The same argument covers the PUT, and more so: its cost is unverified, so a
      -- balance returning is the only thing that would retry one the game refused.
      M.stowGold()
   end, "loot")
end

return M

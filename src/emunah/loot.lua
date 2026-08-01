--- Picking up what dies.
---
--- Gold spills from corpses when a denizen dies -- "A few golden sovereigns spill from the
--- corpse." -- and it stays on the ground until someone takes it. Over a 132-room hunt
--- that is a lot of sovereigns left behind.
---
--- DRIVEN BY GMCP, NOT BY THE MESSAGE
--- ----------------------------------
--- The obvious approach is to trigger on the spill line and send `get gold`. This does not,
--- because Char.Items.Add already tells us precisely what appeared in the room and gives us
--- its replica number. That matters for the same reason it matters when attacking: `get
--- gold` is ambiguous when several piles are on the ground, whereas `get 12345` is not. It
--- also works for gold that arrives any other way -- a corpse someone else made, a pile
--- dropped by a fleeing denizen -- without needing a pattern for each.
---
--- The spill message is kept as a backstop, since a corpse's contents occasionally land
--- without a separate Add.

local M = {}

local log   = emunah.log
local event = emunah.event

--- Item names that are money. Achaea's gold is "sovereigns" in every observed form
--- ("a few golden sovereigns", "a pile of gold sovereigns"), but `gold` is included so an
--- unusual phrasing is not silently walked past.
M.PATTERNS = { "sovereign", "gold coin", "golden crown" }

--- Replica numbers we have already tried to take, so a pile we cannot pick up (someone
--- else's, or out of reach) is not retried on every room list.
M.attempted = {}

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
--- "A few golden sovereigns spill from the corpse" looks identical whoever made the corpse.
--- Hoovering up every pile on the floor is how an automated character ends up taking a
--- stranger's loot, which is a social problem rather than a technical one and not one the
--- system should create on your behalf. So the default is to take only what our own kill
--- produced, established by "You have slain ..." rather than inferred.
local function credited()
   if emunah.config.get("loot.ownKillsOnly", true) == false then return true end
   return M.creditUntil ~= nil and emunah.util.now() < M.creditUntil
end

--- Nobody else in the room.
---
--- Same reasoning, one step further: even our own kill's gold is not worth grabbing in front
--- of someone, and picking things off the floor while another player watches is exactly the
--- behaviour that gets an automated character noticed. gmcp.room excludes ourselves from the
--- count (Achaea's Room.Players does not -- see gmcp/room.lua).
local function alone()
   if emunah.config.get("loot.aloneOnly", true) == false then return true end
   local room = emunah.gmcp.room
   return not room or room.playerCount() == 0
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
   if not emunah.act.send("get " .. id, { standing = true, bal = true, eq = true }) then
      return false
   end

   M.attempted[id] = true
   M.stats.picked = M.stats.picked + 1
   log.debug("Picking up %s (%s).", tostring(name or "item"), id)
   event.raise("loot.taken", id, name)
   return true
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
end

--- Gold appearing in the room is the normal case: a corpse spills it and Achaea sends
--- Char.Items.Add.
event.register("emunah.items.added", function(_, location, item)
   if location ~= "room" or not enabled() or not item then return end
   if M.isGold(item.name) then M.take(item.id, item.name) end
end, "loot")

--- A full room list can also carry gold we have not seen (walking into a room where
--- something already died).
event.register("emunah.items.list", function(_, location)
   if location == "room" then M.sweep() end
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
   event.register("emunah." .. moment, function() M.sweep() end, "loot")
end

return M

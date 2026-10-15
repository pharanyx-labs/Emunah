--- Allies: the people you fight beside.
---
--- "We're allies, very trusted allies, and we will soon fight in combat, complementing each
--- other's skills -- set up a framework for this" (the user, 2026-10-15, of Anzerloi). An ally
--- here is a PARTNER: someone you fight with, not just someone your city likes. The name
--- database already says who is friendly (namedb's iff); this says who is on your side of a
--- fight, and what Emunah does about them:
---
---   never a target   adding a partner marks them an ally in the name database, which is what
---                    pvp.setTarget() asks before targeting anyone (`t`, a call, a typo)
---   where they are   their arrivals and departures, said out loud while you are fighting --
---                    a partner leaving the room mid-fight changes the fight
---   their calls      a partner's message on any channel, matched against `allies.calls`,
---                    sets your PvP target to the name it calls
---   who you face     the attackers detect.textFoe() names, with their class, so a call and a
---                    plan can be made against what the other side actually is
---
--- WHAT IS NOT HERE, AND WHY. Nothing is SENT to a partner: no party call, no shared
--- affliction report. Every command Emunah sends needs its syntax from HELP first (CLAUDE.md),
--- and none of those has been captured. Nor is a partner's attack read as landing anything on
--- your shared target: that needs their attack lines as YOU see them, and the only log so far
--- is from their side (docs/game/alchemist.md). Both are the obvious next pieces.

local M = {}

local log   = emunah.log
local event = emunah.event
local util  = emunah.util

-- ---------------------------------------------------------------------------
-- partners
-- ---------------------------------------------------------------------------

--- Partners, lower case, sorted.
function M.partners()
   local out = {}
   for _, name in ipairs(emunah.config.get("allies.partners", {}) or {}) do
      out[#out + 1] = tostring(name):lower()
   end
   table.sort(out)
   return out
end

function M.isPartner(name)
   name = tostring(name or ""):lower()
   for _, partner in ipairs(M.partners()) do
      if partner == name then return true end
   end
   return false
end

local function save(list)
   emunah.config.set("allies.partners", list)
   emunah.config.save()
end

--- Add a partner, and mark them an ally in the name database unless they already are one:
--- that is what keeps every targeting path off them.
function M.add(name)
   name = tostring(name or ""):lower()
   if not name:match("^%a+$") then return false, "a partner is one name, letters only" end
   if M.isPartner(name) then return true end
   local list = M.partners()
   list[#list + 1] = name
   save(list)
   local ndb = emunah.namedb
   if ndb and ndb.relationship(name) ~= "ally" then ndb.iff(name, "ally") end
   event.raise("ally.added", name)
   return true
end

--- Remove a partner. Their standing in the name database is left as it is: they are still
--- whoever they were before, and `emset iff <name> auto` hands that back to their city.
function M.remove(name)
   name = tostring(name or ""):lower()
   local list, kept = M.partners(), {}
   for _, partner in ipairs(list) do
      if partner ~= name then kept[#kept + 1] = partner end
   end
   if #kept == #list then return false end
   save(kept)
   event.raise("ally.removed", name)
   return true
end

-- ---------------------------------------------------------------------------
-- where they are
-- ---------------------------------------------------------------------------

--- Partners in the room with you now, by Room.Players. That list leaves out anyone hidden
--- (gmcp/room.lua), so absent here is "not seen", never "not here".
function M.present()
   local room = emunah.gmcp.room
   local out = {}
   for _, partner in ipairs(M.partners()) do
      if room and room.hasPlayer(partner) then out[#out + 1] = partner end
   end
   return out
end

--- Are we fighting? A PvP session, or someone attacking us within detect.FOE_TIMEOUT.
local function fighting()
   if emunah.pvp and emunah.pvp.enabled then return true end
   local detect = emunah.curing.detect
   return detect ~= nil and next(detect.activeFoes()) ~= nil
end

local function movement(name, arrived)
   if not M.isPartner(name) then return end
   name = tostring(name):lower()
   event.raise(arrived and "ally.arrived" or "ally.left", name)
   -- Walking together, they arrive in every room you do: said only in a fight, where it is
   -- news.
   if fighting() then
      log.info("Your partner %s %s.", util.capitalise(name),
         arrived and "is here" or "has left the room")
   end
end

event.register("emunah.room.playerEntered", function(_, name) movement(name, true) end, "allies")
event.register("emunah.room.playerLeft", function(_, name) movement(name, false) end, "allies")

-- ---------------------------------------------------------------------------
-- their calls
-- ---------------------------------------------------------------------------

--- The last call a partner made: { from, target, at }.
M.lastCall = nil

--- The patterns a call is read with: Lua patterns, each capturing the name called. None
--- ship: how a partner calls a target is their system's business, and is not known yet.
function M.callPatterns()
   local raw = emunah.config.get("allies.calls", {})
   if type(raw) == "string" then
      local out = {}
      for item in raw:gmatch("[^,]+") do
         item = util.trim(item)
         if item ~= "" then out[#out + 1] = item end
      end
      return out
   end
   return type(raw) == "table" and raw or {}
end

--- Read a partner's message as a call. Returns the name called, or nil.
function M.readCall(talker, text)
   if not M.isPartner(talker) then return nil end
   text = tostring(text or "")
   for _, pattern in ipairs(M.callPatterns()) do
      local ok, name = pcall(string.match, text, pattern)
      if ok and type(name) == "string" and name:match("^%a+$") then return name:lower() end
   end
   return nil
end

--- A partner called `target`. Followed when allies.follow is on, unless the name is one PvP
--- would refuse anyway -- another ally, or you.
function M.onCall(from, target)
   M.lastCall = { from = tostring(from):lower(), target = target, at = util.now() }
   event.raise("ally.call", M.lastCall.from, target)
   if emunah.config.get("allies.follow", true) == false then
      log.info("%s calls %s.", util.capitalise(M.lastCall.from), util.capitalise(target))
      return false
   end
   local pvp = emunah.pvp
   if not pvp or pvp.target == target then return false end
   if pvp.setTarget(target) then
      log.info("%s called %s: your target now.", util.capitalise(M.lastCall.from),
         util.capitalise(target))
      return true
   end
   return false
end

event.register("emunah.comm.text", function(_, message)
   if type(message) ~= "table" or not message.talker then return end
   -- The raw text, without its colour: the rendered one carries decho markup.
   local plain = tostring(message.raw or ""):gsub("\27%[[%d;]*m", "")
   local target = M.readCall(message.talker, plain)
   if target then M.onCall(message.talker, target) end
end, "allies")

-- ---------------------------------------------------------------------------
-- who you face
-- ---------------------------------------------------------------------------

--- Everyone attacking you now, with their class, as { name, class } sorted by name.
function M.foes()
   local detect = emunah.curing.detect
   local out = {}
   for name, class in pairs(detect and detect.activeFoes() or {}) do
      out[#out + 1] = { name = name, class = class }
   end
   table.sort(out, function(a, b) return a.name < b.name end)
   return out
end

return M

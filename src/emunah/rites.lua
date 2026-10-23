--- Rites kept up: the room rites you perform are performed again as each one runs out, for as
--- long as you stay in the room they were performed in.
---
--- RITES lists what is up in the room, whose it is and how long it has left. Verbatim, from
--- play at 08:01:41 on 2026-10-16:
---
---     You reach out to sense for holy rites:
---     Rite                Owner                         Seconds left
---     -------------------------------------------------------------
---     Well-being          Saemora                       1224
---     Revitalisation      Saemora                       346
---     Equilibrium used: 1.00s.
---
--- THE LISTING IS THE ONLY THING BELIEVED. Neither the line a rite prints when it is
--- performed nor the one when it lapses has been captured, so nothing here waits for them.
--- Instead, after any `perform rite of <rite>` -- yours or a renewal -- RITES is read once
--- equilibrium is back, and the seconds it gives arm the renewal. A rite of yours that the
--- listing does not show is not up, and is performed (again), at most M.ATTEMPTS times in a
--- row before this gives up and says so. Our own RITES is hidden, cost line and all; one you
--- type is shown and read the same way, and resets every timer just as ours does -- so typing
--- RITES where your rites are up keeps them up too, and stands in for any RITES we owed.
---
--- RENEWED WHEN IT HAS RUN OUT, not before: whether performing a rite that is still up
--- refreshes it or is refused is not known. The listing gives whole seconds, so the renewal
--- waits M.SLACK past the figure, and a rite that turns out to be still up is simply read
--- again and re-armed from its new figure.
---
--- LEAVING THE ROOM ENDS IT (the user, 2026-10-16). A rite belongs to the room it was
--- performed in, and the first Room.Info for any other room forgets every rite kept there.
---
--- RITES ARE YOURS TO RAISE (the user, 2026-10-23: "change it so i put the rites up
--- manually"). Nothing here performs a rite you have not performed. A fight used to raise
--- demons and cleansing (and revitalisation, healing and banishment by situation) in its
--- opening equilibria; at 17:31 that day it spent 7.1s of equilibrium on them while the mace,
--- which needs equilibrium present, waited, and the prayer lapsed under it. Anzerloi, the
--- same minute: "Why I generally don't use them mid-action." A rite you perform is renewed
--- as before, and renewals wait while PvP is on.
---
--- HANDS WINS THE EMERGENCY. Below curing.handsThreshold, `perform hands` wants this
--- equilibrium and the offence's equilibrium lane already sits out for it. A rite must
--- not take the prompt instead. The rite stays due and goes once health is back.

local M = {}

local log   = emunah.log
local event = emunah.event
local util  = emunah.util

--- Equilibrium each rite costs, from AB DEVOTION on 2026-10-15. The listing arms a timer
--- for any of these that are ours. What a fight raises, and what a quiet room renews, are
--- the two tables under it.
M.KEEP = {
   ["well-being"]     = 5.0,
   revitalisation     = 4.0,
   demons             = 3.5,
   cleansing          = 3.6,
   healing            = 3.5,
   banishment         = 4.5,
}

--- Renewed outside a fight, and only once you have performed them.
M.PVE = { ["well-being"] = true, revitalisation = true }

--- `perform hands` wants the equilibrium. Same rule as the offence lane (pvp.lua): trusted
--- health under the hands threshold. Unknown health does not count -- that path is the
--- cure's, via vitals.below.
local function handsWanted()
   local vitals = emunah.gmcp and emunah.gmcp.vitals
   if not vitals or not vitals.percent or not vitals.trusted or not vitals.trusted("hp") then
      return false
   end
   local at = tonumber(emunah.config.get("curing.handsThreshold", 50)) or 50
   return vitals.percent.hp < at
end

--- What RITES costs: "Equilibrium used: 1.00s." in the listing above.
M.CHECK_COST = 1.0

--- How long RITES has to answer before it counts as lost.
M.CHECK_GUARD = 3.0

--- Seconds past the listed figure before a rite is treated as gone. The figure is whole
--- seconds, so the rite may have up to one more.
M.SLACK = 1.0

--- A perform not followed by the rite in the listing, or a RITES with no answer, this many
--- times in a row and the rites are given up on. Whatever stops them -- no devotion, a room
--- that refuses them -- does not get better by trying a fourth time.
M.ATTEMPTS = 3

--- key ("well-being") -> { name = "Well-being", room = number, attempts = n, due = bool }
M.kept = {}

--- The RITES we owe or have sent. `wanted`: send one when equilibrium allows. `sentAt`: ours
--- is in flight. `misses`: ours went unanswered this many times in a row.
M.check = { wanted = false, sentAt = nil, misses = 0 }

--- The listing being read, until its prompt: { rows = { key -> { name, owner, seconds } },
--- ours = bool }.
M.listing = nil

function M.enabled()
   return emunah.config.get("rites.keepup", true) ~= false
end

local function here()
   local room = emunah.gmcp and emunah.gmcp.room
   return room and room.num
end

local function timerName(key)
   return "rites." .. key
end

--- "well-being" -> "Well-being", as the listing writes it.
local function display(key)
   return util.capitalise(key)
end

--- Stop keeping one rite up.
function M.forget(key)
   M.kept[key] = nil
   emunah.timers.stop(timerName(key))
end

--- Stop keeping every rite up, and drop any RITES still owed.
function M.forgetAll()
   for key in pairs(M.kept) do M.forget(key) end
   M.check.wanted, M.check.sentAt, M.check.misses = false, nil, 0
   emunah.timers.stop("rites.check")
   M.listing = nil
end

--- The names kept, sorted, for messages.
local function names(keys)
   local out = {}
   for _, key in ipairs(keys) do out[#out + 1] = display(key) end
   return table.concat(out, ", ")
end

local function sortedKeys()
   local keys = {}
   for key in pairs(M.kept) do keys[#keys + 1] = key end
   table.sort(keys)
   return keys
end

--- Start keeping a rite up in this room.
local function keep(key, name)
   local entry = M.kept[key]
   if not entry then
      entry = { name = name or display(key), attempts = 0, due = false, seen = false }
      M.kept[key] = entry
   end
   entry.room = here()
   return entry
end

--- A rite's time is up: perform it again.
function M.expired(key)
   local entry = M.kept[key]
   if not entry then return end
   entry.due = true
   M.tick()
end

-- ---------------------------------------------------------------------------
-- the listing
-- ---------------------------------------------------------------------------

function M.onHeader()
   M.listing = { rows = {}, ours = M.check.sentAt ~= nil }
   if M.listing.ours then emunah.ui.gag.withPrompt() end
end

--- The column titles and the rule under them: hidden with ours, nothing to read.
function M.onFurniture()
   if M.listing and M.listing.ours then emunah.ui.gag.withPrompt() end
end

--- The listing's cost line. Ours is hidden down to it, so it does not stand alone.
function M.onCost()
   if M.listing and M.listing.ours then emunah.ui.gag.withPrompt() end
end

function M.onRow(name, owner, seconds)
   if not M.listing then return end
   if M.listing.ours then emunah.ui.gag.withPrompt() end
   name = tostring(name or "")
   M.listing.rows[name:lower()] = { name = name, owner = owner, seconds = tonumber(seconds) }
end

--- 1224 -> "20:24".
function M.clock(seconds)
   seconds = math.floor(tonumber(seconds) or 0)
   return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

--- Say it once the block it came in has been drawn. The listing closes on the prompt's
--- Char.Vitals, and our own listing hides that prompt: said there and then, the line went
--- with it -- Revitalisation was read and kept at 08:29:48 (2026-10-16), and nothing said so.
function M.say(fmt, ...)
   local message = fmt:format(...)
   tempTimer(0, function() log.info("%s", message) end)
end

--- The same, as a warning.
function M.warn(fmt, ...)
   local message = fmt:format(...)
   tempTimer(0, function() log.warn("%s", message) end)
end

--- The listing is over: arm a renewal for each of our rites in it, and perform again each
--- one kept that it does not show.
function M.close()
   local listing = M.listing
   if not listing then return end
   M.listing = nil

   -- ANY LISTING ANSWERS WHAT WE OWED, yours or ours: every timer is set again from it
   -- below, and a second RITES would only say the same. Clearing it only for ours sent a
   -- hidden RITES straight after the one you typed (08:13:48.65 -> 08:13:50.58,
   -- 2026-10-16): the perform before it had asked for one, and yours did not count.
   M.check.wanted, M.check.sentAt, M.check.misses = false, nil, 0
   emunah.timers.stop("rites.check")
   if not M.enabled() then return end

   local ndb = emunah.namedb
   local started, reset = {}, {}
   for key, row in pairs(listing.rows) do
      if M.KEEP[key] and row.seconds and ndb and ndb.isSelf(row.owner) then
         local entry = keep(key, row.name)
         -- Said when the listing first shows it, not when it was performed: until then it
         -- is not known to be up.
         if not entry.seen then started[#started + 1] = key end
         entry.name = row.name
         entry.attempts, entry.due, entry.seen = 0, false, true
         emunah.timers.start(timerName(key), row.seconds + M.SLACK,
            function() M.expired(key) end)
         reset[#reset + 1] = key
      end
   end
   if #reset > 0 then
      table.sort(started)
      table.sort(reset)
      local times = {}
      for index, key in ipairs(reset) do
         times[index] = ("%s %s"):format(M.kept[key].name, M.clock(listing.rows[key].seconds))
      end
      M.say("Rites: %stimers reset -- %s.",
         #started > 0 and ("added " .. names(started) .. "; ") or "", table.concat(times, ", "))
   end

   local given = {}
   for _, key in ipairs(sortedKeys()) do
      local row = listing.rows[key]
      if not (row and ndb and ndb.isSelf(row.owner)) then
         local entry = M.kept[key]
         if entry.attempts >= M.ATTEMPTS then
            given[#given + 1] = key
            M.forget(key)
         else
            entry.due = true
         end
      end
   end
   if #given > 0 then
      M.warn("Rites: %s still not up after %d tries -- no longer keeping %s up.",
         names(given), M.ATTEMPTS, #given > 1 and "them" or "it")
   end
end

--- Our RITES went unanswered.
function M.lost()
   M.check.sentAt = nil
   M.check.misses = M.check.misses + 1
   if M.check.misses >= M.ATTEMPTS then
      local keys = sortedKeys()
      M.forgetAll()
      if #keys > 0 then
         log.warn("Rites: RITES went unanswered %d times -- no longer keeping %s up.",
            M.ATTEMPTS, names(keys))
      end
      return
   end
   M.check.wanted = true
end

-- ---------------------------------------------------------------------------
-- sending
-- ---------------------------------------------------------------------------

--- Send an equilibrium command of ours, armed in the prompt's line so a verse that needs the
--- equilibrium goes in front of it rather than behind it into a refusal.
---
--- BALANCE AS WELL. AB DEVOTION gives each rite's equilibrium and nothing about balance;
--- whether one is refused off balance is not seen yet. Both, as the Priest's other
--- equilibrium moves are until play says otherwise (class/priest_pvp.lua), which also keeps
--- a smite from going in front of the rite and taking a balance it might want.
local BOTH = { bal = true, eq = true }
local BOTH_QUIET = { bal = true, eq = true, quiet = true }

local function spendEq(command, needs, seconds)
   if not emunah.act.send(command, needs, "eq") then return false end
   emunah.act.arm("eq")
   -- Char.Vitals goes on reporting equilibrium until the game has run it.
   emunah.timers.start("cure.equilibrium", seconds)
   return true
end

local function perform(key, entry)
   if not spendEq("perform rite of " .. key, BOTH, M.KEEP[key]) then return false end
   entry.due = false
   entry.attempts = entry.attempts + 1
   M.check.wanted = true
   log.info("Rites: performing %s.", entry.name)
   return true
end

--- Perform whatever has run out, then read RITES. One per call: each costs equilibrium.
function M.tick()
   if not M.enabled() then return end

   if next(M.kept) == nil and not M.check.wanted then return end
   -- Renewals, and the RITES that times them, wait while PvP is on: the equilibrium is the
   -- fight's.
   if emunah.pvp and emunah.pvp.enabled then return end
   -- Hands first. Raising above only records what is due; nothing is sent while the
   -- emergency heal wants this equilibrium, RITES included.
   if handsWanted() then return end
   if not emunah.have.balance("equilibrium") then return end

   local room = here()
   for _, key in ipairs(sortedKeys()) do
      local entry = M.kept[key]
      if entry.due and entry.room == room then
         perform(key, entry)
         return
      end
   end

   if M.check.wanted and not M.check.sentAt then
      if spendEq("rites", BOTH_QUIET, M.CHECK_COST) then
         M.check.wanted = false
         M.check.sentAt = util.now()
         emunah.timers.start("rites.check", M.CHECK_GUARD, function() M.lost() end)
      end
   end
end

--- Something went to the game. A rite of ours you performed is kept up from now on: RITES
--- is read once equilibrium is back, and says how long it has.
function M.onSent(command, typed)
   if not typed or not M.enabled() then return end
   local key = tostring(command or ""):match("^perform rite of (%S+)$")
   if not (key and M.KEEP[key]) then return end
   local entry = keep(key)
   entry.attempts, entry.due = 0, false
   emunah.timers.stop(timerName(key))
   M.check.wanted = true
end

--- A Room.Info. Any other room than the one a rite was performed in ends it.
function M.onRoom(num)
   local left = {}
   for _, key in ipairs(sortedKeys()) do
      if M.kept[key].room ~= num then
         left[#left + 1] = key
         M.forget(key)
      end
   end
   if next(M.kept) == nil then M.check.wanted = false end
   if #left > 0 then
      log.info("Rites: left the room -- no longer keeping %s up.", names(left))
   end
end

--- Switch keep-up on or off. Off forgets every rite kept.
function M.set(on)
   emunah.config.set("rites.keepup", on and true or false)
   emunah.config.save()
   if not on then M.forgetAll() end
end

--- What is kept, for `emset rites`: { name, left (seconds) or nil when due, room }.
function M.list()
   local out = {}
   for _, key in ipairs(sortedKeys()) do
      local entry = M.kept[key]
      local running = emunah.timers.active(timerName(key))
      out[#out + 1] = {
         key = key, name = entry.name, room = entry.room,
         left = running and emunah.timers.remaining(timerName(key)) or nil,
      }
   end
   return out
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

do
   emunah._persist = emunah._persist or {}
   for _, id in ipairs(emunah._persist.riteTriggers or {}) do killTrigger(id) end
   local ids = {
      tempRegexTrigger([[^You reach out to sense for holy rites:$]], function() M.onHeader() end),
      tempRegexTrigger([[^Rite\s+Owner\s+Seconds left$]], function() M.onFurniture() end),
      tempRegexTrigger([[^-+$]], function() M.onFurniture() end),
      tempRegexTrigger([[^(\S+)\s+([A-Z][a-z]+)\s+(\d+)$]], function()
         M.onRow(matches[2], matches[3], matches[4])
      end),
      -- After curing/detect/patterns.lua's own trigger on this line, which arms the
      -- equilibrium timer from it: that one was created first, so it has already run.
      tempRegexTrigger([[^Equilibrium used: [\d.]+s\.$]], function() M.onCost() end),
   }
   emunah._persist.riteTriggers = ids
end

-- The prompt ends the listing (gmcp/vitals.lua raises this once per prompt).
event.register("emunah.vitals", function() M.close() end, "rites")
event.register("emunah.tick", function() M.tick() end, "rites")
event.register("emunah.sent", function(_, command, typed) M.onSent(command, typed) end, "rites")
event.register("emunah.room", function(_, num) M.onRoom(num) end, "rites")
event.register("sysDisconnectionEvent", function() M.forgetAll() end, "rites")

return M

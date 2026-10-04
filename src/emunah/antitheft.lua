--- Antitheft: keep what you carry where a thief cannot reach it, and say so when something
--- goes missing.
---
--- HOW THEFT WORKS IN ACHAEA
--- -------------------------
--- HELP THIEVERY: "Keep your gold in the bank! Turn on your curing and setup selfishness as a
--- defence." Thieves may not attack, hinder or move you, and may strip only one defence:
--- SELFISHNESS. The usual sequence (Achaea forums, "How exactly does theft work?") is hide,
--- mesmerise, force GENEROSITY, and PICKPOCKET in the gap before selfishness is back -- the
--- selfishness check happens when the pickpocket completes. Closed containers and worn items
--- take extra steps to reach. Loose gold is the usual prize.
---
--- WHAT THIS DOES (each chosen by the user, 2026-10-04)
--- ----------------------------------------------------
---   Selfishness kept up      added to defence keep-up, so a strip is answered at once
---   Generosity cured first   afflist.lua ranks it just behind the locks and paralysis
---   Loose valuables swept    anything named in `antitheft.sweep` goes back into the pack,
---                            within its 50-item limit; gold is loot.lua's job already
---   Theft alarm              an item leaving inventory or the pack with no command of ours
---                            to explain it raises the alert window
---   Selfishness-lost alarm   the defence dropping without a GENEROSITY of ours
---   Hostile-in-room watch    an enemy walking in tightens up: loose gold and swept
---                            valuables go into the pack at once
---   Loose-gold watch         gold still loose after `antitheft.goldGrace` seconds is
---                            reported and stowed again
---
--- NOT DONE, AND NOT POSSIBLE: keeping the pack CLOSED between uses. The character's packs
--- have no lid -- 08:08:02.35 `close backpack452292` -> "A canvas backpack doesn't have a lid
--- or top of any sort to be closed." (and the same for the sheepskin one). See
--- docs/game/sustenance.md.
---
--- THE ONE PACK. Only `pack.id` is ever used. The character has two other packs that must
--- never be touched (the user, 2026-10-04), so nothing here names a container by anything but
--- that setting, and nothing is put in a pack that is full.

local M = {}

local log   = emunah.log
local event = emunah.event
local util  = emunah.util

local function enabled()
   return emunah.config.get("antitheft.enabled", true) ~= false
end

M.enabled = enabled

local function pack() return emunah.loot and emunah.loot.pack() end

--- The pack's own number: Char.Items reports its contents under location "rep<number>",
--- which gmcp/items.lua keys by the bare number.
local function packKey()
   local id = pack()
   return id and id:match("(%d+)$")
end

--- How many items are in the pack, or nil while its contents have not been listed.
function M.packCount()
   local key = packKey()
   local items = emunah.gmcp.items
   if not (key and items and items.locations[key]) then return nil end
   return #items.locations[key]
end

function M.packFull()
   local count = M.packCount()
   local capacity = tonumber(emunah.config.get("pack.capacity", 50)) or 50
   return count ~= nil and count >= capacity
end

-- ---------------------------------------------------------------------------
-- Sweeping loose valuables into the pack
-- ---------------------------------------------------------------------------

--- The names to keep in the pack, lowercased. `antitheft.sweep` is a comma-separated list of
--- words from the item names ("sigil, key"), because `emset` stores what is typed. Empty by
--- default: curatives must stay loose to be eaten, so nothing is swept that was not named.
function M.sweepList()
   local raw = emunah.config.get("antitheft.sweep", "")
   local out = {}
   if type(raw) == "table" then
      for _, word in ipairs(raw) do out[#out + 1] = tostring(word):lower() end
      return out
   end
   for word in tostring(raw or ""):gmatch("[^,]+") do
      word = util.trim(word):lower()
      if word ~= "" then out[#out + 1] = word end
   end
   return out
end

local function wanted(item)
   if not item or not item.name then return false end
   local name = item.name:lower()
   -- The pack itself, and any other container, are never swept: the other two packs are
   -- not to be used, and a pack is not put inside itself.
   local items = emunah.gmcp.items
   if items and items.attrib then
      local attrib = items.attrib(item)
      if attrib and (attrib.container or attrib.worn or attrib.wielded_left
         or attrib.wielded_right) then
         return false
      end
   end
   for _, word in ipairs(M.sweepList()) do
      if name:find(word, 1, true) then return true end
   end
   return false
end

--- Items swept recently, so one that will not go in is not tried on every prompt.
M.swept = {}
M.SWEEP_RETRY = 5.0
local fullWarned = false

--- Put every named valuable that is loose in inventory into the pack.
--- @return number how many PUTs went out
function M.sweep()
   if not enabled() then return 0 end
   local items = emunah.gmcp.items
   local container = pack()
   if not (items and container and items.inventoryKnown()) then return 0 end
   if #M.sweepList() == 0 then return 0 end

   local now, sent = util.now(), 0
   for _, item in ipairs(items.at("inv")) do
      if wanted(item) and (M.swept[item.id] or 0) <= now then
         if M.packFull() then
            if not fullWarned then
               fullWarned = true
               log.warn("Antitheft: %s is full (%d items) -- %s stays loose. Make room, "
                  .. "or put a full pack inside it (it counts as one item).",
                  container, M.packCount() or 0, item.name)
            end
            return sent
         end
         -- PUT's cost is unverified, as for loot.stowGold(): nothing declared, and the
         -- retry window bounds a refusal.
         if emunah.act.send(string.format("put %s in %s", item.id, container), {}) then
            M.swept[item.id] = now + M.SWEEP_RETRY
            sent = sent + 1
         end
      end
   end
   if not M.packFull() then fullWarned = false end
   return sent
end

-- ---------------------------------------------------------------------------
-- The theft alarm
-- ---------------------------------------------------------------------------

--- Commands that move or use up an item of ours. An item leaving inventory or the pack
--- within M.EXPLAIN_WINDOW of one is accounted for; anything else is reported.
M.EXPLAINS = {
   "put", "get", "take", "give", "drop", "sell", "eat", "drink", "sip", "smoke", "apply",
   "inr", "outr", "buy", "fill", "empty", "junk", "bury", "offer", "discard", "wield",
   "unwield", "wear", "remove", "quit", "qq",
}

local EXPLAIN_SET = {}
for _, verb in ipairs(M.EXPLAINS) do EXPLAIN_SET[verb] = true end

M.EXPLAIN_WINDOW = 3.0

local function explains(command)
   return EXPLAIN_SET[command:match("^(%S+)") or ""] == true
end

local function explained()
   local outgoing = emunah.outgoing
   if not outgoing then return true end
   local at = outgoing.lastSent(explains)
   return at ~= nil and at >= util.now() - M.EXPLAIN_WINDOW
end

--- Someone else in the room, by name, for the alarm.
local function company()
   local room = emunah.gmcp.room
   local names = room and room.playerNames and room.playerNames() or {}
   return names
end

local function alarm(title, what)
   local here = company()
   local who = #here > 0 and table.concat(here, ", ") or "nobody you can see"
   log.warn("<ansi_light_red>%s<ansi_yellow> -- %s. In the room: %s.", title, what, who)
   local alert = emunah.ui and emunah.ui.alert
   if alert and alert.show then
      alert.show("antitheft", title, {
         { "What", what },
         { "Who is here", who },
         { "", "Click to close." },
      }, { duration = 30 })
   end
   event.raise("antitheft.alarm", title, what, here)
end

M.alarm = alarm

local function dead()
   local vitals = emunah.gmcp.vitals
   return vitals and vitals.maxhp > 0 and vitals.hp <= 0
end

local function onRemoved(_, location, item)
   if not enabled() or emunah.config.get("antitheft.alarm", true) == false then return end
   if not item or (location ~= "inv" and location ~= packKey()) then return end
   -- Death drops everything, and leaving puts it all in the rift: neither is a thief.
   if dead() or emunah.act.halted then return end
   if explained() then return end
   alarm("Possible theft", string.format("%s (%s) left your %s, and nothing you sent "
      .. "explains it", tostring(item.name or "an item"), tostring(item.id or "?"),
      location == "inv" and "inventory" or "pack"))
end

-- ---------------------------------------------------------------------------
-- Selfishness
-- ---------------------------------------------------------------------------

--- Add selfishness to keep-up, once. Done once rather than on every load so that
--- `emset defs` dropping it is respected; `emset antitheft on` adds it again.
function M.keepSelfish()
   local keepup = emunah.curing and emunah.curing.defkeepup
   if not keepup then return false end
   if keepup.mode("selfishness") == nil then keepup.add("selfishness") end
   emunah.config.set("antitheft.selfishAdded", true)
   emunah.config.save()
   return true
end

local function onDefenceLost(_, name)
   if name ~= "selfishness" or not enabled() then return end
   local outgoing = emunah.outgoing
   if outgoing and outgoing.sentRecently("^generosity", M.EXPLAIN_WINDOW) then return end
   if dead() or emunah.act.halted then return end
   alarm("Selfishness stripped", "your selfishness dropped and you did not type GENEROSITY "
      .. "-- the usual first step of a pickpocket")
   -- Keep-up raises it again on its own tick; this gets that tick now.
   local keepup = emunah.curing and emunah.curing.defkeepup
   if keepup and keepup.nudge then keepup.nudge() end
end

-- ---------------------------------------------------------------------------
-- Loose gold
-- ---------------------------------------------------------------------------

--- How long gold may sit loose before it is called out. A purchase holds it for
--- shop.PAY_WINDOW, and loot puts the rest away within a round trip.
M.GOLD_GRACE = 5.0

local function looseGold()
   local items, loot = emunah.gmcp.items, emunah.loot
   if not (items and loot and items.inventoryKnown()) then return nil end
   for _, item in ipairs(items.at("inv")) do
      if loot.isGold(item.name) then return item end
   end
   return nil
end

local function checkGold()
   if not enabled() then return end
   local shop = emunah.shop
   if shop and shop.paying and shop.paying() then return end
   -- Gold you took out yourself is yours to hold until loot.HOLD_TYPED runs out.
   if emunah.timers.active("loot.hold") then return end
   local gold = looseGold()
   if not gold then return end
   log.warn("Antitheft: %s has been loose for %ss -- putting it in %s.", gold.name,
      tostring(tonumber(emunah.config.get("antitheft.goldGrace", M.GOLD_GRACE))),
      tostring(pack()))
   -- Through loot's own budget AND its guard: resetting the budget here made a PUT that
   -- never works into a loop, and skipping the guard sent a second PUT alongside one loot
   -- had just sent itself.
   local loot = emunah.loot
   if loot then loot.stowGold() end
end

local function watchGold()
   if not enabled() then return end
   local grace = tonumber(emunah.config.get("antitheft.goldGrace", M.GOLD_GRACE)) or M.GOLD_GRACE
   if grace <= 0 then return end
   if looseGold() and not emunah.timers.active("antitheft.gold") then
      emunah.timers.start("antitheft.gold", grace, checkGold)
   end
end

-- ---------------------------------------------------------------------------
-- Hostiles in the room
-- ---------------------------------------------------------------------------

--- Is this person a reason to tighten up? Enemies by the name database's reckoning.
local function hostile(name)
   local namedb = emunah.namedb
   -- The declared enemies only: our city's list and anyone marked enemy by hand. isEnemy()
   -- also counts every citizen of an organisation marked hostile, which tightened up for
   -- half the people walking past ("we are being a bit too aggressive with the antitheft",
   -- the user, 2026-10-04).
   return namedb and namedb.isDeclaredEnemy and namedb.isDeclaredEnemy(name) or false
end

--- Put everything away now, rather than on the next balance.
function M.tighten(who)
   if not enabled() then return end
   log.info("Antitheft: %s is here -- putting gold and valuables away.", tostring(who))
   local loot = emunah.loot
   if loot then
      emunah.timers.stop("loot.stow")
      loot.stowGold()
   end
   M.swept = {}
   M.sweep()
end

local function onPlayerEntered(_, name)
   if hostile(name) then M.tighten(name) end
end

local function onPlayers(_, names)
   for _, name in ipairs(names or {}) do
      if hostile(name) then M.tighten(name) return end
   end
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

function M.setEnabled(value)
   emunah.config.set("antitheft.enabled", value and true or false)
   emunah.config.save()
   if value then
      M.keepSelfish()
      M.sweep()
   else
      local keepup = emunah.curing and emunah.curing.defkeepup
      if keepup and keepup.mode("selfishness") then keepup.drop("selfishness") end
   end
   log.info("Antitheft %s.",
      value and "<ansi_light_green>on<ansi_yellow>" or "<ansi_light_red>off<ansi_yellow>")
   return value
end

event.register("emunah.items.removed", onRemoved, "antitheft")
event.register("emunah.items.added", function(_, location, item)
   if location ~= "inv" then return end
   if wanted(item) then M.sweep() end
   if item and emunah.loot and emunah.loot.isGold(item.name) then watchGold() end
end, "antitheft")
event.register("emunah.items.list", function(_, location)
   if location == "inv" then M.sweep() watchGold() end
end, "antitheft")
event.register("emunah.defence.lost", onDefenceLost, "antitheft")
event.register("emunah.room.playerEntered", onPlayerEntered, "antitheft")
event.register("emunah.room.players", onPlayers, "antitheft")

-- Selfishness goes on keep-up the first time antitheft is on, and never again by itself.
if enabled() and not emunah.config.get("antitheft.selfishAdded", false) then
   M.keepSelfish()
end

return M

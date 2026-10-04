--- Hostile presences: a warning window when your angel senses an enemy nearby.
---
--- ANGEL PRESENCES lists everyone your guardian angel can sense nearby:
---
---     You bid your guardian angel to seek out life presences nearby.
---     Your guardian angel senses Thelek at Fish Street, on a health of 13144 and a mana of 3674.
---     ...
---     Equilibrium used: 2.50s.
---
--- Each scan is collected line by line and judged at the prompt that ends it. Anyone the name
--- database calls an enemy -- declared with `emset iff`, enemied to a city/house/order, or a
--- member of an organisation marked hostile with `emset hostile` -- raises the alert window.
---
--- What is read, and what is not (verbatim captures in docs/game/help/who-listings.txt):
---   * The NAME, and the room after "at". Nothing after the room is needed, and the line
---     breaks before the mana figure in play ("...and a mana of" / "7233."), so the pattern
---     stops at ", on a health" and does not require what follows.
---   * NOT the "(2098, 2097, 2171, ...) (Targossas)" tail. A Mudlet mapping script appends it,
---     not the game (the user, 2026-10-03); with every script off it is absent.
---   * Everyone sensed counts as nearby: that is what the angel reports. The room name is
---     shown, not used to filter.
---
--- One alert per arrival, not per scan. A scan run every few seconds must not pop the same
--- warning every few seconds, so the window is raised when a hostile appears who was not in
--- the last alert, updated in place while they stay, and closed when a scan finds none.
---
--- Someone sensed for the first time is not in the database yet: the web API lookup
--- capture.lua queues returns after the prompt. When it lands (`namedb.updated`) for someone
--- in the latest scan, the scan is judged again -- so a Mhaldorian you have never met still
--- raises the alert, a moment later.

local M = {}

local util  = emunah.util
local log   = emunah.log
local event = emunah.event

--- How long the window stays up without a click, in seconds. `emset presences.alertFor <n>`.
M.ALERT_FOR = 15

--- A scan older than this is no longer "nearby": a late API answer does not raise it.
M.FRESH = 120

--- The sense line. Anchored at the start. The rest of the line is taken whole and cut at
--- ", on a health" in Lua (M.sensed): the line may end before that or carry a script's tail
--- after it, and one plain capture handles every shape without an alternation.
M.PATTERN = [[^Your guardian angel senses ([A-Z][a-z]+) at (.+)$]]

--- The scan being collected, until its prompt.
local collecting = {}
local collected = 0

--- The latest complete scan: { at = seconds, people = { name -> { where, health } } }.
M.last = { at = nil, people = {} }

--- Names the open alert already warned about.
local warned = {}

function M.enabled()
   return emunah.config.get("presences.alert", false) == true
end

--- One sense line.
function M.sensed(name, where, health)
   if not name then return end
   name = util.capitalise(name)
   if collecting[name] == nil then collected = collected + 1 end
   where = tostring(where or "")
   where = where:match("^(.-), on a health") or where
   collecting[name] = { where = util.trim(where), health = tonumber(health) }
end

--- The scan is over: keep it and judge it.
function M.close()
   if collected == 0 then return end
   M.last = { at = util.now(), people = collecting }
   collecting, collected = {}, 0
   M.check()
end

--- What makes this person an enemy, for the window: their city, house or order, or "enemy".
local function why(person)
   if not person then return "enemy" end
   local ndb = emunah.namedb
   for _, kind in ipairs({ "city", "house", "order" }) do
      local org = person[kind]
      if org and org ~= "" and ndb.hostile[kind][tostring(org):lower()] then
         return util.capitalise(tostring(org))
      end
   end
   if person.iff == "enemy" then return "marked enemy" end
   return person.city and util.capitalise(tostring(person.city)) or "enemy"
end

--- Hostiles in the latest scan, sorted by name.
function M.hostiles()
   local ndb = emunah.namedb
   local out = {}
   if not ndb then return out end
   for name, seen in pairs(M.last.people) do
      if not ndb.isSelf(name) and ndb.relationship(name) == "enemy" then
         out[#out + 1] = { name = name, where = seen.where, health = seen.health,
                           org = why(ndb.get(name)) }
      end
   end
   table.sort(out, function(a, b) return a.name < b.name end)
   return out
end

--- Judge the latest scan, and raise, update or close the window.
function M.check()
   local hostiles = M.hostiles()
   if #hostiles == 0 then
      warned = {}
      if emunah.ui and emunah.ui.alert then emunah.ui.alert.close("presences") end
      return hostiles
   end
   if not M.enabled() then return hostiles end

   local arrived = {}
   local now = {}
   for _, hostile in ipairs(hostiles) do
      now[hostile.name] = true
      if not warned[hostile.name] then arrived[#arrived + 1] = hostile.name end
   end
   warned = now

   local alert = emunah.ui and emunah.ui.alert
   if #arrived > 0 then
      -- In the scrollback too: a window can be dismissed, a transcript should still say it.
      log.warn("Hostile nearby: %s.", table.concat(arrived, ", "))
      if alert then
         alert.show("presences", "Hostiles nearby", M.rows(hostiles), {
            duration = tonumber(emunah.config.get("presences.alertFor", M.ALERT_FOR)) or M.ALERT_FOR,
         })
      end
   elseif alert and alert.isOpen("presences") then
      alert.update("presences", "Hostiles nearby", M.rows(hostiles))
   end
   return hostiles
end

--- Table rows for the window: name, why they are hostile, where, health.
function M.rows(hostiles)
   local rows = {}
   for index, hostile in ipairs(hostiles) do
      rows[index] = {
         hostile.name, hostile.org, hostile.where,
         hostile.health and util.comma(hostile.health) or "",
      }
   end
   return rows
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.presenceTriggers = emunah._persist.presenceTriggers or {}
   return emunah._persist.presenceTriggers
end

for _, id in ipairs(registry()) do killTrigger(id) end
emunah._persist.presenceTriggers = {}

do
   local id = tempRegexTrigger(M.PATTERN, function()
      local line = matches[1] or ""
      M.sensed(matches[2], matches[3], line:match("on a health of (%d+)"))
   end)
   if id then table.insert(registry(), id) end
end

-- The prompt ends the scan. `emunah.vitals` runs once per prompt, whether or not a
-- Char.Vitals came with it (gmcp/vitals.lua's onPrompt).
event.register("emunah.vitals", function() M.close() end, "presences")

-- A lookup that landed for someone in the latest, still-fresh scan.
event.register("emunah.namedb.updated", function(_, name)
   if not (name and M.last.at) then return end
   if util.now() - M.last.at > M.FRESH then return end
   if M.last.people[util.capitalise(name)] then M.check() end
end, "presences")

event.register("sysDisconnectionEvent", function()
   collecting, collected, warned = {}, 0, {}
   M.last = { at = nil, people = {} }
end, "presences")

return M

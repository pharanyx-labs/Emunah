--- The shield: WIELDED at login, and a standing chyron notice whenever no shield is wielded.
---
--- WIELDED, from play (2026-10-04, 09:25:53.45):
---
---   You are wielding:
---         mace341225: a spiritual mace in your left hand.
---         kite shield680194: a kite shield in your right hand.
---
--- No balance line, and the prompt's flags were the same either side of it, so it is sent
--- like PIPELIST: with nothing but the ordinary blocks (act.blocked).
---
--- WHAT COUNTS AS WIELDED comes from Char.Items, not from that listing: any item in the
--- inventory with "shield" in its name and a wielded attribute (`l` or `L`, gmcp/items.lua).
--- Unwielding changes only the attribute, so Char.Items.Update reports it at once, where
--- WIELDED would have to be polled. While blind without mindseye that feed goes quiet
--- (items.inventoryKnown() is false), and the notice is left as it was rather than decided
--- on a stale inventory.
---
--- Notice only: nothing here wields the shield. The user asked to be told, not for it to be
--- done, and WIELD's cost with a shield has never been seen.

local M = {}

local event = emunah.event

--- The chyron notice's key, so it is replaced in place and taken down when put right.
M.NOTICE = "shield"

--- Seconds after Char.Name before WIELDED goes out: the login burst drops requests made
--- inside it (gmcp/init.lua's refresh waits the same).
M.LOGIN_DELAY = 2

local function enabled()
   return emunah.config.get("shield.watch", true) ~= false
end

local function isShield(item)
   local name = item and item.name
   if type(name) ~= "string" then return false end
   return (" " .. name:lower() .. " "):find("[^%a]shield[^%a]") ~= nil
end

--- The shields carried, wielded first. Two values: the wielded one (or nil), and the first
--- one carried at all (or nil).
function M.find()
   local items = emunah.gmcp.items
   if not items then return nil, nil end
   local carried = nil
   for _, item in ipairs(items.at("inv")) do
      if isShield(item) then
         local attrib = items.attrib(item)
         if attrib.wielded_left or attrib.wielded_right then return item, item end
         carried = carried or item
      end
   end
   return nil, carried
end

--- What the notice should say, or nil when the shield is wielded. Nil too when the
--- inventory cannot be trusted yet: say nothing rather than something stale.
function M.problem()
   local items = emunah.gmcp.items
   if not (items and items.inventoryKnown()) then return nil, true end
   local wielded, carried = M.find()
   if wielded then return nil end
   if carried then
      local name = tostring(carried.name):gsub("^an?%s+", "")
      return string.format("Your %s is not wielded", name)
   end
   return "You are carrying no shield"
end

--- Bring the chyron notice in line with the inventory.
function M.check()
   local chyron = emunah.ui and emunah.ui.chyron
   if not chyron then return end
   if not enabled() then
      chyron.dismiss(M.NOTICE)
      return
   end
   local text, unknown = M.problem()
   if unknown then return end
   if text then
      chyron.send(text, "warning", M.NOTICE)
   else
      chyron.dismiss(M.NOTICE)
   end
end

--- Show what is wielded. Ordinary blocks only; see the header.
function M.showWielded()
   return emunah.act.send("wielded", {})
end

local function onInventory(_, location)
   if location == "inv" then M.check() end
end

event.register("emunah.items.list",    onInventory, "shield")
event.register("emunah.items.added",   onInventory, "shield")
event.register("emunah.items.removed", onInventory, "shield")
event.register("emunah.items.updated", onInventory, "shield")

event.register("emunah.character.identified", function()
   emunah.timers.start("shield.login", M.LOGIN_DELAY, function() M.showWielded() end)
end, "shield")

M.check()

return M

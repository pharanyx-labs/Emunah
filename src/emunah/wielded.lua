--- What is wielded: WIELDED at login, and the mace named on the prompt whenever it is not
--- in hand.
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
--- THE MACE ON THE PROMPT. "I need to be alerted on my prompt anytime i am not wielding my
--- mace" (the user, 2026-10-23), after angel panic's fear dropped it mid-spar. Wielded is
--- keep-up's own answer (deflist.SYNTHETIC.trackmace): Char.Items while it can be seen, the
--- game's wield line while blind. Only for a character with the Mace ability.
---
--- KEPT IN HAND AT ALL TIMES. "We need to be rewielding that mace at all times" (the user,
--- 2026-10-23). The free raises -- GET it off the ground, WIELD it -- go from here on every
--- prompt and every change to what is carried, whether or not defence keep-up is on, and
--- through keep-up's own sender so the two never send the same command twice. CALL and
--- SUMMON spend a balance and stay keep-up's, which never gives up on the mace
--- (defkeepup.UNLIMITED). `mace.keep` switches this off.
---
--- NO SHIELD NOTICE. A chyron notice stood while no shield was wielded; the user asked for it
--- gone, "don't alert this at all" (2026-10-23).

local M = {}

local event = emunah.event

--- Seconds after Char.Name before WIELDED goes out: the login burst drops requests made
--- inside it (gmcp/init.lua's refresh waits the same).
M.LOGIN_DELAY = 2

local function enabled()
   return emunah.config.get("mace.warn", true) ~= false
end

--- What the prompt should say about the mace, or nil when it is wielded (or there is none
--- to have).
function M.maceWarning()
   if not enabled() then return nil end
   local have = emunah.have
   if not (have and have.skill and have.skill("mace")) then return nil end
   local items = emunah.gmcp.items
   if not (items and items.inventoryListed) then return nil end
   local deflist = emunah.curing.deflist
   if deflist.SYNTHETIC.trackmace() then return nil end
   if items.sighted() and deflist.maceOnGround() then return "mace on the ground" end
   return "mace not wielded"
end

local function keeping()
   return emunah.config.get("mace.keep", true) ~= false
end

--- Send the mace's free raise when it is not in hand: GET it, or WIELD it. True when sent.
function M.keep()
   if not keeping() then return false end
   local have = emunah.have
   if not (have and have.skill and have.skill("mace")) then return false end
   local items = emunah.gmcp.items
   if not (items and items.inventoryListed) then return false end
   local deflist, defkeepup = emunah.curing.deflist, emunah.curing.defkeepup
   if not (deflist and defkeepup) or deflist.SYNTHETIC.trackmace() then return false end
   local vector, command, needs = deflist.resolve("trackmace")
   if vector ~= "free" or not command then return false end
   return defkeepup.sendCostless("trackmace", vector, command, needs)
end

--- Show what is wielded. Ordinary blocks only; see the header.
function M.showWielded()
   return emunah.act.send("wielded", {})
end

event.register("emunah.promptTag", function()
   local text = M.maceWarning()
   if not text then return end
   local theme = emunah.ui and emunah.ui.theme
   if theme and type(decho) == "function" then
      decho(" " .. theme.dc("textDim") .. "(" .. theme.dc("danger") .. text
         .. theme.dc("textDim") .. ")")
   end
end, "wielded")

event.register("emunah.prompt", function() M.keep() end, "wielded-keep")
for _, name in ipairs({ "emunah.items.added", "emunah.items.removed", "emunah.items.updated" }) do
   event.register(name, function(_, location)
      if location == "inv" or location == "room" then M.keep() end
   end, "wielded-keep")
end

event.register("emunah.character.identified", function()
   emunah.timers.start("wielded.login", M.LOGIN_DELAY, function() M.showWielded() end)
end, "wielded")

-- The notice an earlier version kept up, taken down if a reload finds it showing.
local chyron = emunah.ui and emunah.ui.chyron
if chyron and chyron.dismiss then chyron.dismiss("shield") end

return M

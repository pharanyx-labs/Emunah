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
local afflist = emunah.curing.afflist

--- Priority floor. Everything curing does uses ranks well below this, so keep-up can only
--- claim a vector no cure wanted this tick.
M.PRIORITY = 900

M.enabled = false

--- Defences we know how to raise but that are not in afflist.defenceCures -- these are
--- plain commands rather than item cures. Extend via `emunah def add <name> <command>`.
M.commands = {
   -- name        = { vector, command }
   insomnia     = { vector = "herb",        command = "eat cohosh" },
   deathsight   = { vector = "herb",        command = "eat skullcap" },
   thirdeye     = { vector = "herb",        command = "eat echinacea" },
   rebounding   = { vector = "smoke",       command = "smoke skullcap" },
   speed        = { vector = "elixir",      command = "drink speed" },
   levitation   = { vector = "elixir",      command = "drink levitation" },
   frost        = { vector = "elixir",      command = "drink frost" },
   venom        = { vector = "elixir",      command = "drink venom" },
   immunity     = { vector = "elixir",      command = "drink immunity" },
   -- Equilibrium-cost defences. Skills, not items, so they are gated on have.skill().
   cloak        = { vector = "equilibrium", command = "cloak",        skill = "cloak" },
   shield       = { vector = "balance",     command = "touch shield", skill = "shield" },
   nightsight   = { vector = "equilibrium", command = "nightsight",   skill = "nightsight" },
   mindseye     = { vector = "equilibrium", command = "mindseye",     skill = "mindseye" },
   deaf         = { vector = "equilibrium", command = "deaf",         skill = "deaf" },
   blind        = { vector = "equilibrium", command = "blind",        skill = "blind" },
   fangbarrier  = { vector = "balance",     command = "fangbarrier",  skill = "fangbarrier" },
}

--- The list of defences to maintain. Persisted in config so it survives reloads.
function M.wanted()
   return emunah.config.get("defences.keepup", {}) or {}
end

function M.add(name)
   name = tostring(name or ""):lower()
   if name == "" then return false end
   local list = M.wanted()
   if util.contains(list, name) then return false end
   table.insert(list, name)
   emunah.config.set("defences.keepup", list)
   emunah.config.save()
   log.info("Keeping up <ansi_cyan>%s<ansi_yellow>.", name)
   return true
end

function M.drop(name)
   name = tostring(name or ""):lower()
   local list = M.wanted()
   for index, entry in ipairs(list) do
      if entry == name then
         table.remove(list, index)
         emunah.config.set("defences.keepup", list)
         emunah.config.save()
         log.info("No longer keeping up <ansi_cyan>%s<ansi_yellow>.", name)
         return true
      end
   end
   return false
end

--- Resolve how to raise a defence.
--- @return string|nil vector, string|nil command
local function resolveDefence(name)
   -- Item-based defences share the cure machinery.
   local cure = afflist.defenceCures[name]
   if cure then
      local command = emunah.curing.curelist.command(cure)
      return cure.vector, command
   end

   local entry = M.commands[name]
   if not entry then return nil, nil end
   if entry.skill and not have.skill(entry.skill) then return nil, nil end
   return entry.vector, entry.command
end

--- Which wanted defences are currently missing.
function M.missing()
   local defences = emunah.gmcp.defences
   if not defences then return {} end
   return defences.missingFrom(M.wanted())
end

--- One pass. Queues at most one defence per vector, at a priority no cure will lose to.
function M.tick()
   if not M.enabled then return end

   -- Do not fight the curing engine for a balance while afflicted; cures come first, and
   -- a defence raised mid-lock is usually stripped again immediately.
   local engine = emunah.curing.engine
   if engine and engine.enabled and engine.count() > 0 then return end

   for _, name in ipairs(M.missing()) do
      local vector, command = resolveDefence(name)
      if vector and command then
         queue.push(vector, command, {
            priority = M.PRIORITY,
            tag      = "def:" .. name,
            confirm  = emunah.config.get("curing.confirmWait", 2.0),
            onSent   = function()
               if vector ~= "balance" and vector ~= "equilibrium" then
                  have.spend(vector)
               end
            end,
         })
      end
   end

   queue.flush()
end

function M.start()
   M.enabled = true
   emunah.config.set("defences.enabled", true)
   log.info("Defence keep-up <ansi_light_green>on<ansi_yellow>.")
end

function M.stop()
   M.enabled = false
   emunah.config.set("defences.enabled", false)
   log.info("Defence keep-up <ansi_light_red>off<ansi_yellow>.")
end

function M.toggle()
   if M.enabled then M.stop() else M.start() end
   return M.enabled
end

event.register("emunah.tick", function()
   M.tick()
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

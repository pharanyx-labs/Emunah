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

--- Start maintaining a defence.
---
--- An explicit command can be supplied for anything this file does not already know how to
--- raise -- `emunah defs add moss touch moss`. That matters for tattoos in particular: the
--- name Char.Defences reports is not something to guess at, because a wrong one means the
--- defence silently never goes up, and the command that raises it costs a full balance
--- whether or not it was needed. Read the real name from `emunah gmcp` and pair it here.
--- @param name string the name as Char.Defences reports it
--- @param command string|nil what raises it; omit for a defence already in M.commands
--- @param vector string|nil which balance that command spends; defaults to balance
function M.add(name, command, vector)
   name = tostring(name or ""):lower()
   if name == "" then return false end

   if command and command ~= "" then
      local custom = emunah.config.get("defences.commands", {}) or {}
      custom[name] = { command = command, vector = vector or "balance" }
      emunah.config.set("defences.commands", custom)
   end

   local list = M.wanted()
   if not util.contains(list, name) then
      table.insert(list, name)
      emunah.config.set("defences.keepup", list)
   end
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
   -- A command supplied through `emunah defs add <name> <command>` wins: it is the only
   -- source that came from someone looking at the real defence name.
   local custom = (emunah.config.get("defences.commands", {}) or {})[name]
   if custom and custom.command then
      return custom.vector or "balance", custom.command
   end

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

-- ---------------------------------------------------------------------------
-- The attempt budget
-- ---------------------------------------------------------------------------
--
-- Raising a defence is not free and, for the ones that matter most, is not cheap: touching
-- a tattoo costs a full balance -- around four seconds -- and costs it whether or not the
-- attempt achieves anything. So a defence that never appears in Char.Defences after being
-- raised must not be retried forever. That happens for ordinary reasons: the configured
-- name does not match what the game reports, the ability is not trained, or the command is
-- refused for a reason nothing here models.
--
-- Retrying blind in that state does not fix it and does spend every balance the character
-- has, which in a fight is the character. The budget stops after a few attempts and says
-- what it stopped on. It resets the moment the defence actually appears, so a defence
-- stripped repeatedly in real combat is raised every time.

M.ATTEMPTS = 3

local attempts, warned = {}, {}

--- Has this defence any attempts left?
function M.withinBudget(name)
   if (attempts[name] or 0) < M.ATTEMPTS then return true end
   if not warned[name] then
      warned[name] = true
      log.warn("Raised %s %d times and it never appeared in Char.Defences -- stopping. "
         .. "Check the name matches what `emunah gmcp` reports.", name, attempts[name])
   end
   return false
end

--- Forget the attempt history, for one defence or all of them.
function M.resetBudget(name)
   if name then
      attempts[name], warned[name] = nil, nil
   else
      attempts, warned = {}, {}
   end
end

-- A defence appearing is proof the command works, whatever it took to get there.
event.register("emunah.defence.added", function(_, name)
   M.resetBudget(tostring(name or ""):lower())
end, "curing.defkeepup")

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
      if vector and command and M.withinBudget(name) then
         queue.push(vector, command, {
            priority = M.PRIORITY,
            tag      = "def:" .. name,
            -- The defence may come back on its own while this waits for a balance, and
            -- raising one that is already up costs the balance for nothing -- a full four
            -- seconds for a tattoo.
            valid    = function()
               local defences = emunah.gmcp.defences
               return not (defences and defences.has(name))
            end,
            confirm  = emunah.config.get("curing.confirmWait", 2.0),
            onSent   = function()
               attempts[name] = (attempts[name] or 0) + 1
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

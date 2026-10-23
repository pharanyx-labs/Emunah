--- METABOLISE: resist a second player's rapid delivery of one affliction.
---
--- AB METABOLISE (docs/game/help/abilities-2026-10-15.txt, and Saemora's AB AVOIDANCE on
--- 2026-10-22, by which the lesson is known). Syntax `METABOLISE <affliction>`. Cooldown
--- 3.00 seconds of equilibrium. The help gives no duration, so this treats the focus the
--- way AVOID's is treated: it lasts until another METABOLISE replaces it.
---
--- What it does. The first delivery lands. A different player delivering that same
--- affliction inside about two seconds is resisted. The same player reapplying it still
--- lands both times. It only works against players.
---
--- What can be named. "If the tree tattoo cannot cure it and it is not cured by eating or
--- smoking, it cannot be metabolised." No entry in afflist names the tree as a cure: that
--- mapping has never been verified (engine.lua, on the tattoo). An affliction cured by
--- eating or smoking is eligible either way, and that is the whole set used here.
---
--- What is focused. Impatience. The ability's own example is METABOLISE IMPATIENCE, and
--- the lock lesson names it as the two-second hope (situations.lua,
--- impatience-before-hard-lock): with asthma, slickness and impatience up, getting rid of
--- the impatience is what keeps focus open for the anorexia that comes next. Changing the
--- focus costs another 3s of equilibrium, which is longer than the window, so chasing
--- whichever affliction just landed would miss the delivery it was meant to stop. It is
--- set once, ahead of that window, and left.
---
--- When it is sent. During PvP, because it does nothing against denizens. Once, on the
--- first free equilibrium, unless perform hands or DIAG already wants that equilibrium.
--- After that, only while a lock is holding the attack (the equilibrium is idle) and the
--- focus is something else, which is what a METABOLISE typed by hand gets replaced by.
--- `curing.metabolise` off stops it. The game's focus is left where it is.

local M = {}

local log     = emunah.log
local event   = emunah.event
local queue   = emunah.queue
local have    = emunah.have
local util    = emunah.util
local afflist = emunah.curing.afflist

--- Seconds of equilibrium the ability costs. AB METABOLISE: "3.00 seconds of equilibrium".
M.EQUILIBRIUM = 3.0

--- The affliction the focus is kept on. See the header.
M.ON = "impatience"

--- Behind perform hands and DIAG, both priority 0 on this same vector.
M.PRIORITY = 40

--- Eating or smoking, as the ability text names them. Herb and moss are both eaten.
--- Smoke is smoking. Salve, focus, sip and the tree are not this clause.
local EATEN_OR_SMOKED = { herb = true, moss = true, smoke = true }

local function canonical(name)
   name = tostring(name or ""):lower()
   return afflist.ALIASES[name] or name
end

--- True when eating or smoking cures it, which is the half of the ability's rule that
--- afflist can answer. The tree half is not guessed at.
function M.eligible(name)
   name = canonical(name)
   if name == "" or not afflist.get(name) then return false end
   for _, vector in ipairs(afflist.vectorsFor(name)) do
      if EATEN_OR_SMOKED[vector] then return true end
   end
   return false
end

--- The focus this state calls for, or nil when nothing eligible is worth naming.
function M.choose()
   if M.eligible(M.ON) then return M.ON end
   return nil
end

--- What we last set, here or by a METABOLISE you typed. Kept across a reload: the game's
--- focus does not reset because the client did, and sending it again would spend another
--- 3s of equilibrium on a focus that is already up.
M.focus = nil

local function save()
   emunah._persist = emunah._persist or {}
   emunah._persist.metabolise = { focus = M.focus }
end

do
   local saved = emunah._persist and emunah._persist.metabolise
   if type(saved) == "table" and type(saved.focus) == "string" and saved.focus ~= "" then
      M.focus = saved.focus
   end
end

--- A lock is holding the attack, so this equilibrium is not about to be an offence.
local function attackHeld()
   local watch = emunah.watch
   if not (watch and watch.locks) then return false end
   local locks = watch.locks()
   return type(locks) == "table" and #locks > 0
end

--- Whether this tick may spend the equilibrium. Never ahead of the attack: its 3s held the
--- first smite at 17:31:20 on 2026-10-23 (a smite needs equilibrium present), and the
--- user's verdict on that fight was "way too slow". So the first setting goes while PvP
--- holds in defence (`t <name>` arms there, before F1) or a lock already holds the attack,
--- and a later change only under a lock.
local function maySpend()
   local pvp = emunah.pvp
   if not (pvp and pvp.enabled) then return false end
   if M.focus == nil and pvp.mode and pvp.mode() == "defence" then return true end
   return attackHeld()
end

--- Queue the focus, if this tick should spend equilibrium on it.
function M.queue()
   if emunah.config.get("curing.metabolise", true) == false then return end
   if not have.skill("metabolise") then return end
   local name = M.choose()
   if not name or name == M.focus then return end
   if not maySpend() then return end
   if queue.pending("equilibrium") or queue.awaiting("equilibrium") then return end
   if not have.balance("equilibrium") then return end

   queue.push("equilibrium", "metabolise " .. name, {
      priority = M.PRIORITY,
      tag      = "metabolise:" .. name,
      -- BALANCE TOO, though AB METABOLISE names only equilibrium: `smite erishka head
      -- chasten asthma|metabolise impatience` came back "You must regain balance first."
      -- (2026-10-23 09:58:24.89). Needing it keeps the smite from going in front.
      needs    = { bal = true, eq = true },
      spends   = "eq",
      -- The cost is 3s. A 2s confirm window would lapse while the ability was still
      -- running and re-arm the vector under it, the same reason perform hands waits
      -- out its own cost plus a second.
      confirm  = M.EQUILIBRIUM + 1,
      valid    = function()
         if emunah.config.get("curing.metabolise", true) == false then return false end
         if not have.skill("metabolise") then return false end
         if not (emunah.pvp and emunah.pvp.enabled) then return false end
         if M.focus == name then return false end
         return M.choose() == name
      end,
      onSent   = function()
         M.sent = { name = name, at = util.now() }
         emunah.gmcp.vitals.spend("eq")
         emunah.timers.start("cure.equilibrium", M.EQUILIBRIUM)
      end,
   })
end

--- The METABOLISE of ours waiting on the game: { name, at }. The focus is what the game
--- took, not what was sent. The refused one at 09:58:24.89 was announced and recorded as
--- set, so nothing would have sent it again.
M.sent = nil

--- How long after the send its "Equilibrium used:" line still counts as its answer.
M.ANSWER = 2.0

-- "Equilibrium used: 3.00s." is the ability going through. A refusal prints no such line,
-- and leaves the focus unset for the next free equilibrium to try again.
-- Its own generation of triggers, killed on a reload: Mudlet keeps a temp trigger alive
-- past the Lua state that made it.
emunah._persist = emunah._persist or {}
for _, old in ipairs(emunah._persist.metaboliseTriggers or {}) do killTrigger(old) end
emunah._persist.metaboliseTriggers = {}
do
   local id = tempRegexTrigger([[^Equilibrium used: ]], function()
      local pending = M.sent
      if not pending then return end
      M.sent = nil
      if util.now() - pending.at > M.ANSWER then return end
      M.focus = pending.name
      save()
      log.info("Metabolising %s. A second player's rapid reapplication is resisted.",
         pending.name)
   end)
   if id then table.insert(emunah._persist.metaboliseTriggers, id) end
end

--- A METABOLISE you typed is the focus from here. An ineligible name is not recorded:
--- the game will refuse it, and the next free equilibrium sets the one curing wants.
event.register("emunah.sent", function(_, command, typed)
   if not typed then return end
   local raw = tostring(command or ""):lower():match("^metabolise%s+(%a[%w_]*)")
   if not raw then return end
   local name = canonical(raw)
   if not M.eligible(name) then return end
   M.focus = name
   save()
end, "curing.metabolise")

return M

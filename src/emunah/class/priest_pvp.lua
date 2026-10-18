--- Priest PvP: the moves, and the modes that order them.
---
--- Loaded by class/priest.lua, which passes itself in; pvp.lua drives it through
--- priest.pvpPlan() and priest.pvpSend(). Hunting never reaches this file -- "I can't
--- afflict a monster that I meet in hunt mode, at all. However, I need to overwhelm my pvp
--- opponent with a range of afflictions, damage, and finisher moves" (the user, 2026-10-15).
---
--- THREE LANES, one per balance, each choosing independently every tick it is free:
---
---   prayer       verses (Zeal), 1.60-3.00s of prayer balance, optionally ending in a rebuke
---   balance      the mace: smite or smash, each carrying a chasten
---   equilibrium  Devotion and the angel: afflictions, heresy, contemplate, sap, absolve
---
--- A MODE is an ordered list of moves per lane: the first move whose conditions hold goes.
--- F5-F8 pick the mode (pvp.lua). Adding a mode is adding a table to M.MODES; adding a move
--- is adding one to M.MOVES. Every command here has its syntax and cost from HELP or the
--- GMCP ability text (docs/game/help/), and every move checks have.skill() at the moment it
--- is chosen, because what is trained changes.
---
--- WHAT THE TARGET HAS is confirmed only (the user's ruling): landing lines, symptom lines and
--- cure lines through curing/detect/opponent.lua, mana through contemplate. A verse never says
--- it landed, so a move whose affliction is not confirmed is not known to be on them; the
--- rotation below stops the planner sending the same one into an unknown every time.

return function(P)
   local M = {}

   local have   = emunah.have
   local timers = emunah.timers
   local util   = emunah.util

   -- -----------------------------------------------------------------------------------
   -- lanes
   -- -----------------------------------------------------------------------------------

   -- Both balances for anything that is not a verse: smite needs equilibrium as well as the
   -- balance it spends (docs/game/priest-abilities.md), Anzerloi's angel sap "requires
   -- balance" too, and HELP's default for the rest is both, until play shows otherwise.
   local BOTH = { bal = true, eq = true, standing = true }

   M.LANES = {
      prayer = {
         ready = function()
            return timers.ready("pvp.prayer") and emunah.act.can({ standing = true })
         end,
      },
      balance = {
         ready = function()
            local vitals = emunah.gmcp.vitals
            return vitals and vitals.bal and timers.ready("attack.balance")
               and emunah.act.can(BOTH)
         end,
      },
      equilibrium = {
         ready = function()
            local vitals = emunah.gmcp.vitals
            return vitals and vitals.eq and timers.ready("cure.equilibrium")
               and emunah.act.can(BOTH)
         end,
      },
   }

   -- -----------------------------------------------------------------------------------
   -- choosing what to give
   -- -----------------------------------------------------------------------------------

   --- A move or affliction sent this recently is passed over while something else is open.
   --- Not a game fact -- a rotation, because nothing confirms a verse landed. Moves marked
   --- `again` (sear, contemplate, sap, absolve, heresy) are meant to repeat and skip it.
   M.RECENT = 6.0
   M.sentAt = {}

   local function recent(key)
      local at = M.sentAt[key]
      return at ~= nil and util.now() - at < M.RECENT
   end

   --- The chasten affliction to carry: the first in `order` not confirmed on the target and
   --- not chastened a moment ago. HELP CHASTEN's pools: paralysis, healthleech, clumsiness,
   --- nausea, asthma (body); epilepsy, dizziness, confusion, recklessness (mind).
   --- Every affliction chasten can carry (HELP CHASTEN's two pools).
   local CHASTEN_POOL = {}
   for _, aff in ipairs({ "paralysis", "healthleech", "clumsiness", "nausea", "asthma",
                          "epilepsy", "dizziness", "confusion", "recklessness" }) do
      CHASTEN_POOL[aff] = true
   end

   local function chastenPick(ctx, order)
      -- WHAT CLOSES A LOCK GOES FIRST, in any mode. Asthma and paralysis are both in its
      -- pools and both in the lock (opponent.lockNeeds): asthma keeps the pipe shut on the
      -- slickness, paralysis keeps the tree shut on everything. With a partner giving the
      -- rest -- a Bard's sunrise gives asthma and prone, his jab anorexia -- this is the piece
      -- that is still missing (Anzerloi, 2026-10-15 20:26:06, docs/game/pvp-locks.md).
      for _, aff in ipairs(ctx.lockNeeds or {}) do
         if CHASTEN_POOL[aff] and not ctx.afflictions[aff] and not recent("chasten:" .. aff) then
            return aff
         end
      end
      local fallback
      for _, aff in ipairs(order) do
         if not ctx.afflictions[aff] then
            fallback = fallback or aff
            if not recent("chasten:" .. aff) then return aff end
         end
      end
      return fallback or order[1]
   end

   --- Per mode: the order chasten picks from. Kelp first in offence (asthma, clumsiness,
   --- healthleech are all kelp, and asthma shuts their pipes), lobelia's recklessness
   --- between -- the two momentum routes (Anzerloi, 12:50:44-12:52:15).
   M.CHASTEN = {
      attack  = { "asthma", "clumsiness", "recklessness", "healthleech", "paralysis" },
      offence = { "asthma", "recklessness", "clumsiness", "healthleech", "paralysis",
                  "confusion", "epilepsy", "dizziness", "nausea" },
      hinder  = { "paralysis", "asthma", "clumsiness", "epilepsy", "dizziness" },
      finish  = { "asthma", "recklessness", "clumsiness", "confusion", "paralysis" },
   }

   --- Rebukes a mode ends a prayer with, best first. A rebuke counts the verse it rides on
   --- (P.prayerAllows) and ends the prayer. Heresy gives inquisition only on a target with
   --- both guilt and spiritburn; nothing confirms those, so it is tried when the prayer is
   --- long enough, as Anzerloi's route has it.
   M.REBUKES = {
      offence = { "heresy", "evil", "chaos" },
      hinder  = { "darkness" },
   }

   -- -----------------------------------------------------------------------------------
   -- the moves
   -- -----------------------------------------------------------------------------------

   --- How fresh a contemplate reading must be to act on. Mana drains as they act, and
   --- Anzerloi's advice is to contemplate "as close to the next attack as possible". A
   --- tuning number, not a game fact.
   M.FRESH = 4.0

   local function freshMana(ctx)
      local reading = ctx.mana
      return reading ~= nil and not reading.stale and util.now() - reading.at <= M.FRESH
   end

   local function mace(ctx)
      -- Heresy burns rebounding away (HELP HERESY); without it a mace blow into rebounding
      -- comes back on you (13.9% and 404 health, 2026-10-15 13:58:03).
      return ctx.heresy or not ctx.rebounding
   end

   local function verse(name, gives, extra)
      local move = { lane = "prayer", skill = name, gives = gives, verse = name,
         command = function(ctx) return "recite " .. name .. " " .. ctx.target end }
      for key, value in pairs(extra or {}) do move[key] = value end
      return move
   end

   M.MOVES = {
      -- prayer (HELP: 1.60s unless noted; VERSES for the limited ones)
      guilt        = verse("guilt", "guilt"),
      ash          = verse("ash", "spiritburn"),
      burn         = verse("burn", "tenderskin"),
      penance      = verse("penance", "paralysis"),
      condemnation = verse("condemnation", "justice"),
      purge        = verse("purge", "ablaze"),
      revelations  = verse("revelations", "hellsight"),
      wrath        = verse("wrath", nil, { cost = 3.00 }),
      fragility    = verse("fragility", nil),
      -- Conveys heresy when you are not hunting heretics (HELP UNFLINCHING).
      unflinching  = verse("unflinching", nil, { when = function(ctx) return not ctx.heresy end }),

      -- balance: the mace, always carrying a chasten
      smite = { lane = "balance", skill = "mace", when = mace,
         command = function(ctx)
            local aff = chastenPick(ctx, M.CHASTEN[ctx.mode] or M.CHASTEN.offence)
            -- `head` is the only limb word the smite has been seen to take (13:58:03).
            return ("smite %s head chasten %s"):format(ctx.target, aff), "chasten:" .. aff
         end },
      smashlegs = { lane = "balance", skill = "smash", when = mace,
         command = function(ctx)
            local aff = chastenPick(ctx, M.CHASTEN[ctx.mode] or M.CHASTEN.offence)
            return ("smash legs %s chasten %s"):format(ctx.target, aff), "chasten:" .. aff
         end },

      -- equilibrium
      heresy = { lane = "equilibrium", skill = "heresy", again = true,
         when = function(ctx) return not ctx.heresy end,
         command = function() return "hunt heresy" end },
      sloth = { lane = "equilibrium", skill = "sloth", gives = "weakness",
         command = function(ctx) return "perform sloth " .. ctx.target end },
      visions = { lane = "equilibrium", skill = "visions", gives = "dementia",
         command = function(ctx) return "perform visions " .. ctx.target end },
      dazzle = { lane = "equilibrium", skill = "dazzle", gives = "stupidity",
         command = function(ctx) return "perform dazzle " .. ctx.target end },
      panic = { lane = "equilibrium", skill = "panic", gives = "fear",
         command = function(ctx) return "angel panic " .. ctx.target end },
      sear = { lane = "equilibrium", skill = "sear", again = true,
         command = function(ctx)
            return emunah.config.get("pvp.attack", "angel sear") .. " " .. ctx.target
         end },
      contemplate = { lane = "equilibrium", skill = "contemplate", again = true,
         when = function(ctx) return not freshMana(ctx) end,
         command = function(ctx) return "contemplate " .. ctx.target end },
      sap = { lane = "equilibrium", skill = "sap", again = true,
         when = function(ctx) return freshMana(ctx) and not P.absolveKills(ctx.mana.percent) end,
         command = function(ctx) return "angel sap " .. ctx.target end },
      absolve = { lane = "equilibrium", skill = "absolve", again = true,
         when = function(ctx) return freshMana(ctx) and P.absolveKills(ctx.mana.percent) end,
         command = function(ctx) return "angel absolve " .. ctx.target end },
   }

   -- -----------------------------------------------------------------------------------
   -- the modes (F5-F8)
   -- -----------------------------------------------------------------------------------

   M.MODES = {
      -- F5: damage first, afflictions on the side.
      attack = {
         prayer      = { "purge", "unflinching", "guilt", "ash" },
         balance     = { "smite" },
         equilibrium = { "heresy", "sear" },
      },
      -- F6: bury them in afflictions, on the lobelia and kelp routes, building to the sap.
      offence = {
         prayer      = { "guilt", "ash", "burn", "penance", "revelations", "purge" },
         balance     = { "smite" },
         equilibrium = { "sloth", "visions", "dazzle", "panic" },
      },
      -- F7: keep them here and slow -- legs, paralysis, fragility on the next blow.
      hinder = {
         prayer      = { "penance", "fragility", "guilt" },
         balance     = { "smashlegs", "smite" },
         equilibrium = { "sloth", "panic" },
      },
      -- F8: read their mana, sap it under half, absolve.
      finish = {
         prayer      = { "wrath", "guilt", "ash" },
         balance     = { "smite" },
         equilibrium = { "absolve", "contemplate", "sap" },
      },
   }

   -- A heresy defence is wanted by every mode the moment a mace blow would rebound.
   for _, mode in pairs(M.MODES) do
      if mode.equilibrium[1] ~= "heresy" then
         table.insert(mode.equilibrium, 1, "heresyIfRebounding")
      end
   end
   M.MOVES.heresyIfRebounding = { lane = "equilibrium", skill = "heresy", again = true,
      when = function(ctx) return ctx.rebounding and not ctx.heresy end,
      command = function() return "hunt heresy" end }

   -- -----------------------------------------------------------------------------------
   -- planning and sending
   -- -----------------------------------------------------------------------------------

   local function allowed(name, move, ctx)
      if move.skill and not have.skill(move.skill) then return false end
      if move.verse then
         if P.ONCE_PER_PRAYER[move.verse] and P.prayerSpent[move.verse] then return false end
         if not P.prayerAllows(move.verse) then return false end
      end
      if move.gives and ctx.afflictions[move.gives] then return false end
      if move.when and not move.when(ctx) then return false end
      return true
   end

   --- The move this lane should send now, under this mode, or nil.
   function M.plan(modeName, lane, ctx)
      local mode = M.MODES[modeName]
      local spec = M.LANES[lane]
      if not (mode and spec and mode[lane]) then return nil end
      if not spec.ready() then return nil end
      local fallback
      for _, name in ipairs(mode[lane]) do
         local move = M.MOVES[name]
         if move and allowed(name, move, ctx) then
            if not recent(name) or move.again then return move, name end
            fallback = fallback or { move, name }
         end
      end
      if fallback then return fallback[1], fallback[2] end
      return nil
   end

   --- The rebuke a verse should carry, or nil.
   local function rebukeFor(ctx)
      for _, sin in ipairs(M.REBUKES[ctx.mode] or {}) do
         if have.skill("rebuke") and P.prayerAllows(sin) then return sin end
      end
      return nil
   end

   --- Send a planned move. True when it went.
   function M.send(move, name, ctx)
      local command, tag = move.command(ctx)
      if move.verse then
         local sin = rebukeFor(ctx)
         if sin then command = command .. " rebuke " .. sin end
      end
      local needs = move.lane == "prayer" and { standing = true } or BOTH
      if not emunah.act.send(command, needs) then return false end

      local now = util.now()
      M.sentAt[name] = now
      if tag then M.sentAt[tag] = now end
      -- The pessimistic guard until the game's own line replaces it ("You may speak another
      -- holy verse." / "Balance used:" / "Equilibrium used:"), as every attack here does.
      --
      -- ARMED AFTER THE OTHER LANES HAVE SENT. Prayer, the mace and an equilibrium move go
      -- out on one prompt (the user, 2026-10-15). Arming balance as the smite leaves would
      -- hold the equilibrium move of that same prompt, which spends the other resource.
      local function arm()
         if move.lane == "prayer" then
            timers.start("pvp.prayer", move.cost or P.RECITE_BALANCE_GUESS)
            if P.ONCE_PER_PRAYER[move.verse] then P.prayerSpent[move.verse] = true end
         elseif move.lane == "balance" then
            timers.start("attack.balance", P.inflightGuard())
         else
            timers.start("cure.equilibrium", P.inflightGuard())
         end
      end
      if M.deferring then M.deferred[#M.deferred + 1] = arm else arm() end
      return true
   end

   M.deferred = {}
   M.deferring = false

   --- Hold the lane guards until every lane of this prompt has been offered a send.
   function M.defer(on)
      M.deferring = on and true or false
      if on then M.deferred = {} end
   end

   function M.armDeferred()
      local pending = M.deferred
      M.deferred = {}
      M.deferring = false
      for index = 1, #pending do pending[index]() end
   end

   -- A new fight, or a new target, starts the rotation afresh: what was sent at the last
   -- one says nothing about this one.
   emunah.event.kill("priest-pvp")
   for _, name in ipairs({ "emunah.pvp.started", "emunah.pvp.target" }) do
      emunah.event.register(name, function() M.sentAt = {} end, "priest-pvp")
   end

   P.pvp = M
   P.pvpPlan = M.plan
   P.pvpSend = M.send
   P.pvpDefer = M.defer
   P.pvpArm = M.armDeferred
   P.PVP_MODES = M.MODES
end

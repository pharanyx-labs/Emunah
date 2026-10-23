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
--- F1-F4 pick the mode (pvp.lua): attack, defence, hinder, finish. Offence has no key.
--- Adding a mode is adding a table to M.MODES; adding a move
--- is adding one to M.MOVES. Every command here has its syntax and cost from HELP or the
--- GMCP ability text (docs/game/help/), and every move checks have.skill() at the moment it
--- is chosen, because what is trained changes.
---
--- OFFENCE IS ANZERLOI'S ROUTE, from three spars of his against Maelgor (2026-10-13,
--- docs/game/pvp-locks.md). Its prayer lane follows his prayers verse by verse (M.PRAYERS),
--- its mace spreads blows across the legs, and each exchange is a verse plus either the
--- mace or one equilibrium move, never both: "Recite/bal/option eq" (13:48, 2026-10-15),
--- and so in every exchange of the three spars. Every attacking mode exchanges the same
--- way, for the reason in M.plan; the verse needs both balances and goes first.
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

   -- Both balances for everything, verses included: smite needs equilibrium as well as the
   -- balance it spends (docs/game/priest-abilities.md), Anzerloi's angel sap "requires
   -- balance" too, and HELP's default for the rest is both, until play shows otherwise.
   --
   -- A VERSE NEEDS BOTH AND SPENDS NEITHER. The spar with Erishka, 2026-10-23 09:58: every
   -- recite sent with balance or equilibrium down came back "You must regain balance first."
   -- or "...equilibrium first." (25.24, 26.24, 30.21 behind `perform rite of demons`, 41.12,
   -- 44.27, 45.60), and the three that landed went with both up. The smite at 24.89 went
   -- through behind the guilt at 24.63, so the verse took neither. It goes in front of the
   -- prompt's spender (act.ahead), as Anzerloi's verse comes before his smite.
   local BOTH = { bal = true, eq = true, standing = true }

   --- What each lane's sends use up. The prayer lane's own balance is its timer.
   local SPENDS = { balance = "bal", equilibrium = "eq" }

   M.LANES = {
      prayer = {
         ready = function()
            return timers.ready("pvp.prayer") and emunah.act.can(BOTH)
         end,
      },
      balance = {
         ready = function()
            local vitals = emunah.gmcp.vitals
            return vitals and vitals.bal and timers.ready("attack.balance")
               and emunah.act.can(BOTH, "bal")
         end,
      },
      equilibrium = {
         ready = function()
            local vitals = emunah.gmcp.vitals
            return vitals and vitals.eq and timers.ready("cure.equilibrium")
               and emunah.act.can(BOTH, "eq")
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

   --- Per mode: the order chasten picks from. Offence's is what Anzerloi chastened on the
   --- legs in the spars; the route puts asthma and recklessness ahead of it when its
   --- cadence calls for them (M.routeChasten).
   M.CHASTEN = {
      attack  = { "asthma", "clumsiness", "recklessness", "healthleech", "paralysis" },
      offence = { "clumsiness", "paralysis", "healthleech", "asthma", "epilepsy",
                  "recklessness" },
      hinder  = { "paralysis", "asthma", "clumsiness", "epilepsy", "dizziness" },
      finish  = { "asthma", "recklessness", "clumsiness", "confusion", "paralysis" },
   }

   --- Rebukes a mode ends a prayer with, best first, on any verse once the prayer is long
   --- enough. A rebuke counts the verse it rides on (P.prayerAllows) and ends the prayer.
   --- Offence has none here: its prayers say where theirs go (M.PRAYERS).
   M.REBUKES = {
      hinder  = { "darkness" },
   }

   -- The planner's test of a move, defined with the planning below; the route uses it too.
   local allowed

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

   --- When a strip was sent at each target, so a shield seen before it is not stripped twice.
   M.strippedAt = {}

   --- Is the target behind a magical shield? Seen going up (a shield tattoo touched, the
   --- opponent tracker's line) and not stripped since. How it reads when it falls by other
   --- means -- their own attack, or our blow on it -- is not captured.
   function M.shielded(target)
      local opponent = emunah.curing.detect and emunah.curing.detect.opponent
      local seen = opponent and opponent.defences[tostring(target or ""):lower()]
      local up = seen and seen.shield
      local stripped = M.strippedAt[tostring(target or ""):lower()]
      return up ~= nil and (stripped == nil or up > stripped)
   end

   local function mace(ctx)
      -- Heresy burns rebounding away (HELP HERESY); without it a mace blow into rebounding
      -- comes back on you (13.9% and 404 health, 2026-10-15 13:58:03). A shield takes the
      -- blow: the strip goes first ("But must strip before smite", 14:35, 2026-10-15).
      if M.shielded(ctx.target) then return false end
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
      reflection   = verse("reflection", nil, { cost = 2.70 }),
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
      -- The route's blow: a leg, the one our blows have hurt least (M.legFor), carrying
      -- the route's chasten (M.routeChasten). `left leg`/`right leg` are HELP TARGET's limb
      -- words; the smite has been seen to take `head` (13:58:03), the legs not yet.
      legsmite = { lane = "balance", skill = "mace", when = mace,
         command = function(ctx)
            local aff = M.routeChasten(ctx)
            local leg = M.legFor(ctx.target)
            M.lastLeg[ctx.target] = leg
            return ("smite %s %s chasten %s"):format(ctx.target, leg, aff), "chasten:" .. aff
         end },

      -- equilibrium
      -- A magical shield, stripped by the angel ("It will always strip magical shields
      -- first", AB STRIP). PvP's own move, for this one use: the user lifted strip's
      -- hunting-only ruling for a target's shield, 2026-10-23, after Anzerloi's spar (#49,
      -- 07:41:00: "Your shield defence has been stripped by Anzerloi's guardian angel.").
      strip = { lane = "equilibrium", skill = "strip", again = true,
         when = function(ctx) return M.shielded(ctx.target) end,
         command = function(ctx) return "angel strip " .. ctx.target end },
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
   -- the route: offence, as Anzerloi fights
   -- -----------------------------------------------------------------------------------
   --
   -- Three spars against Maelgor, 2026-10-13, seen from Maelgor's end, so every verse
   -- comes with the game naming what it gave (docs/game/pvp-locks.md). What they show:
   --
   --   * TWO HERBS EVERY EXCHANGE. Each fight opens Burn (tenderskin, lobelia) with sloth
   --     (weariness, kelp), twice, then Condemnation (justice, bellwort) with sloth. The
   --     target eats one herb at a time, so something stays on.
   --   * FOUR VERSES, THEN A REBUKE that ends the prayer. The first prayer closes on guilt
   --     rebuke evil with a smite chastening recklessness: guilt, masochism and
   --     recklessness, three lobelia afflictions at once. The second takes Reflection third
   --     and Revelations (hellsight) fourth, rebuke evil again, chastening asthma.
   --   * HELLSIGHT AND ASTHMA. Hellsight gives a random affliction about once a second and
   --     is smoked away; asthma shuts the pipe. In #49 it stayed 28s with asthma reapplied,
   --     and gave confusion, stupidity, dizziness, hallucinations, epilepsy, vertigo,
   --     slickness and sleep.
   --   * INQUISITION on the verse after guilt and ash have both gone out.
   --   * THE LEGS. Past the first prayer the mace goes to the legs, 16.6% a blow.
   --   * THE KILL (#50): a prayer of burn, ash, wrath, with a sap and then absolve on
   --     equilibrium. The closed prayers' conviction pays for wrath.
   --
   -- The user's rulings, 2026-10-23: the prayer is this fixed cadence, never a belief that
   -- a verse landed; absolve only on a contemplate under half, so wrath is a second sap
   -- rather than half of a finisher; the legs are worked evenly; a shield is stripped.

   --- Anzerloi's prayers, verse by verse. A slot lists its verse and what to fall back on
   --- when that cannot go (untrained, its needs unmet, or confirmed on them already);
   --- `rebuke` is the sin the slot ends the prayer with.
   M.PRAYERS = {
      -- His first prayer in all three spars.
      stack     = { { "burn" }, { "burn", "ash" }, { "condemnation", "guilt" },
                    { "guilt", rebuke = "evil" } },
      -- His second, once conviction pays for Reflection (5) and Revelations (10).
      hellsight = { { "burn" }, { "burn", "ash" }, { "reflection", "condemnation" },
                    { "revelations", "guilt", rebuke = "evil" } },
      -- #49's third and fourth closed on heresy, with guilt and spiritburn just given.
      heresy    = { { "burn" }, { "burn", "ash" }, { "guilt" }, { "ash", rebuke = "heresy" } },
      -- #50's last: tenderskin and spiritburn on them, then wrath's sap. He killed on the
      -- third; the fourth closes it like his others, so its conviction can pay for the next.
      drain     = { { "burn" }, { "ash" }, { "wrath", "guilt" }, { "guilt", rebuke = "evil" } },
   }

   --- Verses for a prayer that runs past its template (a verse that faltered, or a rebuke
   --- that could not go), rotated.
   M.PRAYER_FILL = { "burn", "ash", "guilt", "condemnation" }

   --- The prayer in progress and the last one finished, by their M.PRAYERS names.
   M.prayerKind = nil
   M.lastKind = nil

   --- Which prayer to start on the conviction in hand: wrath's 20 drains, Revelations' 10
   --- alternates hellsight and heresy, and below that the stack.
   function M.routeKind(conviction)
      conviction = tonumber(conviction) or 0
      if conviction >= P.VERSE_NEEDS.wrath.conviction then return "drain" end
      if conviction >= P.VERSE_NEEDS.revelations.conviction then
         return M.lastKind == "hellsight" and "heresy" or "hellsight"
      end
      return "stack"
   end

   --- The prayer in progress, choosing one when none is.
   function M.currentKind()
      if not M.prayerKind then M.prayerKind = M.routeKind(P.prayer().conviction) end
      return M.prayerKind
   end

   --- The slot the next verse fills, or nil past the template's end.
   local function currentSlot()
      return M.PRAYERS[M.currentKind()][P.prayer().length + 1]
   end

   --- The route's verse: a move carrying the rebuke its slot ends on (false for none), and
   --- its name. Nil when nothing can go.
   function M.routePrayer(ctx)
      local slot = currentSlot()
      -- In a slot its verses go in order, as often as it comes round. Past the template
      -- the fill rotates, and repeats only when everything in it went a moment ago.
      for pass = 1, slot and 1 or 2 do
         for _, name in ipairs(slot or M.PRAYER_FILL) do
            local move = M.MOVES[name]
            if move and allowed(name, move, ctx) and (slot or pass == 2 or not recent(name)) then
               local sin = slot and slot.rebuke
               if sin and not (have.skill("rebuke") and P.prayerAllows(sin)) then sin = nil end
               return setmetatable({ rebuke = sin or false }, { __index = move }), name
            end
         end
      end
      return nil
   end

   --- The legs, the first taking a tie: Anzerloi started on the right (#48, #49).
   M.LEGS = { "right leg", "left leg" }
   --- target -> the leg smitten last
   M.lastLeg = {}

   --- The leg to smite: the one our blows have hurt least, so the two break close together
   --- (the user, 2026-10-23). Level, the one not smitten last, so they alternate even while
   --- no figure comes back.
   function M.legFor(target)
      local hurt = P.limbs(target)
      local first, second = M.LEGS[1], M.LEGS[2]
      local a, b = hurt[first] or 0, hurt[second] or 0
      if a < b then return first end
      if b < a then return second end
      return M.lastLeg[target] == first and second or first
   end

   --- How long after Revelations the chasten keeps asthma on them, so hellsight cannot be
   --- smoked away. A tuning number: in the spars hellsight lasted 12s and 28s, as long as
   --- asthma held. Nothing says hellsight landed, so this times the cadence, not a belief.
   M.HELLSIGHT = 20
   M.revelationsAt = nil

   --- How close a verse and a blow must go to count as one exchange, in seconds. Prayer
   --- balance (1.60s) and the mace's come round at different rates.
   M.TOGETHER = 2.0
   --- The verse sent last: { name, rebuke, at }.
   M.lastVerse = nil

   --- The piece of a forming lock a chasten can give, not on them and not just tried, or nil.
   local function lockPiece(ctx)
      for _, aff in ipairs(ctx.lockNeeds or {}) do
         if CHASTEN_POOL[aff] and not ctx.afflictions[aff] and not recent("chasten:" .. aff) then
            return aff
         end
      end
      return nil
   end

   --- The route's chasten. A lock's missing piece first, as in every mode; then asthma
   --- while hellsight is being held, as soon as it is not confirmed on them; then
   --- recklessness on the stack's close; then Anzerloi's order on the legs.
   function M.routeChasten(ctx)
      local piece = lockPiece(ctx)
      if piece then return piece end
      local now = util.now()
      if M.revelationsAt and now - M.revelationsAt < M.HELLSIGHT
         and not ctx.afflictions.asthma then
         return "asthma"
      end
      local verse = M.lastVerse
      if verse and verse.name == "guilt" and verse.rebuke == "evil"
         and now - verse.at < M.TOGETHER and not ctx.afflictions.recklessness then
         return "recklessness"
      end
      return chastenPick(ctx, M.CHASTEN.offence)
   end

   --- Does this exchange want an equilibrium affliction rather than the mace? In the first
   --- prayer every exchange but the rebuke's (sloth, sloth, sloth, then the smite); after
   --- it, a prayer's first. Never while draining, when equilibrium reads and saps, and
   --- never while the mace's chasten can close a forming lock.
   function M.openingDue(ctx)
      local kind = M.currentKind()
      if kind == "drain" then return false end
      if ctx and lockPiece(ctx) then return false end
      if kind == "stack" then
         local slot = currentSlot()
         return not (slot and slot.rebuke)
      end
      return P.prayer().length == 0
   end

   --- Is the route on its draining prayer: reading their mana, sapping, and absolving?
   function M.draining()
      return M.currentKind() == "drain"
   end

   --- A move that goes only while `condition` holds as well as its own conditions.
   local function onlyWhen(name, condition)
      local base = M.MOVES[name]
      return setmetatable({ when = function(ctx)
         return condition(ctx) and (base.when == nil or base.when(ctx))
      end }, { __index = base })
   end
   M.MOVES.openSloth        = onlyWhen("sloth", M.openingDue)
   M.MOVES.openDazzle       = onlyWhen("dazzle", M.openingDue)
   M.MOVES.drainContemplate = onlyWhen("contemplate", M.draining)
   M.MOVES.drainSap         = onlyWhen("sap", M.draining)

   --- The route as `emset pvp` shows it: the prayer and the legs.
   function M.routeReport(target)
      local kind = M.currentKind()
      local length = P.prayer().length
      local template = M.PRAYERS[kind]
      local hurt = P.limbs(target)
      local legs = {}
      for _, leg in ipairs(M.LEGS) do
         legs[#legs + 1] = ("%s %.1f%%"):format(leg, hurt[leg] or 0)
      end
      return ("%s prayer, verse %d of %d"):format(kind, length + 1, #template),
         table.concat(legs, ", ")
   end

   -- -----------------------------------------------------------------------------------
   -- the modes (F1 attack, F2 defence, F3 hinder, F4 finish; offence has no key)
   -- -----------------------------------------------------------------------------------

   M.MODES = {
      -- F1: damage first, afflictions on the side.
      attack = {
         exchange    = true,
         alternate   = true,
         prayer      = { "purge", "unflinching", "guilt", "ash" },
         balance     = { "smite" },
         equilibrium = { "heresy", "sear" },
      },
      -- F2: hold the attack. Curing and the defence keep-up are not this mode's to send,
      -- and no game command for a defensive rotation has been captured.
      defence = {
         prayer      = {},
         balance     = {},
         equilibrium = {},
      },
      -- No key. `emset pvp mode offence`, and the mode a fresh session starts in.
      -- Anzerloi's route (above): his prayers, the legs, and an equilibrium affliction in
      -- the exchanges where he used one. One of mace or equilibrium an exchange.
      offence = {
         exchange    = true,
         prayer      = M.routePrayer,
         balance     = { "legsmite" },
         equilibrium = { "absolve", "drainContemplate", "drainSap", "openSloth", "openDazzle" },
      },
      -- F3: keep them here and slow -- legs, paralysis, fragility on the next blow.
      hinder = {
         exchange    = true,
         alternate   = true,
         prayer      = { "penance", "fragility", "guilt" },
         balance     = { "smashlegs", "smite" },
         equilibrium = { "sloth", "panic" },
      },
      -- F4: read their mana, sap it under half, absolve.
      finish = {
         exchange    = true,
         prayer      = { "wrath", "guilt", "ash" },
         balance     = { "smite" },
         equilibrium = { "absolve", "contemplate", "sap" },
      },
   }

   -- Every attacking mode strips a shield before its mace or its equilibrium afflictions
   -- meet it, and wants a heresy defence the moment a mace blow would rebound. Defence
   -- holds the attack; both are attacks.
   for name, mode in pairs(M.MODES) do
      if name ~= "defence" then
         local raisesHeresy = mode.equilibrium[1] == "heresy"
         table.insert(mode.equilibrium, 1, "strip")
         if not raisesHeresy then table.insert(mode.equilibrium, 1, "heresyIfRebounding") end
      end
   end
   M.MOVES.heresyIfRebounding = { lane = "equilibrium", skill = "heresy", again = true,
      when = function(ctx) return ctx.rebounding and not ctx.heresy end,
      command = function() return "hunt heresy" end }

   -- -----------------------------------------------------------------------------------
   -- planning and sending
   -- -----------------------------------------------------------------------------------

   function allowed(name, move, ctx)
      if move.skill and not have.skill(move.skill) then return false end
      if move.verse then
         if P.ONCE_PER_PRAYER[move.verse] and P.prayerSpent[move.verse] then return false end
         if not P.prayerAllows(move.verse) then return false end
      end
      if move.gives and ctx.afflictions[move.gives] then return false end
      if move.when and not move.when(ctx) then return false end
      return true
   end

   --- What has gone out on this prompt, by lane. Cleared as each prompt starts (M.defer).
   M.thisTick = {}

   --- One lane's move under a mode, or nil. A lane may be a list of move names or, as the
   --- route's prayer is, a function choosing one.
   local function planLane(mode, lane, ctx)
      local spec = M.LANES[lane]
      local moves = mode[lane]
      if not (spec and moves) then return nil end
      if not spec.ready() then return nil end
      if type(moves) == "function" then return moves(ctx) end
      local fallback
      for _, name in ipairs(moves) do
         local move = M.MOVES[name]
         if move and allowed(name, move, ctx) then
            if not recent(name) or move.again then return move, name end
            fallback = fallback or { move, name }
         end
      end
      if fallback then return fallback[1], fallback[2] end
      return nil
   end

   --- The lane, mace or equilibrium, that sent the last exchange. An alternating mode gives
   --- the other one the next.
   M.lastExchange = nil

   --- The move this lane should send now, under this mode, or nil.
   ---
   --- EVERY ATTACKING MODE IS AN EXCHANGE: the mace or an equilibrium move on a prompt, never
   --- both. A smite needs equilibrium and the angel needs balance, so the second of two on
   --- one prompt only bounces: `smite erishka head chasten clumsiness|angel sear erishka`
   --- came back "You must regain balance first." for the sear, every time (2026-10-23
   --- 09:58:41.12, 44.20). Equilibrium speaks first: the mace waits for any equilibrium move
   --- that is due, and goes when none is. An ALTERNATING mode (attack, hinder) always has
   --- one due -- sear repeats -- so there the two take turns, the mace first.
   function M.plan(modeName, lane, ctx)
      local mode = M.MODES[modeName]
      if not mode then return nil end
      if mode.exchange then
         local eqHeld = ctx.held and ctx.held.equilibrium
         local eqFirst = not mode.alternate or M.lastExchange == "balance"
         if lane == "balance" and eqFirst and not eqHeld
            and planLane(mode, "equilibrium", ctx) then
            return nil
         end
         if lane == "equilibrium" and M.thisTick.balance then return nil end
      end
      return planLane(mode, lane, ctx)
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
      local sin
      if move.verse then
         -- The route's verse names its own (false for none); other modes' come from the
         -- mode's list.
         sin = move.rebuke
         if sin == nil then sin = rebukeFor(ctx) end
         if sin then command = command .. " rebuke " .. sin end
      end
      local spends = SPENDS[move.lane]
      if not emunah.act.send(command, BOTH, spends) then return false end

      local now = util.now()
      M.sentAt[name] = now
      if tag then M.sentAt[tag] = now end
      M.thisTick[move.lane] = true
      if spends then M.lastExchange = move.lane end
      if move.verse then
         M.lastVerse = { name = move.verse, rebuke = sin or nil, at = now }
         if move.verse == "revelations" then M.revelationsAt = now end
      end
      if move.skill == "strip" then M.strippedAt[ctx.target] = now end
      -- The pessimistic guard until the game's own line replaces it ("You may speak another
      -- holy verse." / "Balance used:" / "Equilibrium used:"), as every attack here does.
      --
      -- ARMED AS IT LEAVES. Lanes used to arm only after every lane of the prompt had sent,
      -- so that the mace and an equilibrium move could share one -- and the second always
      -- bounced (M.plan). Armed now, the lane after a smite waits for the balance, and a
      -- cure or rite later in the prompt's line does not go out behind it into a refusal.
      if move.lane == "prayer" then
         timers.start("pvp.prayer", move.cost or P.RECITE_BALANCE_GUESS)
         if P.ONCE_PER_PRAYER[move.verse] then P.prayerSpent[move.verse] = true end
      else
         emunah.act.arm(spends)
      end
      return true
   end

   --- A new prompt: nothing has gone out on it yet.
   function M.defer(on)
      if on then M.thisTick = {} end
   end

   -- A new fight, or a new target, starts the rotation afresh: what was sent at the last
   -- one says nothing about this one. The prayer is the game's, and carries on.
   emunah.event.kill("priest-pvp")
   for _, name in ipairs({ "emunah.pvp.started", "emunah.pvp.target" }) do
      emunah.event.register(name, function()
         M.sentAt, M.lastLeg, M.strippedAt = {}, {}, {}
         M.lastVerse, M.revelationsAt, M.lastExchange = nil, nil, nil
         P.targetLimbs = {}
      end, "priest-pvp")
   end
   -- The prayer ended (priest.prayerReset()): the next verse starts the next one.
   emunah.event.register("emunah.priest.prayerEnded", function()
      M.lastKind = M.prayerKind or M.lastKind
      M.prayerKind = nil
   end, "priest-pvp")

   P.pvp = M
   P.pvpPlan = M.plan
   P.pvpSend = M.send
   P.pvpDefer = M.defer
   P.PVP_MODES = M.MODES
end

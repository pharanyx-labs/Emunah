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
   --- `again` (contemplate, sap, absolve, heresy, purity) are meant to repeat and skip it.
   M.RECENT = 6.0
   M.sentAt = {}

   local function recent(key)
      local at = M.sentAt[key]
      return at ~= nil and util.now() - at < M.RECENT
   end

   --- Every affliction chasten can carry, and which pool it is in (P.CHASTEN_POOLS).
   local CHASTEN_POOL = {}
   for category, pool in pairs(P.CHASTEN_POOLS) do
      for _, aff in ipairs(pool) do CHASTEN_POOL[aff] = category end
   end

   --- Fewer confirmed afflictions than this and the picture is clean enough to name the
   --- chasten; at or over it, chasten body or mind. "You want to focus them early when the
   --- enemy is relatively clean of affs and your estimation is good ... later on you switch
   --- to body/mind to efficiently fill whatever's left, since picture will be uncertain"
   --- (Anzerloi, 2026-10-23 14:38:04, 14:38:52). A tuning number, not a game fact.
   M.NAMED_CHASTEN_UNTIL = 3

   --- MENTALS ONLY WHEN THEY PAY. Anzerloi, 2026-10-23, after the 17:44 spar: "See the
   --- problem? Matching mentals with eatables. I get rid of them before your next attack."
   --- "Gotta only use mentals when they can't focus or it can harm them." "That's why I
   --- work the kelp trail primarily." "Mentals are for when you get a good lobelia trail
   --- to hold the guilt. And you don't have a more worthy affliction to contribute to the
   --- kelp trail." "Between another mental and hellsight, I'll go hellsight any day."
   ---
   --- A mental is anything FOCUS cures. One goes when:
   ---   * focus is shut on them: impatience or inquisition confirmed (opponent.blockedVectors);
   ---   * we are in the slickness sequence, where focus has anorexia to cure as well
   ---     (M.slickPhase, his procedure of 16:07-16:08);
   ---   * guilt is held on a lobelia trail (guilt and another lobelia affliction confirmed)
   ---     and every kelp affliction a chasten gives is already on them.
   --- Hellsight comes ahead of any of it: Revelations is a verse, on its own lane, and goes
   --- whenever asthma is secure (M.MOVES.revelations).
   local function isMental(aff)
      return #emunah.curing.afflist.curesVia(aff, "focus") > 0
   end

   --- How many afflictions focus cures are confirmed on them, anorexia aside.
   function M.mentalCount(ctx)
      local n = 0
      for aff in pairs(ctx.afflictions) do
         if aff ~= "anorexia" and isMental(aff) then n = n + 1 end
      end
      return n
   end

   --- The mentals a chasten names, when one may go. Never recklessness: "Take that
   --- recklessness out" (Anzerloi, 2026-10-23). And never `chasten mind` but for its
   --- capstone, since the game may pick recklessness from the pool.
   M.MENTALS = { "epilepsy", "dizziness", "confusion" }
   local function curedBy(aff, herb)
      for _, option in ipairs(emunah.curing.afflist.curesVia(aff, "herb")) do
         if option.item == herb then return true end
      end
      return false
   end
   --- The kelp afflictions a chasten can give.
   M.KELP_TRAIL = { "asthma", "clumsiness", "healthleech" }
   function M.lobeliaTrail(ctx)
      if not ctx.afflictions.guilt then return false end
      for aff in pairs(ctx.afflictions) do
         if aff ~= "guilt" and curedBy(aff, "lobelia") then return true end
      end
      return false
   end
   function M.kelpTrailFull(ctx)
      for _, aff in ipairs(M.KELP_TRAIL) do
         if not ctx.afflictions[aff] then return false end
      end
      return true
   end
   --- "Still too many mentals" (Anzerloi, 2026-10-23): in the slickness sequence, one is
   --- enough. Fasting's anorexia needs one beside it for focus to choose wrong ("Minimum
   --- 1/2 chance they focus the wrong thing", 16:08:59), and no more.
   function M.mentalsAllowed(ctx)
      if ctx.blocked and ctx.blocked.focus then return true end
      if M.slickPhase ~= nil and M.slickPhase(ctx) == true and M.mentalCount(ctx) < 1 then
         return true
      end
      return M.lobeliaTrail(ctx) and M.kelpTrailFull(ctx)
   end

   --- `body` or `mind` for a smart chasten, or nil. A pool they have all of comes first:
   --- chastening it gives the capstone, and impatience comes no other way ("You can't
   --- intentionally afflict with impat", 14:35:53). Otherwise the pool with more missing,
   --- ties to the pool of the first affliction `order` still wants.
   local function smartPool(ctx, order, capstoneOnly)
      local missing = {}
      for _, category in ipairs({ "mind", "body" }) do
         local pool, n = P.CHASTEN_POOLS[category], 0
         for _, aff in ipairs(pool) do
            if not ctx.afflictions[aff] then n = n + 1 end
         end
         if n == 0 and not ctx.afflictions[pool.capstone] then return category end
         missing[category] = n
      end
      if capstoneOnly then return nil end
      -- Never `mind` but for its capstone: the pool is all mentals, and the game may pick
      -- recklessness from it.
      return missing.body > 0 and "body" or nil
   end

   --- How many afflictions are confirmed on the target.
   local function confirmedCount(ctx)
      local n = 0
      for _ in pairs(ctx.afflictions) do n = n + 1 end
      return n
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
      -- A capstone to be had beats anything named: its pool is full, so naming one wastes it.
      local capstone = smartPool(ctx, order, true)
      if capstone then return capstone end
      -- A mental that pays, once the kelp trail is laid: their focus shut, or guilt held on a
      -- lobelia trail (M.mentalsAllowed). It comes ahead of the body pool.
      if M.mentalsAllowed(ctx) and M.kelpTrailFull(ctx) then
         for _, aff in ipairs(M.MENTALS) do
            if not ctx.afflictions[aff] and not recent("chasten:" .. aff) then return aff end
         end
      end
      -- Late, or when everything named is on them: let the game pick from a pool.
      if confirmedCount(ctx) >= M.NAMED_CHASTEN_UNTIL then
         local pool = smartPool(ctx, order)
         if pool then return pool end
      end
      for _, aff in ipairs(order) do
         if not ctx.afflictions[aff] and not recent("chasten:" .. aff) then return aff end
      end
      -- The orders hold no mentals. One is named only when it may go (M.mentalsAllowed).
      if M.mentalsAllowed(ctx) then
         for _, aff in ipairs(M.MENTALS) do
            if not ctx.afflictions[aff] and not recent("chasten:" .. aff) then return aff end
         end
      end
      -- Everything named is on them or was just tried: a pool never repeats one they have.
      return smartPool(ctx, order) or "body"
   end

   --- Per mode: the order chasten picks from. THE KELP TRAIL FIRST, ASTHMA LAST: "That's
   --- why I work the kelp trail primarily", and "I like saving asthma for the end"
   --- (Anzerloi, 2026-10-23). Clumsiness, healthleech and asthma are all kelp, and a kelp
   --- eaten cures one of them, so the rest stay; asthma, which shuts the pipe, lands on a
   --- trail already laid. Hinder leads with paralysis, its purpose. Mentals are named last
   --- and only go when they may (M.mentalsAllowed). The route holds asthma on while
   --- hellsight is up (M.routeChasten). No mentals: those come from M.MENTALS, and only
   --- when they may.
   M.CHASTEN = {
      attack  = { "clumsiness", "healthleech", "asthma", "paralysis" },
      offence = { "clumsiness", "healthleech", "asthma", "paralysis" },
      hinder  = { "paralysis", "clumsiness", "healthleech", "asthma" },
      finish  = { "clumsiness", "healthleech", "asthma", "paralysis" },
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

   --- THEIR MANA, ESTIMATED. "Don't contemplate too much as it'll cost us valuable time. Try
   --- and estimate it and only use contemplate when you feel they are close" (the user,
   --- 2026-10-23). From the last reading, or full at the start of a fight with none: less
   --- each sap and wrath of ours since, by sapPercent over what was on them as it went, and
   --- less M.FOCUS_COST for each focus they were seen to make. Their regeneration, moss and
   --- mana sips are not counted, so it errs low, and reads come a little early rather than
   --- late. It only decides when to look and when to sap: absolve waits for a real reading.
   ---
   --- FOCUS COSTS ABOUT 13% OF MAXIMUM MANA: the user's own, twice on 2026-10-23, 94% to 81%
   --- at 18:08:23-26 and 85% to 72% at 18:09:00-01. A tuning number for anyone else's.
   M.FOCUS_COST = 13
   --- Contemplate when the estimate is at or under this: close enough to the kill to look.
   M.READ_BELOW = 60
   --- target -> { { at, percent } }: what our saps and wraths were estimated to take.
   M.drains = {}
   --- When this fight began, the base of an estimate with no reading.
   M.fightAt = nil

   function M.manaEstimate(ctx)
      local reading = ctx.mana
      local estimate, since
      if reading then
         estimate, since = reading.percent, reading.at
      else
         estimate, since = 100, M.fightAt or 0
      end
      for _, drain in ipairs(M.drains[ctx.target] or {}) do
         if drain.at >= since then estimate = estimate - drain.percent end
      end
      local opponent = emunah.curing.detect and emunah.curing.detect.opponent
      if opponent and opponent.focusesSince then
         estimate = estimate - opponent.focusesSince(ctx.target, since) * M.FOCUS_COST
      end
      return estimate > 0 and estimate or 0
   end

   --- CONTEMPLATE RIDES ON THE BLOW. `smite anzerloi head chasten ...;contemplate anzerloi`
   --- goes through as one line (the user, 2026-10-23 14:37:02), as Anzerloi said it would
   --- ("you can also append 'contemplate '..target to your attack without issue", 14:53:13).
   --- So a mode that reads mana takes its reading with every blow that has none fresh,
   --- and equilibrium stays free for the moves. AB CONTEMPLATE: 1.00s of equilibrium, armed
   --- as it leaves, which is also what holds a second one until the reading is back.
   local function contemplateWithBlow(mode, ctx)
      if not (mode and mode.readMana) or freshMana(ctx) then return end
      -- Only when they may be close: a contemplate is a second of equilibrium.
      if M.manaEstimate(ctx) > M.READ_BELOW then return end
      if not have.skill("contemplate") then return end
      if emunah.act.send("contemplate " .. ctx.target, { eq = true }, "eq") then
         M.sentAt.contemplate = util.now()
         emunah.act.arm("eq")
      end
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

   local function isKelp(aff)
      for _, option in ipairs(emunah.curing.afflist.curesVia(aff, "herb")) do
         if option.item == "kelp" then return true end
      end
      return false
   end

   --- Is asthma confirmed on them with another kelp affliction beside it? Then the next
   --- kelp they eat may take the other, and asthma keeps the pipe shut on hellsight: "only
   --- give hellsight when asthma is secure with more kelp affs" (Anzerloi, 2026-10-23
   --- 16:03:25).
   function M.asthmaSecure(ctx)
      if not ctx.afflictions.asthma then return false end
      for aff in pairs(ctx.afflictions) do
         if aff ~= "asthma" and isKelp(aff) then return true end
      end
      return false
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
      -- NO FIRE WITHOUT INQUISITION: "Don't set people on fire at all unless they have
      -- inquisition/you are giving it in the same attack" (Anzerloi, 2026-10-23 14:03:16).
      -- Only once it is confirmed on them: no mode here gives it in the attack that burns.
      purge        = verse("purge", "ablaze",
         { when = function(ctx) return ctx.afflictions.inquisition == true end }),
      revelations  = verse("revelations", "hellsight", { when = M.asthmaSecure }),
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
      -- Attack's blow: a leg, the two evenly, chastening the mode's own order. The legs are
      -- "another possible source for sap power, and to immobilize them during the kill
      -- window" (Anzerloi, 2026-10-23 14:40:09).
      legsmiteChasten = { lane = "balance", skill = "mace", when = mace,
         command = function(ctx)
            local aff = chastenPick(ctx, M.CHASTEN[ctx.mode] or M.CHASTEN.offence)
            local leg = M.legFor(ctx.target)
            M.lastLeg[ctx.target] = leg
            return ("smite %s %s chasten %s"):format(ctx.target, leg, aff), "chasten:" .. aff
         end },
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
      -- "ANGEL PANIC now gives slickness instead of fear if the target suffers from
      -- HELLSIGHT" (CLASSLEADS #178, 2026-10-23).
      panic = { lane = "equilibrium", skill = "panic",
         gives = function(ctx) return ctx.afflictions.hellsight and "slickness" or "fear" end,
         command = function(ctx) return "angel panic " .. ctx.target end },
      -- THE KILLING BLOW. Heavy magical damage through any shield (AB PURITY: 4.00s of
      -- equilibrium, 250 devotion), "too slow to be useful" unless it kills (Anzerloi,
      -- 14:45:07). So only on their health as the game gave it, at or under
      -- pvp.purityBelow; with no reading it never goes.
      purity = { lane = "equilibrium", skill = "purity", again = true,
         when = function(ctx)
            local below = tonumber(emunah.config.get("pvp.purityBelow", 20)) or 0
            return below > 0 and ctx.health ~= nil and ctx.health <= below
         end,
         command = function(ctx) return "perform purity " .. ctx.target end },
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

   --- THE KILL, WHEREVER IT IS. "You win by having their mana low enough. If that does not
   --- present itself on its own (on your contemplations), you attempt to create conditions
   --- to attack their mana with saps" (Anzerloi, 2026-10-23 14:38:17-14:38:57). A reading
   --- under half absolves; a reading one sap would take under half saps now, in any mode
   --- and any prayer, not only the drain; and the reading that sap left stale is taken
   --- again at once, so the absolve follows it. The sap's share is sapPercent() over what
   --- is confirmed on them, which only undercounts: nothing unconfirmed adds to it.
   M.KILL_WINDOW = 10
   --- The sap that takes them under half, by the estimate (M.manaEstimate): a fresh
   --- reading when there is one, the reading less what has gone since when not.
   M.MOVES.killSap = { lane = "equilibrium", skill = "sap", again = true,
      when = function(ctx)
         local estimate = M.manaEstimate(ctx)
         if P.absolveKills(estimate) then return false end
         return P.absolveKills(P.sapAfter(estimate, ctx.afflictions))
      end,
      command = function(ctx) return "angel sap " .. ctx.target end }
   --- The reading absolve waits for: straight after the kill sap, or whenever the estimate
   --- says they are already under half. Never two inside M.FRESH, but for the kill sap's.
   M.MOVES.killRead = { lane = "equilibrium", skill = "contemplate", again = true,
      when = function(ctx)
         if freshMana(ctx) then return false end
         local at = M.sentAt.killSap
         if at ~= nil and util.now() - at < M.KILL_WINDOW then return true end
         local last = math.max(M.sentAt.contemplate or 0, M.sentAt.killRead or 0)
         if util.now() - last < M.FRESH then return false end
         return P.absolveKills(M.manaEstimate(ctx))
      end,
      command = function(ctx) return "contemplate " .. ctx.target end }

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
   --   * SLICKNESS ON HELLSIGHT, since CLASSLEADS #178 (2026-10-23): angel panic gives it in
   --     place of fear. Anzerloi's procedure: "only give hellsight when asthma is secure
   --     with more kelp affs, that's a sure slickness afflict that can easily stick"
   --     (16:03:25). So the hellsight prayer's mace builds asthma and a kelp affliction,
   --     Revelations waits for both confirmed, and a panic follows it.
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
      -- His second, once conviction pays for Reflection (5) and Revelations (10). Since
      -- panic gives slickness on hellsight, Revelations goes without a rebuke and the
      -- prayer carries on: "don't rebuke, and on next attack guilt rebuke a mental/perform
      -- sloth" (Anzerloi, 2026-10-23 16:08:36). Masochism, evil's, is cured by focus.
      -- Guilt in Revelations' place still closes the prayer.
      hellsight = { { "burn" }, { "burn", "ash" }, { "reflection", "condemnation" },
                    { "revelations", "guilt", rebuke = "evil", open = { revelations = true } },
                    { "guilt", rebuke = "evil" } },
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
               if slot and slot.open and slot.open[name] then sin = nil end
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

   --- Kelp afflictions a chasten can give, to sit beside asthma before Revelations.
   M.KELP_CHASTEN = { "clumsiness", "healthleech" }

   --- The route's chasten. Asthma while hellsight is being held, as soon as it is not
   --- confirmed on them; then, once they are slick, the mind pool (M.slickPhase); then a
   --- lock's missing piece, as in every mode; then, while a hellsight prayer builds to
   --- Revelations, asthma and another kelp affliction so it can go (M.asthmaSecure); then
   --- recklessness on the stack's close; then Anzerloi's order.
   function M.routeChasten(ctx)
      local now = util.now()
      local holding = M.revelationsAt and now - M.revelationsAt < M.HELLSIGHT
      -- While hellsight is held, asthma before anything: it keeps the pipe shut on it.
      if holding and not ctx.afflictions.asthma then return "asthma" end
      -- Slick: mentals, so focus has more than anorexia to choose from. "Minimum 1/2 chance
      -- they focus the wrong thing before you chasten another mental in them" (16:08:59).
      -- His newer word, ahead of a lock's other pieces; a full mind pool chastens for
      -- impatience, the hard lock's last piece.
      -- One mental, not a run of them ("Still too many mentals", 2026-10-23).
      if M.slickPhase(ctx) and M.mentalCount(ctx) < 1 then
         for _, aff in ipairs(M.MENTALS) do
            if not ctx.afflictions[aff] and not recent("chasten:" .. aff) then return aff end
         end
      end
      local piece = lockPiece(ctx)
      if piece then return piece end
      -- Building to Revelations: the kelp first and asthma last ("I like saving asthma for
      -- the end", Anzerloi, 2026-10-23), so it lands on a trail and Revelations follows.
      if M.currentKind() == "hellsight" and not P.prayerSpent.revelations
         and not M.asthmaSecure(ctx) then
         local kelp = false
         for aff in pairs(ctx.afflictions) do
            if aff ~= "asthma" and isKelp(aff) then kelp = true end
         end
         if not kelp then
            for _, aff in ipairs(M.KELP_CHASTEN) do
               if not ctx.afflictions[aff] and not recent("chasten:" .. aff) then return aff end
            end
         end
         if not ctx.afflictions.asthma then return "asthma" end
      end
      -- The stack's close used to chasten recklessness beside guilt rebuke evil, three
      -- lobelia afflictions at once. "Take that recklessness out" (Anzerloi, 2026-10-23).
      return chastenPick(ctx, M.CHASTEN.offence)
   end

   --- Does this exchange want an equilibrium affliction rather than the mace? In the first
   --- prayer every exchange but the rebuke's (sloth, sloth, sloth, then the smite); after
   --- it, a prayer's first, and the guilt that follows Revelations ("guilt rebuke a
   --- mental/perform sloth"). Never while draining, when equilibrium reads and saps, and
   --- never while the mace's chasten can close a forming lock.
   function M.openingDue(ctx)
      local kind = M.currentKind()
      if kind == "drain" then return false end
      -- Slick, the mace chastens mentals rather than the lock's piece, so sloth may go.
      if ctx and lockPiece(ctx) and not M.slickPhase(ctx) then return false end
      if kind == "stack" then
         local slot = currentSlot()
         return not (slot and slot.rebuke)
      end
      if kind == "hellsight" and P.prayerSpent.revelations then return true end
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

   --- STEPPING THEM DOWN. On a fresh reading at or under this, a mode that drains (attack)
   --- saps with wrath on the prayer and the angel on equilibrium, toward the half where
   --- absolve kills: "step them down when it's worth it (such as bringing 100% mana down to
   --- 60%)" (Anzerloi, 2026-10-15 12:41), and "You win by having their mana low enough"
   --- (2026-10-23 14:38:17). A tuning number, not a game fact: a sap takes a few percent to
   --- a fifth of their mana by what is on them (P.sapPercent), and their mana climbs back.
   M.DRAIN_BELOW = 70
   --- An angel sap that takes less than this is not worth the 2.75s of equilibrium and the
   --- blow it replaces ("step them down when it's worth it"). Wrath costs no equilibrium.
   M.SAP_WORTH = 5
   function M.drainDue(ctx)
      local estimate = M.manaEstimate(ctx)
      return not P.absolveKills(estimate) and estimate <= M.DRAIN_BELOW
   end
   M.MOVES.stepWrath = onlyWhen("wrath", M.drainDue)
   -- Its own move, not onlyWhen("sap"): the plain sap wants a fresh reading, and every sap
   -- leaves the reading stale, so the step-down would stop after one.
   M.MOVES.stepSap   = { lane = "equilibrium", skill = "sap", again = true,
      when = function(ctx)
         return M.drainDue(ctx) and P.sapPercent(ctx.afflictions) >= M.SAP_WORTH
      end,
      command = function(ctx) return "angel sap " .. ctx.target end }

   --- When angel panic was sent last, and when slickness was last confirmed on the target.
   M.panicAt = nil
   M.slickAt = nil

   --- Inside the window after Revelations, with asthma still holding the pipe shut.
   local function hellsightHeld(ctx)
      local at = M.revelationsAt
      return at ~= nil and util.now() - at < M.HELLSIGHT and ctx.afflictions.asthma == true
   end

   --- SLICKNESS FROM HELLSIGHT. Panic on a target with hellsight gives slickness, not fear
   --- (CLASSLEADS #178), and with asthma held they can neither smoke the hellsight away nor
   --- the slickness: "that's a sure slickness afflict that can easily stick" (Anzerloi,
   --- 2026-10-23 16:03:25). "If target has hellsight, or you determined your recite to be
   --- revelations, angel panic becomes a slickness-giving move" (16:16:16): on hellsight
   --- confirmed, or inside the window after Revelations. Nothing confirms Revelations
   --- landed, so the window is the cadence, not a belief; on a target without hellsight the
   --- panic gives fear.
   ---
   --- Once, and again only when slickness was confirmed since the last panic and has gone:
   --- they ate it away. A panic into slickness that was never confirmed would cost the mace
   --- every exchange. Their fangbarrier sloughing off confirms it (16:09:48).
   M.MOVES.hellsightPanic = setmetatable({ gives = "slickness", when = function(ctx)
      if not (ctx.afflictions.hellsight or hellsightHeld(ctx)) then return false end
      local last = M.panicAt
      if last == nil or (M.revelationsAt and last < M.revelationsAt) then return true end
      return M.slickAt ~= nil and M.slickAt >= last
   end }, { __index = M.MOVES.panic })

   --- Is the target in our slickness phase: panicked since our Revelations, and either
   --- still inside its window or slick by confirmation? Slickness from anyone else (a
   --- partner) is not this sequence, and leaves the lock's pieces first.
   function M.slickPhase(ctx)
      local at, panic = M.revelationsAt, M.panicAt
      if not (at and panic and panic >= at) then return false end
      return ctx.afflictions.slickness == true or hellsightHeld(ctx)
   end

   --- ANOREXIA ONCE THEY ARE SLICK. "Next attack could be a perform fasting to get
   --- anorexia, which they'll have to focus because slick. For that to be worth it, need
   --- some mentals" (Anzerloi, 16:07:08-16:07:17): one other mental confirmed, so focus
   --- has two to choose from. Once per Revelations; anorexia shows no landing line yet.
   M.MOVES.slickFasting = { lane = "equilibrium", skill = "fasting", gives = "anorexia",
      mentalOk = true,
      when = function(ctx)
         if not M.slickPhase(ctx) or M.mentalCount(ctx) < 1 then return false end
         local last = M.sentAt.slickFasting
         return last == nil or (M.revelationsAt ~= nil and last < M.revelationsAt)
      end,
      command = function(ctx) return "perform fasting " .. ctx.target end }

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
      -- F1: damage first, afflictions on the side. A verse and a smite carrying a chasten,
      -- every exchange: two afflictions and the damage. No angel sear: that is the hunt's
      -- attack, and fire without inquisition is wasted (the purge above).
      --
      -- THE FIRST BLOW ON THE KEY. "I need it to attack the very moment i hit f1" (the user,
      -- 2026-10-23). `hunt heresy` used to open it, 4s of equilibrium the mace waited out,
      -- though the opening verse gives heresy itself: "recite unflinching" at 17:31:20,
      -- "Rage fills you as the thought of heresy inspires you". So the verse and the smite
      -- go on F1's own line, and heresy is hunted only once a blow has rebounded
      -- (heresyIfRebounding, below).
      --
      -- HELLSIGHT WHEN IT CAN STICK. "Between another mental and hellsight, I'll go
      -- hellsight any day" (Anzerloi, 2026-10-23): Revelations first in the prayer once
      -- asthma is secure, with the panic that turns it to slickness, and fasting once they
      -- are slick (his procedure, 16:03-16:16; the moves are the route's).
      --
      -- AND THE KILL. Their mana is read with the blow (contemplate rides on it), and the
      -- kill moves every attacking mode shares go first: absolve under half, the sap that
      -- brings it in reach, and the reading after it. At or under M.DRAIN_BELOW, wrath and
      -- the angel's sap step them down. The mace works the legs, for sap power and to hold
      -- them in place for the kill.
      attack = {
         exchange    = true,
         readMana    = true,
         prayer      = { "purge", "stepWrath", "revelations", "unflinching", "guilt", "ash" },
         balance     = { "legsmiteChasten" },
         equilibrium = { "hellsightPanic", "slickFasting", "stepSap" },
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
         readMana    = true,
         prayer      = M.routePrayer,
         balance     = { "legsmite" },
         equilibrium = { "hellsightPanic", "slickFasting", "drainContemplate",
                         "drainSap", "openSloth", "openDazzle" },
      },
      -- F3: keep them here and slow -- legs, paralysis, fragility on the next blow.
      hinder = {
         exchange    = true,
         alternate   = true,
         prayer      = { "penance", "fragility", "guilt" },
         balance     = { "smashlegs", "smite" },
         equilibrium = { "sloth", "panic" },
      },
      -- F4: read their mana, sap it under half, absolve (the kill, below, goes first).
      finish = {
         exchange    = true,
         readMana    = true,
         prayer      = { "wrath", "guilt", "ash" },
         balance     = { "smite" },
         equilibrium = { "contemplate", "sap" },
      },
   }

   -- Every attacking mode takes the kill the moment it is there: purity on their health,
   -- absolve on their mana, and the sap that brings absolve in reach (M.MOVES.killSap).
   -- A shield is stripped before anything but purity meets it ("Dazzle and purity bypass
   -- shield", Anzerloi, 14:43:48), and heresy goes up the moment a mace blow would rebound.
   -- Defence holds the attack; the rest are attacks.
   for name, mode in pairs(M.MODES) do
      if name ~= "defence" then
         local raisesHeresy = mode.equilibrium[1] == "heresy"
         if not raisesHeresy then table.insert(mode.equilibrium, 1, "heresyIfRebounding") end
         for _, move in ipairs({ "killRead", "killSap", "absolve", "strip", "purity" }) do
            table.insert(mode.equilibrium, 1, move)
         end
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
      local gives = move.gives
      if type(gives) == "function" then gives = gives(ctx) end
      if gives and ctx.afflictions[gives] then return false end
      -- A move that gives a mental waits until it may (M.mentalsAllowed), unless it is part
      -- of a sequence that is its own reason, as fasting once they are slick is.
      if gives and not move.mentalOk and isMental(gives) and not M.mentalsAllowed(ctx) then
         return false
      end
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
   --- that is due, and goes when none is. An ALTERNATING mode (hinder) has one due most
   --- prompts, so there the two take turns, the mace first.
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
      -- What it takes from their mana, for the estimate.
      if move.skill == "sap" or move.verse == "wrath" then
         M.drains[ctx.target] = M.drains[ctx.target] or {}
         table.insert(M.drains[ctx.target], { at = now, percent = P.sapPercent(ctx.afflictions,
            { via = move.verse == "wrath" and "wrath" or "angel" }) })
      end
      if move.skill == "panic" then M.panicAt = now end
      if move.lane == "balance" then contemplateWithBlow(M.MODES[ctx.mode], ctx) end
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

   --- THE KILL WINDOW, for the alert (pvp.lua). Rows of { what, state, detail }: absolve
   --- now on a real reading, in range or a sap away by the estimate; judge while they are
   --- locked, or have justice. Judge's times are Anzerloi's ("I think 12 seconds. 6 if
   --- afflicted with justice. Again, I think", 2026-10-23 18:05); nothing sends it.
   function M.killRows(ctx)
      local rows = {}
      if have.skill("absolve") then
         local estimate = M.manaEstimate(ctx)
         if freshMana(ctx) and P.absolveKills(ctx.mana.percent) then
            rows[#rows + 1] = { "ABSOLVE", "now", ("mana %d%%, read %.0fs ago"):format(
               ctx.mana.percent, util.now() - ctx.mana.at) }
         elseif P.absolveKills(estimate) then
            rows[#rows + 1] = { "ABSOLVE", "in range", ("about %d%% by estimate; reading it")
               :format(estimate) }
         elseif P.absolveKills(P.sapAfter(estimate, ctx.afflictions)) then
            rows[#rows + 1] = { "ABSOLVE", "a sap away", ("about %d%% by estimate"):format(estimate) }
         end
      end
      if have.skill("judge") then
         if ctx.afflictions.justice then
            rows[#rows + 1] = { "JUDGE", "about 6s", "justice is on them" }
         elseif ctx.locks and #ctx.locks > 0 then
            rows[#rows + 1] = { "JUDGE", "about 12s", "locked; condemnation's justice halves it" }
         end
      end
      return rows
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
         M.panicAt, M.slickAt = nil, nil
         P.targetLimbs = {}
         M.drains, M.fightAt = {}, util.now()
      end, "priest-pvp")
   end
   -- Slickness confirmed on the target: a panic may follow once it is eaten away.
   emunah.event.register("emunah.opponent.afflicted", function(_, name, affliction)
      local target = emunah.pvp and emunah.pvp.target
      if affliction == "slickness" and target and name == tostring(target):lower() then
         M.slickAt = util.now()
      end
   end, "priest-pvp")
   -- The prayer ended (priest.prayerReset()): the next verse starts the next one.
   emunah.event.register("emunah.priest.prayerEnded", function()
      M.lastKind = M.prayerKind or M.lastKind
      M.prayerKind = nil
   end, "priest-pvp")

   P.pvp = M
   P.pvpPlan = M.plan
   P.pvpSend = M.send
   P.pvpDefer = M.defer
   P.pvpKillRows = M.killRows
   P.PVP_MODES = M.MODES
end

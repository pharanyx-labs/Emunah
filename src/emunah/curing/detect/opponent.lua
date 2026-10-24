--- Opponent affliction tracking.
---
--- The PvP counterpart to curing/engine.lua's M.tracked, but for someone else's
--- afflictions. There is no GMCP equivalent for this -- Char.Afflictions only ever reports
--- YOUR OWN state -- so everything here has to come from third-person combat text, and the
--- same discipline that governs curing/detect/patterns.lua applies: a pattern that fires on
--- the wrong line asserts an affliction on the wrong person, which is worse than not
--- knowing. Grow this from learn mode (`detect.startLearning()`) transcripts of real fights, not from memory --
--- see patterns.lua's header for the reasoning this module inherits wholesale.
---
--- This file ships with NO patterns, deliberately -- it is framework, not corpus, exactly
--- like detect/init.lua shipped before patterns.lua had anything in it. The corpus lives
--- wherever self-affliction patterns do (patterns.lua, or a sibling file), added via
--- M.add() once real third-person messages are on hand.
---
--- PATTERN SHAPE
--- -------------
--- Achaea's third-person combat messages name the actor, so a pattern here needs exactly
--- one capture group for that name -- Mudlet puts it in matches[2]:
---
---   opponent.add("paralysis", [[^(\w+) collapses, paralysed\.$]])
---
--- WHY AGE, NOT RECONCILE
--- ----------------------
--- curing/engine.lua's reconcile() works because Char.Afflictions.List is authoritative for
--- YOUR OWN state -- if the game does not mention an affliction, and the record came from
--- GMCP, it is gone. There is no equivalent feed for an opponent, so there is nothing to
--- reconcile against: an entry here can only be retracted by another trigger (if one is
--- ever written for the relevant cure-side message) or aged out by M.prune(). Callers that
--- plan around this data should treat every entry as "true as of `since`", not "true now".

local M = {}

local log   = emunah.log
local event = emunah.event

--- name (lower) -> { affliction (lower) -> since }
M.tracked = {}

--- Trigger ids live on _persist so a reload can kill the previous generation -- same
--- problem, and same fix, as curing/detect/init.lua and core/event.lua.
local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.opponentTriggers = emunah._persist.opponentTriggers or {}
   return emunah._persist.opponentTriggers
end

--- Remove every trigger this module owns.
function M.killAll()
   local reg = registry()
   local n = 0
   for _, id in ipairs(reg) do
      if killTrigger(id) then n = n + 1 end
   end
   emunah._persist.opponentTriggers = {}
   return n
end

-- ---------------------------------------------------------------------------
-- registration
-- ---------------------------------------------------------------------------

--- Register a third-person gain pattern for an affliction. The pattern's one capture group
--- must be the actor's name.
--- @param affliction string
--- @param pattern string a Mudlet-flavoured (PCRE) regex with one capture group
--- @return boolean
function M.add(affliction, pattern)
   affliction = tostring(affliction or ""):lower()
   if affliction == "" or type(pattern) ~= "string" then return false end

   local id = tempRegexTrigger(pattern, function()
      local name = matches and matches[2]
      if type(name) ~= "string" or name == "" then return end
      M.assert(name, affliction)
   end)

   if not id then
      log.error("Could not create an opponent trigger for %s.", affliction)
      return false
   end

   table.insert(registry(), id)
   return true
end

--- Register a third-person CURE pattern: retracts the affliction instead of asserting it.
--- A handful of these exist even though there's no general reconcile path (see the module
--- header) -- specific messages like "writhed free of the ropes" are a real, unambiguous
--- confirmation when Achaea happens to say them, same principle as patterns.lua's cure-side
--- entries. A separate function rather than overloading M.add(), so the existing two-arg
--- gain signature stays unchanged.
--- @param affliction string
--- @param pattern string a Mudlet-flavoured (PCRE) regex with one capture group
--- @return boolean
function M.addCure(affliction, pattern)
   affliction = tostring(affliction or ""):lower()
   if affliction == "" or type(pattern) ~= "string" then return false end

   local id = tempRegexTrigger(pattern, function()
      local name = matches and matches[2]
      if type(name) ~= "string" or name == "" then return end
      M.curedNamed(name, affliction)
   end)

   if not id then
      log.error("Could not create an opponent cure trigger for %s.", affliction)
      return false
   end

   table.insert(registry(), id)
   return true
end

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

--- Record that an opponent has an affliction. Exposed directly (not just as a trigger
--- callback) so tests, and any future non-regex source, can drive it without a trigger.
function M.assert(name, affliction)
   name = tostring(name or ""):lower()
   affliction = tostring(affliction or ""):lower()
   if name == "" or affliction == "" then return false end

   M.tracked[name] = M.tracked[name] or {}
   M.tracked[name][affliction] = emunah.util.now()
   M.odds[name] = M.odds[name] or {}
   M.odds[name][affliction] = 1
   if M.suspected[name] then M.suspected[name][affliction] = nil end
   event.raise("opponent.afflicted", name, affliction)
   return true
end

--- Retract one affliction for one opponent, or everything known about them.
function M.forget(name, affliction)
   name = tostring(name or ""):lower()
   local afflictions = M.tracked[name]
   if not afflictions then return false end

   if affliction then
      afflictions[tostring(affliction):lower()] = nil
   else
      M.tracked[name] = nil
      M.odds[name], M.suspected[name] = nil, nil
   end
   return true
end

function M.has(name, affliction)
   local afflictions = M.tracked[tostring(name or ""):lower()]
   if not afflictions then return false end
   return afflictions[tostring(affliction or ""):lower()] ~= nil
end

--- Every affliction currently tracked for one opponent, sorted.
function M.list(name)
   local out = {}
   for affliction in pairs(M.tracked[tostring(name or ""):lower()] or {}) do
      out[#out + 1] = affliction
   end
   table.sort(out)
   return out
end

--- Count afflictions for one opponent, or across everyone tracked.
function M.count(name)
   if name then
      return emunah.util.count(M.tracked[tostring(name):lower()] or {})
   end
   local total = 0
   for _, afflictions in pairs(M.tracked) do
      total = total + emunah.util.count(afflictions)
   end
   return total
end

--- Drop entries older than maxAge seconds. Not wired to a timer -- there is not yet a
--- consumer whose real needs would tell us the right default, and inventing one without
--- data is exactly the kind of guess this module otherwise avoids. Call it explicitly
--- (e.g. when a PvP session ends) until something in Phase 3 needs it continuously.
function M.prune(maxAge)
   maxAge = tonumber(maxAge) or 30
   local now = emunah.util.now()
   for name, afflictions in pairs(M.tracked) do
      for affliction, since in pairs(afflictions) do
         if now - since > maxAge then afflictions[affliction] = nil end
      end
      if not next(afflictions) then M.tracked[name] = nil end
   end
end

function M.clear(name)
   if name then
      name = tostring(name):lower()
      M.tracked[name] = nil
      if M.used then M.used[name] = nil end
      if M.defences then M.defences[name] = nil end
      if M.focuses then M.focuses[name] = nil end
      if M.lastEat then M.lastEat[name] = nil end
      if M.eatenAt then M.eatenAt[name] = nil end
      M.odds[name], M.suspected[name], M.lastSpread[name] = nil, nil, nil
      if M.history then M.history[name] = nil end
   else
      M.tracked, M.used, M.defences, M.focuses, M.lastEat = {}, {}, {}, {}, {}
      M.eatenAt, M.odds, M.suspected, M.lastSpread = {}, {}, {}, {}
      M.history = {}
   end
end

-- Drop the previous generation before installing this one.
-- ---------------------------------------------------------------------------
-- cure lines: what an opponent is seen eating
-- ---------------------------------------------------------------------------
--
-- "As for pvp you go on afflict lines and cure lines" (Anzerloi, 2026-10-15 19:27:11).
-- `Anzerloi eats an aurum flake.` (13:58:10) names the herb by its description, which the
-- rift listing pairs with the commodity (gmcp/ire.lua's riftFind) -- so no table of
-- descriptions is kept here to go stale. One eat cures one affliction: of those tracked on
-- them that this herb cures, the first in the cure table's order goes, which is the order a
-- curing system eats in. An herb that cures nothing tracked, or a description the rift does
-- not know, retracts nothing.

--- Every item afflist and deflist cure or raise with, as a set: the commodity names.
local curatives = nil
local function curativeItems()
   if curatives then return curatives end
   curatives = {}
   local afflist = emunah.curing.afflist
   local function take(option)
      if option.item then curatives[option.item] = true end
      if option.alt then curatives[option.alt] = true end
   end
   for _, entry in pairs(afflist.afflictions) do
      for _, option in ipairs(entry.cures or {}) do take(option) end
   end
   for _, option in pairs(afflist.defenceCures) do take(option) end
   for _, entry in pairs(emunah.curing.deflist.commands) do
      if entry.item then curatives[entry.item] = true end
   end
   -- Moss cures no affliction, so the tables above never name it: "Anzerloi eats a potash
   -- crystal." went unseen (2026-10-24 14:33:30), and with it the mana it gave him back.
   curatives.irid, curatives.potash = true, true
   return curatives
end

--- The commodity an eaten item's description names, or nil. The rift's own listing pairs a
--- description with its commodity; failing that, a word of the description that IS a
--- commodity's name -- `a kola nut`, `a hawthorn berry`, `an aurum flake` (20:29:34 and
--- 13:58:10, 2026-10-15) -- so an herb we hold none of is still recognised.
function M.itemFromDescription(desc)
   desc = tostring(desc or ""):lower():gsub("^an? ", ""):gsub("^some ", "")
   local ire = emunah.gmcp and emunah.gmcp.ire
   local entry = ire and ire.riftFind and ire.riftFind(desc)
   if entry and entry.name then return entry.name end
   local known = curativeItems()
   for word in desc:gmatch("%a+") do
      if known[word] then return word end
   end
   return nil
end

-- ---------------------------------------------------------------------------
-- what they can still cure with, and how close they are to a lock
-- ---------------------------------------------------------------------------
--
-- "Prone, asthmatic, slick, impatient, broken limbs ... missing anorexia and paralysis for
-- lock." "They can't salve, because they're slick. They can't puff the slickness because
-- they're asthmatic. As soon as anorexia hits, no hope of eating for asthma to clear that
-- slickness too." (Anzerloi, party, 2026-10-15 20:25:57-20:30:28.) That is afflist.blocks
-- read for someone else, and watch.lua's locks judged on their afflictions.

--- Their curing routes shut by what they have: vector -> the affliction shutting it.
function M.blockedVectors(name)
   local out = {}
   local blocks = emunah.curing.afflist.blocks
   for affliction in pairs(M.tracked[tostring(name or ""):lower()] or {}) do
      for _, vector in ipairs(blocks[affliction] or {}) do
         out[vector] = out[vector] or affliction
      end
   end
   return out
end

--- The locks they are in, and what each other lock still needs. See watch.lockProgress().
--- By the odds, an even chance or better: an aurum on asthma and another kelp affliction
--- leaves neither certain, and a lock read off the confirmed list would still hold.
M.LOCK_AT = 0.5
function M.lockProgress(name)
   name = tostring(name or ""):lower()
   local odds = M.oddsFor(name)
   return emunah.watch.lockProgress(function(affliction)
      return (odds[affliction] or 0) >= M.LOCK_AT
   end)
end

--- How many of the lock's afflictions must already be on them before it is worth chasing.
--- A tuning number, not a game fact: with fewer, every mode would chase the same two
--- afflictions from the first blow and the modes would mean nothing.
M.LOCK_BUILDING = 2

--- What to give them next to close a lock: the afflictions both the hard and the venom lock
--- still need, together -- slickness, anorexia and asthma shut eating, smoking and salving;
--- impatience shuts focus; paralysis shuts the tree. That union is the lock Anzerloi builds
--- toward (20:26:06: "Missing anorexia and paralysis for lock."). Empty once it is held, and
--- until M.LOCK_BUILDING of it are on them.
function M.lockNeeds(name)
   local _, missing = M.lockProgress(name)
   local out, seen = {}, {}
   for _, lock in ipairs({ "hard", "venom" }) do
      for _, affliction in ipairs(missing[lock] or {}) do
         if not seen[affliction] then
            seen[affliction] = true
            out[#out + 1] = affliction
         end
      end
   end
   -- The union is five afflictions: slickness, anorexia, asthma, impatience, paralysis.
   if 5 - #out < M.LOCK_BUILDING then return {} end
   return out
end

-- ---------------------------------------------------------------------------
-- the odds: how likely each affliction is to be on them
-- ---------------------------------------------------------------------------
--
-- Anzerloi, 2026-10-24 15:20:11-15:21:50: "Iterate over target's existing affs. Preferably
-- in percent probabilities value ... Each of these relative to that aff's probability. If
-- 50% I got spiritburn, then + (3.5/0.5)" -- times, by the sense of it: an affliction half
-- likely counts half. And "Afftracking is really the first thing you should implement,
-- before any thought of attack protocol" (15:45:44).
--
-- M.tracked stays the confirmed picture the locks and the rest decide on. Beside it,
-- M.odds[name][affliction] is a chance from 0 to 1. A landing line makes it 1, and so does
-- a verse we sent, which prints none (M.suspect). A cure that could have taken any of
-- several shares itself among them by their chances (spread): one argentum with guilt,
-- spiritburn and tenderskin all certain leaves each at two in three. A line naming what
-- went takes that one off and gives back what the eat was charged to the others.

--- name -> affliction -> chance, 0 to 1.
M.odds = {}
--- name -> affliction -> when we sent what gives it, for those never confirmed. A suspicion
--- no landing line has confirmed lapses after M.SUSPECT_FOR: a verse can fail unseen.
M.suspected = {}
M.SUSPECT_FOR = 12
--- name -> { at, before = { affliction -> chance } }: the last cure shared out.
M.lastSpread = {}

local function setOdds(name, affliction, chance)
   M.odds[name] = M.odds[name] or {}
   M.odds[name][affliction] = chance
end

--- We sent something that gives `affliction` and nothing says whether it landed. `chance`
--- (default 1) is for one that lands only on a condition we are unsure of: heresy's
--- inquisition needs guilt and spiritburn both on them as it goes.
function M.suspect(name, affliction, chance)
   name = tostring(name or ""):lower()
   affliction = tostring(affliction or ""):lower()
   if name == "" or affliction == "" then return false end
   chance = math.max(0, math.min(1, tonumber(chance) or 1))
   if chance <= 0 then return false end
   setOdds(name, affliction, math.max(chance, (M.odds[name] or {})[affliction] or 0))
   M.suspected[name] = M.suspected[name] or {}
   M.suspected[name][affliction] = emunah.util.now()
   return true
end

--- The odds for `name` as a table, affliction -> chance (0 included: known gone), with
--- lapsed suspicions dropped. Afflictions confirmed before any odds were kept count 1.
function M.oddsFor(name)
   name = tostring(name or ""):lower()
   local odds = M.odds[name] or {}
   local suspected = M.suspected[name] or {}
   local now = emunah.util.now()
   for affliction, at in pairs(suspected) do
      if now - at > M.SUSPECT_FOR then
         suspected[affliction] = nil
         odds[affliction] = nil
      end
   end
   local out = {}
   for affliction, chance in pairs(odds) do out[affliction] = chance end
   for affliction in pairs(M.tracked[name] or {}) do
      if out[affliction] == nil then out[affliction] = 1 end
   end
   return out
end

--- The chance `affliction` is on `name`, 0 to 1.
function M.chance(name, affliction)
   return M.oddsFor(name)[tostring(affliction or ""):lower()] or 0
end

--- One cure that `cures` allows, shared among what it could have taken, by their chances:
--- with a total over one, each keeps 1 - 1/total of its chance; with one or less, it took
--- them all.
local function spread(name, cures)
   local before, total = {}, 0
   for affliction, chance in pairs(M.oddsFor(name)) do
      if chance > 0 and cures(affliction) then
         before[affliction] = chance
         total = total + chance
      end
   end
   if total <= 0 then return end
   local keep = total > 1 and (1 - 1 / total) or 0
   for affliction, chance in pairs(before) do setOdds(name, affliction, chance * keep) end
   M.lastSpread[name] = { at = emunah.util.now(), before = before }
end

--- A line names the one affliction just cured: it is gone, and a cure shared out a moment
--- before is given back to the rest.
local function namedOdds(name, affliction)
   local last = M.lastSpread[name]
   if last and last.before[affliction] and emunah.util.now() - last.at <= 2.0 then
      for other, chance in pairs(last.before) do setOdds(name, other, chance) end
      M.lastSpread[name] = nil
   end
   setOdds(name, affliction, 0)
   if M.suspected[name] then M.suspected[name][affliction] = nil end
end

local function herbCures(item)
   return function(affliction)
      for _, option in ipairs(emunah.curing.afflist.curesVia(affliction, "herb")) do
         if option.item == item or option.alt == item then return true end
      end
      return false
   end
end

-- ---------------------------------------------------------------------------
-- what they are seen using, and what they raise
-- ---------------------------------------------------------------------------

--- name -> vector -> when they were last seen curing through it.
M.used = {}
--- name -> defence -> when it was seen going up.
M.defences = {}

--- name -> vector -> times seen, oldest first: for counting what they did since a moment.
M.history = {}

local function used(name, vector)
   name = name:lower()
   local now = emunah.util.now()
   M.used[name] = M.used[name] or {}
   M.used[name][vector] = now
   M.history[name] = M.history[name] or {}
   M.history[name][vector] = M.history[name][vector] or {}
   table.insert(M.history[name][vector], now)
end

--- How many times `name` was seen using `vector` (sip, moss, herb, salve, smoke, tree,
--- focus) after `since`.
function M.usesSince(name, vector, since)
   local n = 0
   for _, at in ipairs(((M.history[tostring(name or ""):lower()] or {})[vector]) or {}) do
      if at > since then n = n + 1 end
   end
   return n
end

--- Seconds since `name` was seen curing through `vector`, or nil.
function M.usedAgo(name, vector)
   local at = (M.used[tostring(name or ""):lower()] or {})[vector]
   return at and emunah.util.now() - at or nil
end

function M.defenceUp(name, defence)
   name = tostring(name or ""):lower()
   M.defences[name] = M.defences[name] or {}
   M.defences[name][defence] = emunah.util.now()
   event.raise("opponent.defence", name, defence)
end

function M.defenceDown(name, defence)
   local defences = M.defences[tostring(name or ""):lower()]
   if defences then defences[defence] = nil end
end

function M.hasDefence(name, defence)
   return (M.defences[tostring(name or ""):lower()] or {})[defence] ~= nil
end

--- Their defences seen going up, sorted.
function M.defenceList(name)
   local out = {}
   for defence in pairs(M.defences[tostring(name or ""):lower()] or {}) do out[#out + 1] = defence end
   table.sort(out)
   return out
end

--- Herbs that raise a defence when eaten: deflist's item defences on the herb vector, by the
--- same tables keep-up raises them with (kola, myrrh, echinacea, skullcap, hawthorn,
--- bayberry), mineral alternatives included.
local defenceItems = nil
local function defenceFromItem(item)
   if not defenceItems then
      defenceItems = {}
      for defence, option in pairs(emunah.curing.afflist.defenceCures) do
         if option.vector == "herb" then
            if option.item then defenceItems[option.item] = defence end
            if option.alt then defenceItems[option.alt] = defence end
         end
      end
      for defence, entry in pairs(emunah.curing.deflist.commands) do
         if entry.vector == "herb" and entry.item then defenceItems[entry.item] = defence end
      end
   end
   return defenceItems[item]
end

--- Irid moss and potash have a balance of their own (docs/game/balance.md).
local MOSS = { irid = true, potash = true }

--- `name` ate the item described as `desc`: a cure for what it cures, a defence for what it
--- raises, and their herb (or moss) balance spent.
function M.ate(name, desc)
   local item = M.itemFromDescription(desc)
   if not item then return nil end
   used(name, MOSS[item] and "moss" or "herb")
   spread(name:lower(), herbCures(item))
   local cured, since
   if M.tracked[name:lower()] then cured, since = M.curedBy(name, item) end
   M.lastEat[name:lower()] = { item = item, cured = cured, since = since, at = emunah.util.now() }
   M.eatenAt[name:lower()] = M.eatenAt[name:lower()] or {}
   M.eatenAt[name:lower()][item] = emunah.util.now()
   local defence = defenceFromItem(item)
   if defence and not cured then M.defenceUp(name, defence) end
   return item, cured
end

--- `name` ate `item`: retract the tracked affliction it cures first. Returns it, or nil.
function M.curedBy(name, item)
   name = tostring(name or ""):lower()
   local tracked = M.tracked[name]
   if not (tracked and item) then return nil end
   local afflist = emunah.curing.afflist
   local best, bestRank
   for affliction in pairs(tracked) do
      for _, option in ipairs(afflist.curesVia(affliction, "herb")) do
         if option.item == item or option.alt == item then
            local rank = afflist.priority(affliction, "herb") or math.huge
            if not best or rank < bestRank then best, bestRank = affliction, rank end
         end
      end
   end
   local since = best and tracked[best]
   if best then M.forget(name, best) end
   return best, since
end

--- name -> the last thing they ate: { item, cured, since, at }. Read by M.breathHeld().
M.lastEat = {}
--- name -> item -> when they last ate it. Read by M.couldHaveCured().
M.eatenAt = {}

--- Could `name` have cured `affliction` since `since`? True when they ate one of its herbs
--- (or its mineral), or used any other route that cures it -- focus, tree, salve, smoke --
--- after that moment. Which affliction an eat or a tree took is often not known, so this
--- only ever answers "maybe": the offence uses it to doubt an affliction it gave but never
--- saw land, never to believe one.
function M.couldHaveCured(name, affliction, since)
   name = tostring(name or ""):lower()
   local afflist = emunah.curing.afflist
   local eaten = M.eatenAt[name] or {}
   for _, option in ipairs(afflist.curesVia(affliction, "herb")) do
      if (eaten[option.item] or 0) > since or (option.alt and (eaten[option.alt] or 0) > since) then
         return true
      end
   end
   local used = M.used[name] or {}
   for _, vector in ipairs(afflist.vectorsFor(affliction)) do
      if vector ~= "herb" and (used[vector] or 0) > since then return true end
   end
   local tree = emunah.curing.treefunc
   if tree and tree.CURABLE and tree.CURABLE[affliction] and (used.tree or 0) > since then
      return true
   end
   return false
end

--- How soon after an eat a held breath says what that eat cured. A tuning number: the
--- breath is held "immediately" on the cure (Anzerloi, 2026-10-23 14:30:05).
M.BREATH_AFTER_EAT = 2.0

--- `name` began holding their breath, so asthma is not on them: "You can't do any breathing
--- stuff with asthma" (Anzerloi, 2026-10-23 14:29:10). "If they cure asthma while
--- upkeeping breathing and are on balance, they immediately start holding breath. So if
--- they have multiple kelp affs, eat kelp and hold breath, confirm asthma, other kelp affs
--- untouched" (14:30:05-14:30:21). So when the eat just before it took a different kelp
--- affliction off by rank, that one goes back as it was and asthma comes off instead.
function M.breathHeld(name)
   M.curedNamed(name, "asthma")
end

--- A line names what `name` just cured. When an eat a moment before took a different
--- affliction off by rank, and its herb cures this one, the eat cured this one: the other
--- goes back as it was. "Anzerloi eats an argentum flake." then "Anzerloi straightens, as
--- if some great burden had been lifted from his shoulders." (2026-10-23 17:43:58) is guilt
--- cured, not the recklessness the flake would otherwise have been charged with.
function M.curedNamed(name, affliction)
   name = tostring(name or ""):lower()
   namedOdds(name, affliction)
   local eat = M.lastEat[name]
   if eat and eat.cured and eat.cured ~= affliction
      and emunah.util.now() - eat.at <= M.BREATH_AFTER_EAT then
      for _, option in ipairs(emunah.curing.afflist.curesVia(affliction, "herb")) do
         if option.item == eat.item or option.alt == eat.item then
            M.tracked[name] = M.tracked[name] or {}
            M.tracked[name][eat.cured] = eat.since or emunah.util.now()
            eat.cured = affliction
            break
         end
      end
   end
   M.forget(name, affliction)
end

--- name -> times they were seen focusing, oldest first. For the mana a focus costs them.
M.focuses = {}

--- Take off the one tracked affliction `cures` allows, when there is exactly one. With two
--- or more, which went is not known, and both stay.
local function curedOneOf(name, cures)
   local only
   for affliction in pairs(M.tracked[name] or {}) do
      if cures(affliction) then
         if only then return nil end
         only = affliction
      end
   end
   if only then M.forget(name, only) end
   return only
end

--- `name` focused: one mental cured, and their mana spent.
function M.focused(name)
   name = tostring(name or ""):lower()
   used(name, "focus")
   M.focuses[name] = M.focuses[name] or {}
   table.insert(M.focuses[name], emunah.util.now())
   local function cures(affliction)
      return #emunah.curing.afflist.curesVia(affliction, "focus") > 0
   end
   spread(name, cures)
   return curedOneOf(name, cures)
end

--- `name` rubbed a salve on `location`: legs, arms, head, torso or body, and "skin" is the
--- body. One tracked affliction a salve there cures, cured, when it is the only one. The
--- line does not say which salve, so with two or more both stay.
function M.salved(name, location)
   name = tostring(name or ""):lower()
   used(name, "salve")
   location = location == "skin" and "body" or tostring(location or "")
   local function cures(affliction)
      for _, option in ipairs(emunah.curing.afflist.curesVia(affliction, "salve")) do
         if option.location == location then return true end
      end
      return false
   end
   spread(name, cures)
   return curedOneOf(name, cures)
end

--- `name` stood against an angel's push. A push with a smite prones only a target with
--- inquisition (Anzerloi, 2026-10-24 14:04:50), so they have none: it comes off, and the
--- offence hears it to stop believing its rebuke gave it.
function M.pushResisted(name)
   name = tostring(name or ""):lower()
   M.forget(name, "inquisition")
   setOdds(name, "inquisition", 0)
   if M.suspected[name] then M.suspected[name].inquisition = nil end
   event.raise("opponent.pushResisted", name)
end

--- `name` smoked a pipe: "Anzerloi takes a long drag off his pipe." (2026-10-24 14:34:08.80,
--- 1.6s after a Revelations whose hellsight had landed). The line does not say which herb,
--- so one affliction any pipe cures is shared out among them; with one, it is cured. And
--- they could smoke, so asthma was not on them.
function M.smoked(name)
   name = tostring(name or ""):lower()
   used(name, "smoke")
   local function cures(affliction)
      return #emunah.curing.afflist.curesVia(affliction, "smoke") > 0
   end
   spread(name, cures)
   M.forget(name, "asthma")
   setOdds(name, "asthma", 0)
   return curedOneOf(name, cures)
end

--- `name` touched the tree: one affliction it can cure, cured.
function M.treeTouched(name)
   name = tostring(name or ""):lower()
   used(name, "tree")
   local tree = emunah.curing.treefunc
   local function cures(affliction)
      return tree ~= nil and tree.CURABLE ~= nil and tree.CURABLE[affliction] == true
   end
   spread(name, cures)
   return curedOneOf(name, cures)
end

--- How many times `name` focused since `since`.
function M.focusesSince(name, since)
   local n = 0
   for _, at in ipairs(M.focuses[tostring(name or ""):lower()] or {}) do
      if at >= since then n = n + 1 end
   end
   return n
end

--- Register a line with one capture, the actor, that calls `fn(name)`.
function M.watchLine(pattern, fn)
   local id = tempRegexTrigger(pattern, function()
      local name = matches and matches[2]
      if name then fn(name) end
   end)
   if id then table.insert(registry(), id) end
   return id ~= nil
end

--- Register the line that says `name` began holding their breath. One capture, the actor.
function M.watchBreath(pattern)
   local id = tempRegexTrigger(pattern, function()
      local name = matches and matches[2]
      if name then M.breathHeld(name) end
   end)
   if id then table.insert(registry(), id) end
   return id ~= nil
end

--- Watch for opponents eating. Called with the pattern corpus (opponent_patterns.lua), so a
--- reload re-registers it with everything else this module owns.
function M.watchEats()
   local id = tempRegexTrigger([[^(\w+) eats (.+)\.$]], function()
      local name, desc = matches and matches[2], matches and matches[3]
      if not (name and desc) then return end
      M.ate(name, desc)
   end)
   if id then table.insert(registry(), id) end
   return id ~= nil
end

--- Register a line that says `name` cured through `vector`, or raised `defence`: one
--- capture, the actor. See opponent_patterns.lua for the lines and their evidence.
function M.watchUse(vector, pattern)
   local id = tempRegexTrigger(pattern, function()
      local name = matches and matches[2]
      if name then used(name, vector) end
   end)
   if id then table.insert(registry(), id) end
   return id ~= nil
end

function M.watchDefence(defence, pattern)
   local id = tempRegexTrigger(pattern, function()
      local name = matches and matches[2]
      if name then M.defenceUp(name, defence) end
   end)
   if id then table.insert(registry(), id) end
   return id ~= nil
end

--- A tattoo touched: its name is the defence, for the tattoos keep-up raises by touching
--- (deflist.commands: `touch cloak`, `touch mindseye`, `touch shield`).
function M.watchTattoos()
   local tattoos = {}
   for defence, entry in pairs(emunah.curing.deflist.commands) do
      local tattoo = tostring(entry.command or ""):match("^touch (%a+)$")
      if tattoo then tattoos[tattoo] = defence end
   end
   local id = tempRegexTrigger([[^(\w+) touches an? (\w+) tattoo\.$]], function()
      local name, tattoo = matches and matches[2], matches and matches[3]
      if name and tattoo and tattoos[tattoo:lower()] then M.defenceUp(name, tattoos[tattoo:lower()]) end
   end)
   if id then table.insert(registry(), id) end
   return id ~= nil
end

M.killAll()

event.register("sysDisconnectionEvent", function()
   M.tracked, M.used, M.defences, M.lastEat, M.focuses = {}, {}, {}, {}, {}
end, "pvp.opponent")

-- Publish before loading the pattern file, same reason as curing/detect/init.lua:
-- opponent_patterns.lua reaches back through emunah.curing.detect.opponent to register
-- itself, and that path does not exist until this module returns unless published here.
emunah.curing = emunah.curing or {}
emunah.curing.detect = emunah.curing.detect or {}
emunah.curing.detect.opponent = M

package.loaded["emunah.curing.detect.opponent_patterns"] = nil
local ok, err = pcall(require, "emunah.curing.detect.opponent_patterns")
if not ok then
   log.warn("No opponent detection patterns loaded: %s", tostring(err))
end

return M

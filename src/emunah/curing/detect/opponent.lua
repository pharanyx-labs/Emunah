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
      M.forget(name, affliction)
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
   else
      M.tracked, M.used, M.defences = {}, {}, {}
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
function M.lockProgress(name)
   name = tostring(name or ""):lower()
   return emunah.watch.lockProgress(function(affliction) return M.has(name, affliction) end)
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
-- what they are seen using, and what they raise
-- ---------------------------------------------------------------------------

--- name -> vector -> when they were last seen curing through it.
M.used = {}
--- name -> defence -> when it was seen going up.
M.defences = {}

local function used(name, vector)
   name = name:lower()
   M.used[name] = M.used[name] or {}
   M.used[name][vector] = emunah.util.now()
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
   local cured = M.tracked[name:lower()] and M.curedBy(name, item) or nil
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
   if best then M.forget(name, best) end
   return best
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
   M.tracked, M.used, M.defences = {}, {}, {}
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

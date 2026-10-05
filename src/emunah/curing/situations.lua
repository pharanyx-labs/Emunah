--- Situational curing: rules that move or hold a cure while a particular situation holds.
---
--- afflist's ranks are svof's, and fixed: weariness is always 33, guilt always 59. That is
--- right on average and wrong in particular fights, and the fight that showed it was an
--- arena loss to a Priest (2026-10-05, 07:33:12-07:33:38): weariness re-applied every round
--- took 6 of 13 herb eats, guilt and spiritburn were never eaten once, and so inquisition --
--- which only ends when both are gone -- held focus and the hellsight cure shut until the
--- end. A fixed list cannot express "guilt matters more while inquisition is up".
---
--- A rule says WHEN (afflictions present, health, whether anything is attacking, an
--- affliction coming straight back after its cure) and WHAT: re-rank an affliction on one
--- vector, or hold it -- on some vectors, or on all of them. M.evaluate() runs once per
--- tick, from the engine's classify(), and the engine reads the answer through M.rank() and
--- M.held(); nothing else about curing changes. Every rule carries the evidence for it:
--- they are rulings on transcripts and on what the game says, not svof's, and the same bar
--- applies to adding one as to any other game mechanic (CLAUDE.md, docs/game/curing.md
--- *Situational rules*).
---
--- Names here are afflist's own keys. The server's names reach them through afflist.ALIASES
--- (`weariness` is `weakness`, `burning` is `ablaze`), so a rule written once matches either.

local M = {}

local util    = emunah.util
local log     = emunah.log
local afflist = emunah.curing.afflist

--- A hold on every vector.
M.ALL = true

M.RULES = {
   -- INQUISITION ENDS WHEN GUILT AND SPIRITBURN DO. The server's description (Char.Afflictions
   -- .Add, 07:33:19.64): "It cures once the victim has rid themselves of both guilt and
   -- spiritburn afflictions, and is no longer prone." Confirmed by the Priest who cast it
   -- (tell, 07:50:06): "Inquisition is cured when you clear all of - guilt, spiritburn,
   -- prone." It shuts focus and keeps valerian off hellsight, and at svof's ranks (guilt 59,
   -- spiritburn 61) both sat behind weariness and justice for the whole fight. Ranked just
   -- behind paralysis and the 7s; ahead of impatience (8), which shuts focus too but cannot
   -- reopen it while inquisition holds it shut. Prone is the third key, and already has its
   -- own answer (curing/detect's STAND).
   {
      id   = "inquisition-unlock",
      when = { has = { "inquisition" } },
      rank = { guilt = { herb = 7.5 }, spiritburn = { herb = 7.5 } },
   },

   -- INQUISITION BLOCKS CURING BURNING. From the Priest who cast it, by tell (07:51:40-ish,
   -- relayed by the user): "Also inquisition blocks curing of burning. Salves will fail, tree
   -- will take them out of its pool of possible cures if inquisition is there." Read narrowly
   -- -- the salve FOR BURNING fails, and the tree will not pick burning -- until the wider
   -- reading (every salve fails) is confirmed. Holding the salve keeps a mending from being
   -- wasted; holding the tree keeps touch tree from being spent on something it skips.
   {
      id   = "inquisition-burning",
      when = { has = { "inquisition" } },
      hold = { ablaze = { salve = true, tree = true } },
      why  = "inquisition",
   },

   -- PARALYSIS FIRST WHILE IT HOLDS THE HEALING. Paralysis holds the elixir sip and `perform
   -- hands` (queue.WHILE_PARALYSED; play evidence in curing.md). At 07:33:37.12 it landed at
   -- 18% health together with asthma, asthma's 4 beat its 6, kelp went first at 37.77, and
   -- elixir balance (37.26) and equilibrium (38.33) came back with nothing able to use them
   -- before the last smite. Below the health-sip threshold bloodroot goes ahead of asthma.
   {
      id   = "paralysis-holds-healing",
      when = { has = { "paralysis" }, healthBelow = "curing.healthThreshold" },
      rank = { paralysis = { herb = 3.5 } },
   },

   -- AN AFFLICTION RE-APPLIED EVERY ROUND IS NOT WORTH A HERB EVERY ROUND. The sin of sloth
   -- put weariness back 0.4-4s after each cure in that fight (14.18 -> 15.78, 17.78 -> 19.64,
   -- 21.44 -> 25.50, 27.00 -> 27.42, 28.80 -> 29.33). Back within `window` seconds of its
   -- cure, it ranks after every other herb cure -- still eaten when nothing else wants the
   -- balance -- until `hold` seconds pass without it coming back.
   {
      id   = "weariness-reapplied",
      when = { recurring = "weakness", window = 6, hold = 15 },
      rank = { weakness = { herb = 69 } },
   },

   -- JUSTICE ONLY REFLECTS YOUR OWN ATTACKS. The server's description (07:33:15.78): "any
   -- damaging attack by you against the afflictor to be partially returned to you." Two
   -- bellworts went on it in that fight while nothing was attacking. Cured at its own rank
   -- the moment PvP or bashing starts.
   {
      id   = "justice-not-attacking",
      when = { has = { "justice" }, notAttacking = true },
      hold = { justice = M.ALL },
      why  = "not attacking",
   },
}

-- ---------------------------------------------------------------------------
-- recurrence
-- ---------------------------------------------------------------------------

local function canonical(name)
   return afflist.ALIASES[name] or name
end

--- canonical name -> { window, hold }, from every `recurring` rule. Built at load.
local watched = {}
for _, rule in ipairs(M.RULES) do
   local name = rule.when.recurring
   if name then watched[name] = { window = rule.when.window, hold = rule.when.hold } end
end

local curedAt, recurUntil = {}, {}

--- The engine calls this when an affliction is cured.
function M.onCured(name, now)
   name = canonical(name)
   if watched[name] then curedAt[name] = now or util.now() end
end

--- The engine calls this when an affliction is gained.
function M.onAfflicted(name, now)
   name = canonical(name)
   local watch = watched[name]
   if not watch then return end
   now = now or util.now()
   local cured = curedAt[name]
   if cured and (now - cured) <= watch.window then
      recurUntil[name] = now + watch.hold
      log.debug("%s is back %.1fs after its cure -- treating it as re-applied for %ds.",
         name, now - cured, watch.hold)
   end
end

--- Is this affliction being re-applied as fast as it is cured?
function M.recurring(name, now)
   local until_ = recurUntil[canonical(name)]
   return until_ ~= nil and (now or util.now()) < until_
end

-- ---------------------------------------------------------------------------
-- evaluation
-- ---------------------------------------------------------------------------

--- This tick's answer. Reused across ticks: evaluate() runs on every prompt.
---   ranks  canonical name -> vector -> rank
---   holds  canonical name -> M.ALL | { vector = true }
---   why    canonical name -> the reason a hold gives
M.ranks, M.holds, M.why = {}, {}, {}

--- Whether this tick has any hold, or any re-rank, at all. Nearly every tick has neither,
--- and the engine asks about each affliction on each vector: these let it skip the asking.
M.holding, M.reranking = false, false

--- Rule ids in force this tick, and the set last announced, so a change is logged once.
M.active = {}
local announced = {}

--- Every name an affliction can be tracked under, canonical first. Built at load.
local namesOf = {}
for alias, target in pairs(afflist.ALIASES) do
   namesOf[target] = namesOf[target] or { target }
   table.insert(namesOf[target], alias)
end

local function present(tracked, name)
   if tracked[name] ~= nil then return true end
   local names = namesOf[name]
   if names then
      for index = 2, #names do
         if tracked[names[index]] ~= nil then return true end
      end
   end
   return false
end

local function attacking()
   local pvp, bashing = emunah.pvp, emunah.bashing
   return (pvp ~= nil and pvp.enabled == true) or (bashing ~= nil and bashing.enabled == true)
end

local function healthPercent()
   local vitals = emunah.gmcp and emunah.gmcp.vitals
   if not vitals then return nil end
   -- Untrusted vitals count as empty, as they do for the engine's queueHealing().
   if not vitals.trusted("hp") then return 0 end
   return vitals.percent.hp
end

local function applies(when, tracked, now)
   if when.has then
      for _, name in ipairs(when.has) do
         if not present(tracked, name) then return false end
      end
   end
   if when.recurring then
      if not present(tracked, when.recurring) or not M.recurring(when.recurring, now) then
         return false
      end
   end
   if when.notAttacking and attacking() then return false end
   if when.healthBelow then
      local hp = healthPercent()
      local threshold = tonumber(emunah.config.get(when.healthBelow, 80)) or 80
      if hp == nil or hp >= threshold then return false end
   end
   return true
end

local function clear(map)
   for key in pairs(map) do map[key] = nil end
end

--- Every name to file a result under: the canonical one and each of its aliases, so a
--- lookup by whatever name the engine tracks is one table read, with no alias resolution
--- on the per-vector path.
local function filedUnder(name)
   return namesOf[name] or { name }
end
local filing = {}

--- The rules in force: M.RULES as shipped, or as conf/situations.conf adjusts them while
--- `emset ownprios` is on (see M.configure). evaluate() reads only this.
M.rules = {}

--- Adjust the shipped rules, or with no arguments go back to them.
--- @param disabled table|nil rule id -> true, for a rule switched off
--- @param ranks table|nil rule id -> affliction -> vector -> rank, merged over the rule's
---   own ranks (a name the rule did not mention is added to it)
--- @return number how many rules are in force
function M.configure(disabled, ranks)
   disabled, ranks = disabled or {}, ranks or {}
   for index = #M.rules, 1, -1 do M.rules[index] = nil end
   for name in pairs(filing) do filing[name] = nil end
   for _, shipped in ipairs(M.RULES) do
      if not disabled[shipped.id] then
         local rule = shipped
         local extra = ranks[shipped.id]
         if extra then
            rule = { id = shipped.id, when = shipped.when, hold = shipped.hold, why = shipped.why,
                     rank = {} }
            for name, byVector in pairs(shipped.rank or {}) do
               rule.rank[name] = {}
               for vector, rank in pairs(byVector) do rule.rank[name][vector] = rank end
            end
            for name, byVector in pairs(extra) do
               name = canonical(name)
               rule.rank[name] = rule.rank[name] or {}
               for vector, rank in pairs(byVector) do rule.rank[name][vector] = rank end
            end
         end
         M.rules[#M.rules + 1] = rule
         for name in pairs(rule.rank or {}) do filing[name] = filedUnder(name) end
         for name in pairs(rule.hold or {}) do filing[name] = filedUnder(name) end
      end
   end
   return #M.rules
end

--- A shipped rule by id, or nil.
function M.find(id)
   for _, rule in ipairs(M.RULES) do
      if rule.id == id then return rule end
   end
   return nil
end

--- Work out which rules hold right now. Once per tick, before anything asks M.rank/M.held.
--- @param tracked table the engine's tracked afflictions (name -> record)
function M.evaluate(tracked, now)
   now = now or util.now()
   clear(M.ranks); clear(M.holds); clear(M.why)
   local count = 0
   for _, rule in ipairs(M.rules) do
      if applies(rule.when, tracked, now) then
         count = count + 1
         M.active[count] = rule.id
         if rule.rank then
            for name, byVector in pairs(rule.rank) do
               for _, key in ipairs(filing[name]) do
                  local ranks = M.ranks[key]
                  if not ranks then
                     ranks = {}
                     M.ranks[key] = ranks
                  end
                  for vector, rank in pairs(byVector) do ranks[vector] = rank end
               end
            end
         end
         if rule.hold then
            for name, vectors in pairs(rule.hold) do
               for _, key in ipairs(filing[name]) do
                  if vectors == M.ALL or M.holds[key] == M.ALL then
                     M.holds[key] = M.ALL
                  else
                     local held = M.holds[key]
                     if not held then
                        held = {}
                        M.holds[key] = held
                     end
                     for vector in pairs(vectors) do held[vector] = true end
                  end
                  M.why[key] = rule.why or rule.id
               end
            end
         end
      end
   end
   for index = count + 1, #M.active do M.active[index] = nil end
   M.holding  = next(M.holds) ~= nil
   M.reranking = next(M.ranks) ~= nil

   -- Said when the set changes, which is rarely -- not on every prompt. Compared entry by
   -- entry so an unchanged set builds no string.
   local changed = #announced ~= count
   for index = 1, count do
      if announced[index] ~= M.active[index] then changed = true end
      announced[index] = M.active[index]
   end
   for index = count + 1, #announced do announced[index] = nil end
   if changed then
      log.debug("Situational curing: %s.",
         count > 0 and table.concat(M.active, ", ") or "none in force")
   end
   return count
end

--- The rank a rule gives this affliction on this vector, or nil for afflist's own.
function M.rank(name, vector)
   local ranks = M.ranks[name]
   return ranks and ranks[vector]
end

--- Does a rule hold this affliction? With a vector: held on that vector (or on all). With
--- none: held on every vector. Returns the reason, or nil.
function M.held(name, vector)
   local hold = M.holds[name]
   if hold == nil then return nil end
   if hold == M.ALL or (vector ~= nil and hold[vector]) then return M.why[name] end
   return nil
end

--- Does any rule re-rank this affliction this tick? Lets the engine keep its fast path
--- (afflist's shared rank table) for everything else.
function M.reranks(name)
   return M.ranks[name] ~= nil
end

M.configure()

--- Forget recurrence history -- a new bout, a disconnect, a death.
function M.reset()
   clear(curedAt); clear(recurUntil)
end

return M

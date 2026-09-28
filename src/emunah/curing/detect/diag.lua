--- Reading what DIAG actually said.
---
--- The engine spends a second of equilibrium on DIAG whenever loki is up, because
--- Char.Afflictions cannot be trusted while it is and DIAG reports the ground truth. It
--- then threw the answer away: nothing anywhere parsed the output. The cost was paid and
--- the question went unanswered, which is worse than not asking.
---
--- THE FORMAT, verbatim (docs/game/help/who-listings.txt):
---
---     You are:
---     blind.
---     afflicted by thin blood.
---     Equilibrium used: 1.00s.
---
--- TWO FORMS, AND ONLY ONE OF THEM IS AN AFFLICTION
--- ------------------------------------------------
--- "afflicted by X." is an affliction. A bare "X." is a state, and in the one sample on
--- record that state was `blind` -- which the character was holding DELIBERATELY, as a
--- defence, with DEF listing it among twelve. Curing a bare line would have stripped a
--- defence the user had put up on purpose.
---
--- So bare lines are reported and never acted on. That is the conservative reading of a
--- single sample, and it is the one that cannot do damage if it turns out to be wrong.
---
--- WHAT THIS IS ALLOWED TO DO
--- --------------------------
--- Adding is safe: DIAG naming an affliction we are not tracking is exactly the discovery
--- the command was sent for. Removing USED TO wait for the whole block to be understood --
--- see the comment on the removal loop in M.finish() for why that let a stale tracked
--- affliction survive every DIAG for the rest of a session. DIAG is ground truth; anything
--- it does not name (loki and a deliberately-held bare state excepted) is gone, unmapped
--- lines in the same block or not.

local M = {}

local util    = emunah.util
local log     = emunah.log
local afflist = emunah.curing.afflist

--- The last block read, for `emunah detect` and for tests.
M.last = nil

--- Lines DIAG has produced that no affliction in afflist matches, ever, this session.
---
--- The corpus-growing half. "thin blood" is one: the table has no entry for it under any
--- spelling, so the engine could not have cured it however clearly the game said it was
--- there.
M.unknown = {}

local collecting = nil

--- Names Achaea prints with spaces do not have them in the affliction table. Try the
--- spelling as given first, then the squashed form, and accept only what afflist already
--- knows -- so this can normalise but never invent.
---
--- DIAG phrases some entries with a leading indefinite article -- "afflicted by a crippled
--- left arm." -- that afflist's own key never carries. Confirmed live 2026-08-05: squashing
--- alone turned that into "acrippledleftarm", which matches nothing, even though
--- `crippledleftarm` already exists in afflist and has a real cure -- "DIAG reported a
--- crippled left arm... which the affliction table has no entry for" was wrong; the entry
--- was there, just unreachable. So the article-stripped form is tried too, but only AFTER
--- the unstripped one fails, so this can still normalise but never invent -- an affliction
--- genuinely named starting with "a"/"an" is unaffected.
--- @return string|nil the afflist name
local function resolve(text)
   local name = util.trim(tostring(text or "")):lower()
   if name == "" then return nil end
   if afflist.afflictions[name] then return name end

   local squashed = name:gsub("[%s'-]", "")
   if afflist.afflictions[squashed] then return squashed end

   local withoutArticle = name:gsub("^an? ", ""):gsub("[%s'-]", "")
   if withoutArticle ~= squashed and afflist.afflictions[withoutArticle] then
      return withoutArticle
   end

   return nil
end

--- DIAG's bare-state lines that name an AFFLICTION, not a defence. Without these they
--- counted as absent and DIAG removed what it had just confirmed: 14:27:11.30 on 2026-09-28,
--- "paralysed." and "moving inevitably towards a grand finale." in the block, then "DIAG
--- cleared: paralysis, crescendo." -- while paralysed.
M.STATE_AFFLICTIONS = {
   -- The reference system's `diag_paralysis` trigger matches exactly this line.
   ["paralysed"] = "paralysis",
   -- From that DIAG alone: the only thing tracked that it could be was `crescendo`, and the
   -- same Bard's lines say "Song swells about you as you begin to move inevitably towards a
   -- grand crescendo." and prickly ash cures it ("The building crescendo about you...").
   ["moving inevitably towards a grand finale"] = "crescendo",
}

--- Start a block. Exposed so a test can drive the parse without triggers.
function M.begin()
   collecting = { afflictions = {}, states = {}, unknown = {}, at = util.now() }
   return collecting
end

--- Offer one line to the block being collected.
--- @return boolean whether it was part of the block
function M.line(text)
   if not collecting then return false end
   text = tostring(text or "")

   -- The header itself reaches here: the per-line collector fires on the same line that
   -- armed the block, and "You are:" matches neither entry form -- so without this it
   -- closed the block instantly and DIAG read nothing at all.
   if text:match("^You are:%s*$") then return true end

   local afflicted = text:match("^afflicted by (.+)%.$")
   if afflicted then
      local name = resolve(afflicted)
      if name then
         collecting.afflictions[#collecting.afflictions + 1] = name
      else
         collecting.unknown[#collecting.unknown + 1] = util.trim(afflicted)
         M.unknown[util.trim(afflicted)] = true
      end
      return true
   end

   -- A bare lowercase entry. Uppercase lines are not entries -- which is what lets the cost
   -- line "Equilibrium used: 1.00s." end the block without needing a terminator of its own.
   local state = text:match("^([a-z][a-z '%-]*)%.$")
   if state then
      state = util.trim(state)
      local affliction = M.STATE_AFFLICTIONS[state]
      if affliction then
         collecting.afflictions[#collecting.afflictions + 1] = affliction
      else
         collecting.states[#collecting.states + 1] = state
      end
      return true
   end

   M.finish()
   return false
end

--- Close the block and reconcile the engine against it.
--- @return table|nil what was read
function M.finish()
   local block = collecting
   collecting = nil
   if not block then return nil end

   M.last = block
   local engine = emunah.curing.engine

   local added = {}
   for _, name in ipairs(block.afflictions) do
      if engine and not engine.has(name) then
         engine.add(name, "diag")
         added[#added + 1] = name
      end
   end

   -- REMOVALS USED TO WAIT for the whole picture: an unrecognised line meant DIAG named
   -- something we could not place, so "not in the list" did not necessarily mean "not
   -- afflicted", and the conservative reading was to drop nothing rather than cure less
   -- than before. In practice that let a single unrecognised line (the game reports far
   -- more afflictions than afflist knows) silently disable every removal for that whole
   -- DIAG, and a stale tracked affliction never left -- confirmed live 20:57:29-20:58:04,
   -- `stupidity` sitting in `M.tracked` and re-cured every ~5s (goldenseal from the rift,
   -- then focus) with no opponent present the whole time, because nothing was left to ever
   -- clear it out. DIAG costs a whole equilibrium specifically to re-establish ground
   -- truth, and it losing that authority to one unmapped word costs more than the rare
   -- over-eager removal would. So removal now runs unconditionally; `block.unknown` still
   -- feeds the corpus below, it just no longer gates this.
   local removed = {}
   if engine then
      local reported = util.set(block.afflictions)

      -- A BARE STATE CONFIRMS, IT DOES NOT ABSOLVE. "blind" is excluded from
      -- `block.afflictions` above so curing never reaches for epidermal against a defence
      -- held on purpose -- but Char.Afflictions tracks the very same condition under a
      -- different word ("blindness"), and DIAG naming the bare state is the game itself
      -- saying the condition is still real. Without this, every DIAG run while deliberately
      -- blind logged "DIAG cleared: blindness" and dropped it from tracking, only for the
      -- next reconcile to re-add it -- churn at best, and a real removal is not the answer
      -- DIAG gave.
      -- DIAG_STATES, not DELIBERATE: DIAG's bare-state text is its own vocabulary and does
      -- not agree with the name Char.Defences uses for the same defence (`blind` there,
      -- `blindness` in Char.Defences -- see deflist.lua). Comparing against DELIBERATE's
      -- value here would stop matching the moment that table holds the GMCP name instead.
      local deflist = emunah.curing.deflist
      if deflist then
         for _, state in ipairs(block.states) do
            for affliction, word in pairs(deflist.DIAG_STATES) do
               if word == state then reported[affliction] = true end
            end
         end
      end

      for _, record in ipairs(engine.list()) do
         -- `loki` itself is never in DIAG's answer -- it is the illusion, not an
         -- affliction the game will admit to -- so it must not be dropped for its absence.
         if not reported[record.name] and record.name ~= "loki" then
            engine.remove(record.name)
            removed[#removed + 1] = record.name
         end
      end
   end

   block.added, block.removed = added, removed

   if #added > 0 then
      log.info("DIAG added: %s.", table.concat(added, ", "))
   end
   if #removed > 0 then
      log.info("DIAG cleared: %s.", table.concat(removed, ", "))
   end
   if #block.unknown > 0 then
      -- Said once per new wording rather than every DIAG, and said loudly: an affliction
      -- the cure table has no entry for cannot be cured however plainly the game reports it.
      log.warn("DIAG reported %s, which the affliction table has no entry for -- "
         .. "it cannot be cured. Nothing was removed on this reading.",
         table.concat(block.unknown, ", "))
   end
   if #block.states > 0 then
      log.debug("DIAG states (not treated as afflictions): %s.",
         table.concat(block.states, ", "))
   end

   emunah.event.raise("curing.diag", block)
   return block
end

-- ---------------------------------------------------------------------------
-- triggers
-- ---------------------------------------------------------------------------
--
-- Registered in order: the header arms, then every line is offered to the block. The
-- second trigger has to run after the first on the same line, which is why it is
-- registered after it -- Mudlet fires triggers in creation order.

local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.diagTriggers = emunah._persist.diagTriggers or {}
   return emunah._persist.diagTriggers
end

function M.killAll()
   local n = 0
   for _, id in ipairs(registry()) do
      if killTrigger(id) then n = n + 1 end
   end
   emunah._persist.diagTriggers = {}
   return n
end

M.killAll()

do
   local id = tempRegexTrigger([[^You are:$]], function() M.begin() end)
   if id then table.insert(registry(), id) end

   id = tempRegexTrigger([[^]], function()
      if not collecting then return end
      local line = getCurrentLine()
      if type(line) == "string" then M.line(line) end
   end)
   if id then table.insert(registry(), id) end
end

return M

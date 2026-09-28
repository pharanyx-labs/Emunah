--- Keeping the pipes filled and lit.
---
--- Smoking is a cure vector like any other (curing/curelist.lua), but unlike eating a herb
--- it needs a second thing to be true: a pipe, holding that herb, currently burning. A pipe
--- fails in two independent ways -- it empties as it is smoked, and it goes out on its own
--- after a few minutes -- so "I have valerian" and "I can smoke valerian" are different
--- questions, and this module is what makes the second one answerable.
---
--- PIPELIST IS THE SOURCE OF TRUTH
--- ------------------------------
--- Achaea reports every pipe, its state, its contents and its remaining puffs in one table:
---
---     Status  Pipe         Contents                       Puffs Months
---     -------------------------------------------------------------------------------
---     lit     pipe367581   a skullcap flower              10    250
---     out     pipe408402   slippery elm                   10    250
---     out     pipe422328   a valerian leaf                10    250
---
--- That is complete in a way inventory is not, and the difference is not academic: these
--- three pipes are ALL named "a white stone pipe". have.pipe() matched a herb name against
--- the inventory description and could therefore never match any of them -- it fell through
--- to its permissive "allow it but warn" branch every single time. PIPELIST names the
--- contents, so this module answers that question properly and have.pipe() defers to it.
---
--- REFILLS COME FROM INVENTORY, NEVER FROM THE RIFT
--- -----------------------------------------------
--- This is the one design decision here worth arguing for, and the transcript at 07:16:41
--- is the argument. A manual `outr elm` to fill a pipe put inventory one over the
--- restocker's target, so curing/engine.lua stored it straight back:
---
---     07:16:41  outr elm  ->  inr 1 elm   (ours)  ->  "You remove 1 elm"  -> "You store 1 elm"
---     07:16:48  outr elm  ->  inr 1 elm   (ours)  ->  ... "You fill your pipe with slippery elm."
---     07:16:58  outr 1 elm (ours) ...
---
--- Four rift commands fighting over one leaf. Every smoked herb is already in
--- curelist.restockables(), so the restocker keeps three of each in hand at all times --
--- which means the pipe can be filled from what we are carrying and the restocker's own
--- top-up is the only thing that ever touches the rift. No race, and one command instead of
--- two. If the herb is not in hand, the right response is to wait: the restocker is already
--- fetching it.

local M = {}

local log   = emunah.log
local event = emunah.event

--- id (bare digits) -> { token, status, contents, herb, puffs, months }
---
--- `token` is the "pipe367581" form and `id` the bare "367581", because Achaea wants
--- different ones in different places and both are verified: `light pipe367581` and
--- `put skullcap in 367581`. Neither spelling has been observed working in the other's
--- slot, so neither is assumed to.
M.pipes = {}

--- herb -> true: SMOKE of it was refused with "That pipe isn't lit." and no light has
--- landed since. have.pipe() reads it, so smoking that herb waits for the relight even
--- while the pipes themselves are not yet known.
M.unlit = {}

M.enabled = false

--- How long to leave ONE PIPE alone after acting on it.
---
--- Covers the round trip. A pipe that is out stays out for minutes, so there is nothing to
--- gain from being quicker than the game can answer.
---
--- Per pipe, not global, and that distinction is load-bearing. With a single shared guard,
--- the lowest-numbered pipe that needed attention was re-sent the same command every round
--- trip until it either worked or exhausted its budget -- and the other two sat cold behind
--- it the whole time. One pipe that cannot be fixed must not stop the two that can.
M.ACTION_GUARD = 2.0

--- How long between any two pipe commands, whichever pipe they are for.
---
--- The per-pipe guard lets three pipes be dealt with concurrently; this stops that becoming
--- three commands in the same instant. Achaea throttles fast streams -- "Now now, don't be so
--- hasty!" was observed at roughly one round trip apart -- and act.rateLimited() then holds
--- back every subsystem, not just this one.
M.WIRE_GUARD = 0.5

--- How many times to act on one pipe without its state changing before giving up on it.
---
--- The same shape as the restocker's STOCK_ATTEMPTS: when the model is wrong, stop and say
--- which pipe and which command, rather than sending it forever. Lighting needs a tinderbox
--- ("You use a soot-blackened tinderbox to make fire.") and what happens without one has
--- never been observed -- this is what bounds that.
M.ATTEMPTS = 3

--- How often to ask the game for the truth, when nothing has prompted it.
---
--- A DRIFT BACKSTOP, NOT THE MECHANISM. PIPELIST costs nothing -- six went out between
--- 07:17:49 and 07:18:22 with the prompt reading "ex-" throughout and no "Equilibrium used:"
--- line -- but free is not the same as free of consequence: it prints six lines over whatever
--- else is on screen, and at a minute apart that was reported as spam.
---
--- Everything PIPELIST reports is now tracked from the messages that change it, so this is
--- only here to correct drift from something unobserved (a pipe emptied by hand, an emptying
--- message we do not know). Every state transition below has its own line:
---
---   lit      "You carefully light your treasured pipe until it is smoking nicely."
---            "You light a white stone pipe."   /   "That pipe is already lit..."
---   out      "Your pipe, containing a skullcap flower, has gone cold and dark."
---   filled   "You fill your pipe with a skullcap flower."   -> contents, and M.FULL_PUFFS
---   empty    "There is nothing in the pipe to light."       -> puffs 0
---   -1 puff  "You take a long drag of skullcap off your pipe."
M.POLL = 300

--- Puffs in a freshly filled pipe.
---
--- Observed three times over, once per pipe: each read exactly 10 in the PIPELIST straight
--- after being filled -- skullcap at 07:17:26, elm and valerian in the same listing. Set on
--- the fill message so a refill does not need a poll to find out. It is the one number here
--- inferred rather than read, so it is deliberately a named constant, and the backstop poll
--- above corrects it if a pipe ever fills to something else.
M.FULL_PUFFS = 10

--- How long between reactive polls.
---
--- Only the desync path reaches these now, and a desync during a fight could otherwise ask
--- once per refused smoke. Long, because if tracking is working this should almost never
--- fire; `emunah pipes now` bypasses it.
M.POLL_GUARD = 15

--- attempts per pipe, cleared whenever that pipe's state actually changes.
local attempts = {}

--- Log debounces, so a pipe nothing can fix says so once rather than once per prompt.
local warnedHerb, warnedStock, warnedStuck = {}, {}, {}

local function enabled()
   return emunah.config.get("pipes.enabled", true) ~= false
end

-- ---------------------------------------------------------------------------
-- which herb belongs in which pipe
-- ---------------------------------------------------------------------------
--
-- LEARNED, NOT CONFIGURED. A pipe's contents say what it is for, so every PIPELIST that
-- shows a pipe holding something records the pairing. That matters because the one moment
-- we need the answer -- the pipe is empty -- is the one moment the game has stopped telling
-- us. Baking replica numbers into this file would tie it to one character's three pipes.

local function assignments()
   local stored = emunah.config.get("pipes.assign", nil)
   return type(stored) == "table" and stored or {}
end

local function assign(id, herb)
   local current = assignments()
   if current[id] == herb then return end
   current[id] = herb
   emunah.config.set("pipes.assign", current)
   emunah.config.save()
   log.debug("Pipe %s holds %s.", id, herb)
end

--- Which herb a contents description names, or nil.
---
--- Matched against curelist.smoked rather than a hand-written table of descriptions, so a
--- pipe filled with anything smokable is understood without another entry here. The three
--- observed forms all contain the herb: "a skullcap flower", "slippery elm",
--- "a valerian leaf".
function M.herbIn(contents)
   contents = tostring(contents or ""):lower()
   if contents == "" then return nil end
   for herb in pairs(emunah.curing.curelist.smoked) do
      if contents:find(herb, 1, true) then return herb end
   end
   return nil
end

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

--- Record one PIPELIST row.
function M.record(status, token, contents, puffs, months)
   local id = tostring(token):match("(%d+)$")
   if not id then return nil end

   local herb = M.herbIn(contents)
   if herb then assign(id, herb) end

   local previous = M.pipes[id]
   local pipe = {
      id       = id,
      token    = token,
      status   = tostring(status):lower(),
      contents = contents or "",
      herb     = herb,
      puffs    = tonumber(puffs) or 0,
      months   = tonumber(months) or 0,
   }
   M.pipes[id] = pipe
   if herb and pipe.status == "lit" then M.unlit[herb] = nil end

   -- Any real change means whatever we last sent had an effect, so the budget resets. Without
   -- this a pipe that was successfully relit three times over a long session would exhaust
   -- its attempts and then be left cold.
   --
   -- The guard is dropped with it: a fill that has landed should be followed by the light
   -- immediately rather than after another round trip of waiting for nothing.
   if not previous or previous.status ~= pipe.status
      or previous.puffs ~= pipe.puffs or previous.contents ~= pipe.contents then
      attempts[id] = 0
      emunah.timers.stop("pipes.pipe." .. id)
      warnedStuck[id] = nil
   end
   return pipe
end

--- Drop everything known about the pipes. Used on disconnect, where replica numbers survive
--- but "was it lit" does not.
function M.forget()
   M.pipes, attempts = {}, {}
   M.unlit = {}
   warnedHerb, warnedStock, warnedStuck = {}, {}, {}
   M.lastAction = nil
   emunah.timers.stop("pipes.chain")
end

--- Does this pipe need filling?
---
--- Either signal counts, because only one of them has been seen. Puffs running out is the
--- obvious case, but WHAT PIPELIST PRINTS FOR AN EMPTY PIPE HAS NEVER BEEN OBSERVED -- every
--- capture so far has all three holding something. So an empty Contents column counts too,
--- and M.unparsed() below reports a row this cannot read at all rather than dropping it.
local function needsFilling(pipe)
   return pipe.puffs <= 0 or pipe.contents == "" or pipe.herb == nil
end

--- Pipes in a stable order, so behaviour is predictable and testable.
function M.list()
   local out = {}
   for _, pipe in pairs(M.pipes) do out[#out + 1] = pipe end
   table.sort(out, function(a, b) return a.id < b.id end)
   return out
end

function M.snapshot()
   local lit, out, empty = 0, 0, 0
   for _, pipe in ipairs(M.list()) do
      if needsFilling(pipe) then empty = empty + 1
      elseif pipe.status == "lit" then lit = lit + 1
      else out = out + 1 end
   end
   return { lit = lit, out = out, empty = empty, total = #M.list() }
end

-- ---------------------------------------------------------------------------
-- gagging our own housekeeping
--
-- PIPELIST, LIGHT and PUT that Emunah sends for itself are noise: a poll prints six lines,
-- every relight two more (the tinderbox, then "You carefully light your treasured pipe until
-- it is smoking nicely."). So those commands go out unechoed and their replies are hidden.
-- A command you typed yourself, or `emunah pipes now`, is never gagged.
--
-- NEVER deleteLine() INSIDE A TRIGGER HERE. That is what broke this module once (see the
-- note above the triggers): deleting while Mudlet was still working through the lines of
-- the same packet shifted the buffer, and every PIPELIST row after the first was never
-- parsed. So a trigger only RECORDS the line number, and the lines are removed afterwards by
-- a zero-delay timer -- which Mudlet runs once the packet has been processed -- from the
-- bottom up, so removing one never moves another.
-- ---------------------------------------------------------------------------

--- How long after sending a quiet command its reply is still treated as ours.
M.QUIET_WINDOW = 3.0

--- Our quiet commands still awaiting their reply, PER KIND: kind -> { n, untilAt, rules }.
---
--- One slot for all of them was the bug behind "it's not including all lines": pipes are lit
--- one after another, WIRE_GUARD apart, so pipe A's success line cleared the slot while pipe
--- B's LIGHT was still in flight -- and B's tinderbox and success lines were shown. A LIGHT
--- sent during a PIPELIST overwrote the slot the same way, and the rest of the listing
--- showed. Each kind now counts its own outstanding commands.
local quiet = {}
local gagged = {}

--- Lines since the last prompt, and how many of them were gagged. See M.onLine.
local block = { lines = 0, gagged = 0 }

--- The last prompt seen: its line number (kept current as lines above it are deleted) and
--- its text, so a command typed onto it afterwards can be noticed.
local lastPrompt = nil

function M.quietly(kind)
   local entry = quiet[kind]
   if not entry or emunah.util.now() > entry.untilAt then
      entry = { n = 0, rules = 0 }
      quiet[kind] = entry
   end
   entry.n = entry.n + 1
   entry.untilAt = emunah.util.now() + M.QUIET_WINDOW
end

--- One reply of this kind has fully arrived.
local function answered(kind)
   local entry = quiet[kind]
   if not entry then return end
   entry.n = entry.n - 1
   if entry.n <= 0 then quiet[kind] = nil end
end

local function ours(kind)
   local entry = quiet[kind]
   return entry ~= nil and entry.n > 0 and emunah.util.now() <= entry.untilAt
end

local function flushGags()
   table.sort(gagged, function(a, b) return a.line > b.line end)
   local last, removedAbove = nil, 0
   for _, entry in ipairs(gagged) do
      local line, expect = entry.line, entry.text
      if line ~= last then
         moveCursor("main", 0, line)
         -- An old prompt is only removed while it still reads as it did: if you have typed a
         -- command since, Mudlet echoed it onto that prompt, and the line is yours.
         if expect == nil or getCurrentLine() == expect then
            deleteLine("main")
            if lastPrompt and line < lastPrompt.line then removedAbove = removedAbove + 1 end
         end
         last = line
      end
   end
   if lastPrompt then lastPrompt.line = lastPrompt.line - removedAbove end
   gagged = {}
   moveCursorEnd("main")
end

local function gagCurrent()
   if type(getLineNumber) ~= "function" then return end
   local line = getLineNumber("main")
   if not line then return end
   if #gagged == 0 then tempTimer(0, flushGags) end
   gagged[#gagged + 1] = { line = line }
end

--- Hide the line being processed, once the packet it arrived in has been dealt with.
function M.gag()
   block.gagged = block.gagged + 1
   gagCurrent()
end

--- Every line passes through here (see the `^` trigger below).
---
--- THE LAST LINE IS ALWAYS A CURRENT PROMPT. Gagging the replies alone left a bare prompt
--- behind for every relight -- five in a row at 13:23:14.92-13:23:17.41 -- but gagging the
--- new prompt instead would leave a stale one at the bottom of the window. So when a whole
--- block was ours and gagged, its prompt is KEPT, and the prompt before it -- which that
--- block would otherwise have left stranded above it -- is the one removed. Any run of
--- housekeeping collapses into the one, current, prompt. A block with anything else in it
--- (someone arriving, a line you typed) leaves both prompts alone.
function M.onLine()
   if type(isPrompt) == "function" and isPrompt() then
      if block.gagged > 0 and block.lines == block.gagged and lastPrompt then
         if #gagged == 0 then tempTimer(0, flushGags) end
         gagged[#gagged + 1] = { line = lastPrompt.line, text = lastPrompt.text }
      end
      local line = type(getLineNumber) == "function" and getLineNumber("main") or nil
      lastPrompt = line and { line = line, text = getCurrentLine() } or nil
      block.lines, block.gagged = 0, 0
   else
      block.lines = block.lines + 1
   end
end

-- ---------------------------------------------------------------------------
-- acting
-- ---------------------------------------------------------------------------

--- Ask the game for the current state.
---
--- The fallback, not the mechanism -- see M.POLL. Reactive callers leave `force` unset so
--- they cannot ask more than once per M.POLL_GUARD however often they fire; `emunah pipes now`
--- passes true, because a person asking has a reason.
function M.poll(force, shown)
   if not force and not emunah.timers.ready("pipes.poll") then return false end
   emunah.timers.start("pipes.poll", M.POLL_GUARD)
   -- Our own housekeeping is sent quietly and its output gagged (see M.gag). A poll someone
   -- asked for -- `emunah pipes now` -- is shown, because they asked to see it.
   if shown then return emunah.act.send("pipelist", {}) end
   if emunah.act.send("pipelist", { quiet = true }) then
      M.quietly("list")
      return true
   end
   return false
end

--- How soon to look again while there is still something to do.
---
--- THE TICK IS NOT ENOUGH, and this is the same lesson the restocker learned. keep() ran only
--- on emunah.tick, which fires on Char.Vitals -- which Achaea sends with a PROMPT. An idle
--- character produces almost none: standing in a shop, the prompts at 07:34:21.81 and
--- 07:35:42.82 are EIGHTY-ONE SECONDS apart, and that gap is exactly how long the second pipe
--- sat cold. Nothing was wrong with the decision, there was just nothing to make it.
M.CHAIN = 0.6

--- The last pipe we sent a command about, so a confirmation can be attributed to it.
---
--- Sound because only one pipe command is in flight at a time -- M.WIRE_GUARD sees to that.
--- Achaea's confirmations name neither the pipe nor, for LIGHT, anything identifying at all
--- ("You carefully light your treasured pipe until it is smoking nicely."), so the command we
--- just sent is the only thing that can say which pipe it is about.
M.lastAction = nil

--- Is there a command we could actually send about this pipe right now?
---
--- Not the same question as "is this pipe wrong". A pipe waiting on a herb the restocker has
--- not brought yet is wrong and there is nothing to do about it, so counting it as work would
--- have the chain timer below waking every 0.6s indefinitely to decide the same thing again.
--- The tick picks it up once the herb arrives.
local function actionable(pipe)
   if (attempts[pipe.id] or 0) >= M.ATTEMPTS then return false end
   if needsFilling(pipe) then
      local herb = pipe.herb or assignments()[pipe.id]
      return herb ~= nil and emunah.have.item(herb) > 0
   end
   return pipe.status ~= "lit"
end

--- Is there anything left worth another pass?
local function pendingWork()
   for _, pipe in ipairs(M.list()) do
      if actionable(pipe) then return true end
   end
   return false
end

--- Come back shortly, but only while there is a reason to.
---
--- Bounded by the attempt budget through pendingWork(): a pipe nothing can fix stops counting
--- as work, so this stops rescheduling rather than ticking away forever.
function M.chain()
   if not enabled() then return false end
   if not pendingWork() then return false end
   emunah.timers.start("pipes.chain", M.CHAIN, function() M.keep() end)
   return true
end

--- Record that we have just acted on a pipe, and arrange to come back.
function M.acted(pipe, kind)
   attempts[pipe.id] = (attempts[pipe.id] or 0) + 1
   M.lastAction = { id = pipe.id, kind = kind }
   emunah.timers.start("pipes.pipe." .. pipe.id, M.ACTION_GUARD)
   emunah.timers.start("pipes.action", M.WIRE_GUARD)
   M.chain()
end

--- The pipe our last command was about, if it is still known.
local function acted()
   local last = M.lastAction
   return last and M.pipes[last.id] or nil
end

--- Fix at most one thing. Called from the tick and from the chain timer; one command per
--- round trip is plenty for something that changes on the scale of minutes.
---
--- Pipes are considered in id order, and the order barely matters because each carries its
--- own guard -- whichever is skipped this pass is dealt with on the next. What the ordering
--- must NOT do is let one pipe monopolise the wire, which is what the per-pipe guard fixes.
function M.keep()
   if not enabled() then return false end
   if not emunah.timers.ready("pipes.action") then return false end

   for _, pipe in ipairs(M.list()) do
      local guard = "pipes.pipe." .. pipe.id
      local spent = attempts[pipe.id] or 0

      if not emunah.timers.ready(guard) then
         -- Waiting on this one's round trip. Deliberately not a `return`: another pipe can
         -- still be dealt with on this pass, which is the entire point of the per-pipe guard.

      elseif spent >= M.ATTEMPTS then
         if not warnedStuck[pipe.id] then
            warnedStuck[pipe.id] = true
            log.warn("Pipe %s has not responded after %d attempts -- leaving it. "
               .. "Check you are carrying a tinderbox and the herb it takes.",
               pipe.token, M.ATTEMPTS)
            -- Once, on the way out. Giving up is precisely the moment our tracked state is
            -- most likely to be the thing that is wrong, and this is the one question that
            -- can tell us -- if the pipe is actually fine, the answer resets the budget.
            M.poll()
         end

      elseif needsFilling(pipe) then
         local herb = pipe.herb or assignments()[pipe.id]
         if not herb then
            -- Nothing in it and no record of what it ever held. Cannot be guessed: the pipes
            -- are identical in inventory and the contents column is what names them.
            if not warnedHerb[pipe.id] then
               warnedHerb[pipe.id] = true
               log.warn("Pipe %s is empty and has never been seen holding anything -- "
                  .. "fill it once by hand and it will be kept from then on.", pipe.token)
            end
         elseif emunah.have.item(herb) <= 0 then
            -- The restocker keeps three of every smoked herb in hand, so this is a wait, not
            -- a failure. Deliberately does NOT pull from the rift -- see the header.
            if not warnedStock[pipe.id] then
               warnedStock[pipe.id] = true
               log.debug("Pipe %s wants %s and none is carried -- waiting for restock.",
                  pipe.token, herb)
            end
         else
            warnedStock[pipe.id] = nil
            -- The BARE id here, and the token for LIGHT below. Both forms are verified, each
            -- in its own command, and neither is assumed to work in the other's.
            if emunah.act.send(("put %s in %s"):format(herb, pipe.id), { quiet = true }) then
               M.acted(pipe, "fill")
               M.quietly("fill")
               return true
            end
         end

      elseif pipe.status ~= "lit" then
         if emunah.act.send("light " .. pipe.token, { quiet = true }) then
            M.acted(pipe, "light")
            M.quietly("light")
            return true
         end
      end
   end

   M.chain()
   return false
end

function M.start()
   M.enabled = true
   emunah.config.set("pipes.enabled", true)
   log.info("Pipe keep-up <ansi_light_green>on<ansi_yellow>.")
   -- Forced: switching it on is an explicit request, and it is the one moment we may know
   -- nothing at all about the pipes.
   M.poll(true)
end

function M.stop()
   M.enabled = false
   emunah.config.set("pipes.enabled", false)
   log.info("Pipe keep-up <ansi_light_red>off<ansi_yellow>.")
end

function M.toggle()
   if enabled() then M.stop() else M.start() end
   return enabled()
end

-- ---------------------------------------------------------------------------
-- triggers
-- ---------------------------------------------------------------------------

do
   emunah._persist = emunah._persist or {}
   for _, id in ipairs(emunah._persist.pipeTriggers or {}) do killTrigger(id) end
   emunah._persist.pipeTriggers = {}

   local function keep(id)
      if id then table.insert(emunah._persist.pipeTriggers, id) end
   end

   -- NOTHING HERE CALLS deleteLine() DIRECTLY, AND THAT IS DELIBERATE.
   --
   -- An earlier version hid the output of its own polls: the header, the rules and each row
   -- were deleted when the poll was ours. Reported in play as "it's also only lighting the
   -- skullcap pipe" -- which is the FIRST row of PIPELIST. Deleting a line while Mudlet is
   -- still working through the lines that arrived in the same packet shifts the buffer under
   -- it, and the rows after the deleted one never reached this trigger at all. Only pipe one
   -- was ever recorded, so only pipe one was ever lit.
   --
   -- The state machine was never at fault and a test drives it end to end. Parsing every
   -- row is the entire feature, so the gag that replaced it (M.gag, above) never deletes
   -- from inside a trigger: it records the line and deletes after the packet is done.

   -- Every line, for M.onLine's per-block count.
   keep(tempRegexTrigger([[^]], function() M.onLine() end))

   -- A PIPELIST row.
   --
   -- Deliberately avoids both `|` and `{n,}`: test/mock_mudlet.lua translates PCRE to Lua
   -- patterns, which have neither, so a pattern using them would pass in Mudlet and match
   -- nothing in the tests -- the exact silent divergence that mock exists to prevent. The
   -- status is captured as a plain word and checked in Lua, and `\s\s+` says "two or more"
   -- without a repetition count. Anchoring on `pipe\d+` is what keeps the header row --
   -- "Status  Pipe  Contents  Puffs Months" -- from matching.
   keep(tempRegexTrigger([[^(\w+)\s+(pipe\d+)\s+(.*?)\s\s+(\d+)\s+(\d+)\s*$]], function()
      local status, token, contents, puffs, months =
         matches[2], matches[3], matches[4], matches[5], matches[6]
      if status ~= "lit" and status ~= "out" then return end
      M.record(status, token, contents, puffs, months)
      if ours("list") then M.gag() end
      M.chain()
   end))

   -- The rest of OUR PIPELIST: its header and the two rules around the rows. Seen at
   -- 13:05:24.87:
   --
   --     Status  Pipe         Contents                       Puffs Months
   --     -------------------------------------------------------------------------------
   --     out     pipe367581   a skullcap flower              8     195
   --     ...
   --     -------------------------------------------------------------------------------
   --
   -- The second rule ends the listing, and with it the gag.
   keep(tempRegexTrigger([[^Status\s+Pipe\s+Contents\s+Puffs\s+Months\s*$]], function()
      if ours("list") then M.gag() end
   end))
   keep(tempRegexTrigger([[^[-][-][-][-][-][-][-][-][-][-]+\s*$]], function()
      if not ours("list") then return end
      M.gag()
      local entry = quiet.list
      entry.rules = entry.rules + 1
      if entry.rules >= 2 then
         entry.rules = 0
         answered("list")
      end
   end))

   -- The tinderbox, ahead of every LIGHT: "You use a soot-blackened tinderbox to make fire."
   -- (13:05:25.08). The tinderbox's description is left open.
   keep(tempRegexTrigger([[^You use .+ to make fire\.$]], function()
      if ours("light") then M.gag() end
   end))

   -- A pipe going out. The fast path: this arrives the moment it happens, where the poll
   -- could be a minute away. It names the CONTENTS rather than the pipe, which is enough --
   -- the contents are what PIPELIST keys each pipe by anyway.
   --
   --     Your pipe, containing a skullcap flower, has gone cold and dark.
   keep(tempRegexTrigger([[^Your pipe, containing (.+), has gone cold and dark\.$]], function()
      local herb = M.herbIn(matches[2])
      for _, pipe in ipairs(M.list()) do
         if pipe.herb == herb then
            pipe.status = "out"
            attempts[pipe.id] = 0
            warnedStuck[pipe.id] = nil
            emunah.timers.stop("pipes.pipe." .. pipe.id)
            log.debug("Pipe %s has gone out.", pipe.token)
         end
      end
      M.keep()
      M.chain()
   end))

   -- LIGHTING SUCCEEDED.
   --
   -- Two wordings, and the one that matters was missing. `light pipes` answers "You light a
   -- white stone pipe."; `light pipe367581` answers "You carefully light your treasured pipe
   -- until it is smoking nicely." Only the first was matched, so a successful LIGHT of a
   -- named pipe confirmed nothing -- our state stayed "out", the per-pipe guard lapsed, and
   -- the same pipe was lit again. Visible at 07:34:16 and 07:34:21: light, success, light
   -- again, "That pipe is already lit and burning nicely."
   --
   -- Marked lit HERE rather than waiting for a poll, for the same reason. The next PIPELIST
   -- corrects it if this is ever wrong, and being wrong costs one command.
   for _, pattern in ipairs({
      [[^You carefully light your treasured pipe until it is smoking nicely\.$]],
      [[^You light a white stone pipe\.$]],
      [[^That pipe is already lit and burning nicely\.$]],
   }) do
      keep(tempRegexTrigger(pattern, function()
         local pipe = acted()
         if pipe then
            pipe.status = "lit"
            if pipe.herb then M.unlit[pipe.herb] = nil end
            attempts[pipe.id] = 0
            emunah.timers.stop("pipes.pipe." .. pipe.id)
         end
         if ours("light") then M.gag() answered("light") end
         M.chain()
      end))
   end

   -- Nothing in it after all: our puff count was stale. Mark it empty so the next pass fills
   -- rather than trying to light it again.
   keep(tempRegexTrigger([[^There is nothing in the pipe to light\.$]], function()
      local pipe = acted()
      if pipe then
         pipe.puffs = 0
         attempts[pipe.id] = 0
         emunah.timers.stop("pipes.pipe." .. pipe.id)
      end
      if ours("light") then M.gag() answered("light") end
      M.chain()
   end))

   -- Filled. The herb comes from the line and the puff count from M.FULL_PUFFS, so this needs
   -- no poll -- it used to send one purely to find out a number that is always the same.
   keep(tempRegexTrigger([[^You fill your pipe with (.+)\.$]], function()
      local pipe = acted()
      if pipe then
         pipe.contents = matches[2]
         pipe.herb = M.herbIn(matches[2]) or pipe.herb
         pipe.puffs = M.FULL_PUFFS
         -- A fill leaves the pipe loaded but COLD -- "You fill your pipe" is not "you light
         -- it", and the next pass has to send the LIGHT. Saying so explicitly rather than
         -- leaving whatever status we happened to be holding.
         pipe.status = "out"
         attempts[pipe.id] = 0
         emunah.timers.stop("pipes.pipe." .. pipe.id)
      end
      if ours("fill") then M.gag() answered("fill") end
      M.chain()
   end))

   -- A puff spent. Decremented rather than polled: the line names the herb, which identifies
   -- the pipe, and one drag is exactly one puff -- so there is nothing a PIPELIST would add,
   -- and this fires on every smoke cure.
   keep(tempRegexTrigger([[^You take a long drag of (.+) off your pipe\.$]], function()
      local herb = M.herbIn(matches[2])
      for _, pipe in ipairs(M.list()) do
         if pipe.herb == herb and pipe.puffs > 0 then
            pipe.puffs = pipe.puffs - 1
         end
      end
      M.chain()
   end))

   -- SMOKE refused because the pipe holding that herb has gone out. Observed at 07:32:38 on
   -- `smoke elm`, which incidentally settles that SMOKE takes the herb and resolves it to a
   -- pipe. The line names neither, so the herb comes from the smoke in flight -- the
   -- reference system's unlit_pipe does exactly this (findbybal"smoke", then marks that
   -- herb's pipe unlit and kills the action).
   --
   -- It used to only ask for a PIPELIST, which the poll guard refuses within 15s of the last
   -- one. After a reconnect on 2026-09-28 `smoke elm` for earworm met "That pipe isn't lit."
   -- at 15:03:32.95, 39.12 and 55.49, and landed at 58.95: 26 seconds of earworm. Each
   -- refusal was free -- none was followed by "Your lungs have recovered" -- so the slot and
   -- the balance are handed back too, rather than sitting out the confirm wait.
   keep(tempRegexTrigger([[^That pipe isn't lit\.$]], function()
      local flight = emunah.queue.awaiting("smoke")
      local herb = flight and M.herbIn(tostring(flight.command or ""):match("^smoke%s+(.+)$"))
      if flight then
         emunah.queue.confirm("smoke")
         emunah.have.recover("smoke")
      end
      local marked = false
      if herb then
         M.unlit[herb] = true
         for _, pipe in ipairs(M.list()) do
            if pipe.herb == herb then
               pipe.status = "out"
               attempts[pipe.id] = 0
               emunah.timers.stop("pipes.pipe." .. pipe.id)
               marked = true
            end
         end
      end
      -- Pipes not known (a reconnect forgets them): nothing to light until PIPELIST says
      -- which pipe holds it, and the guard must not stand in the way of that.
      if not marked then M.poll(true) end
      M.keep()
   end))
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

event.register("emunah.tick", function()
   if not enabled() then return end
   if emunah.timers.ready("pipes.poll.due") then
      emunah.timers.start("pipes.poll.due",
         tonumber(emunah.config.get("pipes.poll", M.POLL)) or M.POLL)
      M.poll()
   end
   M.keep()
end, "pipes")

-- Nothing carried over a session boundary is worth believing: replica numbers survive, but
-- whether a pipe is still lit after a reconnect does not.
event.register("sysDisconnectionEvent", function()
   M.forget()
   emunah.timers.stop("pipes.poll.due")
end, "pipes")

M.enabled = enabled()

return M

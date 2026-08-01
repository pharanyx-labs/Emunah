--- Emunah test suite.
---
--- Runs the real loader and the real modules against test/mock_mudlet.lua. These are
--- behavioural tests, not syntax checks: each one drives the system the way Achaea would
--- and asserts on the resulting state.
---
--- Usage: lua test/run.lua   (from the repo root)

local ROOT = (arg and arg[0] or ""):match("^(.*)/test/run%.lua$") or "."
package.path = ROOT .. "/test/?.lua;" .. package.path

local mock = require("mock_mudlet")

local passed, failed = 0, 0
local failures = {}
local currentSuite = ""

local function suite(name)
   currentSuite = name
   io.write("\n", name, "\n")
end

local function ok(condition, description, detail)
   if condition then
      passed = passed + 1
      io.write("  pass  ", description, "\n")
   else
      failed = failed + 1
      failures[#failures + 1] = currentSuite .. " / " .. description ..
         (detail and ("  -- " .. tostring(detail)) or "")
      io.write("  FAIL  ", description, detail and ("  -- " .. tostring(detail)) or "", "\n")
   end
end

local function eq(actual, expected, description)
   ok(actual == expected, description,
      actual ~= expected and ("got " .. tostring(actual) .. ", want " .. tostring(expected)) or nil)
end

-- ---------------------------------------------------------------------------

mock.install(ROOT)
_G.EMUNAH_ROOT = ROOT

local function load()
   dofile(ROOT .. "/src/emunah.lua")
end

-- ===========================================================================
suite("loader")

local loadOk, loadErr = pcall(load)
ok(loadOk, "loads without error", loadErr)
ok(type(emunah) == "table", "creates the emunah namespace")
eq(type(emunah.util), "table", "core.util present")
eq(type(emunah.gmcp.vitals), "table", "gmcp.vitals present")
eq(type(emunah.curing.afflist), "table", "curing.afflist present")
eq(type(emunah.have), "table", "have present")
eq(type(emunah.commands), "table", "commands present")
ok(emunah.curing.afflist.count() > 100, "affliction table is populated",
   emunah.curing.afflist.count())

-- Every manifest entry must actually load. Asserting the count catches a module that was
-- added to the manifest but never written, which otherwise only shows up as a silent
-- missing feature at runtime.
local loadedModules = 0
for _, line in ipairs(mock.echoed) do
   local count = tostring(line):match("loaded %-%- (%d+) modules")
   if count then loadedModules = tonumber(count) end
end
eq(loadedModules, 42, "all 42 manifest modules loaded")

-- ===========================================================================
suite("reload safety (the headline fix)")

local beforeHandlers = mock.handlerCount("gmcp.Char.Vitals")
local beforeAliases  = mock.aliasCount()
local beforeTriggers = mock.triggerCount()

ok(beforeHandlers >= 1, "a Char.Vitals handler is registered", beforeHandlers)

for _ = 1, 3 do
   local reloadOk, reloadErr = pcall(load)
   ok(reloadOk, "reload completes", reloadErr)
end

eq(mock.handlerCount("gmcp.Char.Vitals"), beforeHandlers,
   "Char.Vitals handlers do not accumulate across 3 reloads")
eq(mock.aliasCount(), beforeAliases, "aliases do not accumulate across reloads")
eq(mock.triggerCount(), beforeTriggers, "detection triggers do not accumulate across reloads")

-- emreload must re-read src/emunah.lua ITSELF, not just re-require the modules the
-- in-memory manifest already lists.
--
-- load() is a closure over MANIFEST. A reload that only calls load() picks up edits to
-- existing modules but silently ignores a newly ADDED one -- the file is on disk, its
-- manifest entry is on disk, and neither is in memory. That shipped once: `ui/map.lua`
-- was added, emreload was run, every other module updated, and `emunah.ui.map` was nil.
local runsBefore = EMUNAH_CHUNK_RUNS
emunahReload()
ok(EMUNAH_CHUNK_RUNS == runsBefore + 1,
   "emreload re-executes the loader file, so manifest changes take effect",
   ("chunk runs %s -> %s"):format(tostring(runsBefore), tostring(EMUNAH_CHUNK_RUNS)))
eq(mock.handlerCount("gmcp.Char.Vitals"), beforeHandlers,
   "re-executing the loader still does not leak handlers")

-- ===========================================================================
suite("Char.Vitals (the '0' truthiness trap)")

mock.feed("Char.Vitals", {
   hp = "3200", maxhp = "4000", mp = "2500", maxmp = "3000",
   ep = "20000", maxep = "22000", wp = "18000", maxwp = "20000",
   nl = "43", bal = "1", eq = "1",
   charstats = { "Bleed: 0", "Kai: 35%", "Stance: None" },
})

local vitals = emunah.gmcp.vitals
eq(vitals.hp, 3200, "hp parsed from string")
eq(vitals.maxhp, 4000, "maxhp parsed")
eq(vitals.bal, true, 'bal "1" is true')
eq(vitals.eq, true, 'eq "1" is true')
eq(math.floor(vitals.percent.hp), 80, "health percentage computed")

mock.feed("Char.Vitals", { bal = "0", eq = "0" })
eq(vitals.bal, false, 'bal "0" is FALSE, not truthy')
eq(vitals.eq, false, 'eq "0" is FALSE, not truthy')

eq(vitals.stats.Bleed, 0, "charstats numeric value parsed")
eq(vitals.stats.Kai, 35, 'charstats "35%" parsed to 35')
eq(vitals.stats.Stance, "None", "charstats string value kept")

-- A partial update must not be read as a balance loss.
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
mock.feed("Char.Vitals", { hp = "3000" })
eq(vitals.bal, true, "partial Char.Vitals does not clear balance")
eq(vitals.hp, 3000, "partial Char.Vitals still updates what it carries")

-- ===========================================================================
suite("Char.Afflictions")

mock.feed("Char.Afflictions.List", {
   { name = "paralysis", cure = "bloodroot" },
   { name = "asthma",    cure = "kelp" },
})
eq(emunah.gmcp.afflictions.count(), 2, "List populates")
ok(emunah.gmcp.afflictions.has("paralysis"), "has() finds a listed affliction")

mock.feed("Char.Afflictions.Add", { name = "stupidity", cure = "goldenseal" })
eq(emunah.gmcp.afflictions.count(), 3, "Add appends")

-- Remove is an ARRAY OF NAMES, not objects. Getting this wrong is a classic bug.
mock.feed("Char.Afflictions.Remove", { "paralysis" })
eq(emunah.gmcp.afflictions.count(), 2, "Remove accepts an array of bare names")
ok(not emunah.gmcp.afflictions.has("paralysis"), "removed affliction is gone")

-- Some afflictions report with a live stack count baked into the name itself, e.g.
-- "temperedsanguine (2)" -- without stripping it, afflist.known() would never recognise
-- the affliction under any spelling and the engine would track-but-never-cure it forever.
mock.feed("Char.Afflictions.List", {})
mock.feed("Char.Afflictions.Add", { name = "temperedsanguine (2)" })
ok(emunah.gmcp.afflictions.has("temperedsanguine"),
   "the stack-count suffix is stripped before the name is used as a key")
eq(emunah.gmcp.afflictions.stacks("temperedsanguine"), 2, "the stack count itself is kept")
ok(emunah.curing.afflist.known("temperedsanguine"),
   "the stripped name matches a real afflist.lua entry")

mock.feed("Char.Afflictions.Add", { name = "temperedsanguine (3)" })
eq(emunah.gmcp.afflictions.count(), 1, "a re-report at a new stack level updates, not duplicates")
eq(emunah.gmcp.afflictions.stacks("temperedsanguine"), 3, "the stack count updates")

mock.feed("Char.Afflictions.Remove", { "temperedsanguine (3)" })
ok(not emunah.gmcp.afflictions.has("temperedsanguine"),
   "Remove strips the suffix too, or the entry would never be cleared")

-- A plain affliction with no suffix still defaults to a stack of 1, not 0 -- 0 means "not
-- tracked at all" elsewhere in the API (see gmcp.afflictions.stacks()'s own contract).
mock.feed("Char.Afflictions.Add", { name = "paralysis" })
eq(emunah.gmcp.afflictions.stacks("paralysis"), 1, "a non-stacking affliction defaults to 1")
mock.feed("Char.Afflictions.List", {})

-- ===========================================================================
suite("Char.Items")

mock.feed("Char.Items.List", {
   location = "inv",
   items = {
      { id = "1", name = "a bloodroot", attrib = "e" },
      { id = "2", name = "a leather pack", attrib = "c" },
   },
})
eq(emunah.gmcp.items.count("inv"), 2, "inventory list tracked")
ok(emunah.gmcp.items.has("bloodroot"), "find matches on substring")

-- An Update handler that copies the OLD entry means the new name never lands.
mock.feed("Char.Items.Update", {
   location = "inv",
   item = { id = "1", name = "a withered bloodroot", attrib = "e" },
})
local updated = emunah.gmcp.items.first("withered")
ok(updated ~= nil, "Update applies the INCOMING item, not a copy of the old one")

mock.feed("Char.Items.Remove", { location = "inv", item = { id = "2" } })
eq(emunah.gmcp.items.count("inv"), 1, "Remove drops by id")

-- A GROUPED STACK IS ONE ENTRY. Verbatim from the GMCP trace at 11:42:02 after
-- `outr 5 irid` -- counting entries would answer "1 irid moss" for five of them, which is
-- the difference between a restocker that stops and one that empties the rift.
mock.feed("Char.Items.Add", {
   location = "inv",
   item = { id = "344362", attrib = "gre", icon = "curative",
            name = "a group of 5 pieces of irid moss" },
})
eq(emunah.gmcp.items.count("irid"), 1, "a stack is a single inventory entry")
eq(emunah.gmcp.items.quantity("irid"), 5, "...and quantity reads the number out of its name")
eq(emunah.gmcp.items.quantity("bloodroot"), 1, "an ungrouped item counts as one")

-- ===========================================================================
suite("cure resolution")

local afflist = emunah.curing.afflist

-- anorexia is cured by APPLYING epidermal, not by eating. If this is wrong, the whole
-- lock-breaking logic is wrong.
local anorexiaVectors = afflist.vectorsFor("anorexia")
ok(anorexiaVectors[1] == "salve", "anorexia cures via salve first", anorexiaVectors[1])
ok(afflist.priority("anorexia", "salve") == 1, "anorexia is top salve priority")
ok(afflist.priority("anorexia", "focus") ~= nil, "anorexia is also focusable (the lock escape)")

-- Anorexia shuts BOTH eating vectors: herbs and irid moss, which is on its own balance.
eq(table.concat(afflist.blockedVectors("anorexia"), ","), "herb,moss", "anorexia blocks eating")
eq(table.concat(afflist.blockedVectors("slickness"), ","), "salve", "slickness blocks applying")
eq(table.concat(afflist.blockedVectors("asthma"), ","), "smoke", "asthma blocks smoking")
eq(table.concat(afflist.blockedVectors("impatience"), ","), "focus", "impatience blocks focusing")

-- Every blocker must itself be curable by a vector it does not block, or it is a lock with
-- no key: the engine would need the shut vector to open the shut vector.
for blocker, shut in pairs(afflist.blocks) do
   local escape = false
   for _, option in ipairs(afflist.curesVia(blocker, "herb")) do escape = true end
   for _, vector in ipairs({ "salve", "smoke", "focus", "elixir" }) do
      local blocked = false
      for _, name in ipairs(shut) do if name == vector then blocked = true end end
      if not blocked and #afflist.curesVia(blocker, vector) > 0 then
         escape = true
      end
   end
   ok(escape, ("%s can be cured without the vector it blocks"):format(blocker))
end

-- EVERY CURE MUST BE REACHABLE. engine.resolve() only considers afflictions that have a
-- priority for the vector being resolved, so an entry with a cure but no rank is tracked
-- forever and never acted on -- the game reports it, the panel shows it, and nothing is
-- sent. Four entries shipped in exactly that state (crackedribs, skullfractures,
-- torntendons, wristfractures: all `apply health` damage from ordinary hunting), which
-- presents as one affliction that never heals while everything else cures normally.
local unrankable = {}
for name, definition in pairs(afflist.afflictions) do
   local ranked = false
   for _, option in ipairs(definition.cures or {}) do
      if afflist.priority(name, option.vector) then ranked = true break end
   end
   if not ranked and #(definition.cures or {}) > 0 then
      unrankable[#unrankable + 1] = name
   end
end
table.sort(unrankable)
eq(#unrankable, 0,
   "every affliction with a cure has a priority the engine can select it by",
   table.concat(unrankable, ", "))

local curelist = emunah.curing.curelist
local cure = afflist.curesVia("paralysis", "herb")[1]
local command, item = curelist.command(cure)
eq(command, "eat bloodroot", "herb cure builds an eat command")
eq(item, "bloodroot", "herb cure names its item")

local salveCure = afflist.curesVia("mangledleftleg", "salve")[1]
local salveCommand = curelist.command(salveCure)
eq(salveCommand, "apply restoration to legs", "salve cure targets the right body part")

-- Alchemist mode swaps to the mineral equivalent.
emunah.config.set("curing.method", "minerals")
eq((curelist.command(cure)), "eat magnesium", "minerals mode uses the alchemical equivalent")
emunah.config.set("curing.method", "herbs")

-- Entries added from the later cross-check resolve the same way as the original ones.
ok(afflist.known("guilt"), "an afflist entry added from the tk cross-check is known")
local guiltCure = afflist.curesVia("guilt", "herb")[1]
eq(curelist.command(guiltCure), "eat lobelia", "it resolves to the right herb command")
ok(afflist.priority("guilt", "herb") > 58,
   "its priority is appended after the ranked list, not guessed into the middle of it")

-- ===========================================================================
suite("capability gate")

-- Stock the inventory with kelp so the cure is performable.
mock.feed("Char.Items.List", {
   location = "inv",
   items = { { id = "10", name = "some kelp", attrib = "e" } },
})

local kelpCure = afflist.curesVia("asthma", "herb")[1]
local usable, reason = emunah.have.cure(kelpCure)
ok(usable, "cure is usable when the item is held", reason)

local bloodrootCure = afflist.curesVia("paralysis", "herb")[1]
local usable2, reason2 = emunah.have.cure(bloodrootCure)
ok(not usable2, "cure is refused when the item is absent")
ok(tostring(reason2):find("out of"), "refusal explains why", reason2)

-- THE RIFT IS NOT IN HAND. supply() counts both and answers "can I get this"; performing a
-- cure asks "can I eat this now", which is a different question. A death drops the pack
-- while the rift keeps its stock, and treating the two as equivalent had `eat bloodroot`
-- going out every two seconds against "What do you want to eat?" while paralysis never
-- cleared.
mock.feed("IRE.Rift.List", { { name = "bloodroot", amount = 500 } })
local riftUsable, riftReason = emunah.have.cure(bloodrootCure)
ok(not riftUsable, "rift stock alone does not make a cure performable")
ok(tostring(riftReason):find("in the rift, not in hand"),
   "...and says which of the two situations it is", riftReason)
eq(emunah.have.supply("bloodroot"), 500, "supply still counts the rift, for restocking")
eq(emunah.have.supply("bloodroot"), 500, "supply counts the rift")

-- ===========================================================================
suite("vector blocking")

engine = emunah.curing.engine
engine.clear()
engine.add("anorexia", "trigger")
eq(emunah.have.blockedBy("herb"), "anorexia", "anorexia blocks the herb vector")

local blocked, blockReason = emunah.have.cure(kelpCure)
ok(not blocked, "an eat cure is refused while anorexic")
ok(tostring(blockReason):find("blocked"), "refusal names the block", blockReason)
engine.clear()

-- ===========================================================================
suite("action queue")

local queue = emunah.queue
queue.reset()

queue.push("herb", "eat kelp", { priority = 10, tag = "asthma" })
eq(queue.pending("herb").command, "eat kelp", "queued on the herb vector")

-- Lower rank number = more urgent, and pre-empts.
queue.push("herb", "eat bloodroot", { priority = 5, tag = "paralysis" })
eq(queue.pending("herb").command, "eat bloodroot", "higher priority pre-empts")

-- A less urgent push is dropped, not stacked.
queue.push("herb", "eat ginseng", { priority = 50, tag = "illness" })
eq(queue.pending("herb").command, "eat bloodroot", "lower priority is dropped")

-- Re-pushing the SAME command must not log. The engine re-pushes a cure every tick while
-- the condition holds, which put dozens of "keeping drink health over drink health" lines
-- in one fight and buried everything worth reading.
mock.echoed = {}
queue.push("herb", "eat bloodroot", { priority = 5, tag = "paralysis" })
eq(#mock.echoed, 0, "an identical re-push is silent", table.concat(mock.echoed, " | "))

-- Vectors are independent.
queue.push("salve", "apply epidermal to body", { priority = 1, tag = "anorexia" })
eq(queue.pending("salve").command, "apply epidermal to body", "salve vector is separate")

mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
queue.flush()
eq(#mock.sent, 2, "flush sends one command per free vector")

-- The game announcing a balance is back must free the QUEUE SLOT too, not just the
-- balance. flush() refuses a vector while something is in flight on it, so without this the
-- slot stayed held until the confirm timeout -- and with the elixir confirm at 7s (the real
-- confirmation arrives late) that meant health sipping stopped for stretches of a fight.
emunah.queue.reset()
emunah.timers.stopAll()
emunah.queue.push("elixir", "drink health", { priority = 0, tag = "healhealth", confirm = 7.0,
   onSent = function() emunah.have.spend("elixir") end })
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
emunah.queue.flush()
ok(emunah.queue.awaiting("elixir") ~= nil, "the sip is in flight")

mock.line("You may drink another health or mana elixir.")
eq(emunah.queue.awaiting("elixir"), nil, "the game's own announcement confirms it")
eq(emunah.have.balance("elixir"), true, "...and frees the vector immediately")

emunah.queue.push("elixir", "drink health", { priority = 0, tag = "healhealth" })
mock.sent = {}
eq(emunah.queue.flush(), 1, "so the next sip can go out", table.concat(mock.sent, " | "))
emunah.queue.reset()

-- "What is it that you wish to drink?" -- no vial we hold contains that fluid. Nothing was
-- drunk, so nothing was spent, and the confirmation that would free the vector is never
-- coming. Live at 11:10:14.06 with `drink mana`. Health and mana share the elixir vector,
-- so leaving it held is what stopped health sipping in bursts.
emunah.queue.reset()
emunah.timers.stopAll()
emunah.queue.push("elixir", "drink mana", { priority = 0, tag = "healmana", confirm = 7.0,
   onSent = function() emunah.have.spend("elixir") end })
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
emunah.queue.flush()
ok(emunah.queue.awaiting("elixir") ~= nil, "the impossible sip goes out once")

mock.line("What is it that you wish to drink?")
eq(emunah.queue.awaiting("elixir"), nil, "a drink the game could not resolve frees the slot")
eq(emunah.have.balance("elixir"), true, "...and spends no sip balance, because none was used")

-- ...and the engine stops asking for a fluid it has just been told we do not have, while
-- still sipping the one we do. Without this the retry re-wedges the shared vector every few
-- seconds for as long as mana stays low, which is what stopped health going down.
local lowMana = { hp = "1000", maxhp = "1000", mp = "100", maxmp = "1000", bal = "1", eq = "1" }
emunah.curing.engine.enabled = true

emunah.queue.reset(); emunah.have.recover("elixir"); mock.sent = {}
mock.feed("Char.Vitals",
   { hp = "300", maxhp = "1000", mp = "100", maxmp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("drink health"),
   "health is still sipped while mana is suppressed", table.concat(mock.sent, " | "))

emunah.queue.reset(); emunah.have.recover("elixir"); mock.sent = {}
mock.feed("Char.Vitals", lowMana)
ok(not table.concat(mock.sent, " | "):find("drink mana"),
   "...and mana is not asked for again", table.concat(mock.sent, " | "))

mock.advance(emunah.curing.engine.MISSING_RETRY + 1)
emunah.queue.reset(); emunah.have.recover("elixir"); mock.sent = {}
mock.feed("Char.Vitals", lowMana)
ok(table.concat(mock.sent, " | "):find("drink mana"),
   "...until the retry window lapses, in case a vial has been filled",
   table.concat(mock.sent, " | "))

emunah.curing.engine.enabled = false
emunah.queue.reset()
emunah.timers.stopAll()

-- Stun blocks the whole flush: it blocks literally every command in Achaea, so a cure sent
-- into it is thrown away. The action stays queued, not lost, and goes out once it clears.
local detect = emunah.curing.detect
queue.push("herb", "eat kelp", { priority = 10, tag = "asthma" })
detect.stunned = true
mock.sent = {}
eq(queue.flush(), 0, "stunned: flush sends nothing")
eq(#mock.sent, 0, "...and nothing hit the game", table.concat(mock.sent, " | "))
eq(queue.pending("herb").command, "eat kelp", "...the action is still queued, not dropped")

detect.stunned = false
mock.sent = {}
eq(queue.flush(), 1, "clear: the still-queued action goes out")
ok(table.concat(mock.sent, " | "):find("eat kelp"), "...and it is the one that was waiting")
queue.reset()

-- ...but being PRONE must NOT block curing. An earlier version blocked both, which is wrong
-- (herbs and elixirs work fine lying down) and dangerous: knocked flat in a fight is exactly
-- when refusing to heal gets you killed. Only things that genuinely need you upright --
-- attacks, GET -- declare a standing requirement.
queue.push("herb", "eat kelp", { priority = 10, tag = "asthma" })
detect.prone = true
mock.sent = {}
eq(queue.flush(), 1, "prone: cures still go out -- healing must not stop when knocked down")
ok(table.concat(mock.sent, " | "):find("eat kelp"), "...and it is the cure that was waiting")
detect.prone = false
queue.reset()

-- The gate itself, stated directly.
ok(emunah.act.can(), "act: an unencumbered command is allowed")
detect.prone = true
ok(emunah.act.can(), "act: prone does not block a command with no standing requirement")
eq(emunah.act.blocked({ standing = true }), "prone", "act: ...but does block one that needs it")
detect.prone = false
detect.stunned = true
eq(emunah.act.blocked(), "stunned", "act: stun blocks even a command that needs nothing")
detect.stunned = false

-- ===========================================================================
suite("curing engine")

engine.clear()
queue.reset()
mock.sent = {}

-- Restock so cures are performable.
mock.feed("Char.Items.List", {
   location = "inv",
   items = {
      { id = "20", name = "some kelp", attrib = "e" },
      { id = "21", name = "an epidermal salve", attrib = "e" },
   },
})

engine.enabled = true
engine.add("asthma", "trigger")
engine.add("anorexia", "trigger")

engine.tick()
queue.flush()

local sentText = table.concat(mock.sent, " | ")
ok(sentText:find("apply epidermal"), "engine applies epidermal for anorexia", sentText)
-- Anorexia blocks eating, so the kelp cure for asthma must NOT be sent this tick.
ok(not sentText:find("eat kelp"), "engine does not eat while anorexic", sentText)

-- Clearing anorexia unblocks the herb vector.
engine.remove("anorexia")
emunah.have.recover("herb")
queue.reset()
mock.sent = {}
engine.tick()
queue.flush()
ok(table.concat(mock.sent, " | "):find("eat kelp"),
   "engine eats kelp for asthma once unblocked", table.concat(mock.sent, " | "))

engine.enabled = false

-- PERFORM HANDS: a second healing source on a different resource.
--
-- Worth having alongside the elixir precisely because it does not compete: the elixir
-- spends sip balance, this spends equilibrium, so both can be in flight at once. Its
-- threshold is deliberately lower -- this is the emergency, not the routine top-up.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = true
mock.feed("Char.Vitals", {
   hp = "700", maxhp = "1000", mp = "3000", maxmp = "3000", bal = "1", eq = "1",
})
engine.tick()
eq(queue.pending("equilibrium"), nil, "hands is not used for a routine top-up at 70%")

-- The engine ticks on the Char.Vitals push itself, so clear the record BEFORE feeding:
-- by the time mock.feed returns, the queue has already been built and flushed.
emunah.timers.stopAll()
queue.reset()
mock.sent = {}
mock.feed("Char.Vitals", { hp = "300", maxhp = "1000", bal = "1", eq = "1" })
local healed = table.concat(mock.sent, " | ")
ok(healed:find("perform hands"), "below the threshold, hands is sent", healed)
ok(healed:find("drink health"),
   "...alongside the elixir, which costs a different balance and so does not compete", healed)

-- It costs 3 seconds of equilibrium, and equilibrium will not report the loss until the
-- game has actually run it -- so the vector has to be held meanwhile.
eq(emunah.have.balance("equilibrium"), false,
   "equilibrium is held for the duration, not just until Char.Vitals catches up")
mock.feed("Char.Vitals", { eq = "1" })
eq(emunah.have.balance("equilibrium"), false,
   "...even if Char.Vitals reports equilibrium back early")
mock.advance(emunah.curing.engine.HANDS_EQUILIBRIUM + 0.1)
eq(emunah.have.balance("equilibrium"), true, "...and frees once the cost has elapsed")
queue.reset(); engine.enabled = false

-- ===========================================================================
suite("irid moss")

-- A third healing source, on a balance nothing else uses: it restores health AND mana,
-- announces its own recovery ("You may eat another bit of irid moss or potash."), and has
-- to be pulled out of the rift before it can be eaten.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = true
-- Background restocking off for this suite: it shares the rift vector and would satisfy
-- the need before the healing path could ask, which is correct in play but hides the thing
-- under test here. Its own suite follows.
emunah.config.set("curing.restock", false)
-- The real payload shape, from the GMCP trace at 11:42:02: the rift calls this "moss" and
-- carries "irid" as the DESCRIPTION, while OUTR and the cure tables both say "irid".
mock.feed("IRE.Rift.List", { { name = "moss", desc = "irid", amount = 498 } })
eq(emunah.have.inRift("irid"), 498, "the rift is found by the word OUTR uses, not just by name")
mock.feed("Char.Items.List", { location = "inv", items = {} })

mock.sent = {}
mock.feed("Char.Vitals", { hp = "300", maxhp = "1000", mp = "1000", maxmp = "1000",
   bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("outr irid"),
   "with none held, the moss is pulled from the rift first", table.concat(mock.sent, " | "))

-- One pull at a time. The item does not appear in Char.Items instantly, and without a slot
-- held every tick in that window pulls another one.
mock.sent = {}
mock.feed("Char.Vitals", { hp = "300", maxhp = "1000" })
ok(not table.concat(mock.sent, " | "):find("outr irid"),
   "...and not again while that pull is in flight", table.concat(mock.sent, " | "))

mock.line("You remove 1 irid, bringing the total in the rift to 498.")
eq(emunah.queue.awaiting("rift"), nil, "the game's confirmation frees the pull")

-- Held: now it can be eaten.
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "90", name = "some irid moss", attrib = "e" },
} })
queue.reset(); mock.sent = {}
mock.feed("Char.Vitals", { hp = "300", maxhp = "1000", mp = "1000", maxmp = "1000" })
ok(table.concat(mock.sent, " | "):find("eat irid"),
   "once held, it is eaten", table.concat(mock.sent, " | "))

eq(emunah.have.balance("moss"), false, "its own balance is held while it recovers")
mock.line("You eat some irid moss.")
mock.line("You may eat another bit of irid moss or potash.")
eq(emunah.have.balance("moss"), true, "...and the game's announcement frees it")
eq(emunah.queue.awaiting("moss"), nil, "...along with the queue slot")

-- Low mana alone is reason enough: it refills both bars.
queue.reset(); emunah.timers.stopAll(); mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", mp = "100", maxmp = "1000" })
ok(table.concat(mock.sent, " | "):find("eat irid"),
   "low mana alone is reason enough, because it refills both",
   table.concat(mock.sent, " | "))

-- Anorexia blocks EATING, not the pull. Blocking both would stop us stocking up for the
-- moment it lifts.
queue.reset(); emunah.timers.stopAll(); mock.sent = {}
engine.add("anorexia", "trigger")
mock.feed("Char.Vitals", { hp = "300", maxhp = "1000" })
ok(not table.concat(mock.sent, " | "):find("eat irid"),
   "anorexia stops the moss being eaten", table.concat(mock.sent, " | "))

mock.feed("Char.Items.List", { location = "inv", items = {} })
queue.reset(); emunah.timers.stopAll(); mock.sent = {}
mock.feed("Char.Vitals", { hp = "300", maxhp = "1000" })
ok(table.concat(mock.sent, " | "):find("outr irid"),
   "...but the pull still happens while anorexic", table.concat(mock.sent, " | "))
engine.remove("anorexia")

-- Dead: neither works. Nothing else in act.lua gates on this, so it is opt-in per command.
queue.reset(); emunah.timers.stopAll(); mock.sent = {}
mock.feed("Char.Vitals", { hp = "0", maxhp = "1000" })
local whileDead = table.concat(mock.sent, " | ")
ok(not whileDead:find("irid"), "neither the pull nor the eat is sent while dead", whileDead)
eq(emunah.act.blocked({ alive = true }), "dead", "and act says why")

-- Back to a clean, alive, fully-balanced character: healing above spends equilibrium on
-- `perform hands`, and leaving eq false here fails a later suite for no related reason.
engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", mp = "1000", maxmp = "1000",
   bal = "1", eq = "1" })

-- ===========================================================================
suite("defence keep-up: custom commands and the attempt budget")

local keepup = emunah.curing.defkeepup
emunah.config.set("defences.keepup", {})
emunah.config.set("defences.commands", {})
keepup.resetBudget()
queue.reset(); emunah.timers.stopAll()
engine.clear()
mock.feed("Char.Defences.List", {})

-- A defence this file has never heard of, raised by a command supplied at the call site.
-- Tattoos are the case that needs this: the name Char.Defences reports is not something to
-- guess, and the command that raises one costs a full balance whether or not it was needed.
keepup.add("moss", "touch moss")
keepup.enabled = true
-- Clear BEFORE the feed: a Char.Vitals push drives the tick itself, so by the time it
-- returns the command has already gone out.
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("touch moss"),
   "a defence with a supplied command is raised", table.concat(mock.sent, " | "))

-- Once it is up, it is left alone -- touching an active tattoo costs the balance again for
-- nothing. The guard is Char.Defences, not our own bookkeeping.
mock.feed("Char.Defences.Add", { name = "moss" })
queue.reset(); emunah.timers.stopAll(); mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("touch moss"),
   "an active defence is never re-raised", table.concat(mock.sent, " | "))

-- THE BUDGET. A defence that never appears after being raised must not be retried forever:
-- each attempt spends a real balance, and the usual cause is a name that does not match
-- what the game reports, which no amount of retrying fixes.
mock.feed("Char.Defences.List", {})
keepup.resetBudget()
local raised = 0
for _ = 1, 6 do
   queue.reset(); emunah.timers.stopAll(); mock.sent = {}
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
   if table.concat(mock.sent, " | "):find("touch moss") then raised = raised + 1 end
end
eq(raised, keepup.ATTEMPTS,
   "a defence that never appears is dropped after a bounded number of attempts",
   tostring(raised))

-- The defence actually appearing is proof the command works, and clears the history.
mock.feed("Char.Defences.Add", { name = "moss" })
mock.feed("Char.Defences.List", {})
queue.reset(); emunah.timers.stopAll(); mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("touch moss"),
   "...and the budget resets once it is seen, so a stripped defence is raised again",
   table.concat(mock.sent, " | "))

keepup.enabled = false
emunah.config.set("defences.keepup", {})
emunah.config.set("defences.commands", {})
keepup.resetBudget()
queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Defences.List", {})

-- ===========================================================================
suite("focus curing")

-- Focus clears mental afflictions, and against a Priest every mental affliction left up is
-- 2% more sapping potential -- so the vector matters more than its cure count suggests.
local afflist2 = emunah.curing.afflist

-- ANOREXIA OUTRANKS EVERY MENTAL AFFLICTION ON FOCUS. A mental affliction left up is a
-- slow loss; anorexia is a shut vector, and the vector it shuts is where most cures live.
-- Ranked behind a mental it would wait behind one, which is the ordering that turns a
-- survivable position into a lock.
local worst, worstName = math.huge, nil
for name in pairs(afflist2.afflictions) do
   local rank = afflist2.priority(name, "focus")
   if rank and rank < worst then worst, worstName = rank, name end
end
eq(worstName, "anorexia", "anorexia is the most urgent focus cure", tostring(worstName))

engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = true
mock.feed("Char.Items.List", { location = "inv", items = {} })
mock.feed("IRE.Rift.List", {})
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", mp = "3000", maxmp = "3000",
   bal = "1", eq = "1" })

-- FOCUS COSTS NEITHER BALANCE NOR EQUILIBRIUM, only its own mental balance -- so it goes
-- out with both spent, which is exactly when a lock leaves nothing else available.
engine.add("stupidity", "gmcp")
emunah.gmcp.vitals.bal, emunah.gmcp.vitals.eq = false, false
queue.reset(); mock.sent = {}
engine.tick(); queue.flush()
ok(table.concat(mock.sent, " | "):find("focus"),
   "focus goes out with no balance and no equilibrium", table.concat(mock.sent, " | "))
emunah.gmcp.vitals.bal, emunah.gmcp.vitals.eq = true, true

-- IMPATIENCE SHUTS IT, the same way anorexia shuts eating.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.add("stupidity", "gmcp")
engine.add("impatience", "gmcp")
mock.sent = {}
engine.tick(); queue.flush()
ok(not table.concat(mock.sent, " | "):find("focus"),
   "impatience blocks focusing", table.concat(mock.sent, " | "))
eq(engine.refusals["stupidity"], "focus is blocked by impatience",
   "...and says so", tostring(engine.refusals["stupidity"]))

-- GUILT: eat it away rather than focus -- but only while eating it away is possible.
-- The test is the capability, not the affliction: being out of lobelia shuts the same door
-- anorexia does, and in a real fight it is the commoner way to lose it.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "9", name = "a lobelia seed", attrib = "e" },
} })
mock.feed("IRE.Rift.List", {})
engine.add("stupidity", "trigger")
engine.add("guilt", "trigger")
mock.sent = {}
engine.tick(); queue.flush()
ok(not table.concat(mock.sent, " | "):find("focus"),
   "with lobelia in hand, guilt is eaten away rather than focused through",
   table.concat(mock.sent, " | "))

-- Out of lobelia: nothing can eat the guilt, so focusing is now unambiguously right.
mock.feed("Char.Items.List", { location = "inv", items = {} })
queue.reset(); emunah.timers.stopAll(); mock.sent = {}
engine.tick(); queue.flush()
ok(table.concat(mock.sent, " | "):find("focus"),
   "out of lobelia, it focuses rather than doing nothing at all",
   table.concat(mock.sent, " | "))

-- Anorexia shuts the same door, which is the case the rule was first described with.
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "9", name = "a lobelia seed", attrib = "e" },
} })
engine.add("anorexia", "trigger")
queue.reset(); emunah.timers.stopAll(); mock.sent = {}
engine.tick(); queue.flush()
ok(table.concat(mock.sent, " | "):find("focus"),
   "...and anorexia does too, lobelia in hand or not",
   table.concat(mock.sent, " | "))

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false

-- ===========================================================================
suite("restocking chains rather than waiting for prompts")

-- Restocking runs on the engine tick, and the engine ticks on Char.Vitals -- which arrives
-- with a prompt. An idle character produces no prompts, so after login `outr 3 bloodroot`
-- at 18:14:50 was followed by `outr 3 pear` at 18:15:05: fifteen seconds spent waiting for
-- something to happen that would issue the next pull. The game confirming one pull is the
-- natural moment to send the next, and it arrives in about a fifth of a second.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = true
engine.forgetStock()
-- An earlier suite switches restocking off for its own isolation and a later one switches
-- it back on; this suite sits between them, so it says what it needs and puts it back.
local restockWas = emunah.config.get("curing.restock", true)
emunah.config.set("curing.restock", true)
mock.feed("IRE.Rift.List", {
   { name = "moss", desc = "irid", amount = 400 },
   { name = "bloodroot", amount = 700 },
})
-- Learning what the rift holds is itself a reason to restock, so it will have taken the
-- vector already. Clear it before the listing this case is actually about.
queue.reset(); emunah.timers.stopAll(); engine.forgetStock()
mock.sent = {}
mock.feed("Char.Items.List", { location = "inv", items = {} })
ok(table.concat(mock.sent, " | "):find("outr 3 bloodroot"),
   "the first pull goes out on the listing", table.concat(mock.sent, " | "))

-- No prompt, no tick -- and yet the next pull follows, because the confirmation drives it.
mock.feed("Char.Items.Add", { location = "inv",
   item = { id = "1", name = "a group of 3 pieces of bloodroot", attrib = "gre" } })
mock.sent = {}
mock.line("You remove 3 bloodroot, bringing the total in the rift to 697.")
eq(#mock.sent, 0, "the chain is not sent from inside the trigger itself")
mock.advance(engine.RESTOCK_CHAIN + 0.01)
ok(table.concat(mock.sent, " | "):find("outr 3 irid"),
   "...it follows the confirmation, without waiting for a prompt",
   table.concat(mock.sent, " | "))

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false
engine.forgetStock()
emunah.config.set("curing.restock", restockWas)

-- ===========================================================================
suite("restocking does not oscillate on a stale count")

-- Observed after a death dropped everything: `outr 3 ash` went out, the count still read 0
-- because Char.Items had not caught up, so a second `outr 3 ash` followed. The count then
-- read 6, which is over target, so `inr 3 ash` went out twice and it read 0 again. Four
-- commands a second, indefinitely.
--
-- The rift vector alone cannot stop it: the game's own "You remove 3 ash" frees the vector,
-- and that arrives BEFORE the inventory update it describes.
engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.forgetStock()
engine.enabled = true
local restockWas2 = emunah.config.get("curing.restock", true)
emunah.config.set("curing.restock", true)
mock.feed("IRE.Rift.List", { { name = "ash", amount = 100 } })
queue.reset(); emunah.timers.stopAll(); engine.forgetStock()
mock.feed("Char.Items.List", { location = "inv", items = {} })

mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
local first = table.concat(mock.sent, " | ")
ok(first:find("outr 3 ash") or emunah.gmcp.items.inventoryKnown(),
   "a pull goes out for an item we hold none of", first)

-- The confirmation frees the vector while the count is still stale. Nothing further may be
-- decided about that item until the count actually moves.
mock.line("You remove 3 ash, bringing the total in the rift to 97.")
mock.sent = {}
for _ = 1, 5 do mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" }) end
ok(not table.concat(mock.sent, " | "):find("ash"),
   "no second pull, and no store, while the count has not caught up",
   table.concat(mock.sent, " | "))

-- The count catching up is what releases it -- and at target, neither direction fires.
mock.feed("Char.Items.Add", { location = "inv",
   item = { id = "1", name = "a group of 3 pieces of prickly ash bark", attrib = "gre" } })
eq(emunah.have.quantity("ash"), 3, "the stack is counted correctly once it lands")
queue.reset(); emunah.timers.stopAll()
mock.sent = {}
for _ = 1, 3 do mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" }) end
ok(not table.concat(mock.sent, " | "):find("ash"),
   "at exactly the target, it neither pulls nor stores",
   table.concat(mock.sent, " | "))

-- And the settle window expires rather than wedging: an item whose count never moves is
-- still bounded by the attempt budget, not stuck forever.
mock.feed("Char.Items.List", { location = "inv", items = {} })
queue.reset(); emunah.timers.stopAll(); engine.forgetStock()
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("outr 3 ash"),
   "a fresh decision is made once the ledger is clear", table.concat(mock.sent, " | "))

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false
engine.forgetStock()
emunah.config.set("curing.restock", restockWas2)

-- ===========================================================================
suite("the cure the server itself suggests")

-- Char.Afflictions.Add carries a `cure` field, and it was ignored since the module was
-- written. Meanwhile the engine logged "Tracking unknown affliction" and did nothing --
-- with the answer sitting in the same payload:
--
--   {cure="EAT KELP" desc="Weariness increases..." name="weariness"}
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = true
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "1", name = "a piece of kelp", attrib = "e" },
} })
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })

eq(afflist.known("weariness"), false, "weariness is not in the cure table")
mock.sent = {}
mock.feed("Char.Afflictions.Add", { name = "weariness", cure = "EAT KELP",
   desc = "Weariness increases the rate at which you use endurance." })
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("eat kelp"),
   "an affliction the table has never heard of is cured from the server's own suggestion",
   table.concat(mock.sent, " | "))

-- The table still wins where it has an opinion: it carries priority, which the server does
-- not send and which decides what to cure first when several things are wrong at once.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "1", name = "a piece of kelp", attrib = "e" },
   { id = "2", name = "a bloodroot leaf", attrib = "e" },
} })
mock.feed("Char.Afflictions.Add", { name = "weariness", cure = "EAT KELP" })
mock.feed("Char.Afflictions.Add", { name = "paralysis", cure = "EAT BLOODROOT" })
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("eat bloodroot"),
   "a known cure takes the vector ahead of a server-suggested one",
   table.concat(mock.sent, " | "))

-- A verb this system cannot map to a vector is skipped and said out loud, not guessed into
-- a command.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.echoed = {}
mock.feed("Char.Afflictions.Add", { name = "somethingnew", cure = "WAGGLE YOUR EARS" })
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("waggle"),
   "an unmappable verb is not sent", table.concat(mock.sent, " | "))
ok(table.concat(mock.echoed, " "):find("not one this system maps"),
   "...and is reported", table.concat(mock.echoed, " "))

-- The herb balance is announced by the game, and nothing was listening: every herb cure ran
-- on the fallback timer and held its slot for the full confirmation wait, which is why a
-- real fight logged "No confirmation for [herb] eat kelp -- re-arming" after every cure.
engine.clear(); queue.reset(); emunah.timers.stopAll()
emunah.have.spend("herb")
eq(emunah.have.balance("herb"), false, "eating spends the herb balance")
mock.line("You may eat another plant or mineral.")
eq(emunah.have.balance("herb"), true, "...and the game's own announcement returns it")

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false
mock.feed("Char.Afflictions.List", {})

-- ===========================================================================
suite("a cure is not sent twice for the same affliction")

-- The spam this replaces: `eat kelp` going out repeatedly for one clumsiness. The first
-- attempt at fixing it recorded which cure "had no effect" and refused to use it again --
-- and blacklisted `eat bloodroot` for paralysis, `eat lobelia` for guilt and `eat kelp` for
-- clumsiness within twelve seconds. All correct cures, disabled mid-fight.
--
-- The reason is that the reply cannot be attributed: the herb balance returns on the game's
-- own announcement, so by the time "The plant has no effect." prints, a different cure is
-- already in flight. The guard that works needs no attribution at all.
engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.forgetIneffective()
engine.enabled = true
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "1", name = "a piece of kelp", attrib = "e" },
   { id = "2", name = "a bloodroot leaf", attrib = "e" },
} })
engine.add("clumsiness", "trigger")
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("eat kelp"), "the cure is sent",
   table.concat(mock.sent, " | "))

-- The herb balance returns, the affliction is still listed, and the cure must NOT go again:
-- the first one has not been answered yet.
mock.sent = {}
for _ = 1, 4 do
   mock.line("You may eat another plant or mineral.")
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
end
ok(not table.concat(mock.sent, " | "):find("eat kelp"),
   "a second cure for the same affliction is not sent while the first is unanswered",
   table.concat(mock.sent, " | "))

-- Once the guard lapses, a genuinely still-present affliction is treated again.
mock.advance(engine.CURE_GUARD + 0.01)
emunah.have.recover("herb")
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("eat kelp"),
   "...and is retried once the guard lapses", table.concat(mock.sent, " | "))

-- The affliction going away releases the guard immediately -- the next affliction should
-- not wait out a window belonging to one that has been cured.
engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.forgetIneffective()
engine.add("paralysis", "trigger")
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
engine.remove("paralysis")
engine.add("paralysis", "trigger")
-- The previous cure is still in flight on the vector; that is a separate guard.
queue.reset(); emunah.queue.confirm("herb"); emunah.have.recover("herb")
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("eat bloodroot"),
   "a cured-and-reapplied affliction is treated immediately",
   table.concat(mock.sent, " | "))

-- And "no effect" never disables a cure. It frees the vector and reconciles, nothing more.
mock.line("The plant has no effect.")
engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.forgetIneffective()
engine.add("paralysis", "trigger")
emunah.have.recover("herb")
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("eat bloodroot"),
   "a correct cure is never disabled by a reply it cannot be matched to",
   table.concat(mock.sent, " | "))

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false
engine.forgetIneffective()

-- ===========================================================================
suite("curing an affliction is not the balance coming back")

-- The cause of every "The plant has no effect." in a night of arena logs. A GMCP affliction
-- removal was treated as proof the balance had returned as well as the cure having landed:
-- eating bloodroot cures paralysis instantly AND costs a full herb balance, so the next eat
-- went out 0.22s later, inside the real balance, where Achaea consumes the herb and does
-- nothing.
engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.forgetIneffective()
engine.enabled = true
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "1", name = "a bloodroot leaf", attrib = "e" },
   { id = "2", name = "a piece of kelp", attrib = "e" },
} })
mock.feed("IRE.Rift.List", {})

-- Two afflictions on the same vector: paralysis first by priority, clumsiness behind it.
mock.feed("Char.Afflictions.Add", { name = "paralysis", cure = "EAT BLOODROOT" })
mock.feed("Char.Afflictions.Add", { name = "clumsiness", cure = "EAT KELP" })
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("eat bloodroot"),
   "the first cure goes out", table.concat(mock.sent, " | "))
eq(emunah.have.balance("herb"), false, "...and spends the herb balance")

-- The cure lands. The affliction is gone -- and the balance is NOT back.
mock.sent = {}
mock.feed("Char.Afflictions.Remove", { "paralysis" })
eq(emunah.have.balance("herb"), false,
   "curing an affliction does not return the balance it cost")
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("eat kelp"),
   "so the next cure does not go out inside the balance",
   table.concat(mock.sent, " | "))

-- The game announcing the balance is what releases it, and then the next cure follows.
mock.line("You may eat another plant or mineral.")
eq(emunah.have.balance("herb"), true, "the game's own announcement returns it")
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("eat kelp"),
   "...and the next cure goes out then", table.concat(mock.sent, " | "))

-- "The plant has no effect." means a herb was CONSUMED and treated nothing, because it went
-- down inside the balance. The balance is therefore not free -- it has just been spent
-- again, on nothing. Recovering it there was the same mistake one layer on: every following
-- bloodroot also landed off balance, which is why paralysis was never cured.
engine.clear(); queue.reset(); emunah.timers.stopAll()
emunah.have.recover("herb")
eq(emunah.have.balance("herb"), true, "herb balance starts free")
mock.line("The plant has no effect.")
eq(emunah.have.balance("herb"), false,
   "a wasted eat spends the balance rather than freeing it")

-- Whereas an eat that never happened costs nothing and must free it.
emunah.have.spend("herb")
mock.line("What do you want to eat?")
eq(emunah.have.balance("herb"), true,
   "an eat that did not resolve consumed nothing, so the balance is free")

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false
mock.feed("Char.Afflictions.List", {})

-- ===========================================================================
suite("a cure you cannot reach is not a cure")

-- After a death dropped the pack, `eat bloodroot` went out every two seconds against "What
-- do you want to eat?" while paralysis never cleared. The rift still held 750 bloodroot, so
-- the cure read as performable -- but you cannot eat from the rift.
engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.forgetIneffective()
engine.enabled = true
mock.feed("Char.Items.List", { location = "inv", items = {} })
mock.feed("IRE.Rift.List", { { name = "bloodroot", amount = 750 } })
engine.add("paralysis", "trigger")

mock.sent = {}
for _ = 1, 4 do
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   emunah.have.recover("herb")
   mock.advance(engine.CURE_GUARD + 0.01)
end
ok(not table.concat(mock.sent, " | "):find("eat bloodroot"),
   "a herb that is only in the rift is never eaten", table.concat(mock.sent, " | "))
eq(engine.refusals["paralysis"], "bloodroot is in the rift, not in hand",
   "...and the reason distinguishes that from being out of it entirely",
   tostring(engine.refusals["paralysis"]))

-- Once the restocker has pulled it, the cure becomes possible.
mock.feed("Char.Items.Add", { location = "inv",
   item = { id = "1", name = "a bloodroot leaf", attrib = "gre" } })
queue.reset(); emunah.timers.stopAll(); mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("eat bloodroot"),
   "...and goes out the moment it is in hand", table.concat(mock.sent, " | "))

-- An eat that does not resolve means our view of inventory is wrong by definition, so it
-- asks for the real list rather than waiting for whatever would have corrected it.
-- Requests are paced, so clear anything already queued or the first thing on the wire is
-- whatever was waiting rather than the one this sends.
emunah.gmcp.clearRequests()
emunah.timers.stopAll()
mock.gmcpSent = {}
mock.line("What do you want to eat?")
ok(table.concat(mock.gmcpSent, " | "):find("Char.Items.Inv"),
   "a failed eat re-reads inventory", table.concat(mock.gmcpSent, " | "))
emunah.gmcp.clearRequests()

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false

-- ===========================================================================
suite("paralysis blocks almost everything")

-- Three verbatim refusals from the arena, all for actions the engine kept sending anyway:
--   "Your state of paralysis prevents you from doing that."        (drink health)
--   "You are paralysed and cannot do that."                        (drink health)
--   "Frustratingly, your body won't respond to your call to action." (perform hands)
--
-- Eating is the exception and has to be: bloodroot is what cures paralysis, so blocking
-- everything would lock the character out of its own escape.
engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.forgetIneffective()
engine.enabled = true
detect.prone = false
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "1", name = "a bloodroot leaf", attrib = "e" },
} })
mock.feed("Char.Vitals", { hp = "300", maxhp = "1000", mp = "3000", maxmp = "3000",
   bal = "1", eq = "1" })

engine.add("paralysis", "trigger")
queue.reset(); emunah.timers.stopAll(); mock.sent = {}
engine.tick(); queue.flush()
local whileParalysed = table.concat(mock.sent, " | ")
ok(whileParalysed:find("eat bloodroot"),
   "the eat that cures paralysis still goes out", whileParalysed)
ok(not whileParalysed:find("drink health"),
   "...but the sip does not, because the game would refuse it", whileParalysed)
ok(not whileParalysed:find("perform hands"),
   "...and neither does hands", whileParalysed)

-- Cured, and everything resumes.
engine.remove("paralysis")
queue.reset(); emunah.timers.stopAll(); emunah.have.recover("elixir")
mock.sent = {}
engine.tick(); queue.flush()
local after = table.concat(mock.sent, " | ")
ok(after:find("drink health"), "once it is cured, healing resumes", after)

-- The refusals themselves assert the affliction, ahead of any GMCP push.
engine.clear()
mock.line("Your state of paralysis prevents you from doing that.")
ok(engine.has("paralysis"), "a paralysis refusal asserts the affliction")
engine.clear()
mock.line("Frustratingly, your body won't respond to your call to action.")
ok(engine.has("paralysis"), "...in all its wordings")

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false

-- ===========================================================================
suite("standing up, once")

-- Prone is re-evaluated on every tick, and STAND had no in-flight guard -- so one `sit`
-- produced two STANDs, the second answered with "You are not fallen or kneeling."
detect.prone = false
emunah.timers.stopAll()
mock.sent = {}
mock.feed("Char.Afflictions.Add", { name = "prone", cure = "STAND" })
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
local stands = 0
for _, command in ipairs(mock.sent) do
   if command == "stand" then stands = stands + 1 end
end
eq(stands, 1, "one knockdown sends exactly one STAND",
   table.concat(mock.sent, " | "))

-- And a genuine second knockdown, later, still stands.
mock.advance(detect.STAND_GUARD + 0.01)
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("stand"),
   "...and a retry is allowed once the round trip has passed",
   table.concat(mock.sent, " | "))

detect.prone = false
emunah.timers.stopAll()
mock.feed("Char.Afflictions.List", {})

-- ===========================================================================
suite("loki: DIAG for the ground truth")

-- Char.Afflictions can be relied on for every affliction in player combat except two.
-- Blackout has no answer and is waited out. Loki does have one: DIAG.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = true
mock.feed("Char.Items.List", { location = "inv", items = {} })

-- Requires BOTH balance and equilibrium, so it waits for the next balance rather than being
-- refused into a rejection message.
engine.add("loki", "trigger")
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "0", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("diag"),
   "DIAG waits for balance", table.concat(mock.sent, " | "))

mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("diag"),
   "...and goes out on the next balance", table.concat(mock.sent, " | "))

-- Consumes 1s of equilibrium, and does NOT consume balance -- the same require-versus-
-- consume split as smite.
eq(emunah.have.balance("equilibrium"), false,
   "DIAG spends equilibrium immediately, before Char.Vitals catches up")
eq(emunah.gmcp.vitals.bal, true, "...and does not spend balance")
mock.advance(engine.DIAG_EQUILIBRIUM + 0.1)
eq(emunah.have.balance("equilibrium"), true, "...for one second")

-- Once per bout, not once per tick: it costs the resource attacking needs.
queue.reset(); mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("diag"),
   "DIAG is sent once per bout of loki, not every prompt",
   table.concat(mock.sent, " | "))

-- Loki clearing and returning is a new bout.
engine.remove("loki")
queue.reset(); emunah.timers.stopAll(); mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
engine.add("loki", "trigger")
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("diag"),
   "...and again when loki returns", table.concat(mock.sent, " | "))

-- Cured before the balance arrived: the question is resolved, so do not spend on it.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.add("loki", "trigger")
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "0", eq = "1" })
eq(queue.pending("equilibrium").command, "diag", "queued while waiting for balance")
engine.remove("loki")
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("diag"),
   "loki cured while it waited means the equilibrium is not spent",
   table.concat(mock.sent, " | "))

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false

-- ===========================================================================
suite("a queued action is re-checked before it is sent")

-- Observed: `perform hands` going out at full health. It had been queued at 30% while
-- equilibrium was spent -- attacking and penitence both want that vector -- and by the time
-- equilibrium came back the health it was queued for had recovered. The queue sent it
-- anyway, because nothing re-asked whether it was still wanted.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = true
mock.feed("Char.Items.List", { location = "inv", items = {} })

-- Below the hands threshold, but equilibrium is spent, so it waits.
mock.feed("Char.Vitals", { hp = "300", maxhp = "1000", mp = "3000", maxmp = "3000",
   bal = "1", eq = "0" })
eq(queue.pending("equilibrium").command, "perform hands",
   "hands is queued while equilibrium is unavailable")

-- Health recovers before equilibrium does.
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("perform hands"),
   "a heal queued at 30% is not sent at 100%", table.concat(mock.sent, " | "))
eq(queue.pending("equilibrium"), nil, "...and is dropped rather than left waiting")

-- Still sent when it is still wanted, which is the case that must not regress.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Vitals", { hp = "300", maxhp = "1000", bal = "1", eq = "0" })
mock.sent = {}
mock.feed("Char.Vitals", { hp = "300", maxhp = "1000", eq = "1" })
ok(table.concat(mock.sent, " | "):find("perform hands"),
   "a heal that is still needed goes out", table.concat(mock.sent, " | "))

-- The same applies to a cure whose affliction another vector already removed.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "1", name = "some bloodroot", attrib = "e" },
} })
emunah.have.spend("herb")            -- herb balance busy, so the cure waits
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
engine.add("paralysis", "gmcp")
engine.tick()
eq(queue.pending("herb").command, "eat bloodroot", "the cure is queued behind herb balance")

engine.remove("paralysis")           -- cured by something else meanwhile
emunah.have.recover("herb")
mock.sent = {}
queue.flush()
ok(not table.concat(mock.sent, " | "):find("eat bloodroot"),
   "a cure for an affliction that is already gone is not sent",
   table.concat(mock.sent, " | "))

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false

-- ===========================================================================
suite("namedb: who is a person, and what are they")

local ndb = emunah.namedb
ndb.people = {}
ndb.hostile = { city = {}, house = {}, order = {} }

-- Set directly rather than feeding Char.Status: that message also drives class detection,
-- and a suite that quietly loads a class module changes what later suites are testing.
local savedCity, savedCharacter = emunah.gmcp.status.values.city, emunah.gmcp.character
emunah.gmcp.status.values.city = "Targossas"
emunah.gmcp.character = "Saemora"

-- Give chat somewhere to render, or the channel message below trips the no-console warning
-- and the test that asserts that warning fires later finds it already spent.
local savedConsole, savedMode = emunah.ui.chat.console, emunah.ui.chat.mode
emunah.ui.chat.console = { decho = function() end }
emunah.ui.chat.mode = "plain"

-- A stranger is neutral. That is the honest answer, and it is not the same as an enemy.
eq(ndb.relationship("Nobody"), "neutral", "an unknown name is neutral, not hostile")
ok(ndb.attackable("Nobody"), "...and may be targeted if chosen explicitly")

-- Derivation: organisations, checked against our own.
ndb.set("Anzerloi", "city", "Targossas")
eq(ndb.relationship("Anzerloi"), "ally", "someone in our own city derives as an ally")
eq(ndb.attackable("Anzerloi"), false, "...and can never be targeted")

ndb.set("Malefactor", "city", "Mhaldor")
eq(ndb.relationship("Malefactor"), "neutral",
   "another city is not hostile by itself -- that has to be declared")
ndb.setHostile("city", "Mhaldor", true)
eq(ndb.relationship("Malefactor"), "enemy", "...and once the city is marked hostile, it is")
ok(ndb.attackable("Malefactor"), "an enemy is targetable")

-- DECLARATION BEATS DERIVATION, always. A name someone took the trouble to mark carries
-- information no organisation table has.
ndb.iff("Anzerloi", "enemy")
eq(ndb.relationship("Anzerloi"), "enemy",
   "an explicit iff overrides shared citizenship")
ndb.iff("Anzerloi", "auto")
eq(ndb.relationship("Anzerloi"), "ally", "...and auto hands it back to derivation")

-- Never ourselves, however the question is asked.
eq(ndb.relationship("Saemora"), "self", "we are not a third party")
eq(ndb.attackable("Saemora"), false, "...and never attackable")

-- GMCP populates it exactly: room players and channel talkers are real sightings. Neither
-- says anything about allegiance, so neither sets a relationship.
mock.feed("Room.Players", { { name = "Wanderer", fullname = "Wanderer, a stranger" } })
ok(ndb.known("Wanderer"), "someone in the room is recorded")
eq(ndb.get("Wanderer").fullname, "Wanderer, a stranger", "...with the honorific form")
eq(ndb.relationship("Wanderer"), "neutral", "...and no allegiance invented for them")

mock.feed("Comm.Channel.Text", { channel = "ct", talker = "Talker", text = "hello" })
ok(ndb.known("Talker"), "a channel talker is recorded")

-- PvP REFUSES AN ALLY. Targeting is already explicit, so this guards against a typo, a
-- name resolved from game text, or a target surviving a change of allegiance.
local pvp = emunah.pvp
pvp.clearTarget()
eq(pvp.setTarget("Anzerloi"), false, "PvP refuses to target an ally")
eq(pvp.target, nil, "...and no target is set")
ok(pvp.setTarget("Malefactor"), "an enemy is accepted")
pvp.clearTarget()

-- Notes accumulate rather than overwrite: they are judgement, not data.
ndb.note("Malefactor", "opens with a lock")
ndb.note("Malefactor", "flees below 40%")
eq(#ndb.get("Malefactor").notes, 2, "notes accumulate")

-- Import is additive. Someone else's file is evidence about people we have not met, not a
-- correction of judgement we have already recorded about people we have.
ndb.iff("Malefactor", "ally")
local added, updated = ndb.import({ people = {
   ["malefactor"] = { name = "Malefactor", iff = "enemy", class = "Blademaster",
                      notes = { { text = "imported note" } } },
   ["newcomer"]   = { name = "Newcomer", city = "Cyrene" },
} })
eq(added, 1, "an unknown person is added by import")
eq(ndb.get("Malefactor").iff, "ally", "...but our own declaration is never overwritten")
eq(ndb.get("Malefactor").class, "Blademaster", "...while a field we lacked is filled in")
eq(#ndb.get("Malefactor").notes, 3, "...and notes merge")

ndb.people = {}
ndb.hostile = { city = {}, house = {}, order = {} }
emunah.gmcp.status.values.city, emunah.gmcp.character = savedCity, savedCharacter
emunah.ui.chat.console, emunah.ui.chat.mode = savedConsole, savedMode

-- ===========================================================================
suite("touch tree: the last resort")

-- The Tree of Life tattoo costs no balance and no equilibrium, only its own tree balance --
-- which is why it still works when everything else has been taken, and why it is only worth
-- spending then. No entry in afflist.lua names `tree` as a vector, because which
-- afflictions it clears has never been verified; this fires on the STATE the tattoo exists
-- for, not on a claimed mapping.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = true
mock.feed("Char.Defences.List", { { name = "tree" } })
mock.feed("Char.Items.List", { location = "inv", items = {} })
mock.feed("IRE.Rift.List", {})

-- Curable normally: the tattoo is not touched, however long it sits.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "1", name = "some bloodroot", attrib = "e" },
} })
engine.add("paralysis", "trigger")
mock.advance(engine.TREE_DWELL + 1)
queue.reset(); mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("touch tree"),
   "an affliction that can be cured normally does not spend the tattoo",
   table.concat(mock.sent, " | "))

-- Nothing can cure it: out of the herb, and the rift is empty too.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Items.List", { location = "inv", items = {} })
engine.add("paralysis", "trigger")
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("touch tree"),
   "...and not immediately: a refusal that clears in a second is not a lock",
   table.concat(mock.sent, " | "))

mock.advance(engine.TREE_DWELL + 0.1)
queue.reset(); mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("touch tree"),
   "once nothing has been able to cure it for a while, the tattoo is spent",
   table.concat(mock.sent, " | "))

-- It costs no balance and no equilibrium: it goes out with both spent, which is the whole
-- reason it is the last resort.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.add("paralysis", "trigger")
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
mock.advance(engine.TREE_DWELL + 0.1)
-- After the advance, not before: advancing the clock fires timers, and a flush among them
-- can spend the tree balance this assertion depends on being free.
emunah.timers.stopAll()
emunah.gmcp.vitals.bal, emunah.gmcp.vitals.eq = false, false
queue.reset(); mock.sent = {}
engine.tick(); queue.flush()
ok(table.concat(mock.sent, " | "):find("touch tree"),
   "the tattoo works with no balance and no equilibrium",
   table.concat(mock.sent, " | "))
emunah.gmcp.vitals.bal, emunah.gmcp.vitals.eq = true, true

-- Without the tattoo inked there is nothing to touch.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Defences.List", {})
engine.add("paralysis", "trigger")
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
mock.advance(engine.TREE_DWELL + 0.1)
queue.reset(); mock.sent = {}
engine.tick(); queue.flush()
ok(not table.concat(mock.sent, " | "):find("touch tree"),
   "no tree tattoo, no touch", table.concat(mock.sent, " | "))

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false
mock.feed("Char.Defences.List", {})

-- ===========================================================================
suite("GMCP requests are paced, not burst")

-- Observed live, a Mudlet JSON decode failure:
--
--     parse error: trailing garbage
--         'll fight until the end." ] }Char.Skills.List { "group": "av
--
-- Two GMCP messages arriving as one payload. The decoder reads the first object, finds the
-- second appended where the input should have ended, and discards both -- so a message is
-- silently never delivered. We provoke it: refresh() sends five requests and
-- skills.requestAll() then sends one per skill group, all in the same frame.
emunah.timers.stopAll()
emunah.gmcp.clearRequests()
mock.gmcpSent = {}

emunah.gmcp.request("Char.Items.Inv")
eq(#mock.gmcpSent, 1, "a lone request goes out immediately -- only a burst is spread")

emunah.gmcp.request("Char.Items.Room")
emunah.gmcp.request("IRE.Rift.Request")
emunah.gmcp.request("Comm.Channel.Players")
eq(#mock.gmcpSent, 1, "the rest queue behind it rather than going out in the same frame")
eq(emunah.gmcp.queued(), 3, "...and are counted")

mock.advance(emunah.gmcp.REQUEST_INTERVAL + 0.01)
eq(#mock.gmcpSent, 2, "one goes out per interval")
mock.advance(emunah.gmcp.REQUEST_INTERVAL + 0.01)
mock.advance(emunah.gmcp.REQUEST_INTERVAL + 0.01)
eq(#mock.gmcpSent, 4, "...until the queue drains")
eq(emunah.gmcp.queued(), 0, "...and then stops")

-- The real burst: a full refresh with a class's worth of skill groups behind it. Nothing
-- may go out in one frame except the first.
emunah.timers.stopAll()
mock.gmcpSent = {}
mock.feed("Char.Skills.Groups", {
   { name = "Survival" }, { name = "Devotion" }, { name = "Spirituality" },
   { name = "Weaponry" }, { name = "Tattoos" },
})
emunah.gmcp.refresh()
eq(#mock.gmcpSent, 1, "a full refresh sends exactly one request in the current frame",
   tostring(#mock.gmcpSent) .. " sent: " .. table.concat(mock.gmcpSent, " | "))
ok(emunah.gmcp.queued() > 5,
   "...with the rest queued, including one per skill group",
   tostring(emunah.gmcp.queued()))

-- Bounded, never `while queued() > 0`: advancing the clock also fires the room-list retry,
-- which enqueues another request every time, so draining to empty never terminates.
emunah.timers.stopAll()
emunah.gmcp.clearRequests()
mock.gmcpSent = {}

-- ===========================================================================
suite("why a cure did not happen")

-- have.cure() returns a precise reason for every refusal and resolve() used to discard it,
-- so every failure looked identical from outside: an affliction in the panel, nothing
-- happening, nothing anywhere saying why.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = true
mock.feed("Char.Items.List", { location = "inv", items = {} })
mock.feed("IRE.Rift.List", {})
mock.echoed = {}

mock.feed("Char.Afflictions.Add", { name = "paralysis" })
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
eq(engine.refusals["paralysis"], "out of bloodroot",
   "the reason a cure could not happen is recorded", tostring(engine.refusals["paralysis"]))
ok(table.concat(mock.echoed, " "):find("Cannot cure paralysis"),
   "...and said once", table.concat(mock.echoed, " "))

-- Once per distinct reason, not once per tick: this runs on every prompt.
mock.echoed = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000" })
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000" })
ok(not table.concat(mock.echoed, " "):find("Cannot cure paralysis"),
   "...not repeated every prompt", table.concat(mock.echoed, " "))

-- Restocking the herb clears it, and the cure goes out.
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "1", name = "some bloodroot", attrib = "e" },
} })
queue.reset(); emunah.timers.stopAll(); mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("eat bloodroot"),
   "with the herb in hand the cure goes out", table.concat(mock.sent, " | "))
eq(engine.refusals["paralysis"], nil, "...and the refusal is cleared")

-- A blocked vector reports the blocker rather than nothing.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "1", name = "some kelp", attrib = "e" },
} })
-- Trigger-sourced: a GMCP-sourced affliction is dropped by the periodic reconcile when the
-- server list does not list it, which makes this depend on where the tick counter lands.
engine.add("anorexia", "trigger")
engine.add("asthma", "trigger")
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
eq(engine.refusals["asthma"], "herb is blocked by anorexia",
   "a blocked vector names the affliction blocking it",
   tostring(engine.refusals["asthma"]))

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false
mock.feed("Char.Afflictions.List", {})

-- ===========================================================================
suite("surviving death")

-- Reported from play: channel capture stops after dying and does not come back. Nothing
-- here tears the handlers down -- they are ordinary Mudlet handlers -- so the subscription
-- is being lost upstream. Death is detected from Char.Vitals rather than a message,
-- because a message trigger only covers the deaths whose wording it happens to know.
local vitals = emunah.gmcp.vitals
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = false
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
eq(vitals.dead, false, "alive to begin with")

local died, revived = 0, 0
emunah.event.register("emunah.character.died", function() died = died + 1 end, "test.death")
emunah.event.register("emunah.character.revived", function() revived = revived + 1 end,
   "test.death")

mock.gmcpSent = {}
mock.feed("Char.Vitals", { hp = "0", maxhp = "1000" })
ok(vitals.dead, "zero health is death")
eq(died, 1, "...raised once")

-- An edge, not a state: further prompts while dead must not re-raise it.
mock.feed("Char.Vitals", { hp = "0", maxhp = "1000" })
mock.feed("Char.Vitals", { hp = "0", maxhp = "1000" })
eq(died, 1, "...and not again on every prompt while dead")

-- The subscription is re-established rather than assumed. Delayed, because requests issued
-- into the game's own burst of death traffic get dropped.
mock.advance(2.1)
ok(table.concat(mock.gmcpSent, " | "):find("Core.Supports.Add"),
   "death re-negotiates the GMCP modules", table.concat(mock.gmcpSent, " | "))
-- The refresh behind it is paced one request at a time, so the rest arrive over the next
-- second rather than in the same frame -- which is the entire point of the pacer.
for _ = 1, 8 do mock.advance(emunah.gmcp.REQUEST_INTERVAL + 0.01) end
ok(table.concat(mock.gmcpSent, " | "):find("Comm.Channel.Players"),
   "...and re-requests the state that goes with them, spread over several frames",
   table.concat(mock.gmcpSent, " | "))

mock.gmcpSent = {}
mock.feed("Char.Vitals", { hp = "1450", maxhp = "1450" })
eq(vitals.dead, false, "coming back is the other edge")
eq(revived, 1, "...raised once")
mock.advance(2.1)
ok(table.concat(mock.gmcpSent, " | "):find("Core.Supports.Add"),
   "revival re-negotiates too -- whichever edge the drop happens on, one of them covers it")

emunah.event.kill("test.death")

-- CAPTURE AND RENDERING FAIL INDEPENDENTLY, which is the whole reason they are separate
-- modules. A console that has gone away must not take the GMCP handler with it, and must
-- not fail silently either -- "chat stopped" with nothing in the log is an hour of guessing.
local chat = emunah.ui.chat
local before = #emunah.gmcp.comm.history
chat.console = { decho = function() error("widget is gone", 0) end }
chat.mode = "plain"
chat.broken = false
mock.echoed = {}

mock.feed("Comm.Channel.Text", { channel = "ct", talker = "Anzerloi", text = "still here" })
eq(#emunah.gmcp.comm.history, before + 1,
   "capture records the message even with the console broken")
ok(chat.broken, "...and the render failure is noticed")
ok(table.concat(mock.echoed, " "):find("Capture is unaffected"),
   "...and reported once, saying which half broke", table.concat(mock.echoed, " "))

mock.echoed = {}
mock.feed("Comm.Channel.Text", { channel = "ct", talker = "Anzerloi", text = "and again" })
eq(#emunah.gmcp.comm.history, before + 2, "capture keeps going")
ok(not table.concat(mock.echoed, " "):find("Capture is unaffected"),
   "...without repeating the warning on every line")

-- A broken console rebuilds itself rather than waiting to be told. Telling someone to run
-- a repair command is no use when the thing that broke is the window they would read it in.
chat.rebuilt = false
chat.broken = false
chat.console = { decho = function() error("widget is gone", 0) end }
mock.echoed = {}
mock.feed("Comm.Channel.Text", { channel = "ct", text = "trigger a rebuild" })
ok(table.concat(mock.echoed, " "):find("Rebuilding the chat console"),
   "a render failure rebuilds the console", table.concat(mock.echoed, " "))
ok(chat.rebuilt, "...once")

-- Only once: a console that cannot be rebuilt must not be rebuilt per message arriving.
mock.echoed = {}
chat.console = { decho = function() error("still gone", 0) end }
chat.broken = false
mock.feed("Comm.Channel.Text", { channel = "ct", text = "and again" })
ok(not table.concat(mock.echoed, " "):find("Rebuilding the chat console"),
   "...and not again on every message", table.concat(mock.echoed, " "))

-- No console at all is its own failure, and was previously a silent early return: a chat
-- window that never built looks exactly like one that stopped working.
chat.console, chat.mode = nil, "none"
chat.dropped = 0
mock.echoed = {}
mock.feed("Comm.Channel.Text", { channel = "ct", text = "nowhere to go" })
eq(chat.dropped, 1, "a message with no console is counted, not silently dropped")
ok(table.concat(mock.echoed, " "):find("no console to render into"),
   "...and said out loud", table.concat(mock.echoed, " "))

chat.console, chat.mode, chat.broken = nil, "none", false
chat.rebuilt, chat.dropped = false, 0

-- ===========================================================================
suite("when GMCP lies or goes quiet")

-- RECKLESSNESS SETS hp AND mp TO MAXIMUM in Char.Vitals regardless of the truth. Every
-- healing threshold reads that number, so the affliction works by making a healthy-looking
-- character die. There is no correct number to substitute -- the feed is unusable until it
-- clears -- so every consumer takes the one safe action available without it.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = true
mock.feed("Char.Afflictions.List", {})
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", mp = "1000", maxmp = "1000",
   bal = "1", eq = "1" })
ok(emunah.gmcp.vitals.trusted(), "vitals are trusted with no falsifying affliction")
eq(emunah.gmcp.vitals.below("hp", 80), false, "...and a full bar is not below the threshold")

mock.sent = {}
mock.feed("Char.Afflictions.Add", { name = "recklessness" })
eq(emunah.gmcp.vitals.trusted(), false, "recklessness makes the feed untrustworthy")
eq(emunah.gmcp.vitals.trusted("wp"), true, "...but only for what it actually falsifies")
ok(emunah.gmcp.vitals.below("hp", 80),
   "an unreadable bar reads as below the threshold, because every caller acts protectively")

-- The healing engine treats it the same way: heal from every source rather than believe a
-- number that says nothing is wrong.
emunah.have.recover("elixir"); emunah.have.recover("moss"); queue.reset()
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", mp = "1000", maxmp = "1000" })
local underRecklessness = table.concat(mock.sent, " | ")
ok(underRecklessness:find("drink health"),
   "a character reading 100% is still healed while recklessness is up", underRecklessness)
ok(underRecklessness:find("perform hands"),
   "...from the equilibrium source too", underRecklessness)

-- And it stops once the lie stops.
mock.feed("Char.Afflictions.Remove", { "recklessness" })
ok(emunah.gmcp.vitals.trusted(), "curing it restores trust")
emunah.have.recover("elixir"); queue.reset(); emunah.timers.stopAll()
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", mp = "1000", maxmp = "1000" })
ok(not table.concat(mock.sent, " | "):find("drink health"),
   "...and a genuinely full bar is left alone", table.concat(mock.sent, " | "))

-- BLACKOUT FREEZES THE FEED rather than falsifying it: afflictions applied during it
-- produce no Char.Afflictions update at all. Reconciling against a frozen snapshot would
-- drop every GMCP-sourced affliction that landed since it began.
engine.clear(); queue.reset()
mock.feed("Char.Afflictions.List", { { name = "blackout" } })
ok(engine.blinded(), "blackout means affliction state is unobservable")
-- Note the payload shapes, which differ and are easy to confuse: List carries OBJECTS,
-- Remove carries bare NAMES. A List of strings is silently ignored by the parser.
eq(emunah.gmcp.afflictions.has("blackout"), true, "...as the server reports it")

-- The server list now moves without us hearing about it, which is exactly the situation
-- blackout creates. A reconcile in this state must change nothing.
engine.add("paralysis", "trigger")
mock.feed("Char.Afflictions.List", { { name = "blackout" }, { name = "asthma" } })
engine.reconcile()
eq(engine.has("asthma"), false, "a reconcile while blinded adopts nothing")
ok(engine.has("paralysis"), "...and drops nothing")

-- The moment it lifts, catch up rather than waiting for the periodic pass -- which in a
-- fight can be the whole fight away. Checked as a state edge, so it fires whichever route
-- blackout left by.
mock.feed("Char.Afflictions.List", { { name = "asthma" } })
eq(engine.blinded(), false, "the feed is observable again")
engine.tick()
ok(engine.has("asthma"), "the thaw reconciles immediately, without waiting for the periodic pass")
ok(engine.has("paralysis"), "...without discarding trigger-detected state")

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false
mock.feed("Char.Afflictions.List", {})

-- ===========================================================================
suite("restocking")

-- Curatives live in the rift, and OUTR has a round trip -- pulling one at the moment the
-- affliction lands is a cure that arrives too late. So carry a few. The ceiling matters as
-- much as the floor: inventory is lost on death, the rift is not.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = true
emunah.config.set("curing.restock", true)
-- Deliberately does NOT set curing.restockEvery: restocking every tick is the default, and
-- a test that configures its way around that would not have caught the one-pull-per-ten-
-- prompts crawl this suite exists to pin.
engine.forgetStock()
local healthy = { hp = "1000", maxhp = "1000", mp = "1000", maxmp = "1000",
   bal = "1", eq = "1" }

-- NOT KNOWING what we carry must not read as carrying nothing. A reload empties this
-- module's inventory while the character still holds everything, and pulling on that basis
-- is what put 9 ash and 6 bloodroot in the pack against a target of 3.
emunah.gmcp.items.inventoryListed = false
emunah.gmcp.items.locations.inv = {}
-- The real payload shape, from the GMCP trace at 11:42:02: the rift calls this "moss" and
-- carries "irid" as the DESCRIPTION, while OUTR and the cure tables both say "irid".
mock.sent = {}
mock.feed("IRE.Rift.List", { { name = "moss", desc = "irid", amount = 498 } })
eq(emunah.have.inRift("irid"), 498, "the rift is found by the word OUTR uses, not just by name")
eq(#mock.sent, 0, "nothing is pulled before inventory is known",
   table.concat(mock.sent, " | "))

-- ...and the moment it IS known, without waiting for a prompt. Idle after `emreload` at
-- 12:05:52 the first pull did not go out until a manual LOOK ninety-six seconds later,
-- because the engine only ever ran on a prompt.
mock.sent = {}
mock.feed("Char.Items.List", { location = "inv", items = {} })
ok(table.concat(mock.sent, " | "):find("outr 3 irid"),
   "carrying none, it pulls up to the target as soon as inventory is listed",
   table.concat(mock.sent, " | "))

mock.line("You remove 3 irid, bringing the total in the rift to 495.")
eq(emunah.queue.awaiting("rift"), nil, "the game's confirmation frees the pull")

-- Verbatim from the same trace -- this is what a stack of five actually looks like.
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "344362", name = "a group of 3 pieces of irid moss", attrib = "gre" },
} })
eq(emunah.have.quantity("irid"), 3, "a grouped stack counts by its stated size, not as one entry")

mock.sent = {}
mock.feed("Char.Vitals", healthy)
ok(not table.concat(mock.sent, " | "):find("outr"),
   "at the target, nothing more is pulled -- the ceiling is the point",
   table.concat(mock.sent, " | "))

-- An entry that states no number reads as one, so the target can never be met. Pulling
-- forever would empty the rift into a pack that the next death drops on the floor, so it
-- gives up and says so instead.
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "91", name = "some irid moss", attrib = "e" },
} })
engine.forgetStock()
local pulls = 0
for _ = 1, 6 do
   mock.sent = {}
   mock.feed("Char.Vitals", healthy)
   if table.concat(mock.sent, " | "):find("outr") then pulls = pulls + 1 end
   mock.line("You remove 2 irid, bringing the total in the rift to 493.")
   -- Stop the timers BEFORE advancing: the confirmation schedules the next pull in the
   -- chain, and letting that fire during the advance would spend an attempt outside the
   -- window this loop is counting. The count never moves in this case -- that is the point
   -- -- so each attempt is separated by the settle window rather than by a changing count.
   emunah.timers.stopAll()
   mock.advance(engine.RESTOCK_SETTLE + 0.01)
   emunah.timers.stopAll()
end
eq(pulls, engine.STOCK_ATTEMPTS,
   "an uncountable stack stops after a bounded number of attempts, not never",
   tostring(pulls))

-- BACK TO BACK, not one item per ten prompts. Live, `outr 3 valerian` at 11:47:32 and
-- `outr 3 irid` at 11:48:26 were nearly a minute apart with most of the cure list still not
-- carried: only one pull can be in flight at a time, so a tick interval on top of that was
-- pure delay. The next pull now goes out on the tick after the last one is confirmed.
engine.forgetStock()
mock.feed("IRE.Rift.List", {
   { name = "moss", desc = "irid", amount = 498 },
   { name = "bloodroot", amount = 250 },
})
-- After the rift list, not before: learning what the rift holds is itself a reason to
-- restock now, so it will have taken the vector with a pull of its own -- and left that
-- item settling, which is what forgetStock() clears.
queue.reset(); emunah.timers.stopAll(); engine.forgetStock()
mock.sent = {}
mock.feed("Char.Items.List", { location = "inv", items = {} })
ok(table.concat(mock.sent, " | "):find("outr 3 bloodroot"),
   "the cure list is pulled in order", table.concat(mock.sent, " | "))

-- The game's own ordering: Char.Items.Add lands before the line that frees the vector.
mock.feed("Char.Items.Add", { location = "inv",
   item = { id = "500", name = "a group of 3 pieces of bloodroot", attrib = "gre" } })
mock.line("You remove 3 bloodroot, bringing the total in the rift to 247.")

mock.sent = {}
mock.feed("Char.Vitals", healthy)
ok(table.concat(mock.sent, " | "):find("outr 3 irid"),
   "and the next one goes out on the very next tick", table.concat(mock.sent, " | "))
mock.line("You remove 3 irid, bringing the total in the rift to 495.")

-- OVER the target, the difference goes back. Reloads pulled three of everything afresh
-- each time -- `INR ALL` at 12:07:37 emptied 9 ash and 6 bloodroot out of the pack against
-- a target of 3 -- and anything above the line is just more to drop on death.
engine.forgetStock(); queue.reset(); emunah.timers.stopAll()
mock.feed("IRE.Rift.List", { { name = "ash", amount = 91 } })
queue.reset(); emunah.timers.stopAll()
mock.sent = {}
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "600", name = "a group of 9 pieces of ash", attrib = "gre" },
} })
ok(table.concat(mock.sent, " | "):find("inr 6 ash"),
   "carrying nine against a target of three, six go back", table.concat(mock.sent, " | "))

-- INR confirms the same way OUTR does, and frees the vector the same way.
mock.line("You store 6 ash, bringing the total in the rift to 97.")
eq(emunah.queue.awaiting("rift"), nil, "the store is confirmed by the game's own line")

mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "601", name = "a group of 3 pieces of ash", attrib = "gre" },
} })
queue.reset(); emunah.timers.stopAll()
mock.sent = {}
mock.feed("Char.Vitals", healthy)
ok(not table.concat(mock.sent, " | "):find("ash"),
   "at exactly three, it neither pulls nor stores", table.concat(mock.sent, " | "))

-- Nothing is pulled that the rift does not have.
mock.feed("IRE.Rift.List", {})
engine.forgetStock()
mock.feed("Char.Items.List", { location = "inv", items = {} })
mock.sent = {}
mock.feed("Char.Vitals", healthy)
ok(not table.concat(mock.sent, " | "):find("outr"),
   "an empty rift is not pulled from", table.concat(mock.sent, " | "))

engine.clear(); queue.reset(); emunah.timers.stopAll(); engine.enabled = false
engine.forgetStock()

-- ===========================================================================
suite("cooldowns")

emunah.timers.stopAll()
ok(emunah.timers.ready("cure.herb"), "vector starts ready")
emunah.have.spend("herb")
ok(not emunah.timers.ready("cure.herb"), "spending starts the recovery timer")
ok(emunah.timers.remaining("cure.herb") > 0, "recovery reports time remaining")
mock.advance(3.0)
ok(emunah.timers.ready("cure.herb"), "vector recovers when the timer lapses")

emunah.have.spend("salve")
emunah.have.recover("salve")
ok(emunah.timers.ready("cure.salve"), "trigger confirmation clears a vector early")

-- SIP BALANCE IS TRACKED FROM THE GAME, NOT ESTIMATED.
--
-- The elixir fallback was 1.8s against a real sip balance several times that, so the queue
-- re-sent `drink health` mid-sip: elixirs drunk "without effect", a vial wasted per
-- attempt, and health not actually rising while appearing to be treated.
emunah.timers.stopAll()
ok(emunah.curing.curelist.recovery("elixir") >= 5,
   "the elixir fallback is long enough to outlast a real sip",
   emunah.curing.curelist.recovery("elixir"))

-- Drinking takes the vector, from the game's own line rather than from our send().
mock.line("You take a drink from an oaken vial.")
ok(not emunah.have.balance("elixir"), "drinking spends sip balance")

-- A short wait must NOT free it: this is precisely the window the old timer got wrong.
mock.advance(2.5)
ok(not emunah.have.balance("elixir"),
   "sip balance is still down 2.5s later (the old 1.8s timer would have re-sipped)")

-- The game announcing recovery frees it immediately.
mock.line("You may drink another health or mana elixir.")
ok(emunah.have.balance("elixir"), "the game's own message restores sip balance")

-- And a manual sip is tracked too, since the trigger watches the game rather than us.
mock.line("You take a drink from a crystal vial.")
ok(not emunah.have.balance("elixir"), "a manual sip is tracked the same way")
mock.line("You may drink another health or mana elixir.")

-- ===========================================================================
suite("curing/detect (trigger framework)")

local detect = emunah.curing.detect

-- patterns.lua's seed corpus is already loaded by the time the loader finishes, so the
-- vector-blocking quartet should already have gain patterns registered.
local seedCoverage = detect.coverage()
eq(seedCoverage.totalKnown, afflist.count(), "coverage reports the full affliction count")
ok(seedCoverage.withGain >= 4, "the seeded quartet already has gain patterns", seedCoverage.withGain)

-- A gain pattern asserts the affliction into the engine, tagged as trigger-sourced.
engine.clear()
queue.reset()
ok(detect.add("paralysis", "gain", [[^TEST_PARALYSIS_GAIN$]]), "gain pattern registers")
mock.line("TEST_PARALYSIS_GAIN")
ok(engine.has("paralysis"), "a matched gain line asserts the affliction")

-- A cure pattern retracts the affliction AND confirms whichever vector was waiting on it --
-- this is the whole point of a cure-side pattern (detect/init.lua's onCure): without it the
-- vector stays blocked until the fallback timer lapses.
ok(detect.add("paralysis", "cure", [[^TEST_PARALYSIS_CURE$]]), "cure pattern registers")

emunah.timers.stopAll()
queue.push("herb", "eat bloodroot", { priority = 1, tag = "paralysis", confirm = 5.0 })
queue.flush()
ok(queue.awaiting("herb") ~= nil, "the cure command is sent and awaiting confirmation")

mock.line("TEST_PARALYSIS_CURE")
ok(not engine.has("paralysis"), "the cure line retracts the affliction")
ok(queue.awaiting("herb") == nil, "the cure line confirms the in-flight vector")
ok(emunah.have.balance("herb"), "confirmation recovers the vector immediately")

engine.clear()
queue.reset()

-- detect.balance() drives have.spend/have.recover off the game's own messages, the same
-- mechanism patterns.lua uses for elixir sip balance (exercised end-to-end in "cooldowns"
-- above); this checks the wiring directly against a synthetic vector.
detect.balance("smoke", {
   spend = { [[^TEST_SMOKE_SPEND$]] },
   gain  = { [[^TEST_SMOKE_GAIN$]] },
})
emunah.have.spend("smoke")
emunah.have.recover("smoke")
ok(emunah.have.balance("smoke"), "smoke starts free")
mock.line("TEST_SMOKE_SPEND")
ok(not emunah.have.balance("smoke"), "the spend line takes smoke balance")
mock.line("TEST_SMOKE_GAIN")
ok(emunah.have.balance("smoke"), "the game's own recovery message frees it")

local finalCoverage = detect.coverage()
ok(finalCoverage.withCure >= 1, "coverage counts cure patterns too", finalCoverage.withCure)

-- From a real bashing transcript: a denizen's knockback attack refuses every action with
-- "You must be standing first." until you stand back up manually. This trigger is
-- unconditional (not scoped to curing.enabled), since standing is the right response
-- regardless of what we were trying to do when it fired.
mock.sent = {}
mock.line("You must be standing first.")
ok(table.concat(mock.sent, " | "):find("stand"),
   "knocked down: stands back up", table.concat(mock.sent, " | "))
ok(detect.isProne(), "and is now known to be down")

-- Regression: from the same transcript, a bashing loop that keeps attacking while down gets
-- "You must be standing first." again on its NEXT attempt, which used to resend "stand"
-- again too -- three round trips of this before the character actually finished standing.
-- Once we are known to be down, a repeat of the same rejection must not spam another stand.
mock.sent = {}
mock.line("You must be standing first.")
eq(#mock.sent, 0, "already known to be down: does not resend stand", table.concat(mock.sent, " | "))

mock.line("You stand up.")
ok(not detect.isProne(), "standing confirmed: no longer known to be down")

-- And the flag correctly re-arms for the next knockdown. Past the in-flight guard: a STAND
-- is not re-sent within a round trip of the last one, which is what stopped one knockdown
-- producing a STAND on every prompt until the game caught up.
mock.advance(detect.STAND_GUARD + 0.01)
mock.sent = {}
mock.line("You must be standing first.")
ok(table.concat(mock.sent, " | "):find("stand"),
   "a later knockdown stands back up again", table.concat(mock.sent, " | "))
mock.line("You stand up.")

-- Regression: confirmed live from a guard-pig charge that stuns AND knocks down from the
-- same hit. Stunned is a SEPARATE, unconditional state -- no command fixes it, it just
-- wears off -- and must not be confused with (or leak into) M.prone.
ok(not detect.isStunned(), "not stunned to start")
mock.line("You are too stunned to be able to do anything.")
ok(detect.isStunned(), "now known to be stunned")
ok(not detect.isProne(), "stunned does not imply prone")
mock.line("You are no longer stunned.")
ok(not detect.isStunned(), "stun clears on its own")

-- THE ONSET, which is what actually matters and was missing entirely.
--
-- Matching only "You are too stunned to be able to do anything." -- the REJECTION -- is
-- circular: the flag could only ever become true after a command had already been thrown
-- away, which is the exact thing it exists to prevent. Confirmed live with timestamps: a
-- smite went out at 00:17:21.14 while stunned because this line, two seconds earlier,
-- matched nothing. The tail varies per denizen, so the pattern must not be anchored to it.
mock.line("You are momentarily stunned as the massive bulk of a guard pig smashes into you.")
ok(detect.isStunned(), "the stun ONSET message is what sets the flag, not the rejection")
eq(emunah.act.blocked(), "stunned", "...and it blocks every command, whatever it needs")
mock.line("You are no longer stunned.")
ok(not detect.isStunned(), "cleared again")

-- A stun that never announces its end must not freeze the bot: detect.stunned blocks
-- EVERYTHING, so a missed clear is not degraded behaviour, it is a dead session.
mock.line("You are momentarily stunned as a guard pig smashes into you.")
ok(detect.isStunned(), "stunned, with no clear message to come")
mock.advance(detect.STUN_GUARD + 0.1)
ok(not detect.isStunned(), "the guard releases a stun whose clear message never arrived")

-- Same failure mode for prone, same backstop.
mock.line("You must be standing first.")
ok(detect.isProne(), "prone, with no stand confirmation to come")
mock.advance(detect.PRONE_GUARD + 0.1)
ok(not detect.isProne(), "the guard releases a knockdown that was never confirmed upright")

-- "You are already standing." also resolves it -- something else stood us up first.
mock.line("You must be standing first.")
ok(detect.isProne(), "prone again")
mock.line("You are already standing.")
ok(not detect.isProne(), "an 'already standing' reply clears it too")

-- "You are not fallen or kneeling." is what Achaea actually says to a STAND when already
-- up -- confirmed live. Our guessed wording had never been observed.
mock.line("You must be standing first.")
ok(detect.isProne(), "down")
mock.line("You are not fallen or kneeling.")
ok(not detect.isProne(), "the real 'already standing' reply clears it")

-- Equilibrium is announced with its exact cost, the same as balance.
emunah.timers.stopAll()
mock.line("Equilibrium used: 3.00s.")
eq(emunah.have.balance("equilibrium"), false, "the announced equilibrium cost arms its timer")
mock.advance(3.1)
eq(emunah.have.balance("equilibrium"), true, "...and frees when it elapses")

-- GMCP REPORTS prone AS AN AFFLICTION, which is authoritative where our text patterns are
-- necessarily partial -- there is one onset message per attack per creature and exactly one
-- was ever observed, while the game had been naming it all along.
mock.line("You stand up.")
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
mock.sent = {}
mock.feed("Char.Afflictions.Add", { name = "prone" })
ok(detect.isProne(), "a GMCP prone affliction sets the flag")
ok(table.concat(mock.sent, " | "):find("stand"), "...and gets us up",
   table.concat(mock.sent, " | "))

-- ...and it is not reported as an affliction with no cure: it has one, elsewhere.
ok(emunah.curing.afflist.isState("prone"), "prone is a state, not an uncurable affliction")

-- Remove carries an ARRAY of bare names, not an object -- see gmcp/afflictions.lua.
mock.feed("Char.Afflictions.Remove", { "prone" })
ok(not detect.isProne(), "GMCP clearing it clears the flag")

-- STAND COSTS BALANCE. Confirmed live: knocked down with the prompt reading "e-", the stand
-- went out and came back "You must regain balance first." A knockdown lands right after our
-- own attack, so balance is exactly what we lack at the moment we need to stand.
mock.line("You stand up.")
mock.feed("Char.Vitals", { bal = "0", eq = "1" })
mock.sent = {}
mock.line("You must be standing first.")
eq(#mock.sent, 0, "no stand is sent without the balance it costs",
   table.concat(mock.sent, " | "))
ok(detect.isProne(), "...but we know we are down")

-- Retried once balance returns, rather than left for an unrelated rejection to trigger.
-- Past the in-flight guard: a STAND is not re-sent within a round trip of the last one.
mock.advance(detect.STAND_GUARD + 0.01)
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("stand"),
   "standing is retried the moment balance is back", table.concat(mock.sent, " | "))
mock.line("You stand up.")

-- BOTH AT ONCE, which is the actual live sequence: one guard-pig charge stuns AND knocks
-- down. STAND is refused while stunned like every other command, so it must not be sent
-- into that -- but something has to retry it, or the character stays flat until the prone
-- guard lapses.
mock.line("You are momentarily stunned as a guard pig smashes into you.")
mock.sent = {}
mock.line("You must be standing first.")
ok(detect.isProne(), "knocked down while stunned")
eq(#mock.sent, 0, "STAND is not sent while stunned", table.concat(mock.sent, " | "))

mock.advance(detect.STAND_GUARD + 0.01)
mock.sent = {}
mock.line("You are no longer stunned.")
ok(table.concat(mock.sent, " | "):find("stand"),
   "...and is sent the moment the stun lifts", table.concat(mock.sent, " | "))
mock.line("You stand up.")
ok(not detect.isProne() and not detect.isStunned(), "fully recovered")

-- Bleeding has no observed onset or cure message, only the repeating damage tick, so it is
-- NOT tracked via engine.add/remove -- it queues `clot` directly, and only while curing is
-- actually on.
queue.reset()
engine.enabled = false
mock.line("You bleed 6 health.")
eq(queue.pending("special"), nil, "a bleed tick is ignored while curing is off")

-- Regression: confirmed live -- CLOT is the Survival ability "clotting", and a real
-- transcript showed it sent (and rejected with "Clot is not a valid command.") before the
-- skill index had even finished loading. Unlike every other cure, this one must NOT fall
-- back to have.skill()'s permissive "assume yes" default while the index is incomplete:
-- "unknown" must mean "do not send", not "probably fine".
engine.enabled = true
eq(emunah.gmcp.skills.complete, false, "the skill index has not loaded yet")
mock.line("You bleed 6 health.")
eq(queue.pending("special"), nil, "unknown skill state: a bleed tick queues nothing")

-- Once the index is complete and confirms the character does NOT have it, still nothing --
-- this is the second live confirmation: the character genuinely lacks the lesson.
mock.feed("Char.Skills.Groups", { { name = "Survival", rank = "Adept" } })
mock.feed("Char.Skills.List", { group = "Survival", list = { "Tumble" } })
ok(emunah.gmcp.skills.complete, "the skill index is now complete")
ok(not emunah.have.skill("clotting"), "and confirms clotting is not known")
mock.line("You bleed 6 health.")
eq(queue.pending("special"), nil, "confirmed absent: a bleed tick still queues nothing")

-- Only a POSITIVE confirmation unblocks it.
mock.feed("Char.Skills.List", { group = "Survival", list = { "Tumble", "Clotting" } })
ok(emunah.have.skill("clotting"), "clotting is now confirmed known")
mock.line("You bleed 6 health.")
local bleedPending = queue.pending("special")
ok(bleedPending ~= nil and bleedPending.command == "clot",
   "confirmed present: a bleed tick queues clot on the special vector",
   bleedPending and bleedPending.command)
eq(bleedPending and bleedPending.tag, "bleeding", "tagged as bleeding, not a tracked affliction")
eq(engine.has("bleeding"), false, "bleeding is never asserted into engine.tracked")
queue.reset()

-- The reverse mistake: if the index says yes but the game still rejects it (a modelling
-- error, or a lesson lost), have.denySkill() overrides the index for the rest of the
-- session -- the same backstop every other capability gets when the game corrects us.
mock.line("Clot is not a valid command.")
ok(not emunah.have.skill("clotting"), "rejected despite the index: denied overrides it")
mock.line("You bleed 6 health.")
eq(queue.pending("special"), nil, "a later bleed tick queues nothing -- still denied")
queue.reset()
engine.enabled = false

-- ===========================================================================
suite("Char.Defences (the parry accumulation bug)")

local defences = emunah.gmcp.defences

-- GMCP does not send a Remove for the old "parrying (X)" entry when a new one is granted.
-- Corroborated by an independent implementation carrying the
-- identical workaround: onAdd() has to clear any existing parry entry itself.
mock.feed("Char.Defences.List", {})
mock.feed("Char.Defences.Add", { name = "parrying (a longsword)" })
ok(defences.has("parrying (a longsword)"), "the first parry is recorded")

mock.feed("Char.Defences.Add", { name = "parrying (a rapier)" })
ok(defences.has("parrying (a rapier)"), "the new parry is recorded")
ok(not defences.has("parrying (a longsword)"),
   "the stale parry is cleared even though GMCP never sent a Remove for it")
eq(defences.count(), 1, "only one parry defence is ever tracked at once")

-- Unrelated defences are untouched by the parry-clearing logic.
mock.feed("Char.Defences.Add", { name = "shield" })
mock.feed("Char.Defences.Add", { name = "parrying (a mace)" })
ok(defences.has("shield"), "a non-parry defence survives a parry change")
ok(defences.has("parrying (a mace)"), "the newest parry is recorded")
eq(defences.count(), 2, "shield plus exactly one parry")

mock.feed("Char.Defences.List", {})

-- ===========================================================================
suite("defence keep-up")

local defkeepup = emunah.curing.defkeepup

queue.reset()
engine.clear()
engine.enabled = false
mock.feed("Char.Defences.List", {})
mock.sent = {}

defkeepup.add("rebounding")
ok(emunah.util.contains(defkeepup.wanted(), "rebounding"), "rebounding is now on the wanted list")

-- tick() both queues and flushes (defkeepup.lua's own M.tick), so a free vector's action
-- lands directly in mock.sent rather than sitting in queue.pending.
defkeepup.enabled = true
defkeepup.tick()

ok(table.concat(mock.sent, " | "):find("smoke skullcap", 1, true),
   "a missing wanted defence is queued and sent on its vector", table.concat(mock.sent, " | "))
local inFlight = queue.awaiting("smoke")
ok(inFlight ~= nil and inFlight.tag == "def:rebounding", "the sent action is tagged as a defence")
eq(inFlight and inFlight.priority, defkeepup.PRIORITY,
   "the queued action used the keep-up priority floor")

-- Curing outranks keep-up: while the engine is on and tracking something, keep-up must not
-- even queue -- defkeepup.lua:115's explicit deferral, because a defence raised mid-lock is
-- usually stripped again immediately.
queue.reset()
mock.sent = {}
engine.enabled = true
engine.add("paralysis", "trigger")
defkeepup.tick()
ok(#mock.sent == 0, "keep-up defers entirely while curing is tracking an affliction", table.concat(mock.sent, " | "))

engine.clear()
engine.enabled = false
defkeepup.drop("rebounding")
defkeepup.enabled = false

-- ===========================================================================
suite("Comm.Channel routing")

eq(emunah.gmcp.comm.tabFor("tell"), "Tells", "tells route to Tells")
eq(emunah.gmcp.comm.tabFor("ct"), "City", "ct routes to City")
eq(emunah.gmcp.comm.tabFor("ht"), "House", "ht routes to House")
eq(emunah.gmcp.comm.tabFor("market"), "Market", "market routes to Market")
eq(emunah.gmcp.comm.tabFor("wibble"), "Misc", "unknown channels fall back to Misc")

mock.feed("Comm.Channel.Text", { channel = "ct", talker = "Someone", text = "hello" })
local recent = emunah.gmcp.comm.recent(1)
eq(#recent, 1, "channel text is captured")
eq(recent[1].tab, "City", "captured message carries its tab")

-- ===========================================================================
suite("Room")

mock.feed("Room.Info", {
   num = 1234, name = "A dusty road", area = "Test Area",
   environment = "Hills", exits = { n = 1235, s = 1233 },
   details = { "shop" },
})
eq(emunah.gmcp.room.num, 1234, "room number tracked")
eq(#emunah.gmcp.room.exitList(), 2, "exits tracked")
ok(emunah.gmcp.room.hasDetail("shop"), "room details tracked")

mock.feed("Room.AddPlayer", { name = "Someone", fullname = "Someone the Test" })
ok(emunah.gmcp.room.hasPlayer("someone"), "player added")
-- RemovePlayer arrives as a bare string.
mock.feed("Room.RemovePlayer", "Someone")
ok(not emunah.gmcp.room.hasPlayer("someone"), "RemovePlayer accepts a bare name string")

-- Moving clears the stale player list.
mock.feed("Room.AddPlayer", { name = "Other", fullname = "Other" })
mock.feed("Room.Info", { num = 9999, name = "Elsewhere", exits = {} })
eq(emunah.gmcp.room.playerCount(), 0, "moving rooms clears the player list")

-- ACHAEA'S Room.Players INCLUDES YOU.
--
-- Confirmed from a live payload: standing alone, Room.Players is
-- { { name = "Saemora", fullname = "Saemora" } }. Every consumer of this list means "others
-- here", and two of them (bashing.stopOnPlayer, the walker's equivalent) stop dead when it
-- is non-empty -- so counting yourself makes those settings unusable: switch either on and
-- the loop halts immediately, alone, reporting a player who is you.
--
-- The identification has to work from Char.Name, NOT Char.Status. A GMCP trace of ordinary
-- play shows room changes carrying Char.Vitals, Char.Items.List, Room.Info and Room.Players
-- with no Char.Status at all, so a check against Char.Status alone compares every name to
-- nil and never matches. Simulate exactly that: our name known only via Char.Name.
local savedStatusName, savedCharacter = emunah.gmcp.status.values.name, emunah.gmcp.character
emunah.gmcp.status.values.name = nil
emunah.gmcp.character = "Saemora"
mock.feed("Room.Info", { num = 6181, name = "North gate", exits = {} })
mock.feed("Room.Players", { { name = "Saemora", fullname = "Saemora" } })
eq(emunah.gmcp.room.playerCount(), 0,
   "alone in a room reports NO other players, with Char.Status absent",
   table.concat(emunah.gmcp.room.playerNames(), ", "))
ok(emunah.gmcp.room.isSelf("saemora"), "self-identification is case-insensitive")

-- Someone genuinely else still counts.
mock.feed("Room.Players", {
   { name = "Saemora", fullname = "Saemora" },
   { name = "Sarapis", fullname = "Sarapis, the Logos" },
})
eq(emunah.gmcp.room.playerCount(), 1, "another player in the room does count",
   table.concat(emunah.gmcp.room.playerNames(), ", "))
ok(emunah.gmcp.room.hasPlayer("sarapis"), "...and it is the other one")

-- An AddPlayer for ourselves must not slip past either -- consumers stop dead on that.
mock.feed("Room.Info", { num = 6182, name = "Somewhere", exits = {} })
mock.feed("Room.AddPlayer", { name = "Saemora", fullname = "Saemora" })
eq(emunah.gmcp.room.playerCount(), 0, "an AddPlayer for ourselves is ignored")

emunah.gmcp.status.values.name, emunah.gmcp.character = savedStatusName, savedCharacter

-- ===========================================================================
suite("skills index")

mock.feed("Char.Skills.Groups", { { name = "Survival", rank = "Transcendent" } })
mock.feed("Char.Skills.List", {
   group = "Survival",
   list = { "Tumble", "* Camouflage", "Track" },
})
ok(emunah.gmcp.skills.has("tumble"), "skill indexed")
ok(emunah.gmcp.skills.has("camouflage"), 'the "* " prefix is stripped')
eq(emunah.gmcp.skills.groupOf("track"), "survival", "skill maps back to its group")
eq(emunah.gmcp.skills.rank("survival"), "Transcendent", "skillset rank tracked")

-- Regression: CLOT is the Survival ability "clotting", not a command everyone can send --
-- a real transcript shows Achaea rejecting it with "Clot is not a valid command." for a
-- character who does not have the lesson. The skill index is complete at this point (the
-- Survival group above just finished), and does NOT include "clotting", so the bleed-tick
-- handler must not queue it.
engine.enabled = true
queue.reset()
ok(not emunah.have.skill("clotting"), "the index is complete and clotting is not in it")
mock.line("You bleed 6 health.")
eq(queue.pending("special"), nil, "without the clotting lesson, a bleed tick queues nothing")

-- Learning it (or logging in with it already known) must unblock the same handler.
mock.feed("Char.Skills.List", {
   group = "Survival",
   list = { "Tumble", "* Camouflage", "Track", "Clotting" },
})
ok(emunah.have.skill("clotting"), "clotting is now in the index")
mock.line("You bleed 6 health.")
local clotPending = queue.pending("special")
ok(clotPending ~= nil and clotPending.command == "clot",
   "with the lesson, a bleed tick queues clot", clotPending and clotPending.command)
queue.reset()
engine.enabled = false

-- ===========================================================================
suite("class auto-detection (Char.Status vs skill completion)")

-- Regression: "emunah hunt" right after connecting failed with "No class module loaded"
-- even though "Detected class: Priest" printed on the same line -- Char.Status.class had
-- already arrived, but class loading was gated ONLY on the (slower, multi-round-trip)
-- skill index finishing, so the two facts disagreed. Simulate that exact race: Status
-- arrives with a class name, and NOTHING about skills has happened yet.
emunah.class.active, emunah.class.name = nil, nil
mock.feed("Char.Status", { class = "Priest" })
ok(emunah.class.active ~= nil, "Char.Status alone loads the class module")
eq(emunah.class.name, "priest", "the right one")

-- The other order still works too: skills complete before Status ever names a class.
emunah.class.active, emunah.class.name = nil, nil
emunah.gmcp.status.values.class = nil
mock.feed("Char.Skills.Groups", { { name = "Devotion", rank = "Adept" } })
mock.feed("Char.Skills.List", { group = "Devotion", list = { "Smite" } })
ok(emunah.class.active ~= nil, "skill completion alone also loads the class module")
eq(emunah.class.name, "priest", "detected via the Devotion skillset fallback")

-- Regression: the fix above still was not enough on its own. On an emreload with an
-- existing connection, Char.Status data can already be sitting in the raw gmcp table
-- before class/adapter.lua's listeners even register -- gmcp/status.lua's own "already
-- have data" check fires "emunah.status" synchronously AT ITS OWN load time, which is
-- earlier in the manifest than class/adapter.lua and therefore too early for a listener
-- that has not registered yet. The event is not late, it already happened. Simulate
-- exactly that: Status known before a reload, and nothing fed AFTER it.
emunah.class.active, emunah.class.name = nil, nil
mock.feed("Char.Status", { class = "Priest" })
pcall(load)   -- reload the whole module tree; gmcp.Char.Status still has the data above
ok(emunah.class.active ~= nil,
   "the class loads purely from data already present at module-load time, no new event needed")
eq(emunah.class.name, "priest", "the right one")

mock.feed("Char.Status", { class = "Priest" })

-- A class change mid-session invalidates the attack command, its cost and the class
-- resource -- all configured per class. A running loop must not carry on sending the
-- previous class's attack.
emunah.class.active, emunah.class.name = nil, nil
emunah.gmcp.status.values.class = nil
mock.feed("Char.Status", { class = "Priest" })
eq(emunah.class.name, "priest", "starting as a priest")

emunah.bashing.stop("test")
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })
mock.feed("Room.Info", { num = 4242, name = "Somewhere", area = "Test", exits = {} })
mock.feed("Char.Items.List", {
   location = "room", items = { { id = "9001", name = "a pixie", attrib = "m" } },
})
emunah.denizens.setWanted("a pixie", true)
emunah.bashing.start()
ok(emunah.bashing.enabled, "bashing is running as a priest")

mock.feed("Char.Status", { class = "Monk" })
ok(not emunah.bashing.enabled, "a class change stops the running loop")

emunah.class.active, emunah.class.name = nil, nil
emunah.gmcp.status.values.class = nil
mock.feed("Char.Status", { class = "Priest" })

-- ===========================================================================
suite("config persistence")

emunah.config.set("curing.confirmWait", 1.25)
emunah.config.save()
pcall(load)   -- reload
eq(emunah.config.get("curing.confirmWait"), 1.25, "settings survive a reload")

-- ===========================================================================
suite("UI degradation without Geyser")

ok(type(Geyser) == "nil", "test environment has no Geyser")
eq(emunah.ui.layout.build(), false, "layout declines to build without Geyser")
ok(pcall(emunah.ui.vitals.update), "vitals panel update is safe with no widgets")
ok(pcall(emunah.ui.affpanel.update), "affliction panel update is safe with no widgets")

-- ===========================================================================
suite("UI construction with Geyser")

mock.installGeyser()
local uiOk, uiErr = pcall(load)   -- reload so the UI modules build against Geyser
ok(uiOk, "reloads cleanly with Geyser present", uiErr)

ok(emunah.ui.layout.container("left") ~= nil, "left container built")
ok(emunah.ui.layout.container("right") ~= nil, "right container built")
ok(emunah.ui.layout.container("bottom") ~= nil, "bottom container built")

-- Geyser ignores unknown constructor fields silently, so a typo costs a feature with no
-- error. Every field the panels pass to a MiniConsole must be one Geyser actually reads.
eq(#mock.unknownConsFields, 0, "no unrecognised MiniConsole constructor fields",
   table.concat(mock.unknownConsFields, ", "))

ok(mock.widgets["emunah.gauge.hp"] ~= nil, "health gauge built")
ok(mock.widgets["emunah.gauge.wp"] ~= nil, "willpower gauge built")
ok(mock.widgets["emunah.afflictions"] ~= nil, "affliction console built")
ok(mock.widgets["emunah.room"] ~= nil, "room console built")
ok(mock.widgets["emunah.chat.plain"] ~= nil, "chat falls back to a plain console without EMCO")

-- With MDK present, EMCO must be found via require("MDK.emco") -- it is not a global.
package.loaded["MDK.emco"] = {
   new = function(self, cons, parent)
      mock.emcoCons = cons
      local console = { tabs = {}, lines = {} }
      function console:decho(tab, text) self.lines[#self.lines + 1] = tab .. ":" .. text end
      return console
   end,
}
emunah.ui.chat.build()
eq(emunah.ui.chat.mode, "emco", "EMCO is discovered through require(\"MDK.emco\")")
ok(mock.emcoCons and mock.emcoCons.consoles ~= nil, "EMCO built with a tab list")

-- The all-tab must be a member of `consoles`, or EMCO rejects it.
local hasAllTab = false
for _, tab in ipairs(mock.emcoCons.consoles or {}) do
   if tab == mock.emcoCons.allTabName then hasAllTab = true end
end
ok(hasAllTab, "allTabName is present in the consoles list", mock.emcoCons.allTabName)

mock.feed("Comm.Channel.Text", { channel = "ct", talker = "X", text = "hi" })
local emcoLines = emunah.ui.chat.console.lines
ok(emcoLines and #emcoLines > 0 and tostring(emcoLines[#emcoLines]):find("^City:"),
   "channel text routed into the right EMCO tab",
   emcoLines and emcoLines[#emcoLines])

package.loaded["MDK.emco"] = nil
emunah.ui.chat.build()

-- Panel placement. Chat owns the top of the right column, the room panel the bottom;
-- afflictions own the left column; vitals own the bottom strip. Asserting the parent
-- container of each catches a panel built into the wrong region, which is invisible in
-- a headless test but glaring on screen.
local function parentName(widget)
   return widget and widget.parent and widget.parent.name or "?"
end
eq(parentName(mock.widgets["emunah.afflictions"]), "emunah.left", "afflictions are in the left column")
eq(parentName(mock.widgets["emunah.room"]), "emunah.right", "room panel is in the right column")
eq(parentName(mock.widgets["emunah.gauge.hp"]), "emunah.bottom", "vitals are in the bottom strip")

-- Chat sits above the room panel inside the shared right column.
local chatWidget = mock.widgets["emunah.chat.plain"] or mock.widgets["emunah.chat"]
eq(parentName(chatWidget), "emunah.right", "chat is in the right column")
local function pct(value)
   return tonumber(tostring(value):match("^(%d+)%%")) or 0
end
ok(pct(mock.widgets["emunah.room"].cons.y) > pct(chatWidget.cons.height),
   "room panel starts below the chat console",
   ("chat height %s, room y %s"):format(
      tostring(chatWidget.cons.height), tostring(mock.widgets["emunah.room"].cons.y)))

-- The map: bottom-right, positioned on the Geyser ROOT rather than in a container.
local mapWidget = mock.widgets["emunah.map"]
ok(mapWidget ~= nil, "map widget built")
eq(mapWidget.kind, "mapper", "map uses Geyser.Mapper, not a console")

-- THE map fix. createMapper() draws a native widget at absolute coordinates -- it is not
-- a Qt child of any Geyser container, it only sits where one happens to be. Putting it
-- "inside" the Adjustable.Container meant the container's background label painted over
-- it: the map built correctly, reported healthy geometry, and was invisible. It must have
-- no container parent.
eq(mapWidget.parent, nil, "map has NO container parent (a container's label would cover it)")

-- ...and the right container must stop above the map region, so nothing overlaps it.
local rightContainer = emunah.ui.layout.container("right")
ok(pct(rightContainer.cons.height) <= pct(mapWidget.cons.y),
   "right container ends at or above the map region",
   ("container height %s, map y %s"):format(
      tostring(rightContainer.cons.height), tostring(mapWidget.cons.y)))

-- Embedded, not floating. Geyser.Mapper defaults embedded=true only when NEITHER
-- `embedded` nor `dockPosition` is passed; passing dockPosition would pull the map out
-- of the layout into a free-floating widget.
ok(mapWidget.embedded, "map is embedded in the main window, not floating")
eq(mapWidget.cons.dockPosition, nil, "no dockPosition is passed (that would detach the map)")
ok(#mock.mapperCalls > 0, "createMapper was called", #mock.mapperCalls)

-- Vertical ordering: chat, then room, inside the container; map below the container.
local roomTop = pct(mock.widgets["emunah.room"].cons.y)
ok(roomTop > pct(chatWidget.cons.height), "room panel starts below chat")

-- Turning the map off must give its space back to the right container rather than
-- leaving a dead strip.
local heightWithMap = pct(emunah.ui.layout.rightHeight())
emunah.config.set("ui.map", false)
local heightWithoutMap = pct(emunah.ui.layout.rightHeight())
ok(heightWithoutMap > heightWithMap,
   "disabling the map extends the right container into its space",
   ("%d%% -> %d%%"):format(heightWithMap, heightWithoutMap))
emunah.config.set("ui.map", true)

-- Map height is adjustable, and the right container gives up exactly that space so the
-- two always sum to the window minus the vitals strip.
emunah.ui.map.setHeight(50)
eq(emunah.ui.layout.mapHeightPct(), 50, "map height is settable")
eq(pct(emunah.ui.layout.rightHeight()) + emunah.ui.layout.mapHeightPct()
   + pct(emunah.ui.layout.HEIGHT_BOTTOM), 100,
   "right container + map + vitals strip fill the window exactly")

-- Out-of-range values are clamped rather than squeezing the other panels out.
emunah.ui.map.setHeight(95)
eq(emunah.ui.layout.mapHeightPct(), 70, "an oversized map height is clamped to 70%")
emunah.ui.map.setHeight(1)
eq(emunah.ui.layout.mapHeightPct(), 10, "an undersized map height is clamped to 10%")

emunah.ui.map.setHeight(emunah.ui.layout.HEIGHT_MAP_DEFAULT)
eq(emunah.ui.layout.mapHeightPct(), 42, "default map height restored")

-- Driving real data through the panels is where formatting errors surface.
mock.feed("Char.Vitals", {
   hp = "2500", maxhp = "4000", mp = "1200", maxmp = "3000",
   ep = "19000", maxep = "22000", wp = "17000", maxwp = "20000",
   nl = "43.7", bal = "1", eq = "0",
   charstats = { "Bleed: 120", "Kai: 35%", "Stance: Horse" },
})
local hpGauge = mock.widgets["emunah.gauge.hp"]
ok(hpGauge.value ~= nil, "health gauge received a value")
eq(hpGauge.value.current, 2500, "health gauge shows current hp")
ok(tostring(hpGauge.value.text):find("2,500"), "health gauge formats with separators",
   hpGauge.value.text)

-- A fractional nl must not blow up string.format("%d").
ok(mock.widgets["emunah.gauge.xp"].value ~= nil, "xp gauge handles a fractional percentage")

-- Abbreviated: the vitals strip is wide but only ~20px tall per row.
eq(mock.widgets["emunah.balance"].contents, "BAL", "balance light rendered")
eq(mock.widgets["emunah.equilibrium"].contents, "EQ", "equilibrium light rendered")
ok(mock.widgets["emunah.stats"].contents ~= nil, "charstats block rendered")

-- Target gauge with a fractional health percentage.
mock.feed("IRE.Target.Set", "1234")
mock.feed("IRE.Target.Info", { id = "1234", short_desc = "a rat", hpperc = "66.5" })
ok(mock.widgets["emunah.target"].value ~= nil, "target gauge handles fractional hp%",
   mock.widgets["emunah.target"].value and mock.widgets["emunah.target"].value.text)

-- Affliction panel with real content.
--
-- Rebind through the namespace rather than reusing the `engine` local captured earlier:
-- the reload above replaced every module table, so the old local now points at a dead
-- generation. This is exactly how stale references behave in a live profile too, which is
-- why nothing in the system caches another module's table across a reload.
engine = emunah.curing.engine
engine.clear()
engine.add("paralysis", "gmcp")
engine.add("anorexia", "trigger")
ok(pcall(emunah.ui.affpanel.update), "affliction panel renders tracked afflictions")
ok(tostring(mock.widgets["emunah.afflictions"].contents):find("paralysis"),
   "affliction panel shows the affliction")
engine.clear()

-- Room panel with real content.
mock.feed("Room.Info", {
   num = 777, name = "A quiet glade", area = "Forest",
   exits = { n = 778, e = 779 }, details = { "shop" },
})
local roomText = tostring(mock.widgets["emunah.room"].contents)
ok(roomText:find("quiet glade"), "room panel shows the room name")
ok(roomText:find("shop"), "room panel shows room details")

-- ROOM ITEMS. gmcp/items.lua always tracked these, but nothing rendered them -- `ih`
-- would list four items in the game window while the panel showed none.
mock.feed("Char.Items.List", {
   location = "room",
   items = {
      { id = "14664", name = "Vellis, the butterfly collector", attrib = "m" },
      { id = "138062", name = "a silky white fern", attrib = "t" },
      { id = "167244", name = "a small wooden sign", attrib = "" },
      { id = "630491", name = "a logosmas stocking", attrib = "c" },
   },
})
local withItems = tostring(mock.widgets["emunah.room"].contents)
ok(withItems:find("items"), "room panel has an items section")
ok(withItems:find("Vellis"), "room panel lists a creature in the room")
ok(withItems:find("silky white fern"), "room panel lists a takeable item")
ok(withItems:find("logosmas stocking"), "room panel lists a container")
-- The leading article is stripped so a narrow panel reads cleanly.
ok(not withItems:find("a silky white fern"), "leading article is trimmed from item names")

-- An item appearing must refresh the panel without waiting for a room change.
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "999", name = "a gleaming sovereign", attrib = "t" },
})
ok(tostring(mock.widgets["emunah.room"].contents):find("gleaming sovereign"),
   "an item dropped in the room appears immediately")

-- ...and removal must clear it.
mock.feed("Char.Items.Remove", { location = "room", item = { id = "999" } })
ok(not tostring(mock.widgets["emunah.room"].contents):find("gleaming sovereign"),
   "a removed item disappears from the panel")

-- Rebuilding must hide the previous generation rather than stacking dead panels.
-- Hold direct references: the rebuild reuses the same names, so looking the containers up
-- by name afterwards would find the *new* ones and prove nothing.
local oldContainers = {
   emunah.ui.layout.container("left"),
   emunah.ui.layout.container("right"),
   emunah.ui.layout.container("bottom"),
}
emunah.ui.layout.build()

local hidden = 0
for _, container in ipairs(oldContainers) do
   if container and not container.shown then hidden = hidden + 1 end
end
eq(hidden, 3, "rebuilding hides all three previous containers")
ok(emunah.ui.layout.container("left") ~= oldContainers[1],
   "rebuild produced a fresh container, not the old one")

-- ...but the NEW containers must be visible.
--
-- This is the bug that made the whole interface invisible in play. teardown() hides the
-- previous generation, Adjustable.Container:new inherits `hidden` from a same-named
-- container, autoSave writes it to disk and autoLoad restores it -- so after one reload
-- the UI was built correctly and then immediately hidden, permanently, with no error.
for _, which in ipairs({ "left", "right", "bottom" }) do
   ok(emunah.ui.layout.container(which).shown,
      ("%s container is visible after a rebuild"):format(which))
end

-- Saved state that says "hidden" must not win either.
mock.savedContainerState["emunah.left"] = { hidden = true }
mock.savedContainerState["emunah.right"] = { hidden = true }
mock.savedContainerState["emunah.bottom"] = { hidden = true }
emunah.ui.layout.build()
for _, which in ipairs({ "left", "right", "bottom" }) do
   ok(emunah.ui.layout.container(which).shown,
      ("%s container is visible despite saved hidden state"):format(which))
end

-- The escape hatch clears the saved geometry.
emunah.ui.layout.reset()
eq(mock.savedContainerState["emunah.left"], nil, "ui reset deletes the saved layout")
ok(emunah.ui.layout.container("left").shown, "ui reset leaves the container visible")

mock.uninstallGeyser()

-- ===========================================================================
suite("walker")

mock.installMap(30)
local walker = emunah.walker

-- Put us in room 1.
mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = { e = 2 } })

ok(walker.currentRoom() == 1, "position comes from GMCP Room.Info, no mapper script needed",
   walker.currentRoom())

ok(walker.start(), "walk starts over the current area")
eq(#walker.remaining, 29, "current room excluded from the walk list")
ok(walker.enabled, "walker is running")

-- SELF-DRIVING. The walker raises walker.arrived and lets a consumer pace the walk, but
-- with no consumer registered that meant `emunah walk start` enumerated the area and then
-- waited forever for a message nobody sends -- indistinguishable from failing to start.
-- It must step on its own.
eq(walker.nextRoom, nil, "no destination chosen synchronously on start")
mock.advance(1.0)
eq(walker.nextRoom, 2, "walker steps to the nearest room on its own after start")

-- Arriving schedules the next step without anything raising walker.move.
mock.feed("Room.Info", { num = 2, name = "Room 2", area = "Test", exits = {} })
mock.advance(1.0)
ok(walker.nextRoom ~= nil and walker.nextRoom ~= 2,
   "walker keeps going after arriving, unprompted", tostring(walker.nextRoom))

-- With auto off, pacing goes back to the consumer and it must NOT step by itself.
walker.setAuto(false)
walker.nextRoom = nil
mock.advance(2.0)
eq(walker.nextRoom, nil, "auto off: walker waits to be told to move")
walker.move()
ok(walker.nextRoom ~= nil, "auto off: an explicit move() still steps")
walker.setAuto(true)

-- Reset for the assertions that follow.
walker.stop("test")
mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = { e = 2 } })
walker.start()
mock.advance(1.0)

-- Arriving marks it visited and raises the arrival event.
local arrivals = {}
emunah.event.register("emunah.walker.arrived", function(_, room)
   arrivals[#arrivals + 1] = room
end, "test.walker")

mock.feed("Room.Info", { num = 2, name = "Room 2", area = "Test", exits = {} })
eq(walker.stats.visited, 1, "arrival counted")
eq(#walker.remaining, 28, "visited room removed from the list")
ok(arrivals[#arrivals] == 2, "arrival event raised for the target room", arrivals[#arrivals])

-- The O(n^2) fix: a move must not pathfind every remaining room.
local before = mock.pathfindCount()
walker.move()
local pathfinds = mock.pathfindCount() - before
ok(pathfinds <= walker.CANDIDATES + 1,
   "move pathfinds only a bounded candidate set, not all 27 rooms", pathfinds)

-- Safety stop on low health.
walker.config.stopBelowHealth = 40
mock.feed("Char.Vitals", { hp = "100", maxhp = "1000", bal = "1", eq = "1" })
walker.move()
ok(not walker.enabled, "walker stops itself when health drops below the threshold")

-- Avoid list.
walker.config.stopBelowHealth = 0
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = {} })
walker.avoidRoom(5)
ok(walker.start(), "walk restarts")
ok(not emunah.util.contains(walker.remaining, 5), "avoided room excluded from the walk")
walker.stop("test")
walker.unavoidRoom(5)

-- AN UNREACHABLE ROOM MUST NOT LOOP FOREVER.
--
-- The mapper will happily path through an exit the game refuses -- water needing SWIM, a
-- closed door, a gate. Re-issuing the speedwalk restarts it, so with nothing to stop it
-- the log fills with "Starting speedwalk from 2397 to 2396" on every prompt, forever,
-- while the game answers "You'll have to SWIM WEST". The walker has to be able to give up.
walker.stop("test")
mock.installMap(10)
mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = { e = 2 } })
walker.start()
mock.advance(1.0)

local stuckOn = walker.nextRoom
ok(stuckOn ~= nil, "walker is heading somewhere")
local failedBefore = walker.stats.failed

-- Repeated move() calls while travelling must NOT re-issue the walk.
local walksBefore = #mock.map.walkedTo
for _ = 1, 5 do walker.move() end
eq(#mock.map.walkedTo, walksBefore,
   "move() while already travelling does not restart the speedwalk",
   #mock.map.walkedTo - walksBefore)

-- ...but once the timeout passes with no arrival, the room is abandoned.
mock.advance(10.0)
walker.move()
ok(walker.stats.failed > failedBefore,
   "an unreachable room is given up on after the transit timeout")
ok(not emunah.util.contains(walker.remaining, stuckOn),
   "the unreachable room is dropped from the walk list")
walker.stop("test")

-- The genrun findAndRemove bug: removing an absent item must not delete the last element.
-- genrun did table.remove(t, table.index_of(t, item)); index_of returns nil for a missing
-- item and table.remove(t, nil) drops the tail, silently losing an unrelated room.
mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = {} })
walker.start()
local sizeBefore = #walker.remaining
local tail = walker.remaining[sizeBefore]
-- Arriving in a room that is not on the list (already visited, or outside the area).
mock.feed("Room.Info", { num = 999, name = "Nowhere", area = "Test", exits = {} })
eq(#walker.remaining, sizeBefore, "arriving somewhere off-list removes nothing")
eq(walker.remaining[#walker.remaining], tail, "the tail room is NOT silently dropped")
walker.stop("test")

ok(pcall(emunah.commands.dispatch, "walk"), "emunah walk reports status")

-- ===========================================================================
suite("denizens and the per-area kill list")

local den = emunah.denizens
den.areas = {}

mock.feed("Room.Info", {
   num = 500, name = "Entrance to the Pixie village", area = "The Pixie Village",
   exits = { n = 501, e = 502 },
})

-- Entering a room must ASK for its contents. Achaea does not reliably push a room item
-- list on entry, so clearing without asking left the panel permanently empty after the
-- first move -- `ih` showed four pixies while the UI showed none.
local askedForRoom = false
for _, payload in ipairs(mock.gmcpSent) do
   if tostring(payload):find("Char.Items.Room") then askedForRoom = true end
end
ok(askedForRoom, "entering a room requests its item list")

-- The real room from the transcript: four denizens, two of them both called "a pixie".
mock.feed("Char.Items.List", {
   location = "room",
   items = {
      { id = "307246", name = "an androgynous pixie child", attrib = "m" },
      { id = "107736", name = "a pixie warrior",            attrib = "m" },
      { id = "308635", name = "a pixie",                    attrib = "m" },
      { id = "196510", name = "a pixie",                    attrib = "m" },
      { id = "999",    name = "a mangled corpse",           attrib = "md" },
      { id = "888",    name = "a small wooden sign",        attrib = "" },
   },
})

eq(#den.here(), 4, "four denizens here (corpse and scenery excluded)")

-- THE ITEM LIST ARRIVES BEFORE Room.Info WHEN YOU WALK.
--
-- This is why room items updated on LOOK but never on entering a room: LOOK happens to
-- send Room.Info first, movement sends the item list first, and the Room.Info handler was
-- clearing the correct list microseconds after it landed. Replay the movement order.
mock.feed("Char.Items.List", {
   location = "room",
   items = {
      { id = "500001", name = "a pixie warrior", attrib = "m" },
      { id = "500002", name = "a pixie",         attrib = "m" },
   },
})
local pollsBeforeEntry = 0
for _, payload in ipairs(mock.gmcpSent) do
   if tostring(payload):find("Char.Items.Room") then pollsBeforeEntry = pollsBeforeEntry + 1 end
end
mock.feed("Room.Info", {
   num = 502, name = "Deeper still", area = "The Pixie Village", exits = {},
})
eq(#emunah.gmcp.items.at("room"), 2,
   "a list that arrived BEFORE Room.Info survives the room change",
   #emunah.gmcp.items.at("room"))
eq(#den.here(), 2, "and the denizens in it are visible")
ok(emunah.gmcp.items.roomFresh(), "and is immediately fresh -- no confirmation round-trip needed")

-- Regression: Room.Info used to unconditionally reset and re-poll on every genuine room
-- change, even though the list we already hold (above) is already correct. Achaea does not
-- bother re-answering that redundant poll since nothing changed, so it would go unanswered
-- and, once requestRoom()'s retries were exhausted, get misread as "the room is empty" --
-- items would show up correctly on entry and then vanish a couple of seconds later. Since we
-- already have this room's contents, Room.Info must NOT issue another Char.Items.Room poll.
local pollsAfterEntry = 0
for _, payload in ipairs(mock.gmcpSent) do
   if tostring(payload):find("Char.Items.Room") then pollsAfterEntry = pollsAfterEntry + 1 end
end
eq(pollsAfterEntry, pollsBeforeEntry,
   "already having the room's contents does not trigger a redundant re-poll")
mock.advance(3.0)   -- long past every retry window
eq(#emunah.gmcp.items.at("room"), 2,
   "...and the correctly-received items are still there a few seconds later")

-- The other order (LOOK) must keep working too.
mock.feed("Room.Info", { num = 503, name = "Onwards", area = "The Pixie Village", exits = {} })
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "500003", name = "a pixie", attrib = "m" } },
})
eq(#emunah.gmcp.items.at("room"), 1, "a list arriving AFTER Room.Info also lands")
ok(emunah.gmcp.items.roomFresh(), "and is marked fresh")

-- A genuinely empty room clears the previous room's items: an empty list is still a list.
mock.feed("Room.Info", { num = 504, name = "Bare", area = "The Pixie Village", exits = {} })
mock.feed("Char.Items.List", { location = "room", items = {} })
eq(#emunah.gmcp.items.at("room"), 0, "an empty room genuinely empties the list")

-- Restore the pixie room for the assertions that follow. The rooms above recorded their
-- own denizens into this area, so clear the table first or the counts below measure this
-- test's setup rather than the behaviour under test.
den.areas = {}
mock.feed("Room.Info", {
   num = 500, name = "Entrance to the Pixie village", area = "The Pixie Village",
   exits = { n = 501, e = 502 },
})
mock.feed("Char.Items.List", {
   location = "room",
   items = {
      { id = "307246", name = "an androgynous pixie child", attrib = "m" },
      { id = "107736", name = "a pixie warrior",            attrib = "m" },
      { id = "308635", name = "a pixie",                    attrib = "m" },
      { id = "196510", name = "a pixie",                    attrib = "m" },
      { id = "999",    name = "a mangled corpse",           attrib = "md" },
      { id = "888",    name = "a small wooden sign",        attrib = "" },
   },
})

-- Auto-recorded into the area's list, by NAME. "a pixie" appears twice in the room but is
-- one kind of thing.
local recorded = den.forArea("The Pixie Village")
eq(#recorded, 3, "three distinct kinds recorded for the area", #recorded)
ok(not den.wanted("a pixie warrior"),
   "a kind seen for the first time is recorded but NOT auto-added to the kill list")

-- `seen` COUNTS DISTINCT REPLICA NUMBERS, not sightings.
--
-- Counting sightings produced "a pixie warrior seen 25" in a village holding three of
-- them: every Char.Items.List push re-counted every creature, so the number measured how
-- long you stood in the room. Re-pushing the identical list must not move the count.
local function seenCount(name)
   for _, entry in ipairs(den.forArea("The Pixie Village")) do
      if entry.name == name then return entry.seen end
   end
end
eq(seenCount("a pixie"), 2, "two distinct pixies counted (308635 and 196510)")
eq(seenCount("a pixie warrior"), 1, "one pixie warrior counted")

local roomPayload = {
   location = "room",
   items = {
      { id = "307246", name = "an androgynous pixie child", attrib = "m" },
      { id = "107736", name = "a pixie warrior",            attrib = "m" },
      { id = "308635", name = "a pixie",                    attrib = "m" },
      { id = "196510", name = "a pixie",                    attrib = "m" },
   },
}
for _ = 1, 10 do mock.feed("Char.Items.List", roomPayload) end
eq(seenCount("a pixie"), 2, "ten more pushes of the SAME creatures change nothing")
eq(seenCount("a pixie warrior"), 1, "...for any of them")

-- A genuinely new individual does count.
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "777001", name = "a pixie", attrib = "m" },
})
eq(seenCount("a pixie"), 3, "a new replica number increments the count")

-- This section is about TARGETING mechanics, not the first-contact opt-in gate above --
-- allow the two kinds it needs explicitly, the way a real click on the new-denizen
-- announcement (or the room panel) would.
den.setWanted("a pixie", true)
den.setWanted("a pixie warrior", true)

-- TARGETING BY REPLICA NUMBER. Two creatures are called "a pixie"; the name is ambiguous
-- and the id is not. Targeting must yield an id, never the name.
local target = den.next()
ok(target ~= nil, "a target is found")
ok(target.id:match("^%d+$"), "target is a replica number, not a name", target.id)

mock.gmcpSent = {}
local targetedId = den.target()
ok(targetedId and targetedId:match("^%d+$"), "target() returns the replica number", targetedId)
local sentTarget = table.concat(mock.gmcpSent, " ")
ok(sentTarget:find("IRE.Target.Set"), "the game target is set over GMCP", sentTarget)
ok(sentTarget:find(targetedId), "the replica number is what gets sent", sentTarget)
ok(not sentTarget:find('"pixie"'), "the ambiguous name is NOT sent as the target")

-- ENGAGING A REPLICA moves targeting on to a different creature.
--
-- Without it, "attack the first wanted denizen here" means attacking the same pixie
-- forever while its identical neighbours stand untouched: the room list still holds it,
-- and it is still first.
den.clearEngaged()
local first = den.next()
ok(first ~= nil, "a first target is found")
den.engage(first.id)
local second = den.next()
ok(second ~= nil and second.id ~= first.id,
   "after engaging one, the next target is a DIFFERENT replica",
   ("first %s, second %s"):format(first.id, second and second.id or "nil"))
ok(den.isEngaged(first.id), "the engaged replica is remembered")

local pendingCount = #den.pending()
ok(pendingCount < #den.here(), "pending excludes the engaged one", pendingCount)

-- A creature that leaves is no longer ours to deal with.
mock.feed("Char.Items.Remove", { location = "room", item = { id = first.id } })
ok(not den.isEngaged(first.id), "a departing creature drops out of the engaged set")

-- Moving room clears it entirely.
den.engage("308635")
mock.feed("Room.Info", { num = 501, name = "Deeper in", area = "The Pixie Village", exits = {} })
ok(not den.isEngaged("308635"), "changing room clears the engaged set")

-- Skipping keeps the record but takes it off the kill list, so auto-record cannot
-- silently re-add it next visit.
den.setWanted("a pixie warrior", false)
ok(not den.wanted("a pixie warrior"), "a skipped denizen is off the kill list")
den.recordRoom()
ok(not den.wanted("a pixie warrior"), "re-entering does not un-skip it")
eq(#den.forArea("The Pixie Village"), 3, "...and it is still remembered")

-- The list is per area.
mock.feed("Room.Info", { num = 600, name = "Elsewhere", area = "Some Other Area", exits = {} })
eq(#den.forArea("Some Other Area"), 0, "a different area has its own (empty) list")
ok(not den.wanted("a pixie", "Some Other Area"), "kill list does not leak across areas")

ok(pcall(emunah.commands.dispatch, "mobs"), "emunah mobs runs")
ok(pcall(emunah.commands.dispatch, "mobs here"), "emunah mobs here runs")

-- ===========================================================================
suite("click-to-allow: new denizens are announced, not auto-added")

-- A room panel widget built by an earlier Geyser suite outlives mock.uninstallGeyser() --
-- the mock nils the global Geyser, but the widget reference roompanel.lua already holds
-- keeps working regardless, so it would otherwise go on echoing its own links into
-- mock.links for the rest of the file. Not this suite's concern; drop the reference.
emunah.ui.roompanel.widgets.room = nil

den.areas = {}
mock.links = {}
mock.feed("Room.Info", { num = 900, name = "A grove", area = "Newarea", exits = {} })
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "1001", name = "a wildcat soldier", attrib = "m" } },
})

ok(not den.wanted("a wildcat soldier"),
   "a first-ever sighting is not auto-added to the kill list")
eq(#mock.links, 1, "exactly one clickable announcement was echoed")
ok(mock.links[1].text:find("wildcat soldier"),
   "the announcement names the denizen", mock.links[1].text)

local clicked = mock.click(1)
ok(clicked, "the announcement link is clickable")
ok(den.wanted("a wildcat soldier"), "clicking the announcement adds it to the kill list")

-- Persisted the same way any other setWanted() call is -- table.save() runs synchronously
-- against the mock's in-memory store, so a reload proves it was actually written, not just
-- held in the live M.areas table.
pcall(load)
ok(emunah.denizens.wanted("a wildcat soldier", "Newarea"),
   "the click survives a reload -- it was actually saved, not just held in memory")
den = emunah.denizens   -- `load()` rebuilds the namespace; keep the local in sync

-- A kind already known does not get re-announced.
den.areas = {}
mock.feed("Room.Info", { num = 900, name = "A grove", area = "Newarea", exits = {} })
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "1001", name = "a wildcat soldier", attrib = "m" } },
})
mock.links = {}
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "1002", name = "a wildcat soldier", attrib = "m" },
})
eq(#mock.links, 0, "a kind already known is not announced again")

-- A genuinely different new kind still gets its own announcement.
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "1003", name = "a plump sheep", attrib = "m" },
})
eq(#mock.links, 1, "a different new kind is announced separately")
ok(not den.wanted("a plump sheep"), "...and is not wanted until clicked")

-- toggleWanted() flips state in either direction, and reports nil (not an error) for
-- something never recorded at all -- there is no state to flip.
eq(den.toggleWanted("a plump sheep"), true, "toggleWanted() flips not-wanted to wanted")
eq(den.toggleWanted("a plump sheep"), false, "...and back again")
eq(den.toggleWanted("something nobody has ever seen", "Newarea"), nil,
   "toggleWanted() on an unrecorded denizen does nothing and says so")

den.areas = {}

-- ===========================================================================
suite("room panel: clickable, toggleable denizen lines")

mock.installGeyser()
emunah.config.data.ui.enabled = true
emunah.ui.layout.build()

den.areas = {}
mock.feed("Room.Info", { num = 901, name = "A clearing", area = "Newarea2", exits = {} })
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "2001", name = "a moon bear", attrib = "m" } },
})
den.setWanted("a moon bear", true)

mock.links = {}
emunah.ui.roompanel.update()

local bearLink
for _, link in ipairs(mock.links) do
   if link.text:find("moon bear") then bearLink = link end
end
ok(bearLink ~= nil, "a room denizen is echoed as a clickable link")
eq(bearLink.window, "emunah.room", "targeted at the room panel's own console, not the main window")

mock.click(1)
ok(not den.wanted("a moon bear"), "clicking a wanted denizen in the panel toggles it off")

-- The click's own command re-renders the panel (see echoDenizen()'s command string), so a
-- fresh link now exists reflecting the new state -- find it rather than assuming an index.
local secondBearIndex
for i, link in ipairs(mock.links) do
   if link.text:find("moon bear") then secondBearIndex = i end
end
ok(secondBearIndex ~= nil, "the panel re-rendered after the click, producing a fresh link")
mock.click(secondBearIndex)
ok(den.wanted("a moon bear"), "clicking it again toggles it back on")

den.areas = {}
emunah.config.data.ui.enabled = false
-- See the note at the top of "click-to-allow": the widget reference outlives
-- mock.uninstallGeyser() and would otherwise go on echoing into later suites.
mock.uninstallGeyser()
emunah.ui.roompanel.widgets.room = nil

-- ===========================================================================
suite("ih: linkify the ih command's output")

den.areas = {}
mock.feed("Room.Info", { num = 902, name = "A field", area = "Newarea3", exits = {} })

mock.links = {}
mock.deletedLines = 0
mock.line("wildcat338261       a wildcat soldier")

eq(mock.deletedLines, 1, "the matched line is deleted before being redrawn")
eq(#mock.links, 1, "and re-echoed as exactly one clickable link")
ok(mock.links[1].text:find("wildcat soldier"), "naming the same denizen ih named",
   mock.links[1].text)

ok(mock.click(1), "the relinked ih line is clickable")
ok(den.wanted("a wildcat soldier", "Newarea3"), "clicking it allows killing that kind")

-- A second click toggles it back off -- ih's own link, like the room panel's, is
-- toggleable in both directions, not a one-way "allow".
mock.links = {}
mock.deletedLines = 0
mock.line("wildcat338261       a wildcat soldier")
mock.click(1)
ok(not den.wanted("a wildcat soldier", "Newarea3"), "clicking an already-wanted line un-allows it")

-- A trailer line that just happens to have no meaningful shape must not be relinked.
mock.links = {}
mock.line("Number of objects: 3")
eq(#mock.links, 0, "the object-count trailer line is left alone")

den.areas = {}

-- ===========================================================================
suite("bashing loop (Priest)")

-- Become a Priest so the adapter loads class/priest.lua.
mock.feed("Char.Status", { name = "Tester", class = "Priest", level = "80" })
emunah.class.load("priest")
ok(emunah.class.active ~= nil, "priest class module loaded")
eq(emunah.class.name, "priest", "adapter knows the class")

local bash = emunah.bashing
local den2 = emunah.denizens
den2.areas = {}
den2.clearEngaged()

mock.feed("Char.Vitals", {
   hp = "4000", maxhp = "4000", mp = "3000", maxmp = "3000",
   bal = "1", eq = "1", charstats = { "Devotion: 100%" },
})
mock.feed("Room.Info", { num = 700, name = "Pixie glade", area = "Minia", exits = { n = 701 } })
mock.feed("Char.Items.List", {
   location = "room",
   items = {
      { id = "308635", name = "a pixie",         attrib = "m" },
      { id = "196510", name = "a pixie",         attrib = "m" },
      { id = "107736", name = "a pixie warrior", attrib = "m" },
   },
})

-- This suite is about the bashing LOOP, not the first-contact opt-in gate -- allow both
-- kinds explicitly, the way a real click on the new-denizen announcement would.
den2.setWanted("a pixie", true)
den2.setWanted("a pixie warrior", true)

ok(bash.start(), "bashing starts with a class module present")
ok(bash.target ~= nil, "a target was acquired")

-- One attack is in flight already: bash.start() runs a tick. Sending an attack now arms a
-- guard that lasts until the game confirms it ran (see priest.lua's INFLIGHT_GUARD), so any
-- test wanting a FRESH attack has to model the game actually resolving the previous one:
-- confirm the cost, let it elapse, then report balance back.
local function resolveAttack()
   mock.line("Balance used: 3.2s.")            -- the game ran it, and states the exact cost
   mock.advance(3.2)                           -- ...which then elapses
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
end

-- ATTACK BY REPLICA NUMBER, never by name.
mock.sent = {}
resolveAttack()
local attack = table.concat(mock.sent, " | ")
ok(attack:find("smite"), "sends the configured attack command", attack)
ok(attack:find(bash.target), "attacks the replica number", attack)
ok(not attack:find("smite pixie"), "does NOT attack the ambiguous name", attack)

-- `emunah debug` toggles verbose logging so a live command stream is visible on demand,
-- rather than only ever being inferred from the game's own replies.
eq(emunah.log.level, "info", "debug logging is off by default")
mock.echoed = {}
resolveAttack()
ok(not table.concat(mock.echoed, " | "):find("%-> smite"),
   "with debug off, a sent attack is not echoed")

emunah.log.setLevel("debug")
mock.echoed = {}
resolveAttack()
ok(table.concat(mock.echoed, " | "):find("%-> smite"),
   "with debug on, the attack command actually sent is echoed",
   table.concat(mock.echoed, " | "))
emunah.log.setLevel("info")

-- Regression: from a real bashing transcript, an attack command was firing on every prompt
-- for several prompts straight, each rejected with "You must regain balance first." --
-- Char.Vitals omits bal/eq when unchanged, so an unrelated push (e.g. reporting the same
-- round's damage) can still carry the pre-spend value before the server's own bal=0
-- confirmation arrives. vitals.spend() (called from priest.attack()) closes that gap by
-- marking balance spent locally the instant the attack is sent.
ok(not emunah.gmcp.vitals.bal, "balance is spent locally the instant the attack is sent")
mock.sent = {}
mock.feed("Char.Vitals", { hp = "3900" })   -- unrelated; bal/eq omitted, as Achaea does
eq(#mock.sent, 0, "an unrelated vitals push with bal omitted does not re-attack",
   table.concat(mock.sent, " | "))

-- THE DOUBLE-SEND, exactly as captured live at 00:17:22.40 and 00:17:23.06.
--
-- The game has not executed our attack yet, so Char.Vitals goes on reporting the balance it
-- is about to spend as available -- truthfully. The old code trusted that flag, re-attacked,
-- and collected "You must regain balance first." when the first attack finally landed. A
-- flag GMCP is entitled to overwrite cannot defend this; only the in-flight guard can.
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })   -- the game's own pre-execution state
eq(#mock.sent, 0, "a second attack is NOT sent while the first is still in flight",
   table.concat(mock.sent, " | "))

mock.sent = {}
resolveAttack()
ok(table.concat(mock.sent, " | "):find("smite"),
   "attacks again only once the game has confirmed the previous one resolved")

-- NEVER ATTACK IN FRONT OF ANOTHER PLAYER, and leave rather than stand there waiting.
mock.feed("Room.Players", { { name = "Sarapis", fullname = "Sarapis" } })
eq(emunah.gmcp.room.playerCount(), 1, "someone else is in the room")
mock.sent = {}
emunah.timers.stop("attack.balance")
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
eq(#mock.sent, 0, "no attack is sent with another player present",
   table.concat(mock.sent, " | "))
eq(bash.target, nil, "...and the target is dropped rather than held")

-- Alone again: back to normal.
mock.feed("Room.Players", {})
mock.sent = {}
emunah.timers.stop("attack.balance")
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("smite"),
   "attacking resumes once they leave", table.concat(mock.sent, " | "))

-- Regression: confirmed live via a millisecond-timestamped custom prompt -- a second smite
-- was sent (and rejected with "You must regain balance first.") barely 20ms after the
-- game's own prompt had ALREADY reported balance unavailable, nowhere near the real 3.2s
-- cooldown Achaea itself had just announced. vitals.bal alone was not a strong enough
-- guarantee against whatever produced that -- Achaea tells us the exact recovery time every
-- time it takes balance ("Balance used: Xs."), so canAttack() also requires a real timer
-- armed off that announcement, independent of whatever vitals.bal itself says.
mock.line("Balance used: 3.2s.")
ok(not emunah.class.canAttack(), "a hard cooldown blocks attacking even right after sending")

-- Simulate the exact failure mode: vitals.bal reporting ready again well before the real
-- cooldown could possibly have elapsed.
emunah.gmcp.vitals.bal = true
ok(not emunah.class.canAttack(),
   "...even when vitals.bal itself says ready, the announced cooldown still blocks it")

-- The cooldown lapsing is itself the signal to act. tick() otherwise only runs on
-- Char.Vitals, which Achaea sends when something HAPPENS -- so an attack that becomes
-- possible in a quiet moment would wait for the next unrelated event. Measured live at
-- three quarters of a second per swing.
mock.sent = {}
mock.advance(3.2)
ok(table.concat(mock.sent, " | "):find("smite"),
   "the cooldown lapsing attacks immediately, without waiting for a prompt",
   table.concat(mock.sent, " | "))

-- The in-flight guard covers exactly one send -> execute round trip, and Mudlet measures
-- that for us. A fixed guess is wrong in both directions: too long on a fast connection
-- throws away most of a balance, too short on a bad one reinstates the double-send.
local priest = emunah.class.active
mock.latency = 0.1
eq(priest.inflightGuard(), priest.GUARD_MIN, "a fast connection floors at the minimum guard")

mock.latency = 0.5
eq(priest.inflightGuard(), 0.5 * priest.GUARD_SLACK, "a normal connection scales with latency")

mock.latency = 10
eq(priest.inflightGuard(), priest.GUARD_MAX, "a wild reading is clamped, not trusted")

-- A client that does not expose it at all must not break the guard.
local savedLatency = _G.getNetworkLatency
_G.getNetworkLatency = nil
eq(priest.inflightGuard(), priest.GUARD_MIN, "no latency source falls back to the minimum")
_G.getNetworkLatency = savedLatency
mock.latency = 0.1

-- Regression: a knockdown must stop the loop from attacking at all, not just delay it --
-- before this was tracked, every attempt while down was rejected with "You must be
-- standing first.", which fired again on the very next tick: attack -> reject -> stand ->
-- attack -> reject, looping until the character happened to finish standing on its own.
mock.line("You must be standing first.")
ok(emunah.curing.detect.isProne(), "the loop is now known to be down")
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
local whileDown = table.concat(mock.sent, " | ")
ok(not whileDown:find("smite"), "no attack is sent while known to be down", whileDown)
-- ...but getting up is retried. STAND costs balance, and a knockdown lands right after our
-- own attack, so the first attempt is usually refused -- one refused attempt left the
-- character flat for twelve seconds live.
ok(whileDown:find("stand"), "...and standing up is retried until it takes", whileDown)

mock.line("You stand up.")
ok(not emunah.curing.detect.isProne(), "no longer known to be down")
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("smite"), "attacks resume once standing")

-- Regression: confirmed live from a guard-pig charge that stuns AND knocks down from the
-- same hit -- stunned is a separate state from prone and must gate the loop on its own.
mock.line("You are too stunned to be able to do anything.")
ok(emunah.curing.detect.isStunned(), "the loop is now known to be stunned")
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
eq(#mock.sent, 0, "no attack is sent while stunned", table.concat(mock.sent, " | "))

mock.line("You are no longer stunned.")
ok(not emunah.curing.detect.isStunned(), "no longer stunned")
mock.sent = {}
resolveAttack()
ok(table.concat(mock.sent, " | "):find("smite"), "attacks resume once stun passes")

-- A kill is detected from the creature leaving the room, not a death message.
local firstTarget = bash.target
mock.feed("Char.Items.Remove", { location = "room", item = { id = firstTarget } })
eq(bash.stats.killed, 1, "removal from the room counts as a kill")
eq(bash.target, nil, "target cleared when it dies")

-- ...and the loop moves to a DIFFERENT creature rather than re-picking the dead one.
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(bash.target ~= nil and bash.target ~= firstTarget,
   "next tick acquires a different replica", tostring(bash.target))

-- ENTERING A ROOM MUST NOT BE READ AS "ROOM IS CLEAR".
--
-- Room.Info clears the item list and asks Achaea for the new room's contents. Until the
-- reply lands, "nothing to attack" and "contents not arrived yet" look identical. Getting
-- that wrong makes the loop declare every room clear the instant it walks in, so the
-- walker marches through the whole area attacking nothing -- which is exactly what
-- "walks the area but never attacks anything" was.
mock.installMap(20)
emunah.walker.stop("test")
bash.stop("test"); bash.start()

local moved = false
emunah.event.register("emunah.walker.move", function() moved = true end, "test.bash")

mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = { e = 2 } })
emunah.walker.start()
mock.advance(1.0)

ok(not emunah.gmcp.items.roomFresh(), "room items are stale immediately after entering")
moved = false
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(not moved, "does NOT declare the room clear before its contents arrive")

-- Entering must also ask for them.
local asked = false
for _, payload in ipairs(mock.gmcpSent) do
   if tostring(payload):find("Char.Items.Room") then asked = true end
end
ok(asked, "entering a room requests its contents")

-- Regression: confirmed in play as "even with no mobs, I have to LOOK to move again" --
-- Char.Items.Room can go unanswered forever for a genuinely empty room, so roomFresh()
-- never becomes true and the walker never gets told to move. We do NOT paper over that by
-- sending an actual LOOK command into the live session; silence itself, once the GMCP-only
-- retries are exhausted, is treated as the server's answer that the room is empty.
-- The preceding mock.advance(1.0) already fired one retry (attempt 2, at t=0.7); one more
-- 0.7s cycle reaches attempt 3, still within ROOM_RETRIES and so still GMCP-only.
mock.sent = {}
mock.advance(0.7)
ok(not emunah.util.contains(mock.sent, "look"), "no LOOK yet -- retries are not exhausted")
ok(not emunah.gmcp.items.roomFresh(), "still not fresh -- retries are not exhausted")
mock.advance(0.7)   -- attempt 4: retries exhausted -> silence is treated as "empty"
ok(not emunah.util.contains(mock.sent, "look"),
   "no LOOK is ever sent -- exhausted retries are read as confirmation, not chased with a command",
   table.concat(mock.sent, " | "))

-- Once retries are exhausted, the room is treated as current and empty without needing
-- anything more to arrive.
ok(emunah.gmcp.items.roomFresh(), "the list is now current for this room")
moved = false
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(moved, "a genuinely empty room tells the walker to move on")
emunah.walker.stop("test")

-- Safety: it stops itself rather than dying.
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "555", name = "a pixie", attrib = "m" } },
})
bash.stop("test"); bash.start()
mock.feed("Char.Vitals", { hp = "100", maxhp = "4000", bal = "1", eq = "1" })
ok(not bash.enabled, "bashing stops itself below the health threshold")

-- THE DEFAULT REQUIREMENT IS "both", AND IT IS THE ONE IN core/config.lua THAT COUNTS.
--
-- config.get() falls back only when the key is ABSENT, so a DEFAULTS entry saying "bal"
-- silently beats `config.get("bashing.balance", "both")` at the call site. That is exactly
-- what happened: smite was confirmed to need both balance and equilibrium, priest.lua was
-- updated, config.lua was not, and canAttack() went on ignoring equilibrium entirely --
-- through three separate rounds of fixes aimed at the wrong layer. Assert the behaviour
-- against the shipped default, never against a value the test sets itself.
emunah.config.data.bashing.balance = nil
eq(emunah.config.get("bashing.balance", "both"), "both",
   "no stale default overrides the requirement at the call site")
emunah.config.data.bashing.balance = emunah.config.DEFAULTS.bashing.balance
eq(emunah.config.get("bashing.balance"), "both",
   "and the shipped default is 'both': smite costs balance AND equilibrium")

-- ...AND a config written before that correction is repaired, because changing DEFAULTS
-- does not reach one. A saved config keeps its own copy and only ABSENT keys are filled;
-- a reload restores the whole table from _persist without consulting DEFAULTS at all. So
-- the wrong value outlives its own fix unless something rewrites it.
local stale = { bashing = { balance = "bal" } }
ok(emunah.config.migrate(stale), "a config predating the correction reports a change")
eq(stale.bashing.balance, "both", "...and the stale requirement is repaired")
eq(stale.schema, emunah.config.SCHEMA, "...and stamped with the schema it has reached")
ok(not emunah.config.migrate(stale), "migration is idempotent -- a second pass does nothing")

-- A deliberate "eq" is not touched: only the value that was once the shipped default is.
local chosen = { bashing = { balance = "eq" } }
emunah.config.migrate(chosen)
eq(chosen.bashing.balance, "eq", "a value nobody shipped as a default is left alone")

-- The healing thresholds moved the same way, and with the same symptom: a saved config kept
-- 65/40 while the code, the README and the docs all said 80/85, so a character sat at 73%
-- health with nothing happening.
local oldThresholds = { curing = { healthThreshold = 65, manaThreshold = 40 } }
ok(emunah.config.migrate(oldThresholds), "a config with the old healing thresholds migrates")
eq(oldThresholds.curing.healthThreshold, 80, "health 65 -> 80")
eq(oldThresholds.curing.manaThreshold, 85, "mana 40 -> 85")

local tuned = { curing = { healthThreshold = 70, manaThreshold = 50 } }
emunah.config.migrate(tuned)
eq(tuned.curing.healthThreshold, 70, "a threshold someone chose is left alone")
eq(tuned.curing.manaThreshold, 50, "...both of them")

mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "0" })
emunah.timers.stopAll()
ok(not emunah.class.canAttack(),
   "so an attack is refused with balance but no equilibrium -- the penitence window")

-- ...and equilibrium is REQUIRED, not spent. At 12:39:14.49 smite announced "Balance used:
-- 2.9s." with the prompt reading "e-": balance gone, equilibrium still in hand. Marking it
-- spent would block the following attack over a resource the game never took.
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
emunah.timers.stopAll()
emunah.class.attack("999")
eq(emunah.gmcp.vitals.eq, true, "smite does not consume the equilibrium it requires")
eq(emunah.gmcp.vitals.bal, false, "...and does consume the balance it announces")
emunah.timers.stopAll()   -- that attack armed the in-flight guard; clear it for what follows

-- The requirement stays configurable, because a second attack on a different balance is
-- likely enough to be worth keeping.
emunah.config.set("bashing.balance", "bal")
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "0", eq = "1" })
ok(not emunah.class.canAttack(), "balance=bal: cannot attack without balance")
mock.feed("Char.Vitals", { bal = "1", eq = "0" })
ok(emunah.class.canAttack(), "balance=bal: equilibrium is irrelevant")
emunah.config.set("bashing.balance", "eq")
mock.feed("Char.Vitals", { bal = "0", eq = "1" })
ok(emunah.class.canAttack(), "balance=eq: equilibrium alone is enough")

-- Refuses to start with no class module: better than sending nothing and looking hung.
local savedActive = emunah.class.active
emunah.class.active = nil
ok(not bash.start(), "refuses to start with no class module")
emunah.class.active = savedActive

-- BASHING OWNS PACING WHILE IT RUNS.
--
-- The walker auto-steps on its own timer. With bashing also running, both drive movement:
-- the timer fires mid-fight, speedwalks out of the room, and then marches through every
-- populated room afterwards killing nothing. Bashing must claim the walker.
bash.stop("test")
emunah.walker.stop("test")
mock.installMap(20)
mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = { e = 2 } })
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "4242", name = "a pixie", attrib = "m" } },
})
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })

-- This suite is about walker/bashing integration, not the first-contact opt-in gate --
-- allow it explicitly, the way a real click on the new-denizen announcement would.
den2.setWanted("a pixie", true)

emunah.walker.start()
eq(emunah.walker.claimedBy, nil, "walker is unclaimed on its own")
bash.start()
eq(emunah.walker.claimedBy, "bashing", "bashing claims the walker")

-- With a creature still alive here, the walker must NOT wander off on its timer.
emunah.walker.nextRoom = nil
mock.advance(5.0)
eq(emunah.walker.nextRoom, nil,
   "the walker does not auto-step away while bashing is mid-fight",
   tostring(emunah.walker.nextRoom))

-- ATTACKING ONE ROOM AHEAD.
--
-- Achaea volunteers a room's contents BEFORE the Room.Info saying you have arrived, so
-- mid-speedwalk denizens.here() already describes the room in front of us. Confirmed live:
-- "smite 19316" was sent from a room containing nothing but a signpost, while pig 19316
-- stood in the room after it. Movement costs balance too, so that attack raced the mapper's
-- next step for the same balance and one of them collected "You must regain balance first."
emunah.walker.nextRoom = 2          -- in transit
emunah.timers.stop("attack.balance")
mock.feed("Char.Items.List", {      -- the NEXT room's contents, arriving early
   location = "room",
   items = { { id = "19316", name = "a guard pig", attrib = "m" } },
})
-- Wanted, so "nothing was sent" below means the transit gate held rather than the pig
-- simply not being on the kill list.
den2.setWanted("a guard pig", true)
ok(den2.wanted("a guard pig"), "the guard pig is on the kill list")

mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
eq(#mock.sent, 0, "nothing is sent while the walker is between rooms",
   table.concat(mock.sent, " | "))

-- Regression: "it's pathing but not attacking anything". walker.nextRoom is only cleared on
-- arriving at the EXACT target, so anything ending a speedwalk elsewhere -- a closed door, a
-- re-planned route -- leaves it set until the transit timeout. Gating on the flag alone
-- froze the loop outright. Standing in the destination means we have arrived, whatever the
-- flag still says.
emunah.walker.nextRoom = 1          -- stale: we are already standing in room 1
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("smite 19316"),
   "a stale nextRoom for the room we are standing in does not freeze the loop",
   table.concat(mock.sent, " | "))

-- Arriving normally releases it too.
emunah.walker.nextRoom = nil
emunah.timers.stop("attack.balance")
bash.target = nil
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("smite 19316"),
   "...and the attack goes out once we have actually arrived",
   table.concat(mock.sent, " | "))

-- Restore the pixie for the assertions below.
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "4242", name = "a pixie", attrib = "m" } },
})
bash.stop("test"); bash.start()

-- WALKING PAST THE FIGHT.
--
-- closestRoom() can return a room many steps away, and an unclaimed walker speedwalks the
-- whole route -- marking every room it passes through visited without ever raising
-- walker.arrived. Confirmed live from a GMCP trace: a seven-room speedwalk went straight
-- through a room containing a guard pig without attacking it. While something is pacing the
-- walker it must step ONE room, so each room gets its turn.
bash.stop("test"); emunah.walker.stop("test")
mock.installMap(20)
mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = { e = 2 } })
mock.feed("Char.Items.List", { location = "room", items = {} })
-- Movement needs balance AND equilibrium, so state both rather than inheriting whatever a
-- previous suite left behind.
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })
emunah.walker.start()
bash.start()
eq(emunah.walker.claimedBy, "bashing", "bashing is pacing the walker")

-- move() ignores a request while already travelling, and bash.start()'s own tick has
-- already sent us on our way -- clear that first or this measures nothing.
emunah.walker.nextRoom = nil
emunah.walker.lastStepAt = nil
mock.sent = {}
emunah.walker.move()
eq(emunah.walker.nextRoom, 2,
   "a paced walker heads for the NEXT room, not the far end of the route",
   tostring(emunah.walker.nextRoom))
eq(#mock.sent, 1, "...by sending exactly one direction", table.concat(mock.sent, " | "))
eq(mock.map.walkedTo and #mock.map.walkedTo or 0, 0, "...and does not speedwalk")

-- Steps are paced. Nothing else throttles them while claimed: scheduleNext() stands down
-- for the consumer, and sending raw directions bypasses the mapper's own pacing. Confirmed
-- live, Achaea answered the resulting burst with "Now now, don't be so hasty!"
mock.sent = {}
emunah.walker.nextRoom = nil
emunah.walker.move()
eq(#mock.sent, 0, "a step straight after the last one is deferred, not sent",
   table.concat(mock.sent, " | "))
mock.advance(1.0)
eq(#mock.sent, 1, "...and goes out once the step delay has passed",
   table.concat(mock.sent, " | "))

-- Movement costs balance. Confirmed live: prompt "e-" (equilibrium, no balance), "e" sent,
-- "You must regain balance first." A step is held until balance is back, and RETRIED --
-- marking it departed would leave the walker in transit having never moved, which the
-- bashing transit gate would then sit out too.
emunah.walker.nextRoom = nil
emunah.walker.lastStepAt = nil
mock.feed("Char.Vitals", { bal = "0", eq = "1" })
mock.sent = {}
emunah.walker.move()
eq(#mock.sent, 0, "no step is sent without balance", table.concat(mock.sent, " | "))
eq(emunah.walker.nextRoom, nil, "...nor marked in transit")

-- Equilibrium is required too.
mock.feed("Char.Vitals", { bal = "1", eq = "0" })
mock.sent = {}
emunah.walker.lastStepAt = nil
emunah.walker.move()
eq(#mock.sent, 0, "no step is sent without equilibrium either",
   table.concat(mock.sent, " | "))
mock.feed("Char.Vitals", { bal = "0", eq = "1" })
eq(emunah.walker.nextRoom, nil, "...and the walker is NOT marked in transit")

mock.feed("Char.Vitals", { bal = "1", eq = "1" })
mock.advance(1.0)
ok(#mock.sent > 0, "...and the step is retried once balance returns",
   table.concat(mock.sent, " | "))

-- Unclaimed, a plain walk still speedwalks -- that is what you want with nothing to fight.
bash.stop("test")
emunah.walker.release("bashing")
mock.map.walkedTo = {}
emunah.walker.nextRoom = nil
emunah.walker.lastStepAt = nil
emunah.walker.move()
ok(#mock.map.walkedTo > 0, "an unpaced walker still speedwalks the whole route")

-- Restore the fight for the assertions below.
emunah.walker.stop("test")
mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = { e = 2 } })
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "4242", name = "a pixie", attrib = "m" } },
})
emunah.walker.start()
bash.start()

-- Killing the last creature hands control back through roomClear -> walker.move. The
-- Remove is the whole signal: Achaea does not follow it with a fresh list, and the room
-- stays current throughout, so no re-confirmation is needed to know it is now empty.
mock.feed("Char.Items.Remove", { location = "room", item = { id = "4242", name = "a pixie" } })
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(emunah.walker.nextRoom ~= nil, "clearing the room lets the walk continue")

-- Stopping bashing gives the walker its autonomy back.
bash.stop("test")
eq(emunah.walker.claimedBy, nil, "stopping bashing releases the walker")
emunah.walker.stop("test")

-- Kills are recorded per kind, which is the number worth showing. `seen` counts distinct
-- replicas ever encountered and grows forever -- walking an area with butterflies in every
-- room legitimately reaches "100 distinct" without meaning anything.
den2.areas = {}
den2.recordKill("a red admiral butterfly", "Minia")
den2.recordKill("a red admiral butterfly", "Minia")
den2.recordKill("a pixie warrior", "Minia")
local minia = den2.forArea("Minia")
eq(minia[1].name, "a red admiral butterfly", "most-killed sorts first")
eq(minia[1].killed, 2, "kills counted per kind")
eq(minia[2].killed, 1, "...and the next")

-- LOOT. Gold spills from corpses and stays on the ground; over a 132-room hunt that is a
-- lot of sovereigns left behind.
-- Gold is only taken when it came from OUR kill, so establish that first. The slay message
-- is the credit -- see loot.lua.
mock.feed("Room.Players", {})
mock.sent = {}
emunah.loot.attempted = {}
mock.line("You have slain a juvenile wildcat, retrieving the corpse.")
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "778899", name = "a few golden sovereigns", attrib = "t" },
})
local looted = table.concat(mock.sent, " | ")
ok(looted:find("get 778899"), "gold appearing in the room is picked up", looted)
ok(not looted:find("get gold"),
   "taken by replica number, not the ambiguous word (several piles can be down)")

-- Not retried endlessly if the take fails.
mock.sent = {}
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "778899", name = "a few golden sovereigns", attrib = "t" },
})
eq(#mock.sent, 0, "the same pile is not grabbed twice")

-- Non-gold is left alone.
mock.sent = {}
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "778900", name = "a mangled corpse", attrib = "d" },
})
eq(#mock.sent, 0, "corpses and scenery are not picked up")

-- Walking into a room where something already died sweeps the floor.
mock.sent = {}
emunah.loot.attempted = {}
mock.line("You have slain a sheep, retrieving the corpse.")
mock.feed("Char.Items.List", {
   location = "room",
   items = {
      { id = "881", name = "a pile of gold sovereigns", attrib = "t" },
      { id = "882", name = "a small wooden sign",       attrib = "" },
   },
})
local swept = table.concat(mock.sent, " | ")
ok(swept:find("get 881"), "gold already on the floor is swept up", swept)
ok(not swept:find("get 882"), "...and only the gold")

-- Regression: GET needs standing just like everything else -- gold appearing while knocked
-- down must not be sent into the same rejection bashing already avoids, but it must also
-- not be silently lost: "emunah.recovered" (raised once prone actually clears) re-sweeps
-- the room for anything skipped rather than marking it attempted and giving up on it.
mock.sent = {}
mock.line("You have slain a thing, retrieving the corpse.")
emunah.curing.detect.prone = true
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "884", name = "a pile of gold sovereigns", attrib = "t" },
})
eq(#mock.sent, 0, "gold appearing while knocked down is not grabbed", table.concat(mock.sent, " | "))

mock.sent = {}
mock.line("You have slain a thing, retrieving the corpse.")
mock.line("You stand up.")
ok(table.concat(mock.sent, " | "):find("get 884"),
   "...but is picked up once standing again", table.concat(mock.sent, " | "))

-- GET COSTS BALANCE AND EQUILIBRIUM, so it competes with attacking -- which is exactly when
-- gold appears, since the pile comes from a kill that just spent both.
emunah.loot.attempted = {}
mock.feed("Char.Vitals", { bal = "0", eq = "1" })
mock.sent = {}
mock.line("You have slain a thing, retrieving the corpse.")
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "894", name = "a pile of gold sovereigns", attrib = "t" },
})
eq(#mock.sent, 0, "no pickup is attempted without balance", table.concat(mock.sent, " | "))

-- ...and it is retried when balance returns, not left for an unrelated room event.
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("get 894"),
   "...and is picked up the moment balance is back", table.concat(mock.sent, " | "))

-- Equilibrium is required too.
emunah.loot.attempted = {}
mock.feed("Char.Vitals", { bal = "1", eq = "0" })
mock.sent = {}
mock.line("You have slain a thing, retrieving the corpse.")
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "895", name = "a pile of gold sovereigns", attrib = "t" },
})
eq(#mock.sent, 0, "no pickup without equilibrium either", table.concat(mock.sent, " | "))
mock.feed("Char.Vitals", { bal = "1", eq = "1" })

-- ONLY OUR OWN KILLS. Achaea does not say who a pile belongs to, and hoovering up every
-- pile on the floor is how an automated character takes a stranger's loot.
emunah.loot.attempted = {}
emunah.loot.creditUntil = nil
mock.sent = {}
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "890", name = "a pile of gold sovereigns", attrib = "t" },
})
eq(#mock.sent, 0, "gold with no kill of ours behind it is left alone",
   table.concat(mock.sent, " | "))

-- The credit expires, so a pile appearing much later is somebody else's.
mock.line("You have slain a thing, retrieving the corpse.")
mock.advance(emunah.loot.CREDIT_WINDOW + 1)
emunah.loot.attempted = {}
mock.sent = {}
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "891", name = "a pile of gold sovereigns", attrib = "t" },
})
eq(#mock.sent, 0, "credit from an old kill has expired", table.concat(mock.sent, " | "))

-- NOT IN FRONT OF ANYONE. Room.Players excludes ourselves (see gmcp/room.lua), so this is
-- genuinely "someone else is here".
emunah.loot.attempted = {}
mock.feed("Room.Players", { { name = "Sarapis", fullname = "Sarapis" } })
mock.sent = {}
mock.line("You have slain a thing, retrieving the corpse.")
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "892", name = "a pile of gold sovereigns", attrib = "t" },
})
eq(#mock.sent, 0, "nothing is picked up with another player in the room",
   table.concat(mock.sent, " | "))

-- ...and resumes once they leave.
mock.feed("Room.Players", {})
emunah.loot.attempted = {}
mock.sent = {}
mock.line("You have slain a thing, retrieving the corpse.")
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "893", name = "a pile of gold sovereigns", attrib = "t" },
})
ok(table.concat(mock.sent, " | "):find("get 893"), "...and resumes once they leave",
   table.concat(mock.sent, " | "))

-- Off means off.
emunah.config.set("loot.gold", false)
mock.sent = {}
emunah.loot.attempted = {}
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "883", name = "a few golden sovereigns", attrib = "t" },
})
eq(#mock.sent, 0, "disabling loot stops pickup")
emunah.config.set("loot.gold", true)

-- A SAFETY STOP MUST NOT LEAVE US WALKING.
--
-- release() only hands pacing back, and an unclaimed walker resumes stepping on its own --
-- so stopping the fight actually STARTED the wandering. Confirmed live: bashing stopped on
-- a damage spike, then speedwalked through three more rooms while a wolverine chased and
-- mauled us, unable to fight back because bashing was off.
mock.installMap(20)
emunah.walker.stop("test"); bash.stop("test")
mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = { e = 2 } })
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })
mock.feed("Char.Items.List", {
   location = "room", items = { { id = "4242", name = "a pixie", attrib = "m" } },
})
den2.setWanted("a pixie", true)
emunah.walker.start()
bash.start()
ok(emunah.walker.enabled and bash.enabled, "hunting")

-- Health collapses far enough to trip the flat floor.
mock.map.walkedTo = {}
mock.feed("Char.Vitals", { hp = "400", maxhp = "4000" })
ok(not bash.enabled, "bashing stops on a safety condition")
ok(not emunah.walker.enabled, "...and the walk stops too, rather than wandering off hurt")
eq(emunah.walker.claimedBy, nil, "...and the walker is not left claimed by a dead loop")

-- ...and does NOT walk home. Returning to start is right after a completed walk and
-- actively harmful after an emergency: confirmed live, a safety stop at 44% health while
-- bleeding 90 a tick immediately speedwalked three rooms back across the area.
eq(#mock.map.walkedTo, 0, "an emergency stop does not speedwalk home",
   tostring(#mock.map.walkedTo))

-- A deliberate stop still just hands pacing back, so `emunah walk` alone keeps working.
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })
emunah.walker.start()
bash.start()
bash.stop("requested")
ok(emunah.walker.enabled, "a requested stop leaves the walk running")
emunah.walker.stop("test")

ok(pcall(emunah.commands.dispatch, "loot"), "emunah loot reports status")
ok(pcall(emunah.commands.dispatch, "bash"), "emunah bash reports status")

-- Target health drives an evidence-based "is this working" reading, rather than a blind
-- attack count. Achaea reports it per hit via IRE.Target.Info.
bash.stop("test"); bash.start()
bash.target = "4242"
bash.attemptsAtTarget = 0
bash.targetHealth = { first = nil, last = nil }
mock.feed("IRE.Target.Set", "4242")
mock.feed("IRE.Target.Info", { id = "4242", hpperc = "100%" })
bash.attemptsAtTarget = 1
mock.feed("IRE.Target.Info", { id = "4242", hpperc = "80%" })
eq(bash.killIn(), 4, "kill-in is estimated from health actually removed", tostring(bash.killIn()))

-- A target whose health does not move reports nil -- the attack is wrong for it, not slow.
bash.targetHealth = { first = 100, last = 100 }
eq(bash.killIn(), nil, "a target taking no damage reports no estimate")

-- PENITENCE: an amplifier that costs devotion, mana and the equilibrium smite needs, so it
-- is only worth sending when the fight lasts long enough for 10% to repay it.
local priest = emunah.class.active
mock.feed("Char.Vitals", {
   hp = "1000", maxhp = "1000", mp = "3000", maxmp = "3000", bal = "1", eq = "1",
   charstats = { "Devotion: 100%" },
})
ok(priest.shouldPenitence(8), "a long fight is worth branding")
eq(priest.shouldPenitence(2), false, "a two-hit target is not")
eq(priest.shouldPenitence(nil), false,
   "a target taking no damage is not -- 10% more of nothing is nothing")

-- Devotion is the resource to be careful with: the cost against denizens is only described
-- as "reduced" from 300, and charstats reports a percentage, so the floor is cautious
-- rather than calculated.
mock.feed("Char.Vitals", { charstats = { "Devotion: 20%" } })
eq(priest.shouldPenitence(8), false, "low devotion holds it back")
mock.feed("Char.Vitals", { charstats = { "Devotion: 100%" } })
-- Below penitence's own floor but above the safety one, or this stops the loop instead.
mock.feed("Char.Vitals", { mp = "350", maxmp = "3000" })
eq(priest.shouldPenitence(8), false, "so does low mana")
mock.feed("Char.Vitals", { mp = "3000", maxmp = "3000" })

-- AN ALLY'S BRAND COUNTS. The brand is on the creature, not the caster, so a second one
-- achieves nothing. Verbatim from another Priest hunting in the same room.
emunah.gmcp.items.locations.room = {
   { id = "5001", name = "a young rat", attrib = "m" },
   { id = "5002", name = "an old badger", attrib = "m" },
}
bash.penitent = {}
mock.line("Anzerloi calls down holy fire upon a young rat, condemning him to serve penance")
ok(bash.isPenitent("5001"), "an ally's brand is recorded against the right replica")
eq(bash.isPenitent("5002"), false, "...and only that one")

-- Achaea wraps the sentence at the client's width, so the tail arrives on the next line.
-- An anchored pattern would never fire on the real thing.
bash.penitent = {}
mock.line("Anzerloi calls down holy fire upon an old badger, condemning her to serve")
ok(bash.isPenitent("5002"), "the pattern survives the game wrapping the line")

-- Ambiguity is left alone. With two identically-named creatures the description identifies
-- neither, and the costs are not symmetric: marking the wrong one loses a real
-- amplification, marking neither costs at worst a refused command that spends nothing.
emunah.gmcp.items.locations.room = {
   { id = "6001", name = "a young rat", attrib = "m" },
   { id = "6002", name = "a young rat", attrib = "m" },
}
bash.penitent = {}
mock.line("Anzerloi calls down holy fire upon a young rat, condemning him to serve penance")
eq(bash.isPenitent("6001"), false, "an ambiguous description brands nothing")
eq(bash.isPenitent("6002"), false, "...neither of them")

-- OFFENSIVE ABILITIES ONLY AT CONFIRMED DENIZENS. The authority is Achaea's own monster
-- attribute, not our kill list: a player, a shopkeeper or a corpse must never be the object
-- of one, whatever a misparsed name or a stale id says.
emunah.gmcp.items.locations.room = {
   { id = "7001", name = "a young rat", attrib = "m" },
   { id = "7002", name = "Anzerloi", attrib = "" },
   { id = "7003", name = "the corpse of a rat", attrib = "md" },
}
ok(emunah.denizens.isDenizen("7001"), "a live monster is a denizen")
eq(emunah.denizens.isDenizen("7002"), false, "a player is not")
eq(emunah.denizens.isDenizen("7003"), false, "nor is a corpse")
eq(emunah.denizens.isDenizen("9999"), false, "nor is an id that is not in the room")
emunah.gmcp.items.locations.room = {}

-- It costs equilibrium, which smite also needs -- so it is refused without it rather than
-- wasted, the same as everything else.
mock.feed("Char.Vitals", { eq = "0" })
mock.sent = {}
priest.penitence("4242")
eq(#mock.sent, 0, "no branding without equilibrium", table.concat(mock.sent, " | "))
-- Set directly: feeding vitals drives a tick, and the attack it triggers spends the
-- equilibrium locally before we get to call penitence.
mock.feed("Char.Vitals", { mp = "3000", maxmp = "3000" })
emunah.gmcp.vitals.eq = true
mock.sent = {}
priest.penitence("4242")
ok(table.concat(mock.sent, " | "):find("perform penitence 4242"),
   "...and the right command otherwise", table.concat(mock.sent, " | "))

-- Penitence spends equilibrium the instant it is sent, and the announced cooldown blocks
-- attacking for its duration. Confirmed live: two smites went out into that gap, both
-- rejected with "You must regain equilibrium first." while the prompt read "x-".
emunah.timers.stopAll()
emunah.gmcp.vitals.eq = true
mock.sent = {}
priest.penitence("4242")
eq(emunah.gmcp.vitals.eq, false, "equilibrium is spent the moment penitence is sent")
eq(emunah.class.canAttack(), false, "...so no attack goes out into the gap")

-- ...and it stays shut when Char.Vitals pushes before the game has run the command. The
-- flag it reports is truthful -- the equilibrium genuinely is still there until penitence
-- executes -- so the local spend alone was overwritten and a smite went out at 10:32:28.35,
-- rejected with "You must regain equilibrium first." before "Equilibrium used: 1.25s." had
-- arrived to arm the real cooldown.
emunah.gmcp.vitals.eq = true          -- as a Char.Vitals push in the gap would
eq(emunah.class.canAttack(), false,
   "...even when Char.Vitals restores the flag before the game has run the command")

-- The game then states the real cost, which is authoritative over the local guess.
mock.line("Equilibrium used: 1.25s.")
emunah.gmcp.vitals.eq = true          -- as Char.Vitals would once it catches up
eq(emunah.class.canAttack(), false,
   "...and the announced cooldown still blocks it, whatever the flag says")
-- Set directly rather than feeding: a vitals push drives a tick, and the attack it triggers
-- would spend both again before we could check.
mock.advance(1.3)
emunah.timers.stop("attack.balance")
emunah.gmcp.vitals.bal, emunah.gmcp.vitals.eq = true, true
ok(emunah.class.canAttack(), "...until it elapses")

-- Damage dealt and taken, for tuning thresholds from evidence.
bash.stats.dealt, bash.stats.taken = 0, 0
mock.line("Damage dealt: 337 (physical blunt).")
eq(bash.stats.dealt, 337, "damage dealt is accumulated", tostring(bash.stats.dealt))
bash.stop("test")

-- The walk ending ends the hunt. Without this the loop kept ticking over an exhausted
-- route -- every tick found the room clear and asked a walker that was no longer running to
-- move -- so `emunah hunt` never finished on its own.
bash.stop("test")
bash.start()
ok(bash.enabled, "bashing is running")
emunah.event.raise("walker.finished", 12, "route exhausted")
ok(not bash.enabled, "the walk finishing stops bashing too")

-- ...unless bashing was deliberately decoupled from the walker, where clearing a single
-- room by hand is the whole point.
emunah.config.set("bashing.walkWhenClear", false)
bash.start()
emunah.event.raise("walker.finished", 0, "route exhausted")
ok(bash.enabled, "with walkWhenClear off, bashing is independent of the walk")
bash.stop("test")
emunah.config.set("bashing.walkWhenClear", true)

-- The queue routes through the same gate as everything else, and an action can declare what
-- it needs. A cure that requires standing must not go out while prone, but must not be
-- dropped either -- it waits, like any other blocked action.
queue.reset()
queue.push("free", "stand up straight", { needs = { standing = true } })
emunah.curing.detect.prone = true
mock.sent = {}
eq(queue.flush(), 0, "queue: an action needing standing is held while prone")
eq(queue.pending("free").command, "stand up straight", "...and stays queued")
emunah.curing.detect.prone = false
eq(queue.flush(), 1, "...and goes out once upright")
queue.reset()

-- Baseline: full health, no denizens pending, both loops stopped, so the PvP suite starts
-- from a clean slate regardless of what the bashing suite left behind.
bash.stop("test")
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })
mock.feed("Char.Items.List", { location = "room", items = {} })

-- ===========================================================================
suite("watch: checks on every Char event")

local watch = emunah.watch
bash.stop("test"); emunah.walker.stop("test")
watch.reset()
emunah.config.set("watch.damageSpike", 25)

-- Full health, everything reported: nothing to complain about.
mock.feed("Char.Vitals", {
   hp = "950", maxhp = "950", mp = "3000", maxmp = "3000",
   ep = "3000", maxep = "3000", wp = "3000", maxwp = "3000", bal = "1", eq = "1",
})
eq(watch.unsafe(), nil, "healthy character is safe", tostring(watch.unsafe()))

-- A resource with no reported maximum is UNKNOWN, not empty. Treating it as empty would
-- stop every loop before the first complete Char.Vitals arrives.
watch.reset()
mock.feed("Char.Vitals", { hp = "950", maxhp = "950", ep = "0", maxep = "0" })
eq(watch.unsafe(), nil, "a resource with no maximum reported is not treated as empty")

-- Death.
watch.reset()
mock.feed("Char.Vitals", { hp = "0", maxhp = "950" })
ok(tostring(watch.unsafe()):find("dead"), "death is detected", tostring(watch.unsafe()))

-- Damage rate, but only with little bar left to absorb it.
--
-- A rate on its own is not danger. Confirmed live: a wolverine hitting for ~250 on a ~1000
-- bar trips a 25% rate on ONE normal exchange, and the loop stopped at 75% health with
-- plenty of room -- which makes it unusable against anything that hits hard. What is
-- dangerous is losing that fast while ALREADY low.
watch.reset()
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", ep = "3000", maxep = "3000" })
eq(watch.unsafe(), nil, "one sample is not a trend")
mock.feed("Char.Vitals", { hp = "850", maxhp = "1000" })
mock.feed("Char.Vitals", { hp = "700", maxhp = "1000" })
ok(watch.damageRate() >= 25, "the rate itself is detected", watch.damageRate())
eq(watch.unsafe(), nil, "...but a spike with plenty of health left does NOT stop the loops")

-- A burst absorbed by a heal is not a decline. The window has to outlast one heal cycle or
-- a single hit trips it mid-fight -- confirmed live against a goat hitting for ~25% a ram,
-- during a fight that was being sustained fine.
watch.reset()
mock.feed("Char.Vitals", { hp = "600", maxhp = "1000" })
mock.feed("Char.Vitals", { hp = "350", maxhp = "1000" })   -- one big hit
mock.feed("Char.Vitals", { hp = "800", maxhp = "1000" })   -- elixir lands
mock.feed("Char.Vitals", { hp = "780", maxhp = "1000" })
eq(watch.unsafe(), nil, "a hit absorbed by a heal is not a spiral")

-- The same rate, low down and OUT OF COMBAT, does. Nothing is in the room here.
mock.feed("Char.Items.List", { location = "room", items = {} })
eq(watch.inCombat(), false, "nothing is fighting us")
watch.reset()
mock.feed("Char.Vitals", { hp = "700", maxhp = "1000" })
mock.feed("Char.Vitals", { hp = "500", maxhp = "1000" })
mock.feed("Char.Vitals", { hp = "380", maxhp = "1000" })
ok(tostring(watch.unsafe()):find("losing health fast"),
   "a spike while low and unopposed stops the loops", tostring(watch.unsafe()))

-- ...but NOT while something is actively hitting us. Stopping does not make an aggressive
-- denizen stop: confirmed live, the loops halted mid-fight and the goat carried on ramming
-- for ~270 a time, so the character stood there tanking and drinking, neither fighting nor
-- leaving. The fight was being sustained comfortably throughout.
mock.feed("Char.Items.List", {
   location = "room", items = { { id = "77", name = "a creamy white goat", attrib = "m" } },
})
eq(watch.inCombat(), true, "something is fighting us")
eq(watch.unsafe(), nil, "a spike mid-fight does NOT stop the loops -- finish the kill")

-- The critical floor still applies, in or out of combat.
mock.feed("Char.Vitals", { hp = "250", maxhp = "1000" })
ok(tostring(watch.unsafe()):find("critical"),
   "...but the critical floor still stops it", tostring(watch.unsafe()))
mock.feed("Char.Items.List", { location = "room", items = {} })

-- Healing back up clears it: the window only holds recent samples.
for _ = 1, 5 do mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000" }) end
eq(watch.unsafe(), nil, "recovering clears the spike")

-- Endurance and willpower, which were tracked and never read before.
watch.reset()
mock.feed("Char.Vitals", { hp = "950", maxhp = "950", ep = "100", maxep = "3000" })
ok(tostring(watch.unsafe()):find("endurance"), "endurance floor stops the loops",
   tostring(watch.unsafe()))
watch.reset()
mock.feed("Char.Vitals", { hp = "950", maxhp = "950", ep = "3000", maxep = "3000",
   wp = "50", maxwp = "3000" })
ok(tostring(watch.unsafe()):find("willpower"), "willpower floor stops the loops",
   tostring(watch.unsafe()))

-- The class resource, read generically from charstats via the class module's declaration.
watch.reset()
mock.feed("Char.Vitals", {
   hp = "950", maxhp = "950", ep = "3000", maxep = "3000", wp = "3000", maxwp = "3000",
   mp = "3000", maxmp = "3000", charstats = { "Devotion: 100%" },
})
eq(watch.unsafe(), nil, "full devotion is fine")
mock.feed("Char.Vitals", { charstats = { "Devotion: 2%" } })
ok(tostring(watch.unsafe()):find("devotion"),
   "an exhausted class resource stops the loops", tostring(watch.unsafe()))
mock.feed("Char.Vitals", { charstats = { "Devotion: 100%" } })

-- Rate limiting is global, not per-subsystem. Bashing, curing, the walker and loot each
-- pace against their own resource and cannot see the others, so all can be individually
-- reasonable while the total is too fast. The game complains about the sum.
mock.line("Now now, don't be so hasty!")
eq(emunah.act.blocked(), "rate limited", "a throttle notice holds every command")
eq(emunah.act.blocked({ standing = true }), "rate limited", "...whatever the command needs")
mock.advance(emunah.act.BACKOFF + 0.1)
eq(emunah.act.blocked(), nil, "...and lifts on its own")

-- Bleeding is read from the numeric charstat, not the per-tick damage message.
local bled
emunah.event.register("emunah.bleeding", function(_, amount) bled = amount end, "test.watch")
mock.feed("Char.Vitals", { charstats = { "Devotion: 100%", "Bleed: 14" } })
eq(bled, 14, "the Bleed charstat is reported", tostring(bled))

-- ===========================================================================
suite("PvP targeting")

local pvp = emunah.pvp

-- Never auto-targets: starting with no target set, even with balance free, sends nothing.
mock.sent = {}
ok(pvp.start(), "pvp starts with a class module present")
eq(pvp.target, nil, "no target is set on start")
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
eq(#mock.sent, 0, "no attack is sent without an explicit target")

-- Setting a target sends the game-side target and starts attacking on tick.
ok(pvp.setTarget("Sarapis"), "target accepted")
eq(pvp.target, "sarapis", "target is stored lower-case, same convention as denizens.lua")

local targetSet = false
for _, payload in ipairs(mock.gmcpSent) do
   if tostring(payload):find("IRE.Target.Set") and tostring(payload):find("sarapis") then
      targetSet = true
   end
end
ok(targetSet, "the game-side target is set too")

mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
local pvpAttack = table.concat(mock.sent, " | ")
ok(pvpAttack:find("smite sarapis"), "attacks the named target once one is set", pvpAttack)

pvp.clearTarget()
eq(pvp.target, nil, "clearTarget removes the target")
pvp.stop("test")

-- Safety: own health threshold stops it, same shape as bashing's, but a higher default --
-- a PvP loss costs more and there is no "room is clear" backstop to catch a late stop.
eq(emunah.config.get("pvp.stopBelowHealth", 60), 60, "pvp's default health floor is higher than bashing's")
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })
pvp.start()
pvp.setTarget("sarapis")
mock.feed("Char.Vitals", { hp = "100", maxhp = "4000", bal = "1", eq = "1" })
ok(not pvp.enabled, "pvp stops itself below its health threshold")
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })

-- Mutual exclusion in both directions: bashing and PvP must never run concurrently, because
-- fighting a denizen and a player on the same balance is not a thing.
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "9001", name = "a pixie", attrib = "m" } },
})

pvp.start()
pvp.setTarget("sarapis")
ok(pvp.enabled, "pvp is running")
ok(bash.start(), "bashing starts")
ok(not pvp.enabled, "starting bashing stops an active pvp session (emunah.bashing.started)")
bash.stop("test")

pvp.stop("test")
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "9001", name = "a pixie", attrib = "m" } },
})
ok(bash.start(), "bashing is running")
pvp.start()
ok(not bash.enabled, "starting pvp stops an active bashing session (emunah.bashing.pause)")
pvp.stop("test")

-- Death detection: Achaea's own unambiguous system messages, not a guess.
pvp.start()
pvp.setTarget("sarapis")
mock.line("You have slain Sarapis.")
ok(not pvp.enabled, "killing the current target stops the session")
eq(pvp.target, nil, "and clears the target")

-- A kill notice for someone who is NOT the current target must not be mistaken for a win.
pvp.start()
pvp.setTarget("sarapis")
mock.line("You have slain Someoneelse.")
ok(pvp.enabled, "a kill notice for a different name does not stop the session")
eq(pvp.target, "sarapis", "and does not touch the target")
pvp.stop("test")

pvp.start()
pvp.setTarget("sarapis")
mock.line("You have been slain by a rampaging pixie.")
ok(not pvp.enabled, "your own death stops the session")
pvp.stop("test")

-- Refuses to start with no class module, same guard as bashing.
local savedClass = emunah.class.active
local savedName  = emunah.class.name
emunah.class.active, emunah.class.name = nil, nil
ok(not pvp.start(), "refuses to start with no class module")
emunah.class.active, emunah.class.name = savedClass, savedName

ok(pcall(emunah.commands.dispatch, "pvp"), "emunah pvp reports status")
ok(pcall(emunah.commands.dispatch, "pvp target sarapis"), "emunah pvp target <name> dispatches")
eq(pvp.target, "sarapis", "the dispatch path reaches setTarget")
ok(pcall(emunah.commands.dispatch, "pvp target off"), "emunah pvp target off dispatches")
eq(pvp.target, nil, "the dispatch path reaches clearTarget")
pvp.stop("test")

-- Regression: adding pvp.lua must not change bashing's own player-avoidance behaviour.
-- bashing.lua flees deliberately, because a bashing loop is not equipped for PvP; pvp.lua
-- is the module that actually engages, and only on an explicit target.
emunah.config.set("bashing.stopOnPlayer", true)
mock.feed("Room.Players", {})
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "9002", name = "a pixie", attrib = "m" } },
})
bash.stop("test"); bash.start()
mock.feed("Room.AddPlayer", { name = "Sarapis" })
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(not bash.enabled, "bashing still flees when a player arrives and stopOnPlayer is set")
emunah.config.set("bashing.stopOnPlayer", false)

-- ===========================================================================
suite("opponent affliction tracking")

local opponent = emunah.curing.detect.opponent
opponent.clear()

-- Registering a pattern and firing it asserts the affliction for the NAMED actor, not us --
-- the whole point of a capture-group pattern instead of a self-affliction one.
ok(opponent.add("paralysis", [[^(.+) collapses, paralysed\.$]]), "pattern registers")
mock.line("Sarapis collapses, paralysed.")
ok(opponent.has("sarapis", "paralysis"), "the named actor is tracked as paralysed")
ok(not opponent.has("someoneelse", "paralysis"), "no one else is affected by that line")

-- Non-trigger callers (a future lock planner, or a test) can drive it directly too.
opponent.assert("targetname", "asthma")
ok(opponent.has("targetname", "asthma"), "assert() records state directly")
eq(opponent.count("targetname"), 1, "count scopes to one opponent")

opponent.forget("targetname", "asthma")
ok(not opponent.has("targetname", "asthma"), "forget() retracts a single affliction")

opponent.assert("sarapis", "clumsiness")
eq(opponent.list("sarapis")[1], "clumsiness", "list() is sorted")
ok(#opponent.list("sarapis") == 2, "both tracked afflictions are listed", #opponent.list("sarapis"))

-- There is no GMCP feed for someone else's afflictions, so entries age out rather than
-- reconcile the way curing/engine.lua's self-tracking does.
mock.advance(45)
opponent.prune(30)
eq(opponent.count("sarapis"), 0, "prune() ages out stale entries past maxAge")

-- The real corpus (opponent_patterns.lua) is loaded at module load time, not registered by
-- hand in this suite -- these lines exercise a few of its actual patterns end to end.
opponent.clear()
mock.line("Doriath begins to sway unsteadily.")
ok(opponent.has("doriath", "dizziness"), "the real dizziness pattern fires")

mock.line("The face of Doriath contorts in horrified revulsion.")
ok(opponent.has("doriath", "masochism"), "the real masochism pattern fires")

mock.line("Doriath has writhed free of his entanglement by tied ropes.")
ok(not opponent.has("doriath", "roped"), "a cure pattern retracts rather than asserts")
opponent.assert("doriath", "roped")
mock.line("Doriath has writhed free of his entanglement by tied ropes.")
ok(not opponent.has("doriath", "roped"), "addCure() retracts an affliction asserted some other way")

opponent.clear()

opponent.clear()
eq(opponent.count(), 0, "clear() with no name wipes everyone")

-- ===========================================================================
suite("numpad movement keys")

local KEYPAD = mudlet.keymodifier.Keypad

eq(emunah.keys.count(), 24, "13 directions bound across both Num Lock states")

-- Num Lock ON sends the digit.
mock.sent = {}
ok(mock.press(KEYPAD, mudlet.key["8"]), "numpad 8 is bound (Num Lock on)")
eq(mock.sent[#mock.sent], "n", "numpad 8 sends north")

mock.press(KEYPAD, mudlet.key["5"])
eq(mock.sent[#mock.sent], "look", "numpad 5 sends look")

mock.press(KEYPAD, mudlet.key["1"])
eq(mock.sent[#mock.sent], "sw", "numpad 1 sends southwest")

mock.press(KEYPAD, mudlet.key.Plus)
eq(mock.sent[#mock.sent], "up", "numpad + sends up")

mock.press(KEYPAD, mudlet.key.Period)
eq(mock.sent[#mock.sent], "out", "numpad . sends out")

-- Num Lock OFF sends the navigation key sharing that position. Binding only the digits
-- gives a keypad that silently stops working the moment someone taps Num Lock.
mock.press(KEYPAD, mudlet.key.Up)
eq(mock.sent[#mock.sent], "n", "numpad 8 sends north with Num Lock OFF too")

mock.press(KEYPAD, mudlet.key.Clear)
eq(mock.sent[#mock.sent], "look", "numpad 5 sends look with Num Lock off")

mock.press(KEYPAD, mudlet.key.PageDown)
eq(mock.sent[#mock.sent], "se", "numpad 3 sends southeast with Num Lock off")

-- The Keypad modifier is what separates numpad 8 from the 8 above the letters. Without
-- it, typing "8" in a sentence would walk you north.
ok(not mock.press(mudlet.keymodifier.None, mudlet.key["8"]),
   "plain 8 (no Keypad modifier) is NOT bound")

-- FAILURE HAS TO BE LOUD. Numpad movement breaking is invisible until you press a key and
-- walk nowhere, and every path that could stop it used to be silent or debug-only.
local realTempKey = _G.tempKey

_G.tempKey = function() error("Mudlet refused the binding", 0) end
mock.echoed = {}
eq(emunah.keys.build(), false, "a build that binds nothing reports failure")
local said = table.concat(mock.echoed, " ")
ok(said:find("refused by Mudlet"), "...names the refused bindings", said)
ok(said:find("No numpad bindings were installed"),
   "...and says movement keys will do nothing", said)

_G.tempKey = realTempKey
mock.echoed = {}
ok(emunah.keys.build(), "rebuilding restores them")
eq(emunah.keys.count(), 24, "...all of them")

-- Disabled in settings is a different cause with the same symptom, and is now said at info
-- rather than debug: someone whose numpad stopped working is owed the sentence that
-- explains it.
emunah.config.set("keys.numpad", false)
mock.echoed = {}
eq(emunah.keys.build(), false, "disabled in settings does not bind")
ok(table.concat(mock.echoed, " "):find("emunah keys on"),
   "...and says how to turn it back on", table.concat(mock.echoed, " "))
emunah.config.set("keys.numpad", true)
emunah.keys.build()
eq(emunah.keys.count(), 24, "and back on again")

-- Refusing to bind bare digits is deliberate: without the Keypad modifier there is nothing
-- separating numpad 8 from the 8 above the letters, and typing "8" would walk you north.
local realKeypad = mudlet.keymodifier.Keypad
mudlet.keymodifier.Keypad = nil
mock.echoed = {}
eq(emunah.keys.build(), false, "no Keypad modifier means no bindings")
ok(table.concat(mock.echoed, " "):find("refusing to bind bare digits"),
   "...and says why rather than binding something dangerous",
   table.concat(mock.echoed, " "))
mudlet.keymodifier.Keypad = realKeypad
emunah.keys.build()
eq(emunah.keys.count(), 24, "restored")

-- A movement key takes manual control from the walker; `look` does not.
mock.installMap(10)
mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = { e = 2 } })
emunah.walker.start()
ok(emunah.walker.enabled, "walker running")
mock.press(KEYPAD, mudlet.key["2"])
ok(not emunah.walker.enabled, "a movement key stops the walker")

emunah.walker.start()
mock.press(KEYPAD, mudlet.key["5"])
ok(emunah.walker.enabled, "look does NOT stop the walker")
emunah.walker.stop("test")

-- A NUMPAD PRESS MUST STOP THE WHOLE HUNT, NOT HALF OF IT.
--
-- This ended a hunt in one keypress and said only "Walk finished: 0 visited (manual
-- movement)". Stopping the walker alone left bashing running with nothing to move it,
-- which looks like the hunt died for no reason -- and nothing named the numpad as the
-- cause, so it was unattributable from the log.
mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = { e = 2 } })
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "9001", name = "a pixie", attrib = "m" } },
})
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })
emunah.walker.start()
emunah.bashing.start()
ok(emunah.walker.enabled and emunah.bashing.enabled, "hunt running (walk + bash)")

mock.echoed = {}
mock.press(KEYPAD, mudlet.key["2"])
ok(not emunah.bashing.enabled, "a numpad direction stops bashing too")
ok(not emunah.walker.enabled, "...and the walk")
eq(emunah.walker.claimedBy, nil, "the walker claim is released")

local said = table.concat(mock.echoed, " ")
ok(said:find("moved manually"), "and it says a manual move was the cause", said:sub(1, 120))

-- `look` must not end a hunt.
emunah.walker.start()
emunah.bashing.start()
mock.press(KEYPAD, mudlet.key["5"])
ok(emunah.walker.enabled and emunah.bashing.enabled, "look does not end a hunt")
emunah.bashing.stop("test")
emunah.walker.stop("test")

-- Reload safety: bindings must not stack, or every direction would send twice.
local keysBefore = emunah.keys.count()
emunah.keys.build()
eq(emunah.keys.count(), keysBefore, "rebuilding does not stack duplicate bindings")

ok(pcall(emunah.commands.dispatch, "keys"), "emunah keys reports status")

-- ===========================================================================
suite("commands")

for _, command in ipairs({ "status", "affs", "have", "detect", "defs", "help" }) do
   local commandOk, commandErr = pcall(emunah.commands.dispatch, command)
   ok(commandOk, "emunah " .. command .. " runs", commandErr)
end

-- GMCP tracing. Its own switch rather than part of the debug level: Char.Vitals arrives with
-- every prompt, so folding it in would bury whatever you turned debug on to see.
eq(emunah.log.traceGmcp, false, "GMCP tracing is off by default")
emunah.commands.dispatch("debug gmcp")
eq(emunah.log.traceGmcp, true, "emunah debug gmcp turns it on")

-- Received: reported even when the handler ignores the payload, because "it arrived and we
-- ignored it" and "it never arrived" are otherwise indistinguishable from outside.
mock.echoed = {}
mock.feed("Char.Vitals", { hp = "100", maxhp = "100", bal = "1", eq = "1" })
local traced = table.concat(mock.echoed, " | ")
ok(traced:find("<<") and traced:find("Char%.Vitals"), "a received message is traced", traced)

-- Sent, via the wrapped global -- so call sites did not have to change to be visible.
mock.echoed = {}
emunah.gmcp.clearRequests()
emunah.gmcp.items.refresh()
-- Requests are paced now (see gmcp/init.lua), so the second one is a timer away.
mock.advance(emunah.gmcp.REQUEST_INTERVAL + 0.01)
local sentTrace = table.concat(mock.echoed, " | ")
ok(sentTrace:find(">>") and sentTrace:find("Char%.Items%.Room"),
   "a sent message is traced", sentTrace)

-- The wrapper is installed on a global, and this suite has already reloaded the module tree
-- several times. Without the _persist guard each reload would wrap the previous wrapper and
-- one sendGMCP would print N times -- the same stacking bug core/event.lua exists to
-- prevent, in a different disguise. refresh() sends exactly two messages.
local arrows = select(2, sentTrace:gsub(">>", ""))
eq(arrows, 2, "reloads do not stack the trace wrapper", sentTrace)

-- Payloads are summarised, not dumped: arrays report their length, which is the part that
-- distinguishes "arrived and empty" from "never arrived".
eq(emunah.log.summarise({ 1, 2, 3 }), "[3]", "an array summarises to its length")
eq(emunah.log.summarise({}), "{}", "an empty table is visibly empty")
ok(emunah.log.summarise({ location = "room" }):find('location="room"'),
   "a small table shows its keys", emunah.log.summarise({ location = "room" }))

emunah.commands.dispatch("debug gmcp")
eq(emunah.log.traceGmcp, false, "...and toggles back off")
mock.echoed = {}
mock.feed("Char.Vitals", { hp = "100" })
ok(not table.concat(mock.echoed, " | "):find("<<"), "nothing is traced once it is off")

-- ===========================================================================
suite("aliases actually fire (regex, not Lua patterns)")

-- tempAlias takes a PCRE regex. Writing a Lua pattern there (%s for \s) produces an alias
-- that never matches, so the command goes to the game -- silently, with no error anywhere.
eq(#mock.badAliasPatterns, 0, "no alias uses Lua-pattern classes in a regex slot",
   table.concat(mock.badAliasPatterns, ", "))

-- Typing the bare command must be consumed by the alias, not sent to the game.
local dispatched = {}
local realDispatch = emunah.commands.dispatch
emunah.commands.dispatch = function(input) dispatched[#dispatched + 1] = tostring(input or "") end

ok(mock.command("emunah"), "bare 'emunah' is matched by an alias")
eq(dispatched[#dispatched], "", "bare 'emunah' dispatches with an empty argument")

ok(mock.command("emunah status"), "'emunah status' is matched")
eq(dispatched[#dispatched], "status", "argument is captured")

ok(mock.command("emunah prio paralysis herb 1"), "multi-word arguments are matched")
eq(dispatched[#dispatched], "prio paralysis herb 1", "full argument string is captured")

emunah.commands.dispatch = realDispatch

ok(mock.command("ec"), "'ec' shorthand is matched by an alias")
ok(not mock.command("emote waves"), "an unrelated command is NOT swallowed by our aliases")

-- ===========================================================================

io.write("\n", string.rep("-", 60), "\n")
io.write(string.format("%d passed, %d failed\n", passed, failed))
if failed > 0 then
   io.write("\nFailures:\n")
   for _, failure in ipairs(failures) do io.write("  ", failure, "\n") end
   os.exit(1)
end
os.exit(0)

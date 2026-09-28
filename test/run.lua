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
eq(loadedModules, 53, "all 53 manifest modules loaded")

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

-- The stats tables are FILLED IN PLACE rather than replaced -- Achaea sends charstats with
-- essentially every Char.Vitals, so two fresh tables per prompt was two tables of garbage
-- per prompt. What that buys has to be paid for with a sweep: a key present last prompt and
-- absent now must go, or a Monk's `Stance` outlives the class that had one and is read as
-- current.
mock.feed("Char.Vitals", { charstats = { "Devotion: 100%" } })
eq(vitals.stats.Devotion, 100, "the new class's stat is parsed")
eq(vitals.stats.Kai, nil, "a stat the class no longer reports is swept, not left stale")
eq(vitals.stats.Stance, nil, "...and so is a string one")
eq(vitals.statsText.Kai, nil, "...in the text table too")

-- A bare flag with no colon is recorded as present, and must clear the same way.
mock.feed("Char.Vitals", { charstats = { "Insomnia" } })
eq(vitals.stats.Insomnia, true, "a bare charstats flag is recorded as present")
eq(vitals.stats.Devotion, nil, "...and the previous prompt's stat is gone")
mock.feed("Char.Vitals", { charstats = { "Bleed: 0", "Kai: 35%", "Stance: None" } })
eq(vitals.stats.Insomnia, nil, "a flag that stops being sent is swept too")

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

-- COUNT AND QUANTITY ARE MEMOISED, and the memo has to die the instant anything moves.
--
-- Both are asked once per restockable consumable on every prompt, so they cache against
-- items.generation and every mutation site bumps it. The failure this guards against is
-- the expensive direction: a STALE count says we still hold a herb we have already eaten,
-- so the engine queues a cure that cannot fire and the affliction stays up. Each edge is
-- asserted after a read has populated the cache, which is the only ordering in which a
-- missing invalidation actually shows up.
do
   local items = emunah.gmcp.items

   -- Prime, then remove the whole stack.
   eq(items.quantity("irid"), 5, "quantity primed before the removal")
   mock.feed("Char.Items.Remove", { location = "inv", item = { id = "344362" } })
   eq(items.quantity("irid"), 0, "Remove invalidates the quantity memo")
   eq(items.count("irid"), 0, "...and the count memo")

   -- Prime the miss, then add it back: a cached ZERO is just as stale as a cached five.
   mock.feed("Char.Items.Add", {
      location = "inv",
      item = { id = "344363", attrib = "gre", name = "a group of 7 pieces of irid moss" },
   })
   eq(items.quantity("irid"), 7, "Add invalidates a cached zero")
   eq(items.count("irid"), 1, "...and the count memo")

   -- Update rewrites the entry in place, including the number inside the name.
   mock.feed("Char.Items.Update", {
      location = "inv",
      item = { id = "344363", attrib = "gre", name = "a group of 2 pieces of irid moss" },
   })
   eq(items.quantity("irid"), 2, "Update invalidates the quantity memo")

   -- A fresh List replaces the bucket wholesale.
   mock.feed("Char.Items.List", { location = "inv", items = {} })
   eq(items.quantity("irid"), 0, "List invalidates the quantity memo")
   eq(items.count("inv"), 0, "...and the location is genuinely empty")

   -- The memo is keyed by location: a room query must not answer an inventory one.
   mock.feed("Char.Items.List", {
      location = "room",
      items = { { id = "9", name = "a group of 3 pieces of irid moss", attrib = "g" } },
   })
   eq(items.quantity("irid", "room"), 3, "room quantity is counted at the room")
   eq(items.quantity("irid", "inv"), 0, "...and does not leak into the inventory answer")
end

-- ===========================================================================
suite("sight gates what Char.Items can be trusted to know")

do
   local items = emunah.gmcp.items
   mock.feed("Char.Defences.List", {})
   ok(items.sighted(), "sighted by default, nothing blind about it")

   mock.feed("Char.Defences.Add", { name = "blindness" })
   eq(items.sighted(), false, "blind without mindseye is unsighted")

   mock.feed("Char.Defences.Add", { name = "mindseye" })
   ok(items.sighted(), "mindseye compensates for blind")

   mock.feed("Char.Defences.Remove", { "mindseye" })
   eq(items.sighted(), false, "...and losing it again goes back to unsighted")

   -- inventoryKnown() must reflect it too, not just sighted() on its own: a fully listed
   -- inventory taken before going blind is still stale about anything since.
   mock.feed("Char.Items.List", { location = "inv", items = {} })
   ok(items.inventoryListed, "inventory has been listed")
   eq(items.inventoryKnown(), false, "...but is not KNOWN while unsighted")

   -- VERIFIED IN PLAY, 16:22:24-16:22:31 (`emunah debug gmcp`): Char.Items.Add goes silent
   -- while blind without mindseye -- `outr 3 ash` produced IRE.Rift.Change and the room's
   -- own confirmation but no Char.Items.Add, so the pull was never recorded and
   -- queueRestock() kept re-pulling against a phantom zero, three times, for every herb.
   -- The moment mindseye landed (Char.Defences.Add name="mindseye"), the very next outr
   -- produced a normal Char.Items.Add.
   emunah.gmcp.clearRequests()
   mock.gmcpSent = {}
   mock.feed("Char.Defences.Add", { name = "mindseye" })
   eq(items.inventoryKnown(), true, "sight regained makes inventory knowable again")
   ok(table.concat(mock.gmcpSent, " | "):find("Char.Items.Inv", 1, true),
      "...and resyncs against whatever Char.Items missed while blind",
      table.concat(mock.gmcpSent, " | "))

   mock.feed("Char.Defences.List", {})
end

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
eq(table.concat(afflist.blockedVectors("anorexia"), ","), "herb,moss,elixir",
   "anorexia blocks eating, and sipping (svof check_sip)")
eq(table.concat(afflist.blockedVectors("mucous"), ","), "smoke", "mucous blocks smoking (svof)")
eq(table.concat(afflist.blockedVectors("inquisition"), ","), "focus",
   "inquisition blocks focusing (svof)")
for _, name in ipairs({ "paralysis", "webbed", "bound", "transfixed", "roped", "impaled",
                        "numbedleftarm", "numbedrightarm" }) do
   eq(table.concat(afflist.blockedVectors(name), ","), "tree",
      name .. " blocks touching the tree (svof touchtree)")
end
eq(table.concat(afflist.blockedVectors("slickness"), ","), "salve", "slickness blocks applying")
eq(table.concat(afflist.blockedVectors("asthma"), ","), "smoke", "asthma blocks smoking")
eq(table.concat(afflist.blockedVectors("impatience"), ","), "focus", "impatience blocks focusing")

-- Every blocker must itself be curable by a vector it does not block, or it is a lock with
-- no key: the engine would need the shut vector to open the shut vector.
for blocker, shut in pairs(afflist.blocks) do
   -- Writhing out, or waiting it out, is an escape too -- neither needs a shut vector.
   local escape = afflist.isWrithe(blocker) or afflist.wearsOff[blocker] == true
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

-- SMOKE TAKES THE HERB, NOT THE PIPE, and this is pinned because it was in real doubt.
-- Every smoke cure is built as `smoke <herb>`, but the only form ever seen in a transcript
-- was `smoke pipe367581` -- and have.pipe()'s permissive fallback (see capabilities.lua) had
-- been approving every smoke cure regardless, so a herb form that did not resolve would have
-- meant no smoke cure ever worked, silently. Confirmed by the player: `smoke elm` works.
local smokeCure = afflist.curesVia("aeon", "smoke")[1]
eq(curelist.command(smokeCure), "smoke elm", "smoke cure names the herb, not the pipe")

-- Alchemist mode swaps to the mineral equivalent.
emunah.config.set("curing.method", "minerals")
eq((curelist.command(cure)), "eat magnesium", "minerals mode uses the alchemical equivalent")
emunah.config.set("curing.method", "herbs")

-- Entries added from the later cross-check resolve the same way as the original ones.
ok(afflist.known("guilt"), "an afflist entry added from the tk cross-check is known")
local guiltCure = afflist.curesVia("guilt", "herb")[1]
eq(curelist.command(guiltCure), "eat lobelia", "it resolves to the right herb command")

-- RESTOCKING COVERS DEFENCE HERBS TOO, not just affliction cures. Before this, keep-up
-- would raise a defence like insomnia (eat cohosh) or blind (eat bayberry) until the rift
-- ran dry with nothing ever pulling more, because curelist.restockables() only ever walked
-- afflist.afflictions.
do
   local restockables = emunah.util.set(curelist.restockables())
   ok(restockables.cohosh, "insomnia's herb (afflist.defenceCures) is restocked")
   ok(restockables.echinacea, "...as is thirdeye's")
   ok(restockables.skullcap, "...and deathsight/rebounding's")
   ok(restockables.myrrh, "...and myrrh's")
   -- bayberry/deaf (blind, deaf) come from deflist.lua's bare-command table, not afflist at
   -- all -- a third source, verified in play as what actually raises them (see deflist.lua).
   ok(restockables.bayberry, "blind's herb (deflist.commands) is restocked")
   ok(restockables.hawthorn, "...and deaf's")
   -- Salves stay excluded: vials are refilled with FILL, not pulled with OUTR.
   eq(restockables.sileris, nil, "a salve-vector defence cure is still not in the rift list")
end
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

-- "Absent" has to mean CONFIRMED absent -- the rift has actually been listed and does not
-- have it either -- not "the rift reply just has not arrived yet". See the "not loaded yet"
-- suite below for that third state.
mock.feed("IRE.Rift.List", {})
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
suite("the login race: neither inventory nor rift has loaded yet")

-- Live at login 2026-08-03 16:29:25.58, already paralysed by whatever was attacking before
-- the reconnect: have.cure() read zero bloodroot in both inventory and rift -- because
-- neither Char.Items.Inv nor IRE.Rift.List had actually answered yet, not because the
-- character was really out -- and said "Out of bloodroot", consuming the once-only warning.
-- Three seconds later the rift list landed and the truth was "in the rift, not in hand".
-- A third, distinct answer for this window stops the warning from lying, and from being
-- spent on a false alarm that would otherwise silence a real shortage for the rest of the
-- session.
do
   emunah.gmcp.items.inventoryListed = false
   emunah.gmcp.ire.riftListed = false

   local cure = afflist.curesVia("paralysis", "herb")[1]
   local usable, reason = emunah.have.cure(cure)
   ok(not usable, "not usable while neither list has arrived")
   eq(reason, "inventory/rift not loaded yet",
      "...and says so, rather than claiming the item is confirmed out")

   emunah.gmcp.items.inventoryListed = true
   usable, reason = emunah.have.cure(cure)
   ok(not usable, "still not usable with only inventory loaded")
   eq(reason, "inventory/rift not loaded yet",
      "...same reason, since the rift is still unheard from")

   mock.feed("IRE.Rift.List", { { name = "bloodroot", amount = 500 } })
   usable, reason = emunah.have.cure(cure)
   ok(not usable, "still refused -- in hand is what matters, and there is none")
   ok(tostring(reason):find("in the rift, not in hand"),
      "...but now the real answer, once both lists are actually in", reason)
end

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

-- PAUSING (`pp`, M.enabled = false) STOPS THE CURE, NOT THE TRACKING. M.tick() gates on
-- M.enabled, but affliction.added/removed fire straight off GMCP regardless of it, so the
-- panel keeps reporting the truth -- gained and cured -- while curing sits paused mid-fight.
engine.clear(); queue.reset(); mock.sent = {}
engine.enabled = false
mock.feed("Char.Afflictions.Add", { name = "asthma" })
ok(engine.has("asthma"), "an affliction gained while paused is still tracked")
engine.tick()
queue.flush()
eq(#mock.sent, 0, "...but no cure is sent for it while paused")
mock.feed("Char.Afflictions.Remove", { "asthma" })
ok(not engine.has("asthma"), "...and it still clears on its own once cured, while still paused")

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

-- PERFORM HANDS NEEDS BALANCE AS WELL AS EQUILIBRIUM.
--
-- Live: sent three times with the prompt reading "e-" (equilibrium up, balance taken by
-- smite) at 12:01:18.64, 12:01:22.98 and 12:01:27.70, and refused with "You must regain
-- balance first." every time; the two sent with "ex-" both landed. Smite holds balance for
-- 2.8s of every attack cycle, so without this nearly every attempt during a fight is
-- refused -- and each refusal used to re-arm the herb timer too.
engine.clear(); queue.reset(); emunah.timers.stopAll()
engine.enabled = true
mock.sent = {}
mock.feed("Char.Vitals", { hp = "300", maxhp = "1000", bal = "0", eq = "1" })
local offBalance = table.concat(mock.sent, " | ")
ok(not offBalance:find("perform hands"),
   "hands is not sent while off balance, however much equilibrium there is", offBalance)

-- Held, not discarded: the moment balance returns it should go.
eq(queue.pending("equilibrium") and queue.pending("equilibrium").command, "perform hands",
   "...it stays queued rather than being thrown away")
mock.sent = {}
mock.feed("Char.Vitals", { hp = "300", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("perform hands"),
   "...and goes out as soon as balance is back", table.concat(mock.sent, " | "))

-- THE SUCCESS LINE CONFIRMS THE VECTOR. Nothing did, so every hands -- including the ones
-- that plainly worked -- timed out and logged a re-arm:
--   12:01:31.34  You lay your hands on yourself.
--   12:01:31.83  No confirmation for [equilibrium] perform hands -- re-arming.
ok(queue.awaiting("equilibrium") ~= nil, "hands is in flight, awaiting confirmation")
mock.line("You lay your hands on yourself.")
eq(queue.awaiting("equilibrium"), nil, "the game's own success line confirms it")

-- "YOU MUST REGAIN BALANCE FIRST." IS NOT ALWAYS THE HERB.
--
-- It was attributed to the herb vector unconditionally. Observed at 12:01:19.03 answering
-- `perform hands` -- with the very next line reading "You eat some irid moss.", so the eat
-- had worked -- and again at 12:01:24.47 and 12:01:28.17 with nothing eaten in flight at
-- all. Each one re-armed the herb recovery timer regardless, so failing to heal on
-- equilibrium was delaying healing on herbs at exactly the moment both were wanted.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
emunah.have.recover("herb")
eq(emunah.have.balance("herb"), true, "herb balance starts available")

mock.line("You must regain balance first.")
eq(emunah.have.balance("herb"), true,
   "a balance refusal with nothing eaten in flight leaves the herb timer alone")

-- What it DOES always mean is that balance is not there, which is worth recording: it is
-- the one unambiguous fact in the message.
eq(emunah.gmcp.vitals.bal, false, "...and the refusal is taken as balance being gone")

-- ...but the herb reading is kept for the case it was written for. balance.md has this
-- as what a herb eaten too soon gets, and an eat actually in flight is the evidence for it.
queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
emunah.have.recover("herb")
queue.push("herb", "eat bloodroot", { priority = 0, tag = "paralysis", confirm = 2.0 })
queue.flush()
ok(queue.awaiting("herb") ~= nil, "an eat is in flight")
mock.line("You must regain balance first.")
eq(emunah.have.balance("herb"), false,
   "...and then the refusal does re-arm the herb timer")
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

-- THE ALIAS INDEX AND ITS INVALIDATION.
--
-- riftFind() resolves "irid" to an entry keyed "irid moss" through an index, rather than by
-- scanning the whole rift -- have.inRift() is asked fifteen times per prompt by the restock
-- pass, and each of those was a full scan. The failure mode a memo like this has is a STALE
-- entry: believing the rift still holds something it does not, which has the restocker pull
-- what is not there and never say why. So every write site has to rebuild it.
eq(emunah.gmcp.ire.riftFind("moss").key, "irid moss",
   "the bare commodity name resolves too, not only the qualifier")
mock.feed("IRE.Rift.List", { { name = "ash", amount = 12 } })
eq(emunah.have.inRift("irid"), 0, "a re-listed rift forgets what it no longer holds")
eq(emunah.gmcp.ire.riftFind("irid"), nil, "...and the alias for it is gone, not just its count")
eq(emunah.have.inRift("ash"), 12, "...while what it does hold is found")
mock.feed("IRE.Rift.List", { { name = "moss", desc = "irid", amount = 498 } })
eq(emunah.have.inRift("irid"), 498, "and re-listing it again brings the alias back")

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

-- STUPIDITY'S HERB CURE IS BACK. Removed after 20:57:29-20:58:04, restored on HELP
-- AFFLICTIONS and svof (dict.stupidity.herb) agreeing on goldenseal -- see afflist.lua.
eq(afflist2.priority("stupidity", "herb"), 7, "stupidity eats goldenseal again, at rank 7")
eq(#afflist2.curesVia("stupidity", "herb"), 1, "...one herb option")

engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "10", name = "a goldenseal root", attrib = "e" },
} })
mock.feed("IRE.Rift.List", {})
engine.add("stupidity", "trigger")
mock.sent = {}
engine.tick(); queue.flush()
ok(table.concat(mock.sent, " | "):find("eat goldenseal", 1, true),
   "goldenseal in hand is eaten for stupidity (HELP, svof)",
   table.concat(mock.sent, " | "))
ok(table.concat(mock.sent, " | "):find("focus"),
   "...and focus goes too, on its own balance", table.concat(mock.sent, " | "))

mock.feed("Char.Items.List", { location = "inv", items = {} })

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
-- This suite is written against a target of three; the shipped default is 1 (see
-- engine.lua's M.STOCK_TARGET), so pin it explicitly rather than let the numbers below
-- silently start meaning something else.
emunah.config.set("curing.stockTarget", 3)
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
emunah.config.set("curing.stockTarget", nil)

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
emunah.config.set("curing.stockTarget", 3)
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
emunah.config.set("curing.stockTarget", nil)

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

-- `weariness` itself is now in the table: it is svof's gamename for `weakness`
-- (afflist.ALIASES), which that very payload confirms. The fallback is exercised with a name
-- the table cannot know instead.
eq(afflist.known("weariness"), true, "weariness is known, as svof's name for weakness")
eq(afflist.known("unlistedaffliction"), false, "unlistedaffliction is not in the cure table")
mock.sent = {}
mock.feed("Char.Afflictions.Add", { name = "unlistedaffliction", cure = "EAT KELP",
   desc = "An affliction the table has never heard of." })
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("eat kelp"),
   "an affliction the table has never heard of is cured from the server's own suggestion",
   table.concat(mock.sent, " | "))

-- REGRESSION: a server-suggested cure that keeps getting rejected must not be resent every
-- tick forever. Confirmed live 2026-08-05: "apply mending to arms", the server's own
-- suggestion for two simultaneously broken arms tracked under a name afflist did not
-- recognise, went back out on essentially every prompt for close to 30 seconds, each time
-- rejected outright -- a real, mechanically-blocked case that no retry cadence would ever
-- resolve, but which still deserved a pace rather than a per-tick hammer. This does not
-- distinguish success from rejection (there is no live-game rejection to simulate here) --
-- it is armed unconditionally on send, same as M.CURE_GUARD, and a genuine success removes
-- the tracked affliction anyway, which is what actually stops the loop from reaching it.
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("eat kelp"),
   "the same tick's resolution is not resent on the very next vitals push",
   table.concat(mock.sent, " | "))

mock.advance(engine.SERVER_CURE_RETRY - 0.1)
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
eq(#mock.sent, 0, "...still throttled just short of the retry pace")

mock.advance(0.2)
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("eat kelp"),
   "...and resends once the retry pace has actually elapsed", table.concat(mock.sent, " | "))

-- The table still wins where it has an opinion: it carries priority, which the server does
-- not send and which decides what to cure first when several things are wrong at once.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "1", name = "a piece of kelp", attrib = "e" },
   { id = "2", name = "a bloodroot leaf", attrib = "e" },
} })
mock.feed("Char.Afflictions.Add", { name = "unlistedaffliction", cure = "EAT KELP" })
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

-- REGRESSION: `prone` is a state (afflist.isState), not an affliction afflist has simply
-- never heard of -- curing/detect already answers it with its own STAND, driven off the
-- same emunah.affliction.added event, independent of this loop entirely. Before this
-- guard checked afflist.isState() too, the fallback saw Char.Afflictions' cure="STAND",
-- found STAND unmapped in M.CURE_VERBS (it is a body-position command, not a vector verb),
-- and logged "not acting on it" -- true of the fallback, false of the character, which was
-- already being stood back up. Live at 07:33:12: a `sit` raised prone with cure="STAND"
-- and the warning fired even though "You stand up." followed a moment later.
engine.clear(); queue.reset(); emunah.timers.stopAll()
-- An earlier suite leaves `paralysis` in the server's list, and act.blocked() now holds
-- STAND while paralysed -- which is right, and not what this case is about.
mock.feed("Char.Afflictions.Remove", { "paralysis" })
mock.echoed = {}
mock.sent = {}
mock.feed("Char.Afflictions.Add", { name = "prone", cure = "STAND" })
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(not table.concat(mock.echoed, " "):find("not one this system maps"),
   "a state affliction's server-suggested cure is not routed through the unmappable-verb "
      .. "warning -- curing/detect owns it", table.concat(mock.echoed, " "))
ok(table.concat(mock.sent, " | "):find("stand"),
   "...curing/detect sends STAND on its own", table.concat(mock.sent, " | "))

-- A defence held on purpose must not be undone by the server's own suggestion either.
-- Same bug family as blindness/deafness in "a deliberate defence does not wait on
-- Char.Defences to say so", but the OTHER cure path: insomnia has no afflist entry at
-- all (see afflist.M.defenceCures vs M.afflictions), so it only ever reaches the engine
-- through this fallback, and the fallback had no deliberate() guard at all. Confirmed
-- live 17:59:54-18:00:04: `eat cohosh` raised Char.Afflictions.Add AND Char.Defences.Add
-- for "insomnia" together, and the fallback ate the server's suggested "EAT GOLDENSEAL"
-- ten seconds later, undoing the defence it had just raised.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Defences.Add", { name = "insomnia", desc = "x" })
mock.feed("Char.Afflictions.Add", { name = "insomnia", cure = "EAT GOLDENSEAL" })
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("goldenseal", 1, true),
   "insomnia held as a defence is not cured through the server's own suggestion",
   table.concat(mock.sent, " | "))

-- ...and it lapses with the defence. A real bout of insomnia, with no defence up, cures
-- normally from the server's own suggestion, same as weariness above.
mock.feed("Char.Defences.Remove", { "insomnia" })
queue.reset(); emunah.timers.stopAll()
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("goldenseal", 1, true),
   "with the defence gone, insomnia is cured normally from the server's suggestion",
   table.concat(mock.sent, " | "))

engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Defences.List", {})

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

-- TYPED FIELDS. A record's flags are booleans, not the strings the user typed. The GMCP
-- "0" trap has an exact analogue here: `dragon 0` stored as the string "0" is truthy, and
-- everything downstream would read "known not to be a Dragon" as "is a Dragon".
ndb.set("Malefactor", "dragon", "yep")
eq(ndb.get("Malefactor").dragon, true, "an affirmation is stored as a boolean")
ok(ndb.isDragon("Malefactor"), "...and reads back through the API")
ndb.set("Malefactor", "dragon", "0")
eq(ndb.get("Malefactor").dragon, false, "`0` is stored as false, not as a truthy string")
eq(ndb.isDragon("Malefactor"), false, "...and does not read as a Dragon")

ndb.set("Malefactor", "might", "62")
eq(ndb.get("Malefactor").might, 62, "a numeric field is stored as a number")
eq(ndb.set("Malefactor", "cityrank", "9"), false, "...and is range-checked")
eq(ndb.get("Malefactor").cityrank, nil, "...leaving the old value alone")

-- MIGHT IS NOT A 0-100 SCALE. HONOURS says "approximately 510% of your might" -- a ratio
-- against the reader, not a percentage of a fixed maximum. A cap of 100 here silently
-- rejected every reading the game has ever actually given.
ok(ndb.set("Malefactor", "might", "510"), "a might above 100 is accepted")
eq(ndb.get("Malefactor").might, 510, "...because it is a percentage of OUR might")
eq(ndb.set("Malefactor", "favourite_colour", "blue"), false, "an unknown field is refused")

eq(ndb.set("Malefactor", "mark", "ivory"), true, "mark takes a named value")
eq(ndb.set("Malefactor", "mark", "gilded"), false, "...and refuses one it does not know")
ndb.set("Malefactor", "mark", "none")
eq(ndb.get("Malefactor").mark, false,
   "`none` is a positive statement -- known NOT to be a Mark, which is not the same as unasked")

ndb.set("Malefactor", "might", "")
eq(ndb.get("Malefactor").might, nil, "clearing a field means unknown, never zero")

-- THE ORDER INSIDE relationship() IS THE DESIGN. Both of these guard a specific accident.
--
-- An enemying is the GAME stating a fact about this person, so it beats our own inference
-- from a shared organisation.
ndb.set("Housemate", "house", "Ashura")
emunah.gmcp.status.values.house = "Ashura"
eq(ndb.relationship("Housemate"), "ally", "a housemate derives as an ally")
ndb.set("Housemate", "cityenemy", "yes")
eq(ndb.relationship("Housemate"), "enemy",
   "...but an enemying by our own city outranks the shared house")
ndb.set("Housemate", "cityenemy", "no")

-- ...while `hostile` is our own broad brush across a whole city, and must NOT reach through
-- a shared organisation. Getting this backwards makes marking a city hostile silently turn
-- your own housemates into attackable targets.
ndb.set("Housemate", "city", "Mhaldor")
eq(ndb.relationship("Housemate"), "ally",
   "a hostile city does not overrule a shared house")
eq(ndb.attackable("Housemate"), false, "...so a housemate is never attackable")
emunah.gmcp.status.values.house = nil
eq(ndb.relationship("Housemate"), "enemy",
   "...and with nothing shared, the hostile city does decide it")

-- FINDING NAMES IN TEXT. The safety property is that a candidate is only ever returned if
-- it is already a record: this must not invent a person from a capitalised noun.
local found = ndb.findNames("Malefactor bows to Malefactor as Sartan watches.")
eq(#found, 2, "every occurrence of a known name is returned, duplicates included")
eq(found[1], "Malefactor", "...in order of appearance")
eq(ndb.findName("Nobody here is called Sartan or Mhaldor."), nil,
   "a capitalised word that is not a record is never treated as a person")

-- PRUNING. A record carrying nothing anyone typed is disposable; one carrying judgement
-- is not, whatever else is true of it.
ndb.record("Passerby")
ndb.record("Remembered")
ndb.note("Remembered", "worth keeping")
local pruned = ndb.prune()
ok(pruned >= 1, "a record that is only a name is pruned")
eq(ndb.known("Passerby"), false, "...and is gone")
ok(ndb.known("Remembered"), "a record carrying a note survives pruning")
ok(ndb.known("Malefactor"), "...as does one carrying facts")

-- SELECTIVE EXPORT. A roster shared with an ally should be able to carry who is in which
-- city without also carrying your private notes on how each of them opens a fight.
local shared = ndb.export({ fields = { "city" }, notes = false })
eq(shared.people["malefactor"].city, "Mhaldor", "an exported field is present")
eq(shared.people["malefactor"].class, nil, "...and a field not asked for is not")
eq(shared.people["remembered"].notes, nil, "notes are omitted when they are not wanted")
ok(ndb.export().people["remembered"].notes ~= nil, "...and present by default")

local stats = ndb.stats()
eq(stats.total, ndb.count(), "stats count every record")
ok(stats.unknownClass >= 1, "...and report the gaps as loudly as the totals")

ndb.people = {}
ndb.hostile = { city = {}, house = {}, order = {} }

-- ===========================================================================
suite("namedb: the Achaea web API")

local api = emunah.namedb.api
ndb.people = {}
api.cache, api.online, api.onlineAt = {}, {}, nil
api.queue, api.inflight = {}, nil
-- Earlier suites fed Room.Players, which is itself a lookup trigger. Clear what that left
-- on the wire or the first assertion below counts somebody else's request.
mock.requests = {}
emunah.timers.stopAll()

-- Real payloads, captured 2026-08-02. Every value is a string, including the numbers, and
-- mob_kills is sometimes abbreviated -- both of which the mapping has to survive.
local SAEMORA = '{"name":"Saemora","fullname":"Saemora, of Targossas","city":"targossas",'
   .. '"house":"(none)","level":"44","class":"priest","mob_kills":"290","player_kills":"0",'
   .. '"xp_rank":"1017","explorer_rank":"1074"}'
local THELEK = '{"name":"Thelek","fullname":"\'The\' Mistell Magnet, Thelek Ar\'kena",'
   .. '"city":"targossas","house":"(none)","level":"138","class":"monk",'
   .. '"mob_kills":"451k","player_kills":"7","xp_rank":"34","explorer_rank":"296"}'
local ERISHKA = '{"name":"Erishka","fullname":"Lady Sultana Erishka Khalimat, Auroran '
   .. 'Knight","city":"targossas","house":"harbingers","level":"104","class":"paladin",'
   .. '"mob_kills":"14886","player_kills":"720","xp_rank":"272","explorer_rank":"311"}'
local NOT_FOUND = '{"error":{"code":403,"message":"Character not found: zzzznotarealname"}}'

-- The decoder, on the real thing. Exercised directly because the test environment has no
-- yajl.to_value, so this fallback IS the path every other assertion below runs through.
local decoded = api.decode(SAEMORA)
eq(decoded.name, "Saemora", "the payload decodes")
eq(decoded.city, "targossas", "...with the city as the API spells it")
eq(decoded.level, "44", "...and numbers left as the strings they arrive as")
eq(api.decode(NOT_FOUND).error.code, 403, "a nested error object decodes")
eq(api.decode("not json at all"), nil, "unparseable input degrades to nil, it does not raise")
eq(api.decode(""), nil, "...as does an empty body")

-- The escaped forward slashes in the roster's URIs are real, and a decoder that choked on
-- \/ would fail on the one payload used to resolve every honorific.
eq(api.decode('{"uri":"https:\\/\\/api.achaea.com\\/x.json"}').uri,
   "https://api.achaea.com/x.json", "escaped forward slashes decode")

-- Mapping a payload onto a record.
api.apply(api.decode(SAEMORA))
local rec = ndb.get("Saemora")
eq(rec.city, "Targossas", "city is title-cased onto the record")
eq(rec.class, "priest", "class is stored lowercase")
eq(rec.level, 44, "a numeric field is converted")
eq(rec.house, nil, "\"(none)\" is stored as unknown, not as a house called None")

api.apply(api.decode(THELEK))
eq(ndb.get("Thelek").mobkills, "451k",
   "an abbreviated kill count is kept as text -- tonumber would read 451k as 451")

-- The API is authoritative for what it carries and touches nothing else. This is the
-- property that makes automatic refresh safe to leave on.
ndb.iff("Saemora", "enemy")
ndb.note("Saemora", "a note of ours")
ndb.set("Saemora", "importance", "5")
ndb.set("Saemora", "city", "Mhaldor")
api.apply(api.decode(SAEMORA))
eq(ndb.get("Saemora").city, "Targossas", "a fetch corrects a stale city")
eq(ndb.get("Saemora").iff, "enemy", "...and never overwrites your declaration")
eq(#ndb.notes("Saemora"), 1, "...or your notes")
eq(ndb.get("Saemora").importance, 5, "...or anything else the API does not carry")

-- The transport, end to end, through the queue.
ndb.people = {}
api.cache, api.counters = {}, { sent = 0, ok = 0, missing = 0, failed = 0, served = 0 }
mock.serve("https://api.achaea.com/characters/erishka.json", ERISHKA)

api.enrich("Erishka")
eq(#mock.requests, 1, "an enrich puts exactly one request on the wire")
mock.respond()
eq(ndb.get("Erishka").house, "Harbingers", "...and the response lands on the record")
eq(ndb.get("Erishka").api.ok, true, "...marked as successfully fetched")

-- Cached, so a second ask costs nothing. Walking through a city gate re-sees the same
-- twenty people; without this that is twenty requests every time.
api.enrich("Erishka")
eq(#mock.requests, 0, "a cached character is not re-requested")
eq(api.counters.served, 1, "...and is counted as served from cache")

-- A name that is not a character. The API answers 403, and that answer is cached: a
-- mis-resolved honorific must not be re-asked every time it scrolls past.
api.character("Zzzznotarealname")
mock.advance(api.INTERVAL + 0.1)   -- requests are paced; let this one leave
mock.respond()
eq(api.cached("Zzzznotarealname"), false, "a 403 is cached as a definite miss")
api.character("Zzzznotarealname")
eq(#mock.requests, 0, "...and is not asked again")

-- Requests are serialised and paced. Twenty people in a room must not become twenty
-- simultaneous requests to a volunteer-run service.
api.cache, api.queue, api.inflight = {}, {}, nil
mock.requests = {}
emunah.timers.stopAll()
mock.serve("https://api.achaea.com/characters/thelek.json", THELEK)
mock.serve("https://api.achaea.com/characters/saemora.json", SAEMORA)
api.character("Erishka"); api.character("Thelek"); api.character("Saemora")
eq(#mock.requests, 1, "only one request is in flight at a time")
eq(api.pending(), 3, "...with the rest queued")
mock.respond()
eq(#mock.requests, 0, "the next does not go out in the same instant")
mock.advance(api.INTERVAL + 0.1)
eq(#mock.requests, 1, "...it goes out after the interval")

-- Duplicate suppression: the same name asked for twice while in flight is one request.
api.queue, api.inflight = {}, nil
mock.requests = {}
api.cache = {}
api.character("Erishka"); api.character("Erishka")
eq(api.pending(), 1, "a duplicate request is collapsed")

-- A dropped response must not wedge the queue forever.
api.queue, api.inflight, mock.requests = {}, nil, {}
api.cache = {}
api.character("Erishka")
mock.requests = {}                       -- the response never arrives
mock.advance(api.TIMEOUT + api.INTERVAL + 1)
eq(api.pending(), 0, "a request that never lands times out rather than wedging the queue")

-- ===========================================================================
suite("namedb: mining names out of the game's own listings")

local capture = emunah.namedb.capture
ndb.people = {}
api.cache, api.online, api.onlineAt = {}, {}, nil
api.queue, api.inflight, mock.requests = {}, nil, {}
capture.unresolved, capture.buffer, capture.active = {}, {}, nil

-- THE CENTRAL PROBLEM: the character's name sits at no fixed position inside a honorific.
-- These five are all from one real CW listing.
eq(capture.candidates("Saemora, of Targossas")[1], "Saemora", "a bare honorific")
ok(emunah.util.contains(capture.candidates("Seeker Kaellyn, Oathsworn of Targossas"),
   "Kaellyn"), "a name in second position is a candidate")
ok(emunah.util.contains(capture.candidates("Lady Sultana Erishka Khalimat, Auroran Knight"),
   "Erishka"), "...as is one in third")
ok(emunah.util.contains(capture.candidates("'The' Mistell Magnet, Thelek Ar'kena"),
   "Thelek"), "...as is one after the comma")
ok(emunah.util.contains(capture.candidates("Khaalis Saibel Aristata"), "Saibel"),
   "...as is one in the middle with no comma anywhere")

-- Apostrophes are stripped rather than treated as part of the name.
ok(not emunah.util.contains(capture.candidates("Thelek Ar'kena"), "Ar'kena"),
   "an apostrophised surname is not offered whole")

-- Honorific words that are never names are not probed for. This is why reading a CW
-- listing does not spend a request asking whether there is a character called Lady.
ok(not emunah.util.contains(capture.candidates("Lady Sultana Erishka Khalimat"), "Lady"),
   "known honorific words are dropped from the candidate list")

-- Resolution against a known set, which is the only thing that makes any of this safe.
ndb.record("Erishka")
eq(capture.resolve("Lady Sultana Erishka Khalimat, Auroran Knight"), "Erishka",
   "a honorific resolves against a name already in the database")
api.online = { kaellyn = "Kaellyn" }
api.onlineAt = emunah.util.now()
eq(capture.resolve("Seeker Kaellyn, Oathsworn of Targossas"), "Kaellyn",
   "...or against the online roster")
eq(capture.resolve("Some Entirely Unknown Person"), nil,
   "and an unresolvable line resolves to nothing rather than to a guess")

-- CW truncates long fullnames with a literal "...", which is exactly the case where the
-- name is hardest to find any other way.
ok(capture.fullnameMatches("Caefir Knight Aeowynn Banazir, Justiciar of the Nin...",
   "Caefir Knight Aeowynn Banazir, Justiciar of the Nine Vows"),
   "a truncated fullname matches the API's full one on its prefix")
ok(not capture.fullnameMatches("Caefir Knight Aeowynn Banazir, Justiciar of the Nin...",
   "Someone Else Entirely"), "...and does not match a different name")

-- THE CW LISTING, fed line by line exactly as it arrives.
ndb.people = {}
api.online = { thelek = "Thelek", erishka = "Erishka", xarya = "Xarya",
               kaellyn = "Kaellyn", ceredia = "Ceredia", aeowynn = "Aeowynn",
               saemora = "Saemora" }
api.onlineAt = emunah.util.now()
emunah.config.set("namedb.autoFetch", false)   -- the parse is what is under test here

mock.line("Citizen                                                   Rank CT  Class")
mock.line("-------                                                   ---- --  -----")
mock.line("'The' Mistell Magnet, Thelek Ar'kena                        2  On  Monk")
mock.line("Lady Sultana Erishka Khalimat, Auroran Knight               6  On  Paladin")
mock.line("Xarya, Candidate for Redemption                             1  On  Priest")
mock.line("Seeker Kaellyn, Oathsworn of Targossas                      2  On  Paladin")
mock.line("Unsworn Ceredia, Candidate for Redemption                   1  On  Monk")
mock.line("Caefir Knight Aeowynn Banazir, Justiciar of the Nin...      3  On  Priest")
mock.line("Saemora, of Targossas                                       1  On  Priest")

-- The rule of dashes between the header and the first row must NOT end the listing. It
-- did, in the first version of this: the accounting pass ran before the row patterns and
-- judged the wrong line, and every CW read exactly zero citizens.
ok(ndb.known("Thelek"), "the first citizen after the rule of dashes is read")
eq(ndb.get("Thelek").cityrank, 2, "...with their city rank")
eq(ndb.get("Thelek").class, "monk", "...and their class")
eq(ndb.get("Erishka").cityrank, 6, "a CR6 is read as 6, not truncated to one digit")
eq(ndb.get("Aeowynn").class, "priest",
   "a citizen whose fullname was truncated is still recorded")
eq(ndb.count(), 6, "every citizen but ourselves is recorded")

-- CW does NOT set a city. A bare CW is only known to list our own, `CW <othercity>` has
-- never been observed to be legal, and writing everyone into our city on that assumption
-- is the kind of guess that produces a confidently wrong database.
eq(ndb.get("Thelek").city, nil, "CW does not invent a city")

-- The listing ends. A line that is not a row must not be read as one.
mock.line("H:100% M:100% E:100% W:100%  ex-  T:  11:01:40.94-")
mock.line("You see nothing out of the ordinary here.")
eq(capture.active, nil, "the collector disarms once the listing stops")
eq(ndb.count(), 6, "...and nothing after it is recorded")

-- THE CLWHO LISTING.
ndb.people = {}
api.online = { amira = "Amira", saemora = "Saemora", saibel = "Saibel", lokri = "Lokri",
               telox = "Telox", shiora = "Shiora" }
mock.line("The following members of the clan of Mudlet Clan are in the realms:")
mock.line("Amira")
mock.line("Saemora, of Targossas")
mock.line("Khaalis Saibel Aristata")
mock.line("Lokri, Tenebrous Operative")
mock.line("Tiny toad Telox, of the Ticklish Toes")
mock.line("Shiora Madgocerus-Blackcap (off channel)")

eq(ndb.get("Saibel").clan, "Mudlet Clan", "a name buried mid-honorific is found")
eq(ndb.get("Amira").clan, "Mudlet Clan", "a bare name with no honorific is found")
eq(ndb.get("Shiora").clan, "Mudlet Clan", "an (off channel) member is found")
eq(ndb.get("Lokri").clan, "Mudlet Clan", "...and one with a comma")

-- CLWHO's row pattern must be loose enough to match a bare name, which makes what follows
-- the listing the dangerous case. A custom prompt begins with a capital letter.
local before = ndb.count()
mock.line("H:100% M:100% E:100% W:100%  ex-  T:  11:02:52.42-")
mock.line("You bid your guardian angel to seek out life presences nearby.")
eq(ndb.count(), before, "the prompt after a CLWHO listing is not read as a member")
eq(capture.active, nil, "...and the collector is disarmed by it")

-- THE QW LIST, which has no header and so is read backwards from its terminator.
ndb.people = {}
mock.line("Aeowynn, Akri, Aletheia, Amira, Arivar, Aultorius, Ceredia, Clodhna, Crixos, Elius, Erishka, ")
mock.line("Giddieon, Jexa, Kaellyn, Kassie, Khalayx, Kimora, Llewell, Llialesam, Lokri, Luz, Majin, Meldia, ")
mock.line("Milabar, Minsideon, Miriew, Mycen, Naz, Oxton, Saemora, Saibel, Shiora, Tashigawa, Telox, Thelek, ")
mock.line("Thiev, Thundarsa, Tru, Tsia, Ulvin, Veldrin, Vesperyn, Xarya, Xorr, Zalydd, and Zargoth.")
mock.line("Plus another 8 whose presence you cannot fully sense (46 total).")

ok(ndb.known("Aeowynn"), "the first name on the first wrapped line is read")
ok(ndb.known("Zargoth"), "...and the last, after the 'and'")
ok(ndb.known("Kimora"), "...and one from the middle of the block")
eq(ndb.known("Saemora"), false, "...but never ourselves")
ok(ndb.count() >= 44, "the whole wrapped list is read, not just the last line")

-- The backwards walk stops at the first line that is not a name list, so it cannot run off
-- the top of the listing into whatever happened to be on screen before it.
ndb.people = {}
capture.forgetLines()
mock.line("Erishka says, \"Some prose, with a comma in it.\"")
mock.line("Aeowynn, Akri, Amira.")
mock.line("Plus another 8 whose presence you cannot fully sense (46 total).")
eq(ndb.known("Erishka"), false, "the walk stops before a line of prose")
ok(ndb.known("Akri"), "...having read the name list above the terminator")

-- The line buffer is a RING -- it is written on every line of game output, so the old
-- "append then table.remove(t, 1)" shape was a sixteen-element memmove per line, forever.
-- What that costs in correctness is that slot order is no longer arrival order once it
-- wraps, and the QW walk reads it backwards. So: overflow it, and check the walk still sees
-- arrival order rather than ring order.
capture.forgetLines()
for filler = 1, capture.BUFFER + 4 do mock.line("Filler line " .. filler .. " of prose.") end
eq(capture.recent(1), "Filler line " .. (capture.BUFFER + 4) .. " of prose.",
   "the newest line is recent(1) after the ring has wrapped")
eq(capture.recent(capture.BUFFER), "Filler line 5 of prose.",
   "...and the oldest line still held is recent(BUFFER)")
eq(capture.recent(capture.BUFFER + 1), nil, "nothing is remembered past the ring's size")

ndb.people = {}
capture.forgetLines()
mock.line("Erishka says, \"Some prose, with a comma in it.\"")
mock.line("Aeowynn, Akri, Amira.")
mock.line("Plus another 8 whose presence you cannot fully sense (46 total).")
ok(ndb.known("Akri"), "the QW walk still reads correctly after a wrap")
eq(ndb.known("Erishka"), false, "...and still stops at the prose line")

-- THE GUARDIAN ANGEL. The most perishable and most actionable thing the database holds.
ndb.people = {}
mock.line("Your guardian angel senses Erishka at Fish Street, on a health of 6831 "
   .. "and a mana of 4678.  (2098, ")
local sensed = ndb.get("Erishka").sensed
eq(sensed.where, "Fish Street", "the angel's report gives a location")
eq(sensed.health, 6831, "...a health")
eq(sensed.mana, 4678, "...and a mana")

-- THE TRAILING NOISE. The real line wraps, and its continuation carries a parenthesised
-- number list and a city name that are explicitly not to be read. The pattern is anchored
-- at the start of the line, so the continuation cannot match it at all.
local recordsBefore = ndb.count()
mock.line("2097, 2171, ...) (Targossas)")
eq(ndb.count(), recordsBefore, "the wrapped continuation creates nothing")
eq(ndb.get("Erishka").city, nil,
   "...and in particular the (Targossas) in it is not read as a city")

-- HONOURS, fed verbatim including the wrapped second line of the birth sentence.
ndb.people = {}
capture.buffer, capture.active = {}, nil

mock.line("Khaalis Saibel Aristata (female Mhun).")
mock.line("--------------------------------------")
mock.line("She is 668 years old, having been born on the 4th of Mayan, 342 years after the fall of the ")
mock.line("Seleucarian Empire.")
mock.line("She is ranked 279th in Achaea.")
mock.line("She is an extremely credible character.")
mock.line("She is not known for acts of infamy.")
mock.line("She is a Dominion in Mhaldor.")
mock.line("She is a Crimson Paragon(5) in the army of Mhaldor.")
mock.line("She originates from the City of Mhaldor.")
mock.line("She is a member of the Serpent class.")
mock.line("She is considered to be approximately 470% of your might.")
mock.line("She is a mentor and able to take on proteges.")
mock.line("Her motto: 'A dirk in the dark is worth a thousand swords at dawn.'")
mock.line("She has been divorced once.")
mock.line("She bears the arms: Argent, a pair of arrows in saltire Sable.")
mock.line("See HONOURS DEEDS SAIBEL to view her 25 special honours.")

-- THE NAME COMES LAST. It appears nowhere in the block until the DEEDS line, and the
-- header is no help: "Khaalis Saibel Aristata" has it in the middle. Everything gathered
-- above has to survive until that line arrives.
local saibel = ndb.get("Saibel")
ok(saibel ~= nil, "a HONOURS block is applied to the name on its final line")
eq(saibel.fullname, "Khaalis Saibel Aristata", "the honorific is taken from the header")
eq(saibel.sex, "female", "...along with sex")
eq(saibel.race, "Mhun", "...and race")
eq(saibel.age, 668, "age is read")
eq(saibel.xprank, 279, "the ordinal suffix is stripped from the rank")
eq(saibel.class, "serpent", "class is read and stored lowercase")
eq(saibel.credibility, "extremely credible",
   "credibility is kept as the game's own words, not scored")
eq(saibel.mentor, true, "the mentor line sets a flag")
eq(saibel.motto, "A dirk in the dark is worth a thousand swords at dawn.",
   "the motto is read without its quotes")
eq(saibel.deeds, 25, "the special honours count is read")
eq(saibel.infamy, 0,
   "'not known for acts of infamy' is unambiguous and means none")

-- MIGHT IS RELATIVE TO US, and routinely far over 100.
eq(saibel.might, 470, "might is read as the percentage of OUR might that it is")

-- WHAT IS DELIBERATELY NOT READ. "originates from the City of Mhaldor" is where someone is
-- FROM; whether it tracks a change of citizenship has not been established, and the web API
-- is authoritative for the current one.
eq(saibel.city, nil, "HONOURS does not set a city from 'originates from'")

-- ...but nothing is thrown away either. The lines nobody has established the meaning of
-- are kept verbatim, so the user can read what the game actually said.
local kept = table.concat(saibel.honours or {}, " | ")
ok(kept:find("Dominion in Mhaldor"), "an uninterpreted line is kept verbatim", kept)
ok(kept:find("bears the arms"), "...including ones far from the recognised ones", kept)
ok(not kept:find("Seleucarian"), "...while a wrapped continuation is not mistaken for one")

-- The other subject, whose optional lines differ almost entirely -- and whose name IS the
-- first word of the header, which must not become a special case.
mock.line("Khalayx, Tzin Ahuacatl (male Grook).")
mock.line("------------------------------------")
mock.line("He is ranked 116th in Achaea.")
mock.line("He is one of The Dauntless.")
mock.line("He is a member of the Magi class.")
mock.line("He is considered to be approximately 510% of your might.")
mock.line("See HONOURS DEEDS KHALAYX to view his 26 special honours.")
eq(ndb.get("Khalayx").class, "magi", "the second subject parses too")
eq(ndb.get("Khalayx").might, 510, "...with their own might")
eq(ndb.get("Khalayx").race, "Grook", "...and race")
ok(table.concat(ndb.get("Khalayx").honours or {}, " "):find("The Dauntless"),
   "'one of The Dauntless' is kept rather than guessed at")

-- A line shaped like a HONOURS header, with no rule of dashes under it, must not arm the
-- collector -- the header alone is far too weak a signature to trust.
capture.active = nil
mock.line("You see a plaque here (some thing).")
mock.line("He is a member of the Magi class.")
eq(capture.active, nil, "an unconfirmed header does not start reading a block")

emunah.config.set("namedb.autoFetch", true)
ndb.people = {}
capture.buffer, capture.active = {}, nil

-- ===========================================================================
suite("namedb: surviving the end of a session")

-- THE BUG THIS GUARDS. record() and seen() -- the paths almost every name arrives by --
-- did not write to disk at all, so a database populated entirely by walking around was
-- empty again next session. Saving on every mutation is not the fix either: one API
-- enrichment sets ten fields and a CW listing enriches forty people.
ndb.people = {}
ndb.save()
mock.store[ndb.path] = nil

ndb.seen("Passerby")
eq(ndb.dirty, true, "merely seeing someone marks the database dirty")
eq(mock.store[ndb.path], nil, "...without writing immediately")

mock.advance(ndb.SAVE_DELAY + 0.5)
eq(ndb.dirty, false, "the coalesced write happens shortly after")
ok(mock.store[ndb.path] ~= nil, "...and the file exists")
ok(mock.store[ndb.path].people["passerby"] ~= nil,
   "a name learned only from being seen is in it")

-- Many changes, one write. This is what makes touch() safe to call from every mutation.
local writes = 0
local realSave = table.save
table.save = function(path, tbl) writes = writes + 1 return realSave(path, tbl) end
for index = 1, 25 do ndb.set("Passerby", "importance", tostring(index)) end
eq(writes, 0, "twenty-five field writes do not each serialise the database")
mock.advance(ndb.SAVE_DELAY + 0.5)
eq(writes, 1, "...they coalesce into a single write")

-- Quitting inside the coalescing window is exactly when a session ends, so the flush has
-- to be forced on the way out.
ndb.set("Passerby", "importance", "99")
eq(ndb.dirty, true, "a change is pending")
raiseEvent("sysExitEvent")
eq(ndb.dirty, false, "Mudlet closing flushes it")
eq(writes, 2, "...with a real write")
table.save = realSave

-- And it comes back. A fresh load is what a new session does.
local reloaded = {}
table.load(ndb.path, reloaded)
eq(reloaded.people["passerby"].importance, 99,
   "the last change before exit is what the next session reads")

ndb.people = {}
mock.store[ndb.path] = nil

-- ===========================================================================
-- ===========================================================================
suite("(continued)")

-- ===========================================================================
suite("emhelp: every module, checked against the commands and the settings")

-- help.lua is a table so that it can be checked. A command or setting added without being
-- documented fails here, and so does one documented after it was removed.
do
local help = emunah.help

ok(#help.modules >= 8, "help defines the modules", #help.modules)

-- EVERY HANDLER IS DOCUMENTED, AND NOTHING THAT IS NOT A HANDLER.
local documented = {}
for _, row in ipairs(help.commands()) do
   if row.command.handler then documented[row.command.handler] = true end
end
local undocumented, phantom = {}, {}
for name in pairs(emunah.commands.handlers) do
   if not documented[name] then undocumented[#undocumented + 1] = name end
end
for name in pairs(documented) do
   if not emunah.commands.handlers[name] then phantom[#phantom + 1] = name end
end
table.sort(undocumented); table.sort(phantom)
eq(#undocumented, 0, "every command handler is in a module", table.concat(undocumented, ", "))
eq(#phantom, 0, "no module documents a handler that does not exist", table.concat(phantom, ", "))

-- ONE PREFIX: every command is `emset ...` or `emhelp ...`, bar the two documented words
-- that deliberately are not (sleep, emreload).
local stray = {}
for _, row in ipairs(help.commands()) do
   local syntax = row.command.syntax
   if not (syntax:find("^emset") or syntax:find("^emhelp") or row.command.alias) then
      stray[#stray + 1] = syntax
   end
end
eq(#stray, 0, "every command is under emset or emhelp", table.concat(stray, ", "))

-- EVERY SHIPPED DEFAULT IS DOCUMENTED, walked recursively so a nested key cannot hide.
local missingSettings = {}
local function walkDefaults(node, prefix)
   for key, value in pairs(node) do
      local path = prefix and (prefix .. "." .. key) or key
      if type(value) == "table" and not help.setting(path) and next(value) ~= nil
         and type(next(value)) == "string" then
         walkDefaults(value, path)
      elseif not help.setting(path) then
         missingSettings[#missingSettings + 1] = path
      end
   end
end
walkDefaults(emunah.config.DEFAULTS, nil)
table.sort(missingSettings)
eq(#missingSettings, 0, "every shipped config default is documented",
   table.concat(missingSettings, ", "))

-- Every setting belongs to a module that exists, and says what it is.
local orphans = {}
for _, spec in ipairs(help.settings) do
   if not help.module(spec.topic) then orphans[#orphans + 1] = spec.key end
end
eq(#orphans, 0, "every setting belongs to a module", table.concat(orphans, ", "))

-- Every module says what it does, and every command says what it is for.
for _, module in ipairs(help.modules) do
   ok(module.does and #module.does > 40, module.id .. " says what it does")
   for _, command in ipairs(module.commands) do
      ok(command.summary and command.summary ~= "", command.syntax .. " has a summary")
   end
end

-- LOOKUP: a module, a command word, or a setting all land on the right module.
eq(help.lookup("curing").id, "curing", "emhelp curing -> curing")
eq(help.lookup("bash").id, "hunting", "emhelp bash -> the module bash is in")
eq(help.lookup("emset pipes now").id, "pipes", "...with or without the prefix")
local module, spec = help.lookup("curing.method")
eq(module.id, "curing", "emhelp curing.method -> its module")
eq(spec and spec.key, "curing.method", "...pointing at the setting")
eq(help.lookup("qqqzzz"), nil, "nonsense finds nothing")

-- RENDERING. Every form has to run; a help system that errors is worse than none.
mock.installGeyser()
ok(pcall(help.render, ""), "emhelp renders the module list")
for _, m in ipairs(help.modules) do
   ok(pcall(help.render, m.id), "emhelp " .. m.id .. " renders")
end
for _, args in ipairs({ "bash", "curing.method", "nonsense qqq" }) do
   ok(pcall(help.render, args), ("emhelp %q renders"):format(args))
end
emunah.config.set("curing.confirmWait", 3.5)
ok(pcall(help.render, "curing"), "a changed setting renders")
emunah.config.set("curing.confirmWait", 2.0)
mock.uninstallGeyser()

-- SETTINGS THROUGH emset: `emset <setting> <value>` sets it, typed and coerced.
emunah.commands.dispatch("curing.confirmWait 1.5")
eq(emunah.config.get("curing.confirmWait"), 1.5, "emset <setting> <number> stores a number")
emunah.commands.dispatch("curing.antiIllusion off")
eq(emunah.config.get("curing.antiIllusion"), false, "emset <setting> off stores false")
emunah.commands.dispatch("curing.antiIllusion on")
eq(emunah.config.get("curing.antiIllusion"), true, "...and on stores true")
emunah.commands.dispatch("curing.confirmWait 2.0")
mock.echoed = {}
emunah.commands.dispatch("curing.nosuchthing 3")
eq(emunah.config.get("curing.nosuchthing"), nil, "an undocumented setting is refused")
end

-- ===========================================================================
suite("name highlighting: the database, rendered into the scroll")

local names = emunah.ui.names
names.enabled = true

ndb.set("Malefactor", "city", "Mhaldor")
ndb.iff("Malefactor", "enemy")
ndb.set("Anzerloi", "city", "Targossas")
ndb.iff("Anzerloi", "ally")
ndb.record("Stranger")

mock.setLine("Saemora nods at Anzerloi. Malefactor eyes Malefactor's blade.")
names.onLine()

ok(mock.formatOf("Malefactor") ~= nil, "an enemy on the line is styled")
eq(mock.formatOf("Malefactor").colour, emunah.ui.theme.colour.affliction,
   "...in the enemy colour")
eq(mock.formatOf("Malefactor").bold, true, "...and bold")
eq(mock.formatOf("Anzerloi").colour, emunah.ui.theme.colour.defence,
   "an ally is styled in the ally colour")

-- Each occurrence gets its own run. selectString takes an ORDINAL, and passing 1 twice
-- restyles the first name and leaves the second plain -- invisible unless a test counts.
ok(mock.formatOf("Malefactor", 2) ~= nil, "the second occurrence of a name is styled too")

-- Never our own name. It is on almost every line worth reading, and highlighting it turns
-- the signal into noise.
eq(mock.formatOf("Saemora"), nil, "our own name is never highlighted")

-- Attributes are set explicitly even when off. Left unsaid, a name inherits whatever the
-- game's own ANSI left behind, and an ordinary citizen renders bold in the middle of a
-- fight looking exactly like the Dragon two lines up.
eq(mock.formatOf("Anzerloi").bold, false, "a name that is not bold is explicitly un-bolded")
eq(mock.formatOf("Anzerloi").underline, false, "...and explicitly un-underlined")

-- Weight stacks on top of colour, and each channel stays independently readable.
ndb.set("Malefactor", "dragon", "yes")
ndb.set("Malefactor", "mark", "quisalis")
ndb.set("Malefactor", "infamy", "4")
mock.setLine("Malefactor arrives.")
names.onLine()
local style = mock.formatOf("Malefactor")
eq(style.colour, emunah.ui.theme.colour.affliction, "standing still owns the colour")
eq(style.underline, true, "a Mark adds an underline")
eq(style.italic, true, "infamy adds italics")

-- A stranger with no city falls back to a dim tone rather than being skipped: "I have a
-- record of this person" is itself worth seeing.
mock.setLine("Stranger walks in.")
names.onLine()
eq(mock.formatOf("Stranger").colour, emunah.ui.theme.colour.textDim,
   "a known stranger is dimly marked, not ignored")

-- The opt-out, for the ally whose name is a common word.
names.ignore("Stranger", true)
mock.setLine("Stranger walks in.")
names.onLine()
eq(mock.formatOf("Stranger"), nil, "an ignored name is left entirely alone")
eq(names.ignored()[1], "Stranger", "...and is listed as ignored")
names.ignore("Stranger", false)

-- Nothing is invented from prose.
mock.setLine("The Chalice of Sartan sits upon a Pedestal.")
names.onLine()
eq(#mock.formatted, 0, "capitalised words that are not records are never touched")

names.stop()
mock.setLine("Malefactor arrives.")
names.onLine()
eq(#mock.formatted, 0, "nothing is styled while highlighting is off")
names.start()

-- ---------------------------------------------------------------------------
-- THE TRIGGER, not just onLine().
--
-- Every assertion above calls onLine() by hand, so all of them passed while the trigger was
-- `[A-Z][a-z]` -- "contains a capitalised word", which in Achaea is nearly every line. The
-- callback therefore ran per line at 5.1us a time, and no test could see it. What follows
-- drives mock.line() instead, so the PATTERN is what is under test.

-- Scoped in a do-block: the main chunk is already close to Lua 5.1's 200-local ceiling,
-- and a `local` out here costs a slot for the whole rest of the file.
do
local fired = 0
local realOnLine = names.onLine
names.onLine = function() fired = fired + 1 return realOnLine() end

names.rebuild(true)

fired = 0
mock.line("A Pedestal of Iron stands here, beneath a Chalice.")
eq(fired, 0, "a line full of capitalised prose never reaches the highlighter")

fired = 0
mock.line("Malefactor arrives from the north.")
eq(fired, 1, "a line naming somebody in the database does reach it")

-- The roster changes; the pattern has to follow it. On the tick rather than at the mutation
-- site: `ndb learn` records everyone online in one burst, and rebuilding per record would
-- tear the triggers down and re-register them once per person for one command.
ndb.record("Newcomer")
fired = 0
mock.line("Newcomer arrives from the south.")
eq(fired, 0, "a name added since the last rebuild is not matched yet")

emunah.event.raise("tick", 1)
fired = 0
mock.line("Newcomer arrives from the south.")
eq(fired, 1, "...and is matched on the tick after being recorded")

-- Forgetting has to shrink the pattern, not just stop styling. A name left in the regex is
-- a callback per line for somebody we deliberately dropped.
ndb.forget("Newcomer")
emunah.event.raise("tick", 1)
fired = 0
mock.line("Newcomer arrives from the south.")
eq(fired, 0, "a forgotten name stops matching once the roster is rebuilt")

-- An empty database is the fresh-install case, and it should cost exactly nothing: no
-- trigger at all, rather than one that is registered and cannot match.
ndb.people = {}
ndb.generation = ndb.generation + 1
names.rebuild(true)
eq(names.PATTERN, nil, "an empty roster registers no trigger at all")
fired = 0
mock.line("Malefactor arrives.")
eq(fired, 0, "...so no line reaches the highlighter")

names.onLine = realOnLine
end

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
--
-- Uses "ablaze" (salve) rather than paralysis: `touch tree` is itself refused while
-- paralysed (confirmed live 2026-08-03 16:14:25.08, see queue.WHILE_PARALYSED), so paralysis
-- can no longer stand in for "any uncurable affliction" here -- the fixture needs one tree
-- touching actually reaches.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "1", name = "some mending salve", attrib = "e" },
} })
engine.add("ablaze", "trigger")
mock.advance(engine.TREE_DWELL + 1)
queue.reset(); mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("touch tree"),
   "an affliction that can be cured normally does not spend the tattoo",
   table.concat(mock.sent, " | "))

-- Nothing can cure it: out of the salve, and the rift is empty too.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Items.List", { location = "inv", items = {} })
engine.add("ablaze", "trigger")
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
engine.add("ablaze", "trigger")
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
engine.add("ablaze", "trigger")
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
mock.advance(engine.TREE_DWELL + 0.1)
queue.reset(); mock.sent = {}
engine.tick(); queue.flush()
ok(not table.concat(mock.sent, " | "):find("touch tree"),
   "no tree tattoo, no touch", table.concat(mock.sent, " | "))

-- Paralysis refuses `touch tree` too, so it must not pre-empt the last resort into a wasted
-- round trip. Confirmed live 2026-08-03 16:14:25.08: `touch tree` sent while paralysed came
-- back "Frustratingly, your body won't respond to your call to action." -- the same refusal
-- text paralysis is already detected from (detect/patterns.lua). Tree is uncurable-for-real
-- here (empty inventory and rift, past TREE_DWELL), which is exactly the scenario that used
-- to fire it -- and now must not, precisely because paralysis is up.
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Defences.List", { { name = "tree" } })
mock.feed("Char.Items.List", { location = "inv", items = {} })
engine.add("paralysis", "trigger")
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
mock.advance(engine.TREE_DWELL + 0.1)
queue.reset(); mock.sent = {}
engine.tick(); queue.flush()
ok(not table.concat(mock.sent, " | "):find("touch tree"),
   "paralysed, so touch tree is withheld rather than sent into a refusal",
   table.concat(mock.sent, " | "))

-- Both arms broken refuses `touch tree` too -- reported in play, same shape as the
-- paralysis case above: it takes a working hand to reach the tattoo. One broken arm is not
-- enough to block it; both sides have to be out at once (afflist.armAfflictions).
engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Defences.List", { { name = "tree" } })
mock.feed("Char.Items.List", { location = "inv", items = {} })
engine.add("crippledleftarm", "trigger")
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
mock.advance(engine.TREE_DWELL + 0.1)
queue.reset(); mock.sent = {}
engine.tick(); queue.flush()
ok(table.concat(mock.sent, " | "):find("touch tree"),
   "one broken arm alone does not stop the tattoo", table.concat(mock.sent, " | "))

engine.clear(); queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Defences.List", { { name = "tree" } })
mock.feed("Char.Items.List", { location = "inv", items = {} })
engine.add("crippledleftarm", "trigger")
engine.add("crippledrightarm", "trigger")
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
mock.advance(engine.TREE_DWELL + 0.1)
queue.reset(); mock.sent = {}
engine.tick(); queue.flush()
ok(not table.concat(mock.sent, " | "):find("touch tree"),
   "both arms broken at once, so touch tree is withheld rather than sent into a refusal",
   table.concat(mock.sent, " | "))

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
-- This suite is written against a target of three; the shipped default is 1 (see
-- engine.lua's M.STOCK_TARGET), so pin it explicitly rather than let the numbers below
-- silently start meaning something else.
emunah.config.set("curing.stockTarget", 3)
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
emunah.config.set("curing.stockTarget", nil)

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

-- ===========================================================================
suite("asleep")

-- The regression this whole feature is built around. From the 06:03 capture: SLEEP was
-- typed, Achaea sent `sleeping` AND `prone` together, and the prone handler then put STAND
-- on the wire three times over twelve seconds -- each answered with "You are asleep and can
-- do nothing. WAKE will attempt to wake you." Nothing knew the character was asleep.
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
mock.line("You stand up.")
mock.advance(detect.STAND_GUARD + 0.01)
detect.onWake()
detect.sleepIntent = nil
mock.sent = {}

-- The GMCP name is "sleeping", not "asleep" -- getting this wrong means the feature never
-- fires at all, which is why it is asserted by name rather than through the flag alone.
mock.feed("Char.Afflictions.Add",
   { name = "sleeping", cure = "", desc = "While asleep, you can do little but dream, and wake up." })
ok(detect.isAsleep(), "a GMCP `sleeping` affliction sets the asleep flag")
ok(emunah.curing.afflist.isState("sleeping"),
   "sleeping is a state, not an affliction with no cure defined")

-- Blocks EVERY command, the way stun does -- not just the ones needing you upright.
eq(emunah.act.blocked(), "asleep", "asleep blocks a command that needs nothing")
eq(emunah.act.blocked({ standing = true }), "asleep", "...and one that needs you upright")
eq(emunah.act.blocked({ whileAsleep = true }), nil, "...but not WAKE, which opts out")

-- WAKE goes out, and it is the only thing that does.
ok(table.concat(mock.sent, " | "):find("wake"), "...and WAKE goes out",
   table.concat(mock.sent, " | "))

-- Now the actual bug: prone arrives alongside, and must NOT produce a STAND.
mock.sent = {}
mock.feed("Char.Afflictions.Add", { name = "prone", cure = "STAND" })
ok(detect.isProne(), "prone lands alongside sleeping, as the game sends it")
ok(not table.concat(mock.sent, " | "):find("stand"),
   "no STAND while asleep -- the three refused ones in the 06:03 capture",
   table.concat(mock.sent, " | "))

-- And the tick does not resurrect it. This is the line that actually fired in the capture.
mock.advance(detect.WAKE_GUARD + 0.01)
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("stand"),
   "...and the tick does not send one either", table.concat(mock.sent, " | "))
ok(table.concat(mock.sent, " | "):find("wake"), "...though WAKE is retried",
   table.concat(mock.sent, " | "))

-- Curing stops dead too: queue.flush() early-outs on act.can(), so nothing reaches the game.
queue.reset()
queue.push("herb", "eat bloodroot", {})
eq(queue.flush(), 0, "asleep: flush sends nothing")

-- Waking. GMCP removal is the authority -- Remove carries bare names in an array.
mock.feed("Char.Afflictions.Remove", { "sleeping" })
ok(not detect.isAsleep(), "GMCP clearing `sleeping` clears the flag")
eq(emunah.act.blocked(), nil, "...and everything is allowed again")

-- Prone outlives the sleep by a moment in the capture ("You open your eyes..." at
-- 06:03:15.10, "You stand up." at 06:03:15.31), so standing has to resume on waking.
mock.advance(detect.STAND_GUARD + 0.01)
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("stand"),
   "still prone once awake, so STAND resumes", table.concat(mock.sent, " | "))
mock.feed("Char.Afflictions.Remove", { "prone" })

-- ---------------------------------------------------------------------------
-- A SLEEP the character asked for. The system must not wake them out of it.

mock.sent = {}
ok(mock.command("sleep"), "a bare SLEEP is matched by an alias")
eq(table.concat(mock.sent, " | "), "sleep", "...and still reaches the game unchanged",
   table.concat(mock.sent, " | "))

mock.sent = {}
mock.feed("Char.Afflictions.Add", { name = "sleeping", cure = "" })
ok(detect.isAsleep(), "asleep by our own hand")
ok(detect.voluntary, "...and it is recognised as voluntary")
eq(#mock.sent, 0, "no WAKE -- the point of the whole feature",
   table.concat(mock.sent, " | "))

-- Still fully blocked, though: "the system can become mostly unresponsive" is the ask.
eq(emunah.act.blocked(), "asleep", "a voluntary sleep still holds every command")
mock.advance(detect.WAKE_GUARD + 0.01)
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
eq(#mock.sent, 0, "...and the tick sends nothing either", table.concat(mock.sent, " | "))

-- The involuntary backstop must NOT be armed for this one, or it would unblock the system
-- mid-nap -- which is the automation interfering, exactly what voluntary exists to prevent.
mock.advance(detect.SLEEP_GUARD + 1)
ok(detect.isAsleep(), "a voluntary sleep is not cut short by SLEEP_GUARD")

-- Waking clears the voluntary latch, so the next sleep is judged on its own evidence.
mock.line("You open your eyes and stretch languidly, feeling deliciously well-rested.")
ok(not detect.isAsleep(), "the rested-wake message wakes us")
ok(not detect.voluntary, "...and clears the voluntary latch")

mock.sent = {}
mock.feed("Char.Afflictions.Add", { name = "sleeping", cure = "" })
ok(table.concat(mock.sent, " | "):find("wake"),
   "one nap does not buy an opponent a free sleep afterwards",
   table.concat(mock.sent, " | "))
mock.feed("Char.Afflictions.Remove", { "sleeping" })

-- A SLEEP THE GAME REFUSED must not suppress the next sleep forever. The intent is a
-- window, not a flag, precisely so it can lapse.
mock.sent = {}
mock.command("sleep")
mock.advance(detect.SLEEP_INTENT + 0.01)
mock.sent = {}
mock.feed("Char.Afflictions.Add", { name = "sleeping", cure = "" })
ok(not detect.voluntary, "a SLEEP that never landed does not explain a later sleep")
ok(table.concat(mock.sent, " | "):find("wake"), "...so this one is woken from",
   table.concat(mock.sent, " | "))

-- An involuntary sleep whose end is never reported must not freeze the system.
mock.advance(detect.SLEEP_GUARD + 0.01)
ok(not detect.isAsleep(), "SLEEP_GUARD bounds an involuntary sleep")
eq(emunah.act.blocked(), nil, "...and the system is not left frozen")

-- The rejection re-asserts the state, which is what makes being wrong above cheap.
mock.line("You are asleep and can do nothing. WAKE will attempt to wake you.")
ok(detect.isAsleep(), "the rejection re-asserts asleep after an early guard")
mock.feed("Char.Afflictions.Remove", { "sleeping" })

-- SLEEP with an argument is a different command and is left entirely alone.
mock.sent = {}
ok(not mock.command("sleep now"), "SLEEP with an argument is not swallowed by our alias")

detect.sleepIntent = nil

-- ===========================================================================
suite("curing (continued)")

-- Bleeding has no observed onset or cure message, only the repeating damage tick, so it is
-- NOT tracked via engine.add/remove -- it queues `clot` directly, and only while curing is
-- actually on.
queue.reset()
engine.enabled = false
-- CLOT IS GATED ON THE BLEED LEVEL, and the level comes from the `Bleed` charstat rather
-- than the number in "You bleed N health." -- the message says what one tick cost, not how
-- hard we are bleeding (the same call watch.lua makes). Set it above the threshold here so
-- the tests below exercise the skill gate rather than the new one.
mock.feed("Char.Vitals", { charstats = { "Bleed: 45" } })
mock.line("You bleed 6 health.")
eq(queue.pending("special"), nil, "a bleed tick is ignored while curing is off")

-- THE CHARACTER NOW HAS THE CLOTTING LESSON, which inverts the gate this used to assert.
--
-- It once demanded positive confirmation (skills.complete AND skills.has) and sent nothing
-- while the index was loading, because two live rejections had established the lesson was
-- absent. With the lesson trained that evidence is void, so this is back to the ordinary
-- permissive have.skill() gate: unknown means "probably fine", and one wasted CLOT after a
-- reload is cheaper than bleeding through the whole window before the index arrives.
engine.enabled = true
eq(emunah.gmcp.skills.complete, false, "the skill index has not loaded yet")
mock.line("You bleed 6 health.")
local earlyClot = queue.pending("special")
ok(earlyClot ~= nil and earlyClot.command == "clot",
   "unknown skill state: a bleed tick clots anyway -- CLOT is free",
   earlyClot and earlyClot.command)
queue.reset()

-- A complete index that does NOT list it is still authoritative the other way.
mock.feed("Char.Skills.Groups", { { name = "Survival", rank = "Adept" } })
mock.feed("Char.Skills.List", { group = "Survival", list = { "Tumble" } })
ok(emunah.gmcp.skills.complete, "the skill index is now complete")
ok(not emunah.have.skill("clotting"), "and confirms clotting is not known")
mock.line("You bleed 6 health.")
eq(queue.pending("special"), nil, "confirmed absent: a bleed tick queues nothing")

mock.feed("Char.Skills.List", { group = "Survival", list = { "Tumble", "Clotting" } })
ok(emunah.have.skill("clotting"), "clotting is now confirmed known")
mock.line("You bleed 6 health.")
local bleedPending = queue.pending("special")
ok(bleedPending ~= nil and bleedPending.command == "clot",
   "confirmed present: a bleed tick queues clot on the special vector",
   bleedPending and bleedPending.command)
eq(bleedPending and bleedPending.tag, "bleeding", "tagged as bleeding, not a tracked affliction")
eq(engine.has("bleeding"), false, "bleeding is never asserted into engine.tracked")

-- CLOT COSTS NO BALANCE. An earlier version called have.spend("special"), which armed a
-- two-second recovery timer for a balance that does not exist -- so a second CLOT could not
-- go out for two seconds even though the game would have taken it immediately.
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
queue.flush()
ok(emunah.have.balance("special"),
   "sending CLOT spends no balance -- the special vector stays free")

-- "You do not bleed, my friend." is CLOT answered with nothing to clot. It frees the slot
-- rather than letting it sit out the full confirm timeout...
ok(queue.awaiting("special") ~= nil, "the clot is in flight, awaiting an answer")
mock.line("You do not bleed, my friend.")
eq(queue.awaiting("special"), nil, "...and the reply frees the slot immediately")

-- ...and drops a clot still queued behind it, which would go out into the same reply.
mock.line("You bleed 6 health.")
ok(queue.pending("special") ~= nil, "another bleed tick queues another clot")
mock.line("You do not bleed, my friend.")
eq(queue.pending("special"), nil, "...and the reply drops it rather than sending it")

-- ---------------------------------------------------------------------------
-- THE BLEED THRESHOLD. CLOT costs no balance and no equilibrium, so the only price is mana
-- -- but mana is what an enemy Priest's kill route drains and what `perform hands` spends,
-- and a trickle bleed clots itself off in a few ticks.
queue.reset()
mock.feed("Char.Vitals", { charstats = { "Bleed: 30" } })
mock.line("You bleed 6 health.")
eq(queue.pending("special"), nil, "at exactly the threshold, no clot -- it is MORE than 30")

mock.feed("Char.Vitals", { charstats = { "Bleed: 12" } })
mock.line("You bleed 6 health.")
eq(queue.pending("special"), nil, "a trickle bleed is left alone")

mock.feed("Char.Vitals", { charstats = { "Bleed: 31" } })
mock.line("You bleed 6 health.")
ok(queue.pending("special") ~= nil, "one over the threshold clots")

-- THE LEVEL, NOT THE TICK. The damage number in the line is large here and the charstat is
-- small: the line says what one tick cost, which is not how hard we are bleeding. Gating on
-- the wrong one of those two numbers is the whole point of this test.
queue.reset()
mock.feed("Char.Vitals", { charstats = { "Bleed: 4" } })
mock.line("You bleed 90 health.")
eq(queue.pending("special"), nil,
   "a big one-off tick with a small bleed level does not clot")

-- Re-checked at send time: a clot queued at 45 must not go out once the bleed has clotted
-- down past the threshold, or it spends mana on a problem that has already gone.
queue.reset()
mock.feed("Char.Vitals", { charstats = { "Bleed: 45" }, bal = "1", eq = "1" })
mock.line("You bleed 40 health.")
ok(queue.pending("special") ~= nil, "queued while bleeding hard")
mock.feed("Char.Vitals", { charstats = { "Bleed: 2" } })
mock.sent = {}
queue.flush()
eq(#mock.sent, 0, "...and dropped rather than sent once the bleed has eased",
   table.concat(mock.sent, " | "))

-- Configurable, like every other threshold here.
queue.reset()
emunah.config.set("curing.clotThreshold", 5)
mock.feed("Char.Vitals", { charstats = { "Bleed: 12" } })
mock.line("You bleed 6 health.")
ok(queue.pending("special") ~= nil, "curing.clotThreshold moves the line")
emunah.config.set("curing.clotThreshold", detect.CLOT_THRESHOLD)
queue.reset()
mock.feed("Char.Vitals", { charstats = { "Bleed: 45" } })

-- It must not touch a `special` action that is not a clot: the vector is general-purpose.
queue.push("special", "something else", { tag = "other", confirm = 2.0 })
mock.line("You do not bleed, my friend.")
ok(queue.pending("special") ~= nil, "an unrelated special action is left alone",
   queue.pending("special") and queue.pending("special").command)
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
suite("blind and deaf are defences, not afflictions to cure")

do
   local deflist   = emunah.curing.deflist
   local defkeepup = emunah.curing.defkeepup
   engine.clear(); queue.reset(); emunah.timers.stopAll()
   defkeepup.resetBudget()

   -- THEY REQUIRE MINDSEYE. Blinding and deafening yourself is protection against attacks
   -- that need you to see or hear -- but without mindseye up you then genuinely cannot see
   -- or hear anything. Raising them in the wrong order is not a partial success.
   eq(deflist.requires("blind"), "mindseye", "blind requires mindseye")
   eq(deflist.requires("deaf"), "mindseye", "...and so does deaf")
   eq(deflist.requires("rebounding"), nil, "an ordinary defence requires nothing")

   -- NOT A SKILL -- A HERB. The bare `blind`/`deaf` verbs this held before were guessed and
   -- DISPROVEN IN PLAY ("I don't know what \"blind\" does."). Verified 16:07:54-16:08:08:
   -- `eat bayberry` while already blind answered "The bayberry has no effect. You are
   -- already blind." -- bayberry causes blindness, not cures it -- and `eat hawthorn` was
   -- followed immediately by "The aural world fades to silence.", deafness onset. See
   -- deflist.lua.
   --
   -- KEYED ON `blindness`/`deafness`: Char.Defences does not use the verbs. Confirmed live
   -- for both -- three raises of `eat bayberry`/`eat hawthorn` never registering, and the
   -- attempt budget naming `blindness`/`deafness` as unclaimed Char.Defences names in turn.
   -- `blind`/`deaf` still resolve there, through the alias.
   eq(deflist.canonical("blind"), "blindness",
      "the typed name resolves to the one Char.Defences reports")
   eq(deflist.canonical("deaf"), "deafness", "...and so does the other")
   eq(select(1, deflist.resolve("blindness")), "herb", "blind is raised on the herb vector")
   eq(select(2, deflist.resolve("blindness")), "eat bayberry", "...by eating bayberry")
   eq(select(1, deflist.resolve("deafness")), "herb", "deaf is raised on the herb vector too")
   eq(select(2, deflist.resolve("deafness")), "eat hawthorn", "...by eating hawthorn")

   mock.feed("Char.Defences.List", {})
   defkeepup.enabled = true
   defkeepup.setMode("blind", "keepup")
   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   ok(not table.concat(mock.sent, " | "):find("bayberry", 1, true),
      "blind is not raised while mindseye is down", table.concat(mock.sent, " | "))
   eq(defkeepup.blockedBy("blind"), "mindseye", "...and the grid can say why")

   -- Held, not abandoned: it costs no attempt, because the prerequisite going up is the
   -- ordinary way this resolves.
   ok(defkeepup.withinBudget("blindness"), "waiting on a prerequisite spends no attempts")

   mock.feed("Char.Defences.Add", { name = "mindseye", desc = "x" })
   eq(defkeepup.blockedBy("blind"), nil, "...and stops being blocked once mindseye is up")

   -- NOT IN HAND IS NOT THE SAME AS NEVER COMING. Sending the raise before restocking has
   -- pulled the herb in burns the whole attempt budget on "What do you want to eat?" --
   -- watched in play with deathsight/skullcap, three refusals in under three seconds at
   -- login while the rift still held plenty. Held, not abandoned, same as a blocked
   -- prerequisite: the item arriving is the ordinary way this resolves.
   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   ok(not table.concat(mock.sent, " | "):find("bayberry", 1, true),
      "blind is not raised with no bayberry in hand", table.concat(mock.sent, " | "))
   ok(defkeepup.withinBudget("blindness"),
      "...and waiting on the item spends no attempt either")

   mock.feed("Char.Items.List", { location = "inv", items = {
      { id = "1", name = "a piece of bayberry bark", attrib = "e" },
   } })
   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   ok(table.concat(mock.sent, " | "):find("eat bayberry", 1, true),
      "...and it goes out once mindseye is up and bayberry is in hand",
      table.concat(mock.sent, " | "))

   -- CHAR.DEFENCES MUST BE RECOGNISED, under the name it actually reports. Before the fix,
   -- Char.Defences confirming `blindness` matched nothing keep-up was watching for -- it
   -- kept re-raising `eat bayberry` on every tick, none of it ever registering, until the
   -- attempt budget stopped it with "Raised blind 3 times and it never appeared in
   -- Char.Defences" while genuinely blind the whole time.
   mock.feed("Char.Defences.Add", { name = "blindness", desc = "x" })
   ok(not emunah.util.contains(defkeepup.missing(), "blindness"),
      "blindness is recognised as up the moment Char.Defences confirms it")

   mock.sent = {}
   for _ = 1, 5 do
      mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   end
   ok(not table.concat(mock.sent, " | "):find("bayberry", 1, true),
      "...and it is not raised again while it is already up",
      table.concat(mock.sent, " | "))
   ok(defkeepup.withinBudget("blindness"),
      "...so the attempt budget is never spent chasing a defence already up")

   mock.feed("Char.Defences.Remove", { "blindness" })
   defkeepup.setMode("blind", nil)

   -- SAME CHECK, `deaf` -> `deafness`. Confirmed live the same session as `blind`:
   --   [emunah] Raised deaf 3 times and it never appeared in Char.Defences -- stopping.
   --   [emunah]   Char.Defences is reporting these, ...: boartattoo, deafness, mosstattoo, ...
   --
   -- Reset the queue first: the herb vector is still "awaiting" the bayberry raise above,
   -- never confirmed in this simulated timeline, and the one-slot-per-vector rule would
   -- otherwise silently swallow the hawthorn push.
   queue.reset(); emunah.timers.stopAll()
   defkeepup.setMode("deaf", "keepup")
   mock.feed("Char.Items.List", { location = "inv", items = {
      { id = "1", name = "a red hawthorn berry", attrib = "e" },
   } })
   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   ok(table.concat(mock.sent, " | "):find("eat hawthorn", 1, true),
      "deaf is raised on the herb vector too, once mindseye and hawthorn are ready",
      table.concat(mock.sent, " | "))

   mock.feed("Char.Defences.Add", { name = "deafness", desc = "x" })
   ok(not emunah.util.contains(defkeepup.missing(), "deafness"),
      "deafness is recognised as up the moment Char.Defences confirms it")

   mock.sent = {}
   for _ = 1, 5 do
      mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   end
   ok(not table.concat(mock.sent, " | "):find("hawthorn", 1, true),
      "...and it is not raised again while it is already up",
      table.concat(mock.sent, " | "))
   ok(defkeepup.withinBudget("deafness"),
      "...so the attempt budget is never spent chasing a defence already up")

   mock.feed("Char.Defences.Remove", { "deafness" })
   defkeepup.setMode("deaf", nil)
   defkeepup.enabled = false

   -- THE ENGINE MUST NOT STRIP IT. The game reports the resulting state as an affliction
   -- too, so the cure loop sees `blindness` and reaches for epidermal while the user is
   -- deliberately blind. Watched at 13:55:02 -- "Cannot cure blindness: epidermal is in the
   -- rift, not in hand" -- with DEF listing "You are blind." at the same moment. Only the
   -- salve being out of reach stopped it undoing the defence.
   engine.clear(); queue.reset(); emunah.timers.stopAll()
   engine.enabled = true
   mock.feed("Char.Defences.List", { { name = "blindness" } })
   mock.feed("Char.Items.List", { location = "inv", items = {
      { id = "1", name = "some epidermal salve", attrib = "e" },
   } })
   engine.add("blindness", "gmcp")
   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   ok(not table.concat(mock.sent, " | "):find("epidermal", 1, true),
      "blindness is not cured while the blind defence is up",
      table.concat(mock.sent, " | "))

   -- ...and it lapses with the defence. A real blinding, with no defence up, cures normally.
   mock.feed("Char.Defences.Remove", { "blindness" })
   queue.reset(); emunah.timers.stopAll()
   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   ok(table.concat(mock.sent, " | "):find("epidermal", 1, true),
      "with the defence gone, blindness is cured normally",
      table.concat(mock.sent, " | "))

   -- A DIFFERENT affliction wanting epidermal must not strip the defence either. Reported
   -- in play: applying epidermal for anorexia can cure blind/deaf as a side effect
   -- regardless of which affliction actually queued it -- the guard above only ever fires
   -- for `blindness`/`deafness` themselves being the TARGET, and says nothing about
   -- anorexia sharing the same item. See have.cure()'s epidermal check.
   engine.clear(); queue.reset(); emunah.timers.stopAll()
   engine.enabled = true
   mock.feed("Char.Defences.List", { { name = "blindness" } })
   mock.feed("Char.Items.List", { location = "inv", items = {
      { id = "1", name = "some epidermal salve", attrib = "e" },
   } })
   engine.add("anorexia", "gmcp")
   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   ok(not table.concat(mock.sent, " | "):find("epidermal", 1, true),
      "anorexia is not cured via epidermal while the blind defence is up",
      table.concat(mock.sent, " | "))

   -- ...and it lapses with the defence, same as the direct case above.
   mock.feed("Char.Defences.Remove", { "blindness" })
   queue.reset(); emunah.timers.stopAll()
   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   ok(table.concat(mock.sent, " | "):find("epidermal", 1, true),
      "with the defence gone, anorexia is cured via epidermal normally",
      table.concat(mock.sent, " | "))

   engine.clear(); queue.reset(); emunah.timers.stopAll()
   engine.enabled = false
   mock.feed("Char.Defences.List", {})
end

-- ===========================================================================
suite("mindseye is touched, not just named")

do
   local deflist = emunah.curing.deflist

   -- mindseye is untrained in the fixed skill index the rest of the suite builds up (it
   -- never appears in any Char.Skills.List fed anywhere in this file), so borrow the same
   -- trick the blind/deaf test above uses to look past the skill gate and at the command.
   local wasComplete = emunah.gmcp.skills.complete
   emunah.gmcp.skills.complete = false

   -- VERIFIED IN PLAY: "touch mindseye" -> "Touching the mindseye tattoo, your senses are
   -- suddenly heightened. Equilibrium used: 3.00s." The bare `mindseye` command this held
   -- before was never watched working -- it is a tattoo, touched, not a stanced ability.
   local vector, command = deflist.resolve("mindseye")
   eq(vector, "equilibrium", "mindseye spends equilibrium")
   eq(command, "touch mindseye", "the raise command is the verified one, not the guessed one")

   emunah.gmcp.skills.complete = wasComplete
end

-- ===========================================================================
suite("a deliberate defence does not wait on Char.Defences to say so")

do
   local deflist   = emunah.curing.deflist
   local defkeepup = emunah.curing.defkeepup
   engine.clear(); queue.reset(); emunah.timers.stopAll()
   defkeepup.resetBudget()

   -- LOGIN RACE: "You are blind and can see nothing but darkness." can print before
   -- Char.Defences.List arrives. Watched in play: with only live GMCP state consulted, the
   -- engine spent the gap between the two chasing epidermal for a defence keep-up was about
   -- to confirm was up on purpose a moment later.
   mock.feed("Char.Defences.List", {})
   eq(deflist.deliberate("blindness"), false,
      "not deliberate with nothing raising it and nothing confirming it")

   defkeepup.setMode("blind", "keepup")
   eq(deflist.deliberate("blindness"), true,
      "deliberate the instant keep-up wants it, ahead of any GMCP confirmation")
   eq(deflist.deliberate("deafness"), false, "...only the one actually configured")

   defkeepup.setMode("deaf", "defup")
   eq(deflist.deliberate("deafness"), true, "defup counts as intent too, not just keepup")

   -- And once the server actually confirms it, that still works on its own -- clearing
   -- keep-up's own intent must not un-confirm a defence the game says is genuinely up.
   defkeepup.setMode("blind", nil)
   mock.feed("Char.Defences.List", { { name = "blindness" } })
   eq(deflist.deliberate("blindness"), true,
      "still deliberate on Char.Defences alone once keep-up's own intent is cleared")

   defkeepup.setMode("deaf", nil)
   mock.feed("Char.Defences.List", {})
   engine.clear(); queue.reset(); emunah.timers.stopAll()
end

-- ===========================================================================
suite("a permanent deliberate defence must not starve keep-up forever")

do
   local defkeepup = emunah.curing.defkeepup
   engine.clear(); queue.reset(); emunah.timers.stopAll()
   defkeepup.resetBudget()

   -- Char.Afflictions reports the same state blind/deaf produce as an affliction, and it
   -- never leaves M.tracked while the defence is held -- so a keep-up guard keyed on the raw
   -- affliction count would read "curing is busy" for the rest of the session and never run
   -- again, including for mindseye, the defence that makes holding blind/deaf survivable.
   engine.enabled = true
   defkeepup.setMode("blind", "keepup")
   engine.add("blindness", "gmcp")
   eq(engine.count(), 1, "blindness is tracked like any other affliction")
   eq(engine.curableCount(), 0, "...but it does not count as something curing is fighting")

   engine.add("asthma", "gmcp")
   eq(engine.curableCount(), 1, "a genuine affliction alongside it still counts")

   defkeepup.setMode("blind", nil)
   engine.clear(); queue.reset(); emunah.timers.stopAll()
   engine.enabled = false

   -- End to end: with blind held deliberately and tracked as an affliction, mindseye --
   -- blind's own prerequisite -- must still go out, not sit blocked behind engine.count().
   local wasComplete = emunah.gmcp.skills.complete
   emunah.gmcp.skills.complete = false

   engine.enabled = true
   defkeepup.enabled = true
   mock.feed("Char.Defences.List", {})
   defkeepup.setMode("blind", "keepup")
   defkeepup.setMode("mindseye", "keepup")
   engine.add("blindness", "gmcp")

   mock.sent = {}
   defkeepup.tick()
   ok(table.concat(mock.sent, " | "):find("touch mindseye", 1, true),
      "mindseye is raised even while a deliberate defence sits in the tracked list",
      table.concat(mock.sent, " | "))

   defkeepup.setMode("blind", nil)
   defkeepup.setMode("mindseye", nil)
   defkeepup.enabled = false
   engine.clear(); queue.reset(); emunah.timers.stopAll()
   engine.enabled = false
   emunah.gmcp.skills.complete = wasComplete
   mock.feed("Char.Defences.List", {})
end

-- ===========================================================================
suite("DIAG: reading the answer we paid for")

-- The engine spends a second of equilibrium on DIAG whenever loki is up, because
-- Char.Afflictions cannot be trusted while it is. Nothing parsed the reply: the cost was
-- paid and the question went unanswered.
do
   local diag = emunah.curing.diag
   engine.clear(); queue.reset(); emunah.timers.stopAll()
   engine.enabled = true
   diag.unknown = {}

   -- Verbatim, 13:55:02.85. The character was holding `blind` DELIBERATELY as a defence --
   -- DEF listed it among twelve -- and was genuinely afflicted by thin blood.
   mock.line("You are:")
   mock.line("blind.")
   mock.line("afflicted by thin blood.")
   mock.line("Equilibrium used: 1.00s.")

   local block = diag.last
   ok(block ~= nil, "the DIAG block is read")
   eq(#block.states, 1, "a bare entry is read as a state")
   eq(block.states[1], "blind", "...and named")

   -- A BARE LINE IS NOT AN AFFLICTION. `blind` was a defence the user put up on purpose,
   -- and curing it would have stripped it.
   eq(engine.has("blind"), false, "a bare state is never tracked as an affliction")
   eq(engine.has("blindness"), false, "...and is not mapped onto one either")

   -- And that has to hold for a bare name the affliction table DOES know, or the rule is
   -- only being enforced by `blind` happening to be absent from the table.
   engine.clear()
   mock.line("You are:")
   mock.line("asthma.")
   mock.line("Equilibrium used: 1.00s.")
   eq(engine.has("asthma"), false,
      "a bare line is not cured even when it names a known affliction")
   eq(diag.last.states[1], "asthma", "...it is reported as a state instead")

   -- "thin blood" has no entry in the affliction table under any spelling, so it cannot be
   -- cured however plainly the game reports it. That is worth saying out loud.
   eq(#block.unknown, 1, "an affliction the table has no entry for is reported")
   eq(block.unknown[1], "thin blood", "...by the name the game used")
   eq(diag.unknown["thin blood"], true, "...and remembered for the session")

   -- The cost line ends the block: entries are lowercase and it is not.
   eq(diag.last.at ~= nil, true, "the block closed on the cost line")

   -- ADDING IS SAFE -- it is the discovery DIAG was sent for.
   engine.clear()
   mock.line("You are:")
   mock.line("afflicted by asthma.")
   mock.line("afflicted by anorexia.")
   mock.line("Equilibrium used: 1.00s.")
   ok(engine.has("asthma"), "an affliction DIAG names is picked up")
   ok(engine.has("anorexia"), "...all of them")

   -- REMOVING NEEDS THE WHOLE PICTURE. With every line understood, DIAG is ground truth and
   -- anything it does not list is gone.
   engine.add("slickness", "trigger")
   mock.line("You are:")
   mock.line("afflicted by asthma.")
   mock.line("Equilibrium used: 1.00s.")
   ok(engine.has("asthma"), "what DIAG still reports stays")
   eq(engine.has("slickness"), false, "what it does not report is cleared")

   -- ...EVEN ON A PARTIAL READING. This used to be withheld -- "we cannot tell absence from
   -- failure-to-parse" -- but that let one unmapped word (the game reports far more
   -- afflictions than afflist knows) silently disable every removal for the whole DIAG.
   -- Confirmed live 20:57:29-20:58:04: `stupidity` sat in tracked and was re-cured every
   -- ~5s with no opponent present, because nothing was ever left to clear it. DIAG paid a
   -- whole equilibrium for ground truth; ground truth wins outright now.
   engine.clear()
   engine.add("slickness", "trigger")
   mock.line("You are:")
   mock.line("afflicted by thin blood.")
   mock.line("Equilibrium used: 1.00s.")
   eq(engine.has("slickness"), false,
      "a line that could not be understood no longer blocks removal of the rest")

   -- loki is the illusion, not something DIAG will admit to, so its absence never clears it.
   engine.clear()
   engine.add("loki", "trigger")
   mock.line("You are:")
   mock.line("afflicted by asthma.")
   mock.line("Equilibrium used: 1.00s.")
   ok(engine.has("loki"), "loki is not cleared by being absent from DIAG's answer")

   -- A BARE STATE CONFIRMS, IT DOES NOT ABSOLVE. `blindness` is tracked from GMCP the
   -- ordinary way, and DIAG names the very same condition as the bare state "blind" --
   -- excluded from block.afflictions so curing never reaches for epidermal against it, but
   -- that exclusion must not read as DIAG saying blindness is gone. Watched in play: every
   -- DIAG run while deliberately blind logged "DIAG cleared: blindness" and dropped it,
   -- only for the next reconcile to re-add it.
   engine.clear()
   engine.add("blindness", "gmcp")
   mock.line("You are:")
   mock.line("blind.")
   mock.line("Equilibrium used: 1.00s.")
   ok(engine.has("blindness"),
      "a bare state matching a tracked affliction's deliberate name is not cleared")

   -- An affliction the bare state does NOT correspond to is still cleared normally.
   engine.clear()
   engine.add("slickness", "trigger")
   mock.line("You are:")
   mock.line("blind.")
   mock.line("Equilibrium used: 1.00s.")
   eq(engine.has("slickness"), false,
      "an unrelated tracked affliction is still cleared by a bare state's confirmed picture")

   -- REGRESSION: DIAG's leading indefinite article defeated the squash. Confirmed live
   -- 2026-08-05: "afflicted by a crippled left arm." squashed to "acrippledleftarm", which
   -- matched nothing in afflist even though `crippledleftarm` was already there with a real
   -- cure -- so DIAG reported it as unknown every single time, forever.
   engine.clear()
   diag.unknown = {}
   mock.line("You are:")
   mock.line("afflicted by a crippled left arm.")
   mock.line("Equilibrium used: 1.00s.")
   ok(engine.has("crippledleftarm"),
      "the article-stripped form resolves to the entry that was there all along")
   eq(#diag.last.unknown, 0, "...and is no longer reported as unknown")

   -- The exact match still wins outright, and squashing without stripping the article still
   -- works too -- this only adds a third, later fallback, never replaces the first two.
   engine.clear()
   mock.line("You are:")
   mock.line("afflicted by asthma.")
   mock.line("Equilibrium used: 1.00s.")
   ok(engine.has("asthma"), "an exact match is unaffected by the article-stripping fallback")

   engine.clear(); queue.reset(); emunah.timers.stopAll()
   engine.enabled = false
end

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
-- lands directly in mock.sent rather than sitting in queue.pending. have.pipe() defaults
-- permissive with no PIPELIST seen yet (same philosophy as have.skill()), so this needs no
-- inventory setup -- see the herb-vector case (blind/bayberry, above) for the item-missing
-- regression test, where have.item() has no such permissive default.
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

-- Scoped: Lua 5.1 allows 200 active locals per function and this file is a single
-- top-level chunk, so a block that declares its own gets one.
do

-- ---------------------------------------------------------------------------
-- THE KEEP-UP GRID -- `emkeepup`. Every defence we know how to raise, as clickable
-- toggles.
queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Defences.List", { { name = "rebounding" }, { name = "speed" } })
defkeepup.enabled = true

-- The list is the union of three sources. Missing any one of them turns the grid into
-- "the things one particular table happens to hold".
local known = defkeepup.known()
ok(emunah.util.contains(known, "cloak"), "a plain-command defence is on the grid")
ok(emunah.util.contains(known, "sileris"),
   "...as is an item-based one from afflist.defenceCures")
ok(emunah.util.contains(known, "inspiration"), "...and inspiration")
ok(emunah.util.contains(known, "magicresist"), "...and one of the unverified ones")

-- TRUST. Nothing in the unverified table has been watched working, so it must lose to
-- anything that has, and the difference has to remain visible rather than living in
-- someone's memory.
eq(defkeepup.source("magicresist"), "imported", "an unverified command is marked as such")
eq(defkeepup.source("inspiration"), "emunah", "an observed one is not")
eq(defkeepup.state("inspiration").command, "perform inspiration",
   "where both hold a defence, the observed entry wins")
eq(defkeepup.state("inspiration").vector, "equilibrium",
   "...including its vector, which the unverified entry records only as costing balance")

-- Every unverified entry needs standing: none is known to work while prone, and the cost of
-- assuming otherwise is a wasted attempt from a budget of three.
local _, _, importedNeeds = defkeepup.resolve("magicresist")
eq(importedNeeds and importedNeeds.standing, true,
   "an unverified defence is not raised while prone")
eq(defkeepup.state("magicresist").vector, "free",
   "one believed to cost no balance sits on the free vector")
eq(defkeepup.state("alertness").vector, "balance",
   "...and a balanceful one to the balance vector")

-- INVISIBLE DEFENCES CANNOT BE KEPT UP THE ORDINARY WAY. `bliss` and `satiation` never
-- appear in DEF output and so never in Char.Defences. This module rests entirely on "not in
-- the list means not up", so a defence raised the ordinary way is raised, unseen, raised
-- again, and retired after three tries -- observed in play at 13:24:45.03, three `perform
-- bliss` at 6.50s of equilibrium each while it was up the whole time.
--
-- `bliss` is not in IMPORTED (unverified) or removed entirely -- it moved to M.commands as
-- `unconfirmable = true`, a defup-only one-shot that is satisfied on send rather than on
-- Char.Defences confirmation (see the suite below). `satiation` has not been given the same
-- treatment and stays out entirely.
eq(emunah.curing.deflist.IMPORTED.bliss, nil, "not treated as an unverified import")
eq(emunah.curing.deflist.IMPORTED.satiation, nil, "...and satiation is not here at all")

-- "COSTS A BALANCE" IS NOT THE BALANCE VECTOR. Achaea has several and knowing a command
-- spends one does not say which: `perform bliss` was recorded as costing balance and
-- announced "Equilibrium used: 6.50s." So an unverified one requires BOTH until observed.
local _, _, alertNeeds = defkeepup.resolve("alertness")
eq(alertNeeds.bal, true, "an unverified balance-costing defence requires balance")
eq(alertNeeds.eq, true, "...and equilibrium, because which of them it spends is unknown")
eq(alertNeeds.standing, true, "...and standing")

-- THE DEFENCE NAME IS NOT ALWAYS THE THING THAT GRANTS IT. `venom` is the elixir;
-- `poisonresist` is what Char.Defences calls the defence. Configured under the elixir's
-- name it can never match, so keep-up raised it forever -- three elixirs and three balances
-- before the budget stopped it, while the defence had been up since the first one.
eq(emunah.curing.deflist.canonical("venom"), "poisonresist",
   "the elixir's name resolves to the defence's name")
eq(emunah.curing.deflist.IMPORTED.venom, nil, "there is no entry under the elixir's name")
eq(defkeepup.state("poisonresist").command, "drink venom",
   "the defence is raised by the elixir")

defkeepup.setMode("venom", "keepup")
eq(defkeepup.mode("poisonresist"), "keepup",
   "asking for it by the elixir's name configures the defence")
eq(defkeepup.mode("venom"), "keepup", "...and reads back either way")
-- One key per defence: two would mean two grid cells and two attempt budgets.
local venomCells = 0
for _, n in ipairs(defkeepup.known()) do
   if n == "venom" or n == "poisonresist" then venomCells = venomCells + 1 end
end
eq(venomCells, 1, "it appears exactly once on the grid")
defkeepup.setMode("poisonresist", nil)

-- Same bug, same family: `levitation` is the elixir; `levitating` is what Char.Defences
-- calls the defence. Confirmed live 18:20:50-18:21:03: three sips each came back "The
-- elixir flows down your throat without effect", with the attempt budget naming
-- `levitating` as unclaimed and DEF's own readout listing "You are walking on a small
-- cushion of air." throughout.
eq(emunah.curing.deflist.canonical("levitation"), "levitating",
   "the elixir's name resolves to the defence's name")
eq(emunah.curing.deflist.IMPORTED.levitation, nil, "there is no entry under the elixir's name")
eq(defkeepup.state("levitating").command, "drink levitation",
   "the defence is raised by the elixir")

defkeepup.setMode("levitation", "keepup")
eq(defkeepup.mode("levitating"), "keepup",
   "asking for it by the elixir's name configures the defence")
eq(defkeepup.mode("levitation"), "keepup", "...and reads back either way")
local levitationCells = 0
for _, n in ipairs(defkeepup.known()) do
   if n == "levitation" or n == "levitating" then levitationCells = levitationCells + 1 end
end
eq(levitationCells, 1, "it appears exactly once on the grid")
defkeepup.setMode("levitating", nil)

-- `immunity` is not a naming mismatch -- it IS `poisonresist`, confirmed by an identical
-- DEF line, and sipping it while poisonresist was already up produced an actual affliction
-- ("As the antivenom ravages your system, you feel very unwell. You are confused as to the
-- effects of the venom."), not just a wasted sip. Aliased the same way as venom, so keep-up
-- never sends `drink immunity` at all once poisonresist is recognised as up.
eq(emunah.curing.deflist.canonical("immunity"), "poisonresist",
   "immunity resolves to the same defence venom does")
eq(emunah.curing.deflist.IMPORTED.immunity, nil, "there is no entry under immunity's own name")
eq(defkeepup.state("poisonresist").command, "drink venom",
   "the verified command wins over the duplicate elixir")

-- `frost` is the elixir; `temperance` is what Char.Defences calls the defence. Confirmed
-- live 18:39:57.43-18:39:57.62: a sip answered "The elixir flows down your throat without
-- effect", and the attempt budget's own diagnostic named `temperance` as unclaimed.
eq(emunah.curing.deflist.canonical("frost"), "temperance",
   "the elixir's name resolves to the defence's name")
eq(emunah.curing.deflist.IMPORTED.frost, nil, "there is no entry under the elixir's name")
eq(defkeepup.state("temperance").command, "drink frost",
   "the defence is raised by the elixir")

defkeepup.setMode("frost", "keepup")
eq(defkeepup.mode("temperance"), "keepup",
   "asking for it by the elixir's name configures the defence")
eq(defkeepup.mode("frost"), "keepup", "...and reads back either way")
local frostCells = 0
for _, n in ipairs(defkeepup.known()) do
   if n == "frost" or n == "temperance" then frostCells = frostCells + 1 end
end
eq(frostCells, 1, "it appears exactly once on the grid")
defkeepup.setMode("temperance", nil)

-- ---------------------------------------------------------------------------
-- BLISS -- invisible to Char.Defences and DEF, tracked from its own lines (svof)
-- ---------------------------------------------------------------------------
--
-- It used to be satisfied on send, in memory only, so every `emreload` forgot it and sent
-- `perform bliss` again. Now up comes from svof's bliss lines and survives a reload.
do
   queue.reset(); emunah.timers.stopAll()
   defkeepup.resetBudget()
   emunah.curing.detect.prone = false
   emunah.curing.deflist.setBliss(false)
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })

   defkeepup.enabled = true
   defkeepup.setMode("bliss", "defup")
   mock.sent = {}
   defkeepup.tick()
   ok(table.concat(mock.sent, " | "):find("perform bliss", 1, true),
      "bliss, not seen yet, is raised", table.concat(mock.sent, " | "))
   mock.line("You pour blessings of bliss over yourself, granting visions of the majesty of the divine.")
   eq(defkeepup.state("bliss").up, true, "its own line marks it up")
   eq(emunah.util.contains(defkeepup.missing(), "bliss"), false, "...so it is not missing")

   -- "Already experiencing bliss" says the same thing: up.
   emunah.curing.deflist.setBliss(false)
   mock.line("That person is already experiencing bliss.")
   eq(defkeepup.state("bliss").up, true, "`already experiencing bliss` marks it up too")

   -- It survives a reload: the state lives in emunah._persist.
   eq(emunah._persist.blissUp, true, "bliss is remembered where a reload keeps it")

   -- And it goes with death.
   mock.feed("Char.Vitals", { hp = "0", maxhp = "1000" })
   eq(defkeepup.state("bliss").up, false, "dying clears it")
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })

   defkeepup.setMode("bliss", nil)
   queue.reset(); emunah.timers.stopAll()
end

-- ---------------------------------------------------------------------------
-- AFTER A RELOAD: DEFENCES first, then keep-up
-- ---------------------------------------------------------------------------
do
   local defences = emunah.gmcp.defences
   queue.reset(); emunah.timers.stopAll()
   defkeepup.resetBudget()
   defkeepup.enabled = true
   defkeepup.setMode("rebounding", "keepup")
   mock.feed("Char.Defences.List", {})          -- the stale list a reload starts from
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })

   mock.sent = {}
   raiseEvent("emunah.loaded", true)
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   eq(table.concat(mock.sent, " | "), "defences",
      "after a reload, DEFENCES goes out -- and nothing is raised yet")

   mock.line("You have the following defences:")
   mock.line("You are protected from hand-held weapons with an aura of rebounding.")
   mock.line("Your mind has been attuned to the realm of Death.")
   mock.line("You are protected by 2 defences.")
   ok(defences.has("rebounding"), "the listing is read: rebounding is up")
   ok(defences.has("deathsight"), "...and deathsight")
   eq(defkeepup.checking, false, "keep-up resumes once it has been read")
   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   ok(not table.concat(mock.sent, " | "):find("rebounding", 1, true),
      "...and does not raise what the listing showed was up", table.concat(mock.sent, " | "))

   -- A known defence missing from a later listing is down.
   mock.line("You have the following defences:")
   mock.line("Your mind has been attuned to the realm of Death.")
   mock.line("You are protected by 1 defences.")
   ok(not defences.has("rebounding"), "a known defence missing from the listing is down")

   -- A reply that never comes cannot stall keep-up.
   raiseEvent("emunah.loaded", true)
   mock.advance(defkeepup.CHECK_TIMEOUT + 0.1)
   eq(defkeepup.checking, false, "no listing: keep-up resumes after the timeout")

   defkeepup.setMode("rebounding", nil)
   queue.reset(); emunah.timers.stopAll()
end

-- ---------------------------------------------------------------------------
-- SYNTHETIC DEFENCES -- `trackangel` and `trackmace`, which have no Char.Defences entry at
-- all. Confirmed live via `emunah debug gmcp`: neither `angel summon`/`angel fade` nor
-- `call mace` ever touch Char.Defences or Char.Status. gmcp/defences.lua stays a pure
-- mirror of the GMCP feed; deflist.M.SYNTHETIC and M.isUp() are the exception path, and
-- defkeepup.lua's state()/missing()/tick() all go through M.isUp() rather than
-- emunah.gmcp.defences.has() directly so these two can slot into the same keep-up grid as
-- everything else.
-- ---------------------------------------------------------------------------
do
   local deflist = emunah.curing.deflist

   -- trackangel: pure text-trigger state, no GMCP signal to assert against at all.
   queue.reset(); emunah.timers.stopAll()
   defkeepup.resetBudget()
   emunah.curing.detect.angel = false
   mock.feed("Char.Defences.List", {})

   eq(deflist.isUp("trackangel"), false, "the angel starts unsummoned")
   local vector, command = deflist.resolve("trackangel")
   eq(vector, "equilibrium", "raised on the equilibrium vector")
   eq(command, "angel summon", "...with the verified command")

   defkeepup.enabled = true
   defkeepup.setMode("trackangel", "keepup")
   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   ok(table.concat(mock.sent, " | "):find("angel summon", 1, true),
      "keep-up raises a missing angel", table.concat(mock.sent, " | "))

   -- The confirmation line, verbatim from the 07:44:53-07:44:59 capture, is the only thing
   -- that can ever mark this up -- Char.Defences never will.
   mock.line("A flower of white light blooms in the air beside you, and your guardian is "
      .. "by your side.")
   eq(deflist.isUp("trackangel"), true, "the confirmation line marks it up")
   eq(emunah.util.contains(defkeepup.missing(), "trackangel"), false,
      "...and it drops out of missing() the same as a real Char.Defences entry would")

   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   eq(#mock.sent, 0, "already up, so it is not raised again", table.concat(mock.sent, " | "))

   -- The fade line reacts immediately, the same way losing rebounding mid-fight does --
   -- not on the next ordinary tick.
   emunah.timers.stopAll()
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "0", eq = "0" })
   mock.sent = {}
   mock.line("Your guardian angel shimmers silently away.")
   eq(deflist.isUp("trackangel"), false, "the fade line marks it back down")

   -- REGRESSION: a cold summon and a redundant one answer with DIFFERENT text, and only the
   -- first was covered. Confirmed live 08:32:09.28-08:32:16.27: ANGEL SUMMON sent while
   -- already summoned answered "You feel confusion radiate from your guardian, who hovers
   -- already at your side." -- which never touched detect.angel, so keep-up resent ANGEL
   -- SUMMON every equilibrium cycle forever, stopped only by the user pausing keep-up (`pp`)
   -- by hand.
   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   ok(table.concat(mock.sent, " | "):find("angel summon", 1, true),
      "keep-up raises the angel again after the fade", table.concat(mock.sent, " | "))
   mock.line("You feel confusion radiate from your guardian, who hovers already at your side.")
   eq(deflist.isUp("trackangel"), true,
      "the redundant-summon refusal ALSO marks it up -- the game is saying the same thing "
         .. "the cold-summon confirmation does, just in different words")
   mock.sent = {}
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
   eq(#mock.sent, 0,
      "...so the runaway loop actually stops instead of resending every equilibrium cycle",
      table.concat(mock.sent, " | "))

   defkeepup.setMode("trackangel", nil)
   emunah.curing.detect.angel = false
   queue.reset(); emunah.timers.stopAll()
   -- Restore ordinary vitals -- the fade-reaction check above deliberately starved the
   -- vector so nothing would actually send, and left bal/eq at 0 for whatever runs next.
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })

   -- trackmace: no trigger at all -- read live off Char.Items, three different raise
   -- commands depending on what state the mace is actually in.
   queue.reset(); emunah.timers.stopAll()
   defkeepup.resetBudget()
   emunah._persist.maceSummoned = nil
   mock.feed("Char.Items.List", { location = "inv", items = {} })

   eq(deflist.isUp("trackmace"), false, "no mace known, so not up")
   local maceVector, maceCommand = deflist.resolve("trackmace")
   eq(maceVector, "balance", "never summoned this login -- raised on balance")
   eq(maceCommand, "summon mace", "...with SUMMON, not CALL")

   -- Once seen -- summoned by us or already standing before keep-up was told to track it --
   -- it is never summoned a second time. Confirmed live 07:49:40.91: CALL MACE recalled the
   -- SAME item id (616546) rather than creating a new one.
   mock.feed("Char.Items.Add", { location = "inv",
      item = { id = "616546", name = "a spiritual mace", attrib = "" } })
   ok(emunah._persist.maceSummoned, "seeing the mace at all marks it summoned for the login")
   eq(deflist.isUp("trackmace"), false, "present but unwielded is still not up")

   local awayVector, awayCommand = deflist.resolve("trackmace")
   eq(awayVector, "free", "in inventory, unwielded -- raised on the free vector")
   eq(awayCommand, "wield mace", "...with WIELD, since it is already in hand's reach")

   -- Recalled rather than re-summoned once it leaves inventory again.
   mock.feed("Char.Items.Remove", { location = "inv", item = { id = "616546" } })
   local callVector, callCommand = deflist.resolve("trackmace")
   eq(callVector, "equilibrium", "gone from inventory, but seen before -- CALL's vector")
   eq(callCommand, "call mace", "...not SUMMON again")

   -- Wielded is up, on either hand.
   mock.feed("Char.Items.Add", { location = "inv",
      item = { id = "616546", name = "a spiritual mace", attrib = "l" } })
   eq(deflist.isUp("trackmace"), true, "wielded left-hand reads as up")
   mock.feed("Char.Items.Update", { location = "inv",
      item = { id = "616546", name = "a spiritual mace", attrib = "L" } })
   eq(deflist.isUp("trackmace"), true, "...and so does wielded right-hand")

   -- resolve() still answers "wield mace" while already wielded -- the same as every other
   -- entry answers regardless of current state (see resolveTrackmace()'s own note). Whether
   -- to actually send it is M.isUp()'s question, asked separately by M.missing() and the
   -- queue's `valid` closure, not resolve()'s.
   local upVector, upCommand = deflist.resolve("trackmace")
   eq(upVector, "free", "resolve() does not go blank just because it is already up")
   eq(upCommand, "wield mace", "...it still names the command that would re-raise it")

   -- Not chained. The transcript this was built from showed exactly why: `summon
   -- mace;;wield mace` sent the wield before the mace existed ("What do you wish to wield?"
   -- preceded the conjuring message by 0.01s), and it had to be typed again by hand. Each
   -- tick resolves fresh off current Char.Items instead, so the wield only ever goes out
   -- once the item is actually there.
   mock.feed("Char.Items.Remove", { location = "inv", item = { id = "616546" } })
   emunah._persist.maceSummoned = nil
   local firstVector, firstCommand = deflist.resolve("trackmace")
   eq(firstCommand, "summon mace", "nothing summoned yet -- SUMMON, not the chained pair")
   ok(not (firstCommand or ""):find(";;", 1, true), "...and never a chained command at all")

   -- Both arms broken blocks the wield -- the one verified "needs a working hand" predicate
   -- in this codebase (see curing/engine.lua's queueTree()), not a single-arm check nothing
   -- here has confirmed.
   mock.feed("Char.Items.Add", { location = "inv",
      item = { id = "616546", name = "a spiritual mace", attrib = "" } })
   engine.add("brokenleftarm", "trigger")
   engine.add("brokenrightarm", "trigger")
   local blockedVector, blockedCommand = deflist.resolve("trackmace")
   eq(blockedVector, nil, "wield is withheld with both arms broken")
   eq(blockedCommand, nil, "...no command at all, not just an unraisable one")
   engine.clear()
   local unblockedVector = deflist.resolve("trackmace")
   eq(unblockedVector, "free", "...and returns the moment the arms are not both broken")

   -- WIELD spends neither balance nor equilibrium but needs both, and the user confirmed
   -- it directly -- there is no cost line to read it from.
   local _, _, wieldNeeds = deflist.resolve("trackmace")
   eq(wieldNeeds.bal, true, "wield needs balance present")
   eq(wieldNeeds.eq, true, "...and equilibrium present")

   -- Persisted in emunah._persist deliberately -- that table is scratch space modules use
   -- to survive an emreload (see emunah.lua), which must not forget a mace already standing
   -- and pay 2.9s of balance to conjure a second one. Only a real disconnect should forget
   -- it; not exercised here via a raw sysDisconnectionEvent, which cascades into every other
   -- module's own handler (items.lua's inventory wipe, gmcp/defences.lua's active-list
   -- wipe) and would leave the rest of this suite's ambient state disturbed for tests that
   -- never asked for a reconnect.

   mock.feed("Char.Items.Remove", { location = "inv", item = { id = "616546" } })
   emunah._persist.maceSummoned = nil
   engine.clear()
   queue.reset(); emunah.timers.stopAll()
end

-- AN ELIXIR THAT DID NOTHING is the game saying the defence is already up -- under some
-- other name. Retrying is the one case where the budget is delay rather than protection.
queue.reset(); emunah.timers.stopAll()
defkeepup.resetBudget()
mock.feed("Char.Defences.List", { { name = "poisonresist" } })
defkeepup.setMode("frost", "keepup")
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(queue.awaiting("elixir") ~= nil, "a defence elixir is in flight")
mock.line("The elixir flows down your throat without effect.")
eq(defkeepup.withinBudget("frost"), false,
   "a sip with no effect abandons the defence instead of spending the rest of the budget")
defkeepup.setMode("frost", nil)
defkeepup.resetBudget()

-- The game is already reporting the real name; it just needed putting in front of someone.
mock.feed("Char.Defences.List", { { name = "somethingunknown" }, { name = "rebounding" } })
ok(emunah.util.contains(defkeepup.unclaimed(), "somethingunknown"),
   "a reported name nothing claims is surfaced")
eq(emunah.util.contains(defkeepup.unclaimed(), "rebounding"), false,
   "...and a claimed one is not")

-- Put back the list the assertions further down were set up against.
mock.feed("Char.Defences.List", { { name = "rebounding" }, { name = "speed" } })

-- A PROMPT IS REQUESTED ON TOGGLE. Keep-up only decides anything on a prompt-driven tick,
-- so without this a toggle sits idle until the game happens to say something -- which,
-- standing still, reads as the click not having worked.
defkeepup.enabled = true
mock.sent = {}
eq(defkeepup.nudge(), true, "a nudge is sent while keep-up is on")
eq(mock.sent[1], "", "...as a blank line, which Achaea answers with a prompt")

defkeepup.enabled = false
mock.sent = {}
eq(defkeepup.nudge(), false, "...and not while keep-up is off, when it would achieve nothing")
eq(#mock.sent, 0, "...so nothing is sent")
defkeepup.enabled = true

-- Box and colour answer DIFFERENT questions, so all four combinations have to be
-- representable. A defence that is up without being kept up is the one that gets lost when
-- they are merged, and it is the useful one -- it is a candidate to add.
defkeepup.add("rebounding")
local upKept = defkeepup.state("rebounding")
eq(upKept.mode, "keepup", "rebounding is on keepup")
eq(upKept.up, true, "...and is up")

local upNotKept = defkeepup.state("speed")
eq(upNotKept.mode, nil, "speed is switched off")
eq(upNotKept.up, true, "...but is up anyway, which the grid still shows")

defkeepup.add("cloak")
eq(defkeepup.state("cloak").up, false, "cloak is on keepup and down -- the actionable state")

-- THE THREE-STATE CYCLE. off -> defup -> keepup -> off, which is what a click does.
eq(defkeepup.mode("telesense"), nil, "a defence starts switched off")
eq(defkeepup.cycle("telesense"), "defup", "the first click selects defup")
eq(defkeepup.cycle("telesense"), "keepup", "the second selects keepup")
eq(defkeepup.cycle("telesense"), nil, "the third switches it off again")

-- DEFUP RAISES ONCE. The difference between the modes is entirely about what happens when
-- the defence LATER goes away: defup is satisfied the moment it has been seen up.
queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Defences.List", {})
defkeepup.setMode("telesense", "defup")
defkeepup.redoDefup()
ok(emunah.util.contains(defkeepup.missing(), "telesense"),
   "a defup defence that is down wants raising")

mock.feed("Char.Defences.Add", { name = "telesense", desc = "x" })
eq(defkeepup.state("telesense").satisfied, true, "seeing it up satisfies defup")

mock.feed("Char.Defences.Remove", { "telesense" })
eq(emunah.util.contains(defkeepup.missing(), "telesense"), false,
   "...and a later expiry is ignored, which is the whole point of the mode")

-- keepup, by contrast, wants it back.
defkeepup.setMode("telesense", "keepup")
ok(emunah.util.contains(defkeepup.missing(), "telesense"),
   "keepup wants the same defence back after it expires")

-- Changing the mode is a fresh statement of intent and clears "already done".
defkeepup.setMode("telesense", "defup")
eq(defkeepup.state("telesense").satisfied, false,
   "switching mode forgets that defup had been satisfied")
defkeepup.setMode("telesense", nil)

-- A defence nobody has given us a command for. It can sit on the wanted list forever and
-- nothing will ever go out, which is indistinguishable from "keeps failing" unless it is
-- said outright.
defkeepup.add("madeupdefence")
local unknown = defkeepup.state("madeupdefence")
eq(unknown.raisable, false, "a defence with no known command is marked unraisable")
ok(emunah.util.contains(defkeepup.known(), "madeupdefence"),
   "...and still appears on the grid, rather than vanishing from the one view "
   .. "that would explain it")
defkeepup.drop("madeupdefence")

-- Clicking. The grid is a control surface, not a report, so this is the behaviour.
mock.links = {}
mock.echoed = {}
emunah.commands.handlers.defs()
local shieldLink
for index, link in ipairs(mock.links) do
   if link.text:find("shield", 1, true) then shieldLink = index end
end
ok(shieldLink ~= nil, "every defence on the grid is a link")
eq(defkeepup.mode("shield"), nil, "shield starts off")
ok(mock.click(shieldLink), "clicking it runs")
eq(defkeepup.mode("shield"), "defup", "...and selects defup")
mock.click(shieldLink)
eq(defkeepup.mode("shield"), "keepup", "clicking again selects keepup")
mock.click(shieldLink)
eq(defkeepup.mode("shield"), nil, "and a third click switches it off")

-- With keep-up off the grid says so and offers the fix, rather than showing a page of
-- toggles that do nothing.
defkeepup.enabled = false
mock.links = {}
mock.echoed = {}
emunah.commands.handlers.defs()
ok(table.concat(mock.echoed, " "):find("defences are OFF"),
   "the grid says when defences are off")
local turnOn = false
for _, link in ipairs(mock.links) do
   if link.command:find("defkeepup.start", 1, true) then turnOn = true end
end
ok(turnOn, "...and offers a one-click way to turn it on")

defkeepup.drop("rebounding"); defkeepup.drop("cloak")
defkeepup.enabled = false
queue.reset(); emunah.timers.stopAll()

-- ---------------------------------------------------------------------------
-- ADDING A DEFENCE WHILE KEEP-UP IS OFF SAID "Keeping up X" AND DID NOTHING.
--
-- `defences.enabled` ships false and `add` never touched it, so the whole sequence was
-- reachable with no indication anywhere that the subsystem was switched off: the log
-- claimed the defence was being kept up, `emunah defs` listed it MISSING in red, and the
-- UI panel did the same. Reported from play at 13:03:03.43.
queue.reset(); emunah.timers.stopAll()
mock.feed("Char.Defences.List", {})
defkeepup.enabled = false
emunah.log.warnings = nil
mock.echoed = {}
defkeepup.add("inspiration")
local addedOff = table.concat(mock.echoed, " ")
ok(addedOff:find("OFF"), "adding a defence while keep-up is off says so", addedOff)
ok(addedOff:find("emset defs on"), "...and names the command that fixes it", addedOff)
ok(emunah.util.contains(defkeepup.wanted(), "inspiration"),
   "...while still adding it to the list, which was never the broken part")

-- The roster says it where the red text is, not only in the header.
mock.echoed = {}
emunah.commands.dispatch("defs")
local listing = table.concat(mock.echoed, " ")
ok(listing:find("nothing below is being raised"),
   "the defence list explains why everything reads MISSING", listing)

-- And with it on, the claim is true again.
defkeepup.enabled = true
mock.echoed = {}
defkeepup.add("inspiration")
ok(table.concat(mock.echoed, " "):find("keepup"),
   "with defences on, it names the mode instead", table.concat(mock.echoed, " "))
defkeepup.drop("inspiration")

-- ---------------------------------------------------------------------------
-- AN UNRECOGNISED `defs` SUBCOMMAND USED TO TOGGLE KEEP-UP INSTEAD OF ERRORING.
--
-- The handler's final branch was `else keepup.toggle() end`, reached by ANY argument that
-- did not match on/off/add/names/mode/remove/drop/list -- including a plain typo. `emunah
-- defs sttaus` silently flipped defence keep-up on or off with no warning at all. Every
-- sibling handler (bash, pvp, walk, shop, mobs) shows its default report on an unmatched
-- argument instead; `defs` now does the same.
defkeepup.enabled = false
mock.echoed = {}
emunah.commands.dispatch("defs sttaus")
ok(not defkeepup.enabled,
   "an unrecognised `defs` subcommand does not toggle keep-up", tostring(defkeepup.enabled))
local unknownDefsOutput = table.concat(mock.echoed, " ")
ok(unknownDefsOutput:find("Unknown"),
   "...and warns that the subcommand was not recognised", unknownDefsOutput)
ok(unknownDefsOutput:find("defences"),
   "...while still showing the ordinary report", unknownDefsOutput)

defkeepup.enabled = true
mock.echoed = {}
emunah.commands.dispatch("defs sttaus")
ok(defkeepup.enabled,
   "...and the same holds when keep-up started on", tostring(defkeepup.enabled))

-- ---------------------------------------------------------------------------
-- INSPIRATION. A Priest defence that nothing strips -- it simply lapses after about ten
-- minutes -- which is precisely the shape keep-up exists for.
--
-- `perform inspiration`, equilibrium 3.50s (defences.md). It needs balance AND
-- equilibrium AND to be standing: three requirements, only one of which the vector
-- expresses, and with three attempts in the budget three refusals while prone would retire
-- the defence for the rest of the session.
queue.reset(); engine.clear(); engine.enabled = false
emunah.timers.stopAll()
defkeepup.resetBudget()
defkeepup.checking = false   -- an earlier suite's reload leaves it awaiting a DEFENCES reply
-- Its own vitals, rather than whatever the suites before it left behind.
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
mock.feed("Char.Defences.List", {})
defkeepup.add("inspiration")
defkeepup.enabled = true

-- The GMCP shapes, exactly as the game sends them: Add is a single object, Remove an array
-- of bare names. Getting either wrong means the defence is never seen to go up or down.
mock.feed("Char.Defences.Add",
   { desc = "Divine inspiration increases your strength.", name = "inspiration" })
ok(emunah.gmcp.defences.has("inspiration"), "Char.Defences.Add records inspiration")

mock.sent = {}
defkeepup.tick()
eq(#mock.sent, 0, "nothing is raised while the defence is already up",
   table.concat(mock.sent, " | "))

mock.feed("Char.Defences.Remove", { "inspiration" })
eq(emunah.gmcp.defences.has("inspiration"), false,
   "Char.Defences.Remove -- an array of names -- drops it")

-- Losing it raises `defence.lost`, which tick()s immediately rather than waiting for the
-- next prompt -- so a raise is already in flight on the equilibrium vector by now. Clear it
-- before testing the gates below, or the vector is simply busy and every one of them
-- "passes" for the wrong reason.
ok(queue.awaiting("equilibrium") ~= nil,
   "losing the defence raises it again at once, without waiting for a tick")
queue.reset()
defkeepup.resetBudget()

-- Char.Vitals drives the tick, so the record has to be cleared BEFORE the feed -- by the
-- time mock.feed returns, keep-up has already queued and flushed.
--
-- PRONE. The one that costs most to get wrong, because it happens mid-fight and the budget
-- is only three deep.
-- The prone FLAG directly. How it comes to be set has its own tests; what is under test
-- here is that keep-up consults it at all.
local savedProne = emunah.curing.detect.prone
emunah.curing.detect.prone = true
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("perform inspiration", 1, true),
   "it is not attempted while prone", table.concat(mock.sent, " | "))

emunah.curing.detect.prone = savedProne

-- OFF BALANCE. Equilibrium alone is not enough, so the vector being ready does not settle
-- it -- the command needs the physical balance too.
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "0", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("perform inspiration", 1, true),
   "it is not attempted off balance, however much equilibrium there is",
   table.concat(mock.sent, " | "))

-- Held, not dropped: it goes the moment all three are true.
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
ok(table.concat(mock.sent, " | "):find("perform inspiration", 1, true),
   "with balance, equilibrium and upright, it goes out",
   table.concat(mock.sent, " | "))

-- The equilibrium vector is held for the round trip. Char.Vitals omits eq when unchanged,
-- so without this the next push still reads eq=true and a second raise goes out into the
-- gap -- a wide gap here, because the ability costs 3.50s.
eq(emunah.gmcp.vitals.eq, false, "sending it marks equilibrium spent immediately")
mock.sent = {}
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1" })
eq(#mock.sent, 0, "...so a second attempt cannot race into the gap",
   table.concat(mock.sent, " | "))

-- The game states the real cost, and the generic trigger arms the vector from it.
mock.line("Equilibrium used: 3.50s.")
eq(emunah.have.balance("equilibrium"), false, "the announced 3.50s holds the vector")
mock.advance(3.6)
-- The TIMER specifically, not have.balance(): keep-up re-raises the moment the vector
-- frees, spending equilibrium again, so asking the composite question here would answer
-- about that second raise instead of about the cost timer under test.
eq(emunah.timers.ready("cure.equilibrium"), true, "...and frees once it has elapsed")

defkeepup.drop("inspiration")
defkeepup.enabled = false
defkeepup.resetBudget()
queue.reset(); emunah.timers.stopAll()
end

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
mock.feed("Char.Vitals", { charstats = { "Bleed: 45" } })
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

-- READS ARE MEMOISED, so every write has to drop the memo.
--
-- config.get() caches by dotted path, because the curing engine reads a couple of dozen
-- settings on every prompt and splitting the path allocates. The hazard is a setting that
-- keeps answering with its old value after `emunah set` -- the user changes a threshold,
-- nothing happens, and the config file says it took. Each case below primes the cache with
-- a read first, which is the only ordering that catches a missing invalidation.
do
   local config = emunah.config

   eq(config.get("curing.confirmWait"), 1.25, "primed")
   config.set("curing.confirmWait", 2.75)
   eq(config.get("curing.confirmWait"), 2.75, "a write is visible to the next read")

   -- A cached MISS is as stale as a cached value: this path did not exist when it was read.
   eq(config.get("curing.madeUpSetting", "fallback"), "fallback", "missing path takes the fallback")
   config.set("curing.madeUpSetting", 7)
   eq(config.get("curing.madeUpSetting", "fallback"), 7, "...and stops being missing once set")

   -- The fallback belongs to the caller, not the cache: two sites may ask for the same
   -- missing path with different defaults.
   eq(config.get("curing.stillMissing", 1), 1, "first caller's fallback")
   eq(config.get("curing.stillMissing", 2), 2, "second caller gets its OWN fallback")

   -- Writing a PARENT replaces the table a child path resolves through.
   config.set("curing.nested", { leaf = "before" })
   eq(config.get("curing.nested.leaf"), "before", "child read primed")
   config.set("curing.nested", { leaf = "after" })
   eq(config.get("curing.nested.leaf"), "after", "replacing the parent invalidates the child")

   -- `emunah priority` mutates the returned table in place and then calls set(). A table is
   -- cached by reference, so that has to stay visible.
   config.set("priorities", {})
   local priorities = config.get("priorities", {})
   priorities.paralysis = { herb = 1 }
   config.set("priorities", priorities)
   eq(config.get("priorities").paralysis.herb, 1, "in-place mutation then set() is visible")

   config.reset()
   ok(config.get("curing.madeUpSetting") == nil, "reset() drops the memo too")
end

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
ok(mock.widgets["emunah.target"] ~= nil, "target gauge built")
ok(mock.widgets["emunah.afflictions"] ~= nil, "affliction console built")
ok(mock.widgets["emunah.defences"] ~= nil, "defences console built")
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

-- REGRESSION: a chat console that self-heals once must be able to self-heal AGAIN. Before
-- the fix, M.rebuilt latched true forever after the first repair (see chat.lua's build()),
-- so any LATER console failure hit `if M.rebuilt then return false end` and was refused a
-- rebuild -- captured into history by gmcp/comm.lua same as ever, but never rendered, with
-- no further warning. Reported as "comm.channel data isn't echoing into the chat window",
-- fixable only by a manual `emreload` (which re-executes the module and gets a fresh
-- M.rebuilt = false for free).
emunah.ui.chat.console = { decho = function() error("widget is gone", 0) end }
emunah.ui.chat.broken, emunah.ui.chat.rebuilt = false, false
mock.echoed = {}
mock.feed("Comm.Channel.Text", { channel = "ct", text = "first break" })
ok(table.concat(mock.echoed, " "):find("Rebuilding the chat console"),
   "first console failure triggers a self-heal")
ok(not emunah.ui.chat.rebuilt,
   "...and a successful rebuild resets the one-shot guard so a later failure can heal too")
ok(emunah.ui.chat.console ~= nil and emunah.ui.chat.mode ~= "none",
   "the console was actually rebuilt, not just marked healthy")

-- Break the freshly-rebuilt console and confirm a SECOND, independent failure also heals.
emunah.ui.chat.console = { decho = function() error("widget is gone again", 0) end }
emunah.ui.chat.broken = false
mock.echoed = {}
mock.feed("Comm.Channel.Text", { channel = "ct", text = "second break" })
ok(table.concat(mock.echoed, " "):find("Rebuilding the chat console"),
   "a second, later console failure also self-heals instead of being silently dropped",
   table.concat(mock.echoed, " "))

-- Panel placement. Room/items own the top of the left column, afflictions the bottom;
-- chat owns the top of the right column, defences the bottom; vitals (and the target bar)
-- own the bottom strip. Asserting the parent container of each catches a panel built into
-- the wrong region, which is invisible in a headless test but glaring on screen.
local function parentName(widget)
   return widget and widget.parent and widget.parent.name or "?"
end
eq(parentName(mock.widgets["emunah.room"]), "emunah.left", "room panel is in the left column")
eq(parentName(mock.widgets["emunah.afflictions"]), "emunah.left", "afflictions are in the left column")
eq(parentName(mock.widgets["emunah.defences"]), "emunah.right", "defences are in the right column")
eq(parentName(mock.widgets["emunah.gauge.hp"]), "emunah.bottom", "vitals are in the bottom strip")
eq(parentName(mock.widgets["emunah.target"]), "emunah.bottom", "target bar is in the bottom strip")

-- Chat sits above defences inside the shared right column.
local chatWidget = mock.widgets["emunah.chat.plain"] or mock.widgets["emunah.chat"]
eq(parentName(chatWidget), "emunah.right", "chat is in the right column")
local function pct(value)
   return tonumber(tostring(value):match("^(%d+)%%")) or 0
end
ok(pct(mock.widgets["emunah.defences"].cons.y) > pct(chatWidget.cons.height),
   "defences start below the chat console",
   ("chat height %s, defences y %s"):format(
      tostring(chatWidget.cons.height), tostring(mock.widgets["emunah.defences"].cons.y)))

-- Room panel sits above afflictions inside the shared left column.
ok(pct(mock.widgets["emunah.afflictions"].cons.y) > pct(mock.widgets["emunah.room"].cons.height),
   "afflictions start below the room panel",
   ("room height %s, afflictions y %s"):format(
      tostring(mock.widgets["emunah.room"].cons.height), tostring(mock.widgets["emunah.afflictions"].cons.y)))

-- Target bar sits above the resource gauges inside the shared bottom strip.
ok(tonumber(mock.widgets["emunah.target"].cons.y) < tonumber(mock.widgets["emunah.gauge.hp"].cons.y),
   "target bar starts above the HP/MP/EP/WP row",
   ("target y %s, hp y %s"):format(
      tostring(mock.widgets["emunah.target"].cons.y), tostring(mock.widgets["emunah.gauge.hp"].cons.y)))

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

-- Blindness/deafness held on purpose (blind/deaf under keep-up) is not something to cure --
-- engine.curableCount() and resolve() already skip it for that reason, and the panel has to
-- agree or it flags a defence working as intended as a problem needing attention.
emunah.curing.defkeepup.setMode("blind", "keepup")
engine.add("blindness", "gmcp")
ok(pcall(emunah.ui.affpanel.update), "affliction panel renders with a deliberate blindness")
ok(not tostring(mock.widgets["emunah.afflictions"].contents):find("blindness"),
   "deliberately-held blindness is not shown as an affliction to cure")
ok(tostring(mock.widgets["emunah.afflictions"].contents):find("paralysis"),
   "a real affliction is still shown alongside a deliberately-held one")
emunah.curing.defkeepup.setMode("blind", nil)
engine.remove("blindness")

engine.clear()

-- Room panel with real content.
mock.feed("Room.Info", {
   num = 777, name = "A quiet glade", area = "Forest",
   exits = { n = 778, e = 779 }, details = { "shop" },
})
local roomText = tostring(mock.widgets["emunah.room"].contents)
ok(roomText:find("quiet glade"), "room panel shows the room name")
ok(roomText:find("shop"), "room panel shows room details")

-- PLAYERS: the short name, not the honorific fullname, coloured per ui/names.lua's own
-- policy (reused, not duplicated) so the panel agrees with how the same name would be
-- highlighted if it scrolled past in the game text.
emunah.namedb.iff("Anzerloi", "ally")
mock.feed("Room.Players", {
   { name = "Anzerloi", fullname = "Anzerloi, the Grand Something" },
})
ok(tostring(mock.widgets["emunah.room"].contents):find("Anzerloi"),
   "room panel shows the player's short name")
ok(not tostring(mock.widgets["emunah.room"].contents):find("Grand Something"),
   "...not the honorific fullname", tostring(mock.widgets["emunah.room"].contents))
eq(table.concat(emunah.gmcp.room.playerShortNames(), ", "), "Anzerloi",
   "playerShortNames() itself returns the true-case short name")
emunah.namedb.iff("Anzerloi", nil)
mock.feed("Room.Players", {})

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

-- ---------------------------------------------------------------------------
-- DRAW-CALL BUDGET.
--
-- Under Mudlet a decho is a Qt rich-text parse and a setStyleSheet is a stylesheet reparse
-- plus a re-layout; here they are string assignments. So these count calls rather than time
-- them -- the count is what transfers, and it is what regressed. The panels used to emit one
-- decho per row (thirty-odd for a full defence grid) and repaint unconditionally on every
-- one of eight events.

do
   -- ROOM PANEL: one paint, however many rows. The room currently holds four items, one of
   -- them a clickable denizen -- and a link cannot be concatenated into a neighbouring
   -- decho, since dechoLink binds a callback to the text it draws. So the budget is "the
   -- runs of plain text either side of each link", not literally one.
   emunah.ui.roompanel.forgetPainted()
   local drawn = mock.countDraws()
   emunah.ui.roompanel.update()
   eq(drawn.clear, 1, "the room panel clears once per repaint")
   ok(drawn.draw <= 3, "...and draws in a handful of calls, not one per row", drawn.draw)

   -- AND NOTHING AT ALL when nothing it displays has changed. This is what makes a burst
   -- cheap: a restock pulling five herbs fires five Char.Items events into the INVENTORY,
   -- none of which change what the ROOM shows.
   drawn = mock.countDraws()
   emunah.ui.roompanel.update()
   eq(drawn.draw, 0, "an unchanged room panel is not redrawn")
   eq(drawn.clear, 0, "...and not even cleared")

   drawn = mock.countDraws()
   for herb = 1, 5 do
      mock.feed("Char.Items.Add", {
         location = "inv",
         item = { id = "80" .. herb, name = "some bloodroot", attrib = "" },
      })
   end
   eq(drawn.draw, 0, "five inventory events do not repaint the room panel at all")

   -- ...but a real change still lands immediately. The saving must never cost freshness.
   drawn = mock.countDraws()
   mock.feed("Char.Items.Add", {
      location = "room",
      item = { id = "998", name = "a jewelled goblet", attrib = "t" },
   })
   ok(drawn.draw > 0, "an item that really appears in the room does repaint it")
   ok(tostring(mock.widgets["emunah.room"].contents):find("jewelled goblet"),
      "...and is shown")
   mock.feed("Char.Items.Remove", { location = "room", item = { id = "998" } })
end

do
   -- AFFLICTION PANEL: one decho per console, not one per affliction row and one per
   -- defence cell.
   engine.clear()
   engine.add("paralysis", "gmcp")
   engine.add("anorexia", "gmcp")
   engine.add("asthma", "gmcp")
   engine.add("slickness", "gmcp")
   mock.feed("Char.Defences.List", {
      { name = "rebounding" }, { name = "speed" }, { name = "levitating" },
      { name = "insomnia" },   { name = "temperance" }, { name = "clumsiness" },
      { name = "deathsight" }, { name = "mindseye" },
   })

   emunah.ui.theme.forgetPainted()
   local drawn = mock.countDraws()
   emunah.ui.affpanel.update()
   eq(drawn.draw, 2, "the affliction panel draws once per console, whatever the row count",
      drawn.draw)
   eq(drawn.clear, 2, "...and clears once per console")

   drawn = mock.countDraws()
   emunah.ui.affpanel.update()
   eq(drawn.draw, 0, "an unchanged affliction panel is not redrawn")

   -- A real change still lands. The afflictions half carries an age that ticks, so drive
   -- the defences half, which does not.
   drawn = mock.countDraws()
   -- An ARRAY OF NAMES, which is the shape Achaea actually sends (gmcp/defences.lua:6).
   mock.feed("Char.Defences.Remove", { "rebounding" })
   ok(drawn.draw > 0, "losing a defence repaints the panel")
   engine.clear()
end

do
   -- THE VITALS STRIP. The two balance lights each ran a setStyleSheet on every prompt --
   -- a Qt stylesheet reparse for a boolean that had not changed. Four a second, for nothing.
   mock.feed("Char.Vitals", { hp = "2500", maxhp = "4000", bal = "1", eq = "1" })
   local drawn = mock.countDraws()
   mock.feed("Char.Vitals", { hp = "2400", maxhp = "4000", bal = "1", eq = "1" })
   eq(drawn.style, 0, "an unchanged balance light is not restyled on the next prompt")
   ok(drawn.value > 0, "...while the gauges, which did change, are updated")

   -- ...and a light that DOES change is restyled.
   drawn = mock.countDraws()
   mock.feed("Char.Vitals", { hp = "2400", maxhp = "4000", bal = "0", eq = "1" })
   eq(drawn.style, 1, "losing balance restyles exactly that one light")
   eq(mock.widgets["emunah.balance"].contents, "BAL", "...and it still says BAL")

   -- A cure timer lapsing must refresh the vector lights and NOTHING ELSE. This used to
   -- redraw the whole strip -- four gauges, the XP gauge, both lights, the class stats --
   -- several times a second in a fight.
   drawn = mock.countDraws()
   emunah.event.raise("timer.expired", "cure.herb")
   eq(drawn.value, 0, "a lapsing cure timer does not touch the resource gauges")
   eq(drawn.style, 0, "...nor restyle the balance lights")
end

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

-- ---------------------------------------------------------------------------
-- THE CHYRON -- a scrolling announcement strip, scoped to the console's own width.
-- ---------------------------------------------------------------------------
do
   local chyron = emunah.ui.chyron

   -- The container itself must not stretch past the room/chat columns: it starts where the
   -- left column ends and stops where the right column begins, not x=0/width=100% the way
   -- the (deliberately full-width) vitals strip does.
   local topContainer = emunah.ui.layout.container("top")
   ok(topContainer ~= nil, "the top container is built")
   eq(topContainer.cons.x, emunah.ui.layout.WIDTH_LEFT,
      "the chyron starts exactly where the left (room data) column ends")
   local expectedWidth = 100 - pct(emunah.ui.layout.WIDTH_LEFT) - pct(emunah.ui.layout.WIDTH_RIGHT)
   eq(pct(topContainer.cons.width), expectedWidth,
      "...and is exactly as wide as the console gap between room data and chat, no wider")

   eq(parentName(mock.widgets["emunah.chyron"]), "emunah.top",
      "the chyron widget lives in its own container")

   -- Reserving the space: setBorderTop must actually be nonzero once a top region exists,
   -- the same mechanism HEIGHT_BOTTOM already uses for the vitals strip.
   emunah.ui.layout.resizeConsole()
   ok(mock.borders and mock.borders.top and mock.borders.top > 0,
      "the console reserves real space for the chyron rather than floating over it",
      mock.borders and mock.borders.top)

   -- Sending queues a message and starts it scrolling.
   emunah.timers.stopAll()
   chyron.clear()
   chyron.send("first announcement")
   eq(#chyron.messages, 1, "one message queued")
   ok(mock.widgets["emunah.chyron"].contents ~= "", "the strip renders something once sent")

   -- On a loop, at most three -- a fourth drops the oldest rather than growing forever.
   chyron.send("second announcement")
   chyron.send("third announcement")
   chyron.send("fourth announcement")
   eq(#chyron.messages, chyron.MAX_MESSAGES, "capped at three messages")
   eq(chyron.messages[1].text, "second announcement",
      "the oldest (first) message was dropped, not the newest")
   eq(chyron.messages[3].text, "fourth announcement", "...and the newest is the last one")

   -- It actually scrolls: rendered content changes as the scroll timer advances, rather
   -- than sitting on one static frame.
   local before = mock.widgets["emunah.chyron"].contents
   mock.advance(chyron.TICK_INTERVAL * 5)
   local after = mock.widgets["emunah.chyron"].contents
   ok(before ~= after, "the rendered frame changes as the scroll timer fires",
      ("before=%q after=%q"):format(tostring(before), tostring(after)))

   -- Clearing stops the scroll and blanks the strip -- no timer left ticking into a widget
   -- that no longer has anything to show.
   chyron.clear()
   eq(#chyron.messages, 0, "clear empties the queue")
   eq(mock.widgets["emunah.chyron"].contents, "", "...and blanks the strip")
   local blank = mock.widgets["emunah.chyron"].contents
   mock.advance(chyron.TICK_INTERVAL * 5)
   eq(mock.widgets["emunah.chyron"].contents, blank,
      "...and nothing is scrolling anymore to change it back")

   chyron.clear()
   emunah.timers.stopAll()
end

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

-- `walk auto` is no longer a subcommand: auto-stepping is the `walker.auto` setting, and a
-- removed subcommand must warn rather than start or stop anything.
mock.echoed = {}
emunah.commands.dispatch("walk auto on")
ok(table.concat(mock.echoed, " "):find("Unknown"), "a removed `walk` subcommand warns",
   table.concat(mock.echoed, " "))
emunah.commands.dispatch("walker.auto false")
ok(not emunah.config.get("walker.auto", true), "`emset walker.auto false` disables auto-stepping")
emunah.commands.dispatch("walker.auto true")
ok(emunah.config.get("walker.auto", false), "...and `true` enables it again")
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

-- `emunah walk stop` with nothing running says so, rather than doing nothing silently --
-- the same fix as `emunah hunt off`'s (see commands.lua).
ok(not walker.enabled, "walker is already off going into this check")
mock.echoed = {}
emunah.commands.dispatch("walk stop")
ok(table.concat(mock.echoed, " "):find("not running"),
   "'emunah walk stop' with nothing running says so", table.concat(mock.echoed, " "))

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

-- PIN THIS WHOLE SUITE TO SMITE, EXPLICITLY -- it is regression-testing smite's own
-- confirmed cost shape (requires both, spends only balance) and the double-send guard built
-- around that shape, not "whatever bashing.attack currently defaults to". Angel Sear became
-- the shipped default 2026-08-04 with the opposite consumption (spends equilibrium instead),
-- and pinning here is what lets that default change without silently breaking what this
-- suite actually verifies. See the "shipped default" block further down for the assertions
-- that DO care what ships.
emunah.config.set("bashing.attack", "smite")
emunah.config.set("bashing.balance", "both")
emunah.config.set("bashing.consumes", "bal")

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

-- AUTO-RESUME: a health-triggered stop watches for health to climb back out past a margin
-- (stopBelowHealth + resumeMargin, 50+10 here) and restarts itself -- but not right at the
-- stop line, and not for any OTHER reason bashing might have stopped.
ok(bash.awaitingHealthResume, "the health stop armed the auto-resume watch")

mock.feed("Char.Vitals", { hp = "2200", maxhp = "4000" })   -- 55%: clear of the 50% stop
                                                              -- line, short of the 60% margin
ok(not bash.enabled, "recovering just past the stop line alone is not enough to resume")

mock.feed("Char.Vitals", { hp = "3000", maxhp = "4000" })   -- 75%: clear of the margin, and
                                                              -- the pixie is still in the room
ok(bash.enabled, "bashing resumes on its own once health clears the margin")
ok(not bash.awaitingHealthResume, "the watch disarms itself once it has resumed")
bash.stop("test")

-- AN EXPLICIT STOP WINS. Arm the watch again, then stop deliberately (`emunah hunt off` and
-- friends all funnel through here) before it fires -- health recovering afterward must not
-- silently turn bashing back on against the user's own request.
bash.start()
mock.feed("Char.Vitals", { hp = "100", maxhp = "4000", bal = "1", eq = "1" })
ok(not bash.enabled and bash.awaitingHealthResume, "health stop fires again, watch armed")
bash.stop("requested")
ok(not bash.awaitingHealthResume, "an explicit stop clears the auto-resume watch")
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000" })
ok(not bash.enabled, "...and health recovering afterward does not bring it back on its own")

-- NOTHING LEFT TO RESUME ONTO. roomClear() already refuses to walk while the walker is
-- off, so restarting here would just leave bashing on and idle -- worse than not resuming,
-- since it reads as running when there is nothing it could do.
mock.feed("Char.Items.List", { location = "room", items = {} })
bash.start()
mock.feed("Char.Vitals", { hp = "100", maxhp = "4000" })
ok(not bash.enabled and bash.awaitingHealthResume, "health stop fires with an empty room")
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000" })
ok(not bash.enabled, "does not resume into an empty room")
ok(not bash.awaitingHealthResume, "the watch gives up rather than polling forever")

-- Restore the room for what follows.
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "555", name = "a pixie", attrib = "m" } },
})
bash.stop("test")

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
   "and the shipped default is 'both': every attack confirmed so far needs balance AND "
   .. "equilibrium present")

-- The attack command and what it spends moved together, 2026-08-04: "smite" -> "angel
-- sear", with the new "consumes" setting defaulting to "eq" rather than the implicit "bal"
-- smite always meant. Checked against DEFAULTS itself, then explicitly restored to what
-- this whole suite is pinned to -- everything below still exercises smite's own confirmed
-- shape, not whatever ships.
emunah.config.data.bashing.attack = nil
eq(emunah.config.get("bashing.attack", "angel sear"), "angel sear",
   "no stale default overrides the attack command at the call site")
eq(emunah.config.DEFAULTS.bashing.attack, "angel sear",
   "and the shipped attack is angel sear, not smite")

emunah.config.data.bashing.consumes = nil
eq(emunah.config.get("bashing.consumes", "eq"), "eq",
   "no stale default overrides what the attack consumes at the call site")
eq(emunah.config.DEFAULTS.bashing.consumes, "eq",
   "and the shipped default spends equilibrium: angel sear, not smite, is what ships")

emunah.config.set("bashing.attack", "smite")
emunah.config.set("bashing.consumes", "bal")

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

-- `defences.keepup` went from an ARRAY of names to a MAP of name -> mode when defences
-- grew a defup mode. An existing list means exactly one thing -- keep all of these up --
-- so every entry has to convert to "keepup". Left unconverted the array reads as an empty
-- map, and every defence anyone had configured switches itself off silently.
local oldList = { defences = { keepup = { "rebounding", "insomnia" } } }
ok(emunah.config.migrate(oldList), "a config with the old defence array migrates")
eq(oldList.defences.keepup.rebounding, "keepup", "each name becomes a keepup entry")
eq(oldList.defences.keepup.insomnia, "keepup", "...all of them")
eq(oldList.defences.keepup[1], nil, "...and the array form is gone")

-- Idempotent: a map already in the new shape is not re-converted into nothing.
local already = { defences = { keepup = { cloak = "defup" } }, schema = 4 }
emunah.config.migrate(already)
eq(already.defences.keepup.cloak, "defup", "a config already in the new shape is untouched")

-- `venom` is the elixir; `poisonresist` is the defence Char.Defences reports. An entry
-- saved under the elixir's name can never match, so it is raised forever.
-- Scoped: Lua 5.1 caps a function at 200 active locals, and this file is one chunk.
do
   local elixirName = { defences = { keepup = { venom = "keepup" } } }
   ok(emunah.config.migrate(elixirName), "a config naming the elixir migrates")
   eq(elixirName.defences.keepup.poisonresist, "keepup", "...to the defence's name")
   eq(elixirName.defences.keepup.venom, nil, "...with the old key removed")
end
eq(tuned.curing.manaThreshold, 50, "...both of them")

-- Same bug, same fix, a session later: `blind` raises the defence but Char.Defences
-- reports it as `blindness`. An entry saved under `blind` can never match, so keep-up
-- raises it forever without ever seeing it land.
do
   local blindName = { defences = { keepup = { blind = "keepup" } } }
   ok(emunah.config.migrate(blindName), "a config naming the verb migrates")
   eq(blindName.defences.keepup.blindness, "keepup", "...to the defence's name")
   eq(blindName.defences.keepup.blind, nil, "...with the old key removed")
end

-- Same bug again, confirmed the same session: `deaf` raises the defence but Char.Defences
-- reports it as `deafness`.
do
   local deafName = { defences = { keepup = { deaf = "keepup" } } }
   ok(emunah.config.migrate(deafName), "a config naming the other verb migrates")
   eq(deafName.defences.keepup.deafness, "keepup", "...to the defence's name")
   eq(deafName.defences.keepup.deaf, nil, "...with the old key removed")
end

-- Same bug, same family, a later session: `levitation` is the elixir but Char.Defences
-- reports the defence as `levitating`. Confirmed live 18:20:50-18:21:03: three sips each
-- answered "The elixir flows down your throat without effect", and the attempt budget
-- named `levitating` as unclaimed.
do
   local levitationName = { defences = { keepup = { levitation = "keepup" } } }
   ok(emunah.config.migrate(levitationName), "a config naming the elixir migrates")
   eq(levitationName.defences.keepup.levitating, "keepup", "...to the defence's name")
   eq(levitationName.defences.keepup.levitation, nil, "...with the old key removed")
end

-- `immunity` is not a mismatch but a duplicate: it IS `poisonresist`. A saved entry under
-- `immunity` would keep sending a redundant, harmful dose forever -- confirmed live,
-- sipping it while poisonresist was already up triggered an antivenom-overdose affliction.
do
   local immunityName = { defences = { keepup = { immunity = "keepup" } } }
   ok(emunah.config.migrate(immunityName), "a config naming the duplicate elixir migrates")
   eq(immunityName.defences.keepup.poisonresist, "keepup", "...to the defence's name")
   eq(immunityName.defences.keepup.immunity, nil, "...with the old key removed")
end

-- Same bug, same family, a later session: `frost` is the elixir but Char.Defences reports
-- the defence as `temperance`. Confirmed live 18:39:57.43-18:39:57.62: a sip answered "The
-- elixir flows down your throat without effect", and the attempt budget named `temperance`
-- as unclaimed.
do
   local frostName = { defences = { keepup = { frost = "keepup" } } }
   ok(emunah.config.migrate(frostName), "a config naming the elixir migrates")
   eq(frostName.defences.keepup.temperance, "keepup", "...to the defence's name")
   eq(frostName.defences.keepup.frost, nil, "...with the old key removed")
end

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

-- ANY GOLD, PROVIDED THE ROOM IS EMPTY. The kill-credit rule is off by default now: an
-- empty room is the whole condition, so a pile nobody killed for is still taken.
emunah.loot.attempted = {}
emunah.loot.creditUntil = nil
mock.sent = {}
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "890", name = "a pile of gold sovereigns", attrib = "t" },
})
ok(table.concat(mock.sent, " | "):find("get 890"),
   "gold with no kill of ours behind it is taken in an empty room",
   table.concat(mock.sent, " | "))

-- The narrower rule is still there for anyone who wants it back.
emunah.config.set("loot.ownKillsOnly", true)
emunah.loot.attempted = {}
emunah.loot.creditUntil = nil
mock.sent = {}
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "896", name = "a pile of gold sovereigns", attrib = "t" },
})
eq(#mock.sent, 0, "loot.ownKillsOnly restores the own-kills-only rule",
   table.concat(mock.sent, " | "))

-- ...and under that rule the credit expires, so a pile appearing much later is not ours.
mock.line("You have slain a thing, retrieving the corpse.")
mock.advance(emunah.loot.CREDIT_WINDOW + 1)
emunah.loot.attempted = {}
mock.sent = {}
mock.feed("Char.Items.Add", {
   location = "room",
   item = { id = "891", name = "a pile of gold sovereigns", attrib = "t" },
})
eq(#mock.sent, 0, "credit from an old kill has expired", table.concat(mock.sent, " | "))
emunah.config.set("loot.ownKillsOnly", false)

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

-- ---------------------------------------------------------------------------
-- NOTHING ALIVE IN THE ROOM EITHER.
--
-- GET costs balance AND equilibrium -- the same pair an attack needs -- and gold appears at
-- the exact moment a kill has just spent both. Stopping to loot while something else is
-- still swinging trades an attack for a pile that is not going anywhere.
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
emunah.loot.attempted = {}
mock.sent = {}
mock.feed("Char.Items.List", {
   location = "room",
   items = {
      { id = "870", name = "a pile of gold sovereigns", attrib = "t" },
      { id = "871", name = "a pixie warrior",           attrib = "m" },
   },
})
eq(#mock.sent, 0, "no pickup with a live denizen in the room",
   table.concat(mock.sent, " | "))

-- A CORPSE IS NOT A DENIZEN. This is the case that matters: the corpse the gold spilled
-- out of is in the room by definition, so counting it would mean gold from a kill could
-- never be picked up at all. denizens.here() excludes `d`.
emunah.loot.attempted = {}
mock.sent = {}
mock.feed("Char.Items.List", {
   location = "room",
   items = {
      { id = "872", name = "a pile of gold sovereigns", attrib = "t" },
      { id = "873", name = "the corpse of a pixie",     attrib = "md" },
   },
})
ok(table.concat(mock.sent, " | "):find("get 872"),
   "...but a corpse does not count as alive", table.concat(mock.sent, " | "))

-- ---------------------------------------------------------------------------
-- STOWING IT.
--
-- Driven by the gold ARRIVING IN INVENTORY, not by a delay after the GET: a PUT sent before
-- the GET has landed is a command about something we are not holding yet.
mock.feed("Char.Items.List", { location = "inv", items = {} })
mock.sent = {}
mock.feed("Char.Items.Add", {
   location = "inv", item = { id = "872", name = "a pile of gold sovereigns", attrib = "t" },
})
eq(table.concat(mock.sent, " | "), "put gold in backpack452292",
   "gold landing in inventory is put in the pack", table.concat(mock.sent, " | "))

-- Gold leaving inventory is the confirmation, and it resets the attempt budget -- the
-- budget is per pile, not per session, or the fourth pile of a hunt would be refused.
mock.feed("Char.Items.Remove", {
   location = "inv", item = { id = "872", name = "a pile of gold sovereigns" },
})
eq(emunah.loot.stowAttempts, 0, "a stowed pile resets the attempt budget")

-- IT MUST NOT LOOP. Whether gold in a container really leaves the "inv" location has never
-- been verified against a payload, so if that model is wrong this has to stop and say so
-- rather than sending a PUT on every balance for the rest of the session.
mock.advance(emunah.loot.STOW_GUARD + 0.01)
mock.sent = {}
mock.feed("Char.Items.Add", {
   location = "inv", item = { id = "874", name = "a pile of gold sovereigns", attrib = "t" },
})
-- Twelve chances to send; the budget is what stops it, not the number of opportunities.
for _ = 1, 12 do
   mock.advance(emunah.loot.STOW_GUARD + 0.01)
   emunah.loot.stowGold()
end
eq(#mock.sent, emunah.loot.STOW_ATTEMPTS,
   "a PUT that never works stops after STOW_ATTEMPTS", table.concat(mock.sent, " | "))
mock.feed("Char.Items.Remove", {
   location = "inv", item = { id = "874", name = "a pile of gold sovereigns" },
})

-- NOT KNOWING what we carry is not the same as carrying nothing. A reload empties this
-- view while the character still holds everything.
local heldInv = emunah.gmcp.items.locations.inv
emunah.gmcp.items.locations.inv = {}
emunah.gmcp.items.known = false
mock.sent = {}
emunah.loot.stowGold()
eq(#mock.sent, 0, "no PUT while inventory is unknown", table.concat(mock.sent, " | "))
emunah.gmcp.items.known = true
emunah.gmcp.items.locations.inv = heldInv

-- ---------------------------------------------------------------------------
-- KEEPING THE PACK ON. A removed pack silently breaks stowing -- the first sign would be
-- gold quietly accumulating loose -- so the removal message is answered directly.
mock.sent = {}
mock.line("You remove a canvas backpack.")
eq(table.concat(mock.sent, " | "), "wear backpack452292",
   "removing the pack wears it straight back", table.concat(mock.sent, " | "))

-- Blocked states are the one thing that holds it: the game would have thrown it away.
-- Reached through emunah.curing.detect rather than the `detect` local, which points at an
-- earlier generation of the module -- the reload suite above replaces it.
emunah.curing.detect.onSleep()
mock.sent = {}
mock.line("You remove a canvas backpack.")
eq(#mock.sent, 0, "...but not while asleep", table.concat(mock.sent, " | "))
emunah.curing.detect.onWake()

-- The container is one setting, used by both the PUT and the WEAR.
emunah.config.set("loot.stowIn", "pack999")
mock.sent = {}
mock.line("You remove a canvas backpack.")
eq(table.concat(mock.sent, " | "), "wear pack999", "the container is configurable",
   table.concat(mock.sent, " | "))
emunah.config.set("loot.stowIn", "backpack452292")

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

-- Regression: `emunah bash off` / `emunah walk stop` on an already-stopped loop used to
-- return false and log nothing at all -- indistinguishable from the command having failed.
-- Same fix as F12/`emunah hunt off`, applied directly to the two single-purpose commands.
ok(not bash.enabled, "bashing is already off going into this")
mock.echoed = {}
emunah.commands.dispatch("bash off")
ok(table.concat(mock.echoed, " "):find("not running"),
   "'bash off' with nothing running says so", table.concat(mock.echoed, " "))

ok(not emunah.walker.enabled, "the walk is already off going into this")
mock.echoed = {}
emunah.commands.dispatch("walk stop")
ok(table.concat(mock.echoed, " "):find("not running"),
   "'walk stop' with nothing running says so", table.concat(mock.echoed, " "))

-- Regression: confirmed live -- `emunah bash attack "angel sear"` stored the quotes
-- literally (M.dispatch never strips them), so every attack went out as `"angel sear" <id>`
-- and Achaea read the leading `"` as SAY shorthand: "You say, "Angel sear" 235781." A
-- quoted multi-word command is the natural thing to type, so both forms must land the same.
do
   local savedAttack = emunah.config.get("bashing.attack")
   emunah.commands.dispatch('bash attack "angel sear"')
   eq(emunah.config.get("bashing.attack"), "angel sear",
      "a quoted attack command has the quotes stripped before it is stored")
   emunah.commands.dispatch("bash attack angel sear")
   eq(emunah.config.get("bashing.attack"), "angel sear",
      "...and the unquoted form stores identically")
   emunah.config.set("bashing.attack", savedAttack)
end

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

-- `emunah bash off` with nothing running says so, rather than doing nothing silently --
-- the same fix as `emunah hunt off`'s (see commands.lua).
bash.stop("test")
mock.echoed = {}
emunah.commands.dispatch("bash off")
ok(table.concat(mock.echoed, " "):find("not running"),
   "'emunah bash off' with nothing running says so", table.concat(mock.echoed, " "))

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
suite("pipes")

local pipes = emunah.pipes

-- Parsing a real PIPELIST. The row pattern has to survive multi-word contents ("a skullcap
-- flower") without swallowing the two numeric columns after it.
local function pipelist(rows)
   mock.line("Status  Pipe         Contents                       Puffs Months ")
   mock.line("-------------------------------------------------------------------------------")
   for _, row in ipairs(rows) do mock.line(row) end
   mock.line("-------------------------------------------------------------------------------")
end

emunah.curing.detect.onWake()
emunah.timers.stop("pipes.action")
emunah.timers.stop("pipes.poll")
mock.feed("Char.Vitals", { bal = "1", eq = "1" })

pipelist({
   "lit     pipe367581   a skullcap flower              10    250",
   "out     pipe408402   slippery elm                   10    250",
   "out     pipe422328   a valerian leaf                10    250",
})
eq(#pipes.list(), 3, "three pipes parsed from PIPELIST")
eq(pipes.pipes["367581"].status, "lit", "status read")
eq(pipes.pipes["367581"].herb, "skullcap", "'a skullcap flower' resolves to skullcap")
eq(pipes.pipes["408402"].herb, "elm", "'slippery elm' resolves to elm")
eq(pipes.pipes["422328"].herb, "valerian", "'a valerian leaf' resolves to valerian")
eq(pipes.pipes["367581"].puffs, 10, "puffs read past the multi-word contents")
eq(pipes.pipes["367581"].token, "pipe367581", "the pipeNNN token is kept for LIGHT")

-- The header and separator rows must not parse as pipes.
eq(#pipes.list(), 3, "the header and rule lines are not mistaken for pipes")

-- HAVE.PIPE() NOW ANSWERS PROPERLY. All three are called "a white stone pipe" in inventory,
-- so the old description scan could never match a herb and fell through to "allow anything".
eq(emunah.have.pipe("skullcap"), true, "a lit pipe of skullcap can be smoked")
eq(emunah.have.pipe("elm"), false, "an unlit pipe of elm cannot -- it holds it, but it is out")
eq(emunah.have.pipe("cinnabar"), false, "a herb no pipe holds cannot be smoked")

-- ---------------------------------------------------------------------------
-- KEEPING THEM LIT. Two pipes are out; one command per round trip, lowest id first.
mock.sent = {}
pipes.keep()
eq(table.concat(mock.sent, " | "), "light pipe408402", "an unlit pipe is lit",
   table.concat(mock.sent, " | "))

-- One command at a time on the wire: Achaea throttles fast streams, and a rate limit holds
-- back every subsystem rather than just this one.
mock.sent = {}
pipes.keep()
eq(#mock.sent, 0, "a second command waits out the wire guard", table.concat(mock.sent, " | "))

-- Past the wire guard the NEXT pipe goes -- not the one just commanded, which is still
-- inside its own longer guard waiting for the game to answer.
mock.advance(pipes.WIRE_GUARD + 0.01)
mock.sent = {}
pipes.keep()
eq(table.concat(mock.sent, " | "), "light pipe422328", "...then the next pipe, not a repeat",
   table.concat(mock.sent, " | "))

-- Nothing to do once they are all lit.
pipelist({
   "lit     pipe367581   a skullcap flower              10    250",
   "lit     pipe408402   slippery elm                   10    250",
   "lit     pipe422328   a valerian leaf                10    250",
})
mock.advance(pipes.ACTION_GUARD + 0.01)
mock.sent = {}
pipes.keep()
eq(#mock.sent, 0, "three lit pipes need nothing", table.concat(mock.sent, " | "))

-- ---------------------------------------------------------------------------
-- A PIPE GOING OUT is announced, and that is minutes ahead of the next poll. The message
-- names the CONTENTS, not the pipe.
mock.advance(pipes.ACTION_GUARD + 0.01)
mock.sent = {}
mock.line("Your pipe, containing a skullcap flower, has gone cold and dark.")
eq(pipes.pipes["367581"].status, "out", "the announcement marks that pipe out")
ok(table.concat(mock.sent, " | "):find("light pipe367581"),
   "...and it is relit straight away", table.concat(mock.sent, " | "))

-- ---------------------------------------------------------------------------
-- REFILLING COMES FROM INVENTORY, NEVER THE RIFT. The transcript at 07:16:41 shows a manual
-- `outr elm` putting inventory one over the restocker's target, which stored it straight
-- back -- four rift commands fighting over one leaf. The restocker already keeps three of
-- every smoked herb in hand, so the pipe is filled from those.
mock.feed("Char.Items.List", {
   location = "inv",
   items = {
      { id = "1", name = "some slippery elm" },
      { id = "2", name = "a valerian leaf" },
      { id = "3", name = "a skullcap flower" },
   },
})
pipelist({
   "lit     pipe367581   a skullcap flower              10    250",
   "out     pipe408402   slippery elm                   0     250",
   "lit     pipe422328   a valerian leaf                10    250",
})
-- Cleared BEFORE the advance, because the chain timer is what acts now -- waiting for a
-- prompt is exactly the delay it exists to remove.
mock.sent = {}
mock.advance(pipes.ACTION_GUARD + 0.01)
eq(table.concat(mock.sent, " | "), "put elm in 408402",
   "an empty pipe is refilled from inventory -- and with the BARE id, as PUT wants",
   table.concat(mock.sent, " | "))
ok(not table.concat(mock.sent, " | "):find("outr"),
   "...and never touches the rift", table.concat(mock.sent, " | "))

-- ONE BROKEN PIPE MUST NOT BLOCK THE OTHERS. With a single shared guard the lowest-numbered
-- pipe needing attention was re-sent the same command every round trip while the rest sat
-- cold behind it. Each pipe carries its own guard, so a pass that skips one still services
-- the next.
pipes.forget()
mock.feed("Char.Items.List", { location = "inv", items = {} })
pipelist({
   "out     pipe367581   a skullcap flower              10    250",
   "out     pipe408402   slippery elm                   10    250",
   "out     pipe422328   a valerian leaf                10    250",
})
mock.sent = {}
for _ = 1, 3 do
   mock.advance(pipes.WIRE_GUARD + 0.01)
   pipes.keep()
end
eq(table.concat(mock.sent, " | "),
   "light pipe367581 | light pipe408402 | light pipe422328",
   "three cold pipes are each lit once, none of them twice",
   table.concat(mock.sent, " | "))

-- Without the herb in hand a refill waits rather than pulling: the restocker is fetching it.
pipes.forget()
mock.feed("Char.Items.List", { location = "inv", items = {} })
pipelist({ "out     pipe408402   slippery elm                   0     250" })
mock.sent = {}
pipes.keep()
eq(#mock.sent, 0, "no refill while the herb is not carried", table.concat(mock.sent, " | "))

-- ---------------------------------------------------------------------------
-- A pipe that never responds is abandoned rather than commanded forever -- lighting needs a
-- tinderbox, and what happens without one has never been observed.
pipes.forget()
pipelist({ "out     pipe367581   a skullcap flower              10    250" })
mock.sent = {}
for _ = 1, 12 do
   mock.advance(pipes.ACTION_GUARD + 0.01)
   pipes.keep()
end
-- Three lights, then one PIPELIST and nothing further. Giving up is the moment our tracked
-- state is most likely to be the thing that is wrong, so it asks once on the way out.
eq(table.concat(mock.sent, " | "),
   "light pipe367581 | light pipe367581 | light pipe367581 | pipelist",
   "an unresponsive pipe stops after ATTEMPTS, asking once on the way out",
   table.concat(mock.sent, " | "))

-- ...and a state change means the last command worked, so the budget resets.
pipes.forget()
pipelist({ "out     pipe367581   a skullcap flower              9     250" })
mock.sent = {}
mock.advance(pipes.CHAIN + 0.01)
ok(table.concat(mock.sent, " | "):find("light pipe367581"),
   "a pipe that changed state is worth trying again", table.concat(mock.sent, " | "))

-- ---------------------------------------------------------------------------
-- NOTHING IS EVER GAGGED, and this is the regression pin for it.
--
-- An earlier version deleted the output of its own polls. Reported in play as "it's also
-- only lighting the skullcap pipe" -- the FIRST row. Deleting a line while Mudlet is still
-- working through the lines that arrived in the same packet shifts the buffer under it, and
-- the rows after the deleted one never reached the trigger at all, so only pipe one was ever
-- recorded. The state machine was fine; it was being fed one pipe.
pipes.forget()
emunah.timers.stop("pipes.poll")
mock.sent = {}
local before = mock.deletedLines
pipes.poll()
eq(table.concat(mock.sent, " | "), "pipelist", "polling asks the game",
   table.concat(mock.sent, " | "))
pipelist({
   "lit     pipe367581   a skullcap flower              9     250",
   "out     pipe408402   slippery elm                   9     250",
   "out     pipe422328   a valerian leaf                10    250",
})
eq(mock.deletedLines, before, "our own poll output is left on screen, not deleted")
eq(#pipes.list(), 3, "...so every row after the first is still recorded")

-- ---------------------------------------------------------------------------
-- LIGHTING HAS TWO SUCCESS MESSAGES and only one was matched. `light pipes` answers "You
-- light a white stone pipe."; `light pipe367581` answers "You carefully light your treasured
-- pipe until it is smoking nicely." Missing the second meant a successful LIGHT confirmed
-- nothing, so the same pipe was lit again a moment later -- 07:34:16 then 07:34:21, answered
-- "That pipe is already lit and burning nicely."
pipes.forget()
pipelist({
   "out     pipe367581   a skullcap flower              9     250",
   "out     pipe408402   slippery elm                   9     250",
})
mock.sent = {}
mock.advance(pipes.CHAIN + 0.01)
eq(table.concat(mock.sent, " | "), "light pipe367581", "the first cold pipe is lit",
   table.concat(mock.sent, " | "))

mock.line("You use a soot-blackened tinderbox to make fire.")
mock.line("You carefully light your treasured pipe until it is smoking nicely.")
eq(pipes.pipes["367581"].status, "lit",
   "the real LIGHT confirmation marks that pipe lit without waiting for a poll")

mock.sent = {}
mock.advance(pipes.CHAIN + 0.01)
eq(table.concat(mock.sent, " | "), "light pipe408402",
   "...so the next command is the OTHER pipe, not the same one again",
   table.concat(mock.sent, " | "))

-- A puff is counted, not polled: the line names the herb, and one drag is exactly one puff.
mock.line("You take a long drag of skullcap off your pipe.")
eq(pipes.pipes["367581"].puffs, 8, "a drag decrements that pipe's puffs")

-- "There is nothing in the pipe to light." means our puff count was stale -- fill it instead.
pipes.forget()
pipelist({ "out     pipe408402   slippery elm                   9     250" })
mock.sent = {}
mock.advance(pipes.CHAIN + 0.01)
eq(table.concat(mock.sent, " | "), "light pipe408402", "we think it has herb in it",
   table.concat(mock.sent, " | "))
mock.line("There is nothing in the pipe to light.")
eq(pipes.pipes["408402"].puffs, 0, "the refusal corrects the puff count")
mock.feed("Char.Items.List", { location = "inv", items = { { id = "1", name = "slippery elm" } } })
mock.sent = {}
mock.advance(pipes.CHAIN + 0.01)
eq(table.concat(mock.sent, " | "), "put elm in 408402", "...and it is filled rather than relit",
   table.concat(mock.sent, " | "))

-- THE CHAIN IS WHAT MAKES IT PROMPT. keep() used to run only on emunah.tick, which fires on
-- Char.Vitals -- a prompt. Idle in a shop the prompts at 07:34:21.81 and 07:35:42.82 are
-- eighty-one seconds apart, and that gap is how long the second pipe sat cold.
pipes.forget()
mock.feed("Char.Items.List", { location = "inv", items = {} })
pipelist({
   "out     pipe367581   a skullcap flower              9     250",
   "out     pipe408402   slippery elm                   9     250",
   "out     pipe422328   a valerian leaf                9     250",
})
mock.sent = {}
-- No Char.Vitals at all: not one prompt for the whole of this.
for _ = 1, 3 do
   mock.advance(pipes.CHAIN + 0.01)
   mock.line("You carefully light your treasured pipe until it is smoking nicely.")
end
eq(table.concat(mock.sent, " | "),
   "light pipe367581 | light pipe408402 | light pipe422328",
   "all three are lit without a single prompt to drive it",
   table.concat(mock.sent, " | "))

-- ...and it stops once there is nothing left to do, rather than ticking away for ever.
mock.sent = {}
for _ = 1, 5 do mock.advance(pipes.CHAIN + 0.01) end
eq(#mock.sent, 0, "the chain stops when every pipe is lit", table.concat(mock.sent, " | "))

-- ---------------------------------------------------------------------------
-- A WHOLE CYCLE WITHOUT ASKING THE GAME ONCE.
--
-- Reported in play as spamming PIPELIST. Everything it reports is now tracked from the
-- messages that change it, so the poll is a drift backstop rather than the mechanism: one
-- listing at the start, then smoke a pipe empty, refill it and relight it with no further
-- listing at all.
pipes.forget()
emunah.timers.stop("pipes.poll")
emunah.timers.stop("pipes.poll.due")
mock.feed("Char.Items.List", { location = "inv", items = { { id = "1", name = "slippery elm" } } })
pipelist({ "lit     pipe408402   slippery elm                   2     250" })

mock.sent = {}

-- Smoked twice: the drag line names the herb, and one drag is exactly one puff.
mock.line("You take a long drag of elm off your pipe.")
eq(pipes.pipes["408402"].puffs, 1, "first drag counted")
mock.line("You take a long drag of elm off your pipe.")
eq(pipes.pipes["408402"].puffs, 0, "second drag empties it")

-- Empty now, so the next pass fills rather than lights -- and knows it is full afterwards
-- without asking, because a filled pipe always reads 10.
mock.advance(pipes.CHAIN + 0.01)
eq(table.concat(mock.sent, " | "), "put elm in 408402", "an emptied pipe is refilled",
   table.concat(mock.sent, " | "))
mock.line("You fill your pipe with slippery elm.")
eq(pipes.pipes["408402"].puffs, pipes.FULL_PUFFS, "a filled pipe is known to be full")
eq(pipes.pipes["408402"].status, "out", "...and known to still be cold")

mock.sent = {}
mock.advance(pipes.CHAIN + 0.01)
eq(table.concat(mock.sent, " | "), "light pipe408402", "...so it is lit next",
   table.concat(mock.sent, " | "))
mock.line("You carefully light your treasured pipe until it is smoking nicely.")
eq(pipes.pipes["408402"].status, "lit", "and the pipe is back in service")

-- It also goes quiet: nothing more to do, so the chain stops.
mock.sent = {}
for _ = 1, 5 do mock.advance(pipes.CHAIN + 0.01) end
eq(#mock.sent, 0, "no PIPELIST anywhere in the cycle, and no idle chatter",
   table.concat(mock.sent, " | "))

-- A pipe waiting on a herb the restocker has not brought is NOT work: counting it would have
-- the chain waking every CHAIN seconds forever to decide the same thing again.
pipes.forget()
mock.feed("Char.Items.List", { location = "inv", items = {} })
pipelist({ "out     pipe408402   slippery elm                   0     250" })
mock.sent = {}
for _ = 1, 5 do mock.advance(pipes.CHAIN + 0.01) end
eq(#mock.sent, 0, "a pipe blocked on restock does not spin the chain timer",
   table.concat(mock.sent, " | "))

-- `emset pipes on|off`, which is what actually gets typed.
ok(mock.command("emset pipes off"), "'emset pipes off' is matched")
eq(emunah.config.get("pipes.enabled", true), false, "...and turns keep-up off")
mock.sent = {}
mock.advance(pipes.CHAIN + 0.01)
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
eq(#mock.sent, 0, "...so nothing is sent while it is off", table.concat(mock.sent, " | "))

ok(mock.command("emset pipes on"), "'emset pipes on' is matched")
eq(emunah.config.get("pipes.enabled", true), true, "...and turns it back on")
ok(not mock.command("pipes"), "bare 'pipes' is no longer claimed -- one prefix")

-- ===========================================================================
suite("shop: WARES parsing and buying by replica number")

do
   local shop = emunah.shop

   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
   mock.feed("Char.Status", { gold = "10000" })

   -- A shop-row-shaped line before any Proprietor line is not a shop -- WARES always opens
   -- with one (HELP SHOPS), so nothing here has been told a listing is even in progress yet.
   mock.links, mock.popups = {}, {}
   mock.line("          tun999999 a stray line that looks like a row              1     100gp")
   eq(shop.find("tun999999"), nil, "an item-shaped line outside any listing is not parsed")
   eq(#mock.links, 0, "...and nothing is relinked for it")

   -- The real transcript this was built from, plus one credit-priced and one low-stock row to
   -- exercise currency gating and the stock cap without guessing at new game facts -- both
   -- "cr" and the WARES column shapes are straight from HELP SHOPS.
   local function wares(rows)
      mock.line("--------(Item)------(Description)------------------------------(Stock)--(Price)")
      for _, row in ipairs(rows) do mock.line(row) end
   end

   mock.links, mock.popups = {}, {}
   mock.line("Proprietor: Seraph Myrddin D'Ischai, Page of Aeowynn.")
   wares({
      "          tun115258 an elixir of mana (refill only)             53     100gp",
      "          tun266222 a salve of restoration (refill only)        54     100gp",
   })
   mock.line("")
   mock.line("[-[ Inks ]-]")
   wares({
      "      goldink386609 gold inks                                  222     350gp ea",
      "      blueink409794 blue inks                                  397      35gp ea",
      "      rareink555555 a rare shimmering ink                        5     500gp ea",
   })
   mock.line("")
   mock.line("[-[ Clothing ]-]")
   wares({
      "         cape533839 a gentleman's cape of white velvet and gold  1     925gp",
   })
   wares({
      "         token999999 a shining token                             3      50cr",
   })

   eq(shop.find("tun115258").tun, true, "a tun<repnum> is flagged as a tun")
   eq(shop.find("tun115258").category, nil, "...listed before any category header")
   eq(shop.find("goldink386609").bulk, true, "an 'ea'-priced row is flagged bulk")
   eq(shop.find("goldink386609").category, "Inks", "...under the Inks header")
   eq(shop.find("cape533839").category, "Clothing", "...and Clothing after its own header")
   eq(shop.find("cape533839").bulk, false, "a plainly priced row is not bulk")
   eq(shop.find("token999999").currency, "cr", "a credit-priced row parses its currency")
   eq(#mock.links, 7, "one link per row -- the default action")
   -- Only the three bulk ("... ea") rows get a menu now -- tuns and plain "buy 1" items
   -- have exactly one possible action, and Mudlet's own right-click handler
   -- (TTextEdit::mouseReleaseEvent) shows no menu at all for a single-command link, so
   -- offering one was misleading: it was reported back as "menu does the same as left
   -- clicking", which for a single-command link it necessarily always does.
   eq(#mock.popups, 3, "one popup per BULK row only -- nothing to choose for the rest")

   -- The clickable row must start its own line rather than running onto the tail of the
   -- raw row that triggered it -- reported in play as the listing looking garbled and the
   -- menu link not responding to clicks (see render()'s comment for the theory why).
   ok(mock.links[1].text:sub(1, 1) == "\n",
      "the clickable row starts on its own line, not glued to the raw row's tail",
      mock.links[1].text)

   -- The clickable row must not repeat the id/description the raw row above it already
   -- has -- reported back as "the description twice".
   ok(not mock.links[1].text:find("elixir of mana", 1, true),
      "the clickable row does not repeat the item description", mock.links[1].text)
   ok(mock.links[1].text:find("fill rift", 1, true),
      "...it is just the action -- 'fill rift' for a tun", mock.links[1].text)

   -- ---------------------------------------------------------------------------
   -- Left click: the default action. A tun fills the rift, one at a time; everything else
   -- buys one.
   mock.sent = {}
   ok(mock.click(1), "the tun row's link is clickable")
   eq(table.concat(mock.sent, " | "), "get 100 gold from backpack452292 | fill rift with tun115258",
      "clicking a tun gets exact gold, by replica number, then fills the rift -- never BUY",
      table.concat(mock.sent, " | "))

   mock.sent = {}
   ok(mock.click(3), "an ordinary bulk row's link is clickable")
   eq(table.concat(mock.sent, " | "), "get 350 gold from backpack452292 | buy goldink386609",
      "clicking an ink buys exactly one, for exactly its price",
      table.concat(mock.sent, " | "))

   -- ---------------------------------------------------------------------------
   -- Right click's stand-in: a popup menu, context-aware per HELP SHOPS and what the user
   -- confirmed about tuns. Popups are indexed by BULK row now (goldink=1, blueink=2,
   -- rareink=3), not by overall row position, since the two tuns ahead of them no longer
   -- produce one at all.
   eq(#mock.popups[1].commands, 3, "a bulk item's menu offers 1 / 10 / 100")
   mock.sent = {}
   ok(mock.popupClick(2, 2), "choosing '10' from blue ink's menu")
   eq(table.concat(mock.sent, " | "), "get 350 gold from backpack452292 | buy 10 blueink409794",
      "10 blue ink at 35gp each is 350gp, taken by replica number", table.concat(mock.sent, " | "))

   -- Stock caps the quantity: only 5 of the rare ink exist, so "100" cannot ask for 100.
   mock.sent = {}
   ok(mock.popupClick(3, 3), "choosing '100' from a 5-in-stock row")
   eq(table.concat(mock.sent, " | "), "get 2500 gold from backpack452292 | buy 5 rareink555555",
      "the quantity is capped at stock, and the gold pulled matches the capped amount",
      table.concat(mock.sent, " | "))

   -- ---------------------------------------------------------------------------
   -- Currency gating: only gp is automated -- see docs/game/sustenance.md ("Shops").
   mock.sent = {}
   ok(mock.click(7), "a credit-priced row is still clickable")
   eq(#mock.sent, 0, "...but nothing is sent for it -- cr/mc purchases are not automated",
      table.concat(mock.sent, " | "))

   -- ---------------------------------------------------------------------------
   -- A confirm limit holds back a purchase over it rather than sending it.
   shop.setConfirmAbove(300)
   mock.sent = {}
   ok(mock.click(3), "clicking an item over the confirm limit")
   eq(#mock.sent, 0, "...sends nothing", table.concat(mock.sent, " | "))
   shop.setConfirmAbove(nil)
   mock.sent = {}
   ok(mock.click(3), "clearing the limit lets the same click through")
   eq(#mock.sent, 2, "...and it is sent normally", table.concat(mock.sent, " | "))

   -- ---------------------------------------------------------------------------
   -- The ledger tracks what actually went out, for `emunah shop spent`.
   eq(shop.ledger.count, 5, "five purchases recorded (cr and the held one do not count)")
   ok(shop.ledger.total > 0, "a running gold total is kept", shop.ledger.total)
   eq(shop.ledger.log[1].id, "goldink386609", "the most recent purchase is first")

   -- ---------------------------------------------------------------------------
   -- A re-issued WARES for the SAME proprietor replaces that shop's listing rather than
   -- accumulating stale rows -- stock and prices move between visits.
   mock.links = {}
   mock.line("Proprietor: Seraph Myrddin D'Ischai, Page of Aeowynn.")
   wares({
      "          tun115258 an elixir of mana (refill only)             40     100gp",
   })
   eq(shop.find("tun115258").stock, 40, "a re-listed item's stock is updated")
   eq(shop.find("goldink386609"), nil,
      "an item missing from the new listing is gone -- the old one is not left stale")

   -- The purchase cap is a setting now (`emset shop.confirmAbove <gp>`), not a command.
   emunah.commands.dispatch("shop.confirmAbove 500")
   eq(shop.confirmAbove(), 500, "`emset shop.confirmAbove <gp>` sets the cap")

   -- ---------------------------------------------------------------------------
   -- A real transcript surfaced two more things: a shop can head a section with a plain
   -- "[Category]" (no dashes) instead of "[-[ Category ]-]", and rendering must never call
   -- deleteLine() -- WARES prints many rows in one packet, and deleting the current line
   -- while Mudlet is still working through lines that arrived in the same packet shifts
   -- the buffer under it (see shop.lua's render(), and pipes.lua's own note on the same
   -- bug). Reported in play as a shop's category header fusing onto its first item's line.
   local deletedBefore = mock.deletedLines
   mock.line("Proprietor: Yen Jaydde-Stormcrow, Grace Serene.")
   mock.line("[Elixirs]")
   wares({
      "          tun700001 an elixir of venom (refill only)            84     285gp",
   })
   eq(shop.find("tun700001").category, "Elixirs",
      "a plain '[Category]' header (no dashes) is recognised")
   eq(mock.deletedLines, deletedBefore, "rendering a listing never calls deleteLine()")
end

-- ===========================================================================
suite("affpop: walking AFFLICTION LIST -> AFFLICTION SHOW for every name")

-- `emunah affs` panels, `emunah learn`, and now this all exist because a hand-written table
-- is only as good as what it was checked against -- AFFLICTION LIST/SHOW is the game's own
-- reference data, confirmed live 21:02-21:03, and higher authority than memory or the
-- published help pages per docs/afflictions.md. This drives both commands rather than
-- waiting for them to be typed by hand -- "we'll need to send more a few times" -- so MORE
-- is answered automatically and every name gets its own AFFLICTION SHOW in turn.
do
   local detect = emunah.curing.detect
   detect.stopCapture()

   -- Starting the walk sends AFFLICTION LIST immediately. (No command any more: it is a
   -- development tool, reached from Lua -- emunah.curing.detect.startWalk().)
   mock.sent = {}
   detect.startWalk()
   eq(detect.walking, true, "...and starts the walk")
   ok(table.concat(mock.sent, " | "):find("affliction list", 1, true),
      "AFFLICTION LIST goes out first", table.concat(mock.sent, " | "))

   -- A page of names.
   mock.line("Accentato")
   mock.line("Addiction")
   mock.line("Aeon")

   -- MORE is answered without being asked twice.
   mock.sent = {}
   mock.line("[Type MORE if you wish to continue reading. (10% shown)]")
   ok(table.concat(mock.sent, " | "):find("more", 1, true),
      "MORE is answered on its own", table.concat(mock.sent, " | "))

   -- One more page, then silence -- no further MORE prompt.
   mock.line("Agoraphobia")
   eq(#detect.affpopNames(), 4, "all four names collected so far", #detect.affpopNames())

   -- Silence past AFFPOP_SETTLE reads as the list being finished, and starts AFFLICTION
   -- SHOW for the first name collected.
   mock.sent = {}
   mock.advance(3.0)
   ok(table.concat(mock.sent, " | "):find("affliction show Accentato", 1, true),
      "the list settling starts the show walk, first name first",
      table.concat(mock.sent, " | "))
   eq(detect.walking, true, "...still walking -- three names left")

   -- Paced, not bursted: the next name is not sent until the interval passes.
   mock.sent = {}
   mock.advance(0.5)
   eq(#mock.sent, 0, "nothing sent before the pacing interval is up",
      table.concat(mock.sent, " | "))
   mock.advance(1.5)
   ok(table.concat(mock.sent, " | "):find("affliction show Addiction", 1, true),
      "...then the second name, once it is", table.concat(mock.sent, " | "))

   -- Walk the rest out.
   mock.sent = {}
   mock.advance(1.5)
   mock.advance(1.5)
   ok(table.concat(mock.sent, " | "):find("affliction show Aeon", 1, true),
      "third name", table.concat(mock.sent, " | "))
   ok(table.concat(mock.sent, " | "):find("affliction show Agoraphobia", 1, true),
      "fourth and last name", table.concat(mock.sent, " | "))

   -- One more pace after the last name: walkNext finds nothing left and stops rather than
   -- sending a fifth AFFLICTION SHOW.
   mock.sent = {}
   mock.advance(1.5)
   eq(#mock.sent, 0, "nothing sent once the names are exhausted", table.concat(mock.sent, " | "))
   eq(detect.walking, false, "the walk ends once every name has been shown")

   detect.stopCapture()

   -- startWalk / stopCapture are the switch.
   mock.sent = {}
   detect.startWalk()
   eq(detect.walking, true, "startWalk starts the walk")
   detect.stopCapture()
   eq(detect.walking, false, "...and stopCapture stops it")
   eq(detect.capturing, false, "...capture too")
end

emunah.timers.stop("pipes.action")
emunah.timers.stop("pipes.poll")

-- Keep-up polls PIPELIST from the tick, so from here on it would add a `pipelist` to
-- mock.sent in any suite that advances past the poll interval -- which is how it broke the
-- manna step-budget count below. Switched off now that its own suite is done.
pipes.forget()
emunah.config.set("pipes.enabled", false)
emunah.timers.stop("pipes.poll.due")

-- ===========================================================================
suite("manna")

local manna = emunah.manna

-- The whole sequence, driven the way the game drives it: each step advances on Achaea's own
-- confirmation, and the wait between the rite and the GET is the equilibrium the rite spent.
emunah.curing.detect.onWake()
emunah.timers.stop("cure.equilibrium")
emunah.timers.stop("manna.step")
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
mock.sent = {}
ok(manna.start(), "manna starts")
eq(table.concat(mock.sent, " | "), "perform rite of sustenance",
   "step 1 goes out immediately", table.concat(mock.sent, " | "))

-- THE RITE SPENDS 3s OF EQUILIBRIUM, and GET needs it back. Char.Vitals goes on reporting
-- equilibrium as available until the game runs the command, so the flag alone is not enough
-- -- without the timer, `get bowl` would go straight out into "You must regain equilibrium
-- first." This is the reason the sequence is a module rather than three sends.
mock.line("A rain of nourishing manna falls from heaven, filling the bowl to the brim.")
mock.line("Equilibrium used: 3.00s.")
mock.sent = {}
mock.advance(manna.STEP_GUARD + 0.01)
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
eq(#mock.sent, 0, "step 2 waits out the equilibrium the rite spent",
   table.concat(mock.sent, " | "))

-- ...and goes the moment it is actually back.
mock.advance(3.0)
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
eq(table.concat(mock.sent, " | "), "get bowl", "step 2 goes when equilibrium returns",
   table.concat(mock.sent, " | "))

mock.line("You pick up an earthenware bowl.")
-- Advancing on the confirmation, not waiting for the next prompt.
eq(table.concat(mock.sent, " | "), "get bowl | drink bowl",
   "step 3 follows straight off the confirmation", table.concat(mock.sent, " | "))

mock.line("You feel utterly replete.")
ok(not manna.running(), "the sequence finishes on the last confirmation")

-- ---------------------------------------------------------------------------
-- The step triggers are scoped to the step they belong to. These are ordinary game lines --
-- drinking a bowl by hand must not advance a sequence nobody started.
mock.sent = {}
mock.line("You pick up an earthenware bowl.")
mock.line("You feel utterly replete.")
ok(not manna.running(), "confirmations do nothing while idle")
eq(#mock.sent, 0, "...and send nothing", table.concat(mock.sent, " | "))

-- A step that is never confirmed stops after ATTEMPTS rather than retrying forever: the
-- likely causes (no bowl, rite unavailable, an unknown cost) do not improve with a fourth try.
mock.sent = {}
manna.start()
for _ = 1, 12 do
   mock.advance(manna.STEP_GUARD + 0.01)
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
end
eq(#mock.sent, manna.ATTEMPTS, "an unconfirmed step stops after ATTEMPTS",
   table.concat(mock.sent, " | "))
ok(not manna.running(), "...and the sequence is abandoned")

-- The guard is what makes that budget mean three round trips rather than three prompts:
-- the 3s equilibrium wait would otherwise burn the whole budget before it was over.
emunah.timers.stop("cure.equilibrium")
mock.sent = {}
manna.start()
for _ = 1, 8 do mock.feed("Char.Vitals", { bal = "1", eq = "1" }) end
eq(#mock.sent, 1, "prompts during a step in flight do not count as attempts",
   table.concat(mock.sent, " | "))
manna.stop()

-- Blocked states hold it like any other command -- act.send() is the single gate.
emunah.curing.detect.onSleep()
mock.sent = {}
manna.start()
eq(#mock.sent, 0, "nothing goes out while asleep", table.concat(mock.sent, " | "))
emunah.curing.detect.onWake()
manna.stop()

-- Starting it twice does not restart it or double-send.
emunah.timers.stop("cure.equilibrium")
mock.sent = {}
manna.start()
ok(not manna.start(), "a second start is refused while one is running")
eq(#mock.sent, 1, "...and sends nothing extra", table.concat(mock.sent, " | "))
manna.stop()

-- The alias is what the user actually types. The rite above marked equilibrium spent on
-- send (Char.Vitals cannot report it yet), so give it back before asking for another.
emunah.timers.stop("cure.equilibrium")
emunah.timers.stop("manna.step")
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
mock.sent = {}
ok(mock.command("emset manna"), "'emset manna' is matched")
eq(table.concat(mock.sent, " | "), "perform rite of sustenance",
   "...and starts the sequence", table.concat(mock.sent, " | "))
manna.stop()

-- That last rite marked equilibrium spent and armed its 3s timer. Hand both back, or every
-- suite after this one starts without equilibrium.
emunah.timers.stop("cure.equilibrium")
emunah.timers.stop("manna.step")
mock.feed("Char.Vitals", { bal = "1", eq = "1" })

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

-- THE ATTACK IS A FINISHER, NOT THE KILL ROUTE. Damage-racing an opponent the whole fight
-- is exactly the strategy already established as unwinnable (see class/priest.lua's Zeal
-- header) -- afflictions are the route, and the attack only fires once the opponent is
-- already low enough that it becomes a realistic finishing blow. Checked against "smite"
-- specifically, not against mock.sent being empty -- verse-reciting is independent of this
-- gate (different resource entirely) and may legitimately fire the same tick; have.skill()
-- defaults permissive before the skill index completes, same as everywhere else in this file.
--
-- NOT health: IRE.Target.Info does not report a player opponent's vitals at all (confirmed
-- live 2026-08-06), so opponent.count() (curing/detect/opponent.lua) is the only signal
-- actually available to gate this on.
emunah.curing.detect.opponent.clear("sarapis")
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("smite"),
   "no attack while nothing is tracked on the opponent -- never a guess",
   table.concat(mock.sent, " | "))

emunah.curing.detect.opponent.assert("sarapis", "guilt")
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("smite"),
   "...nor with only one affliction tracked, below the finishing threshold",
   table.concat(mock.sent, " | "))

emunah.curing.detect.opponent.assert("sarapis", "justice")
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
local pvpAttack = table.concat(mock.sent, " | ")
ok(pvpAttack:find("smite sarapis"),
   "attacks once the opponent is vulnerable enough to finish", pvpAttack)

-- The threshold is the `pvp.attackAtAfflictions` setting.
emunah.commands.dispatch("pvp.attackAtAfflictions 3")
eq(emunah.config.get("pvp.attackAtAfflictions"), 3, "the threshold is configurable")
mock.sent = {}
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(not table.concat(mock.sent, " | "):find("smite"),
   "two afflictions no longer qualifies once the threshold is tightened to 3",
   table.concat(mock.sent, " | "))
emunah.config.set("pvp.attackAtAfflictions", 2)
emunah.curing.detect.opponent.clear("sarapis")

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
suite("Angel Sear + Rite of Desolation (Battlerage)")

-- Shipped defaults, explicitly -- the "bashing loop (Priest)" suite above pins smite on
-- purpose, for its own regression coverage. This suite is specifically about what actually
-- ships: Angel Sear replaced smite as the attack 2026-08-04, and Rite of Desolation was
-- added alongside it as a pre-attack Battlerage amplifier.
do
   bash.stop("test")
   emunah.timers.stopAll()
   emunah.config.set("bashing.attack", "angel sear")
   emunah.config.set("bashing.balance", "both")
   emunah.config.set("bashing.consumes", "eq")

   mock.feed("Char.Vitals", {
      hp = "4000", maxhp = "4000", mp = "3000", maxmp = "3000",
      bal = "1", eq = "1",
      charstats = { "Devotion: 100%", "Rage: 40", "Angelpower: 1500" },
   })

   -- ANGEL SEAR IS THE MIRROR IMAGE OF SMITE: requires both balance and equilibrium present
   -- (confirmed by the user, 2026-08-04 -- not assumed just because smite's own requirement
   -- happened to be "both" too), but spends only equilibrium, per HELP SEAR's "Cooldown:
   -- 2.50 seconds of equilibrium".
   mock.sent = {}
   emunah.class.attack("999")
   local searSent = table.concat(mock.sent, " | ")
   ok(searSent:find("angel sear 999"), "sends angel sear with the replica number", searSent)
   eq(emunah.gmcp.vitals.bal, true, "angel sear does not consume the balance it requires")
   eq(emunah.gmcp.vitals.eq, false, "...and does consume the equilibrium it announces")

   -- THE GUARD HAS TO FOLLOW WHAT IS ACTUALLY SPENT. Smite guarded attack.balance because it
   -- spent balance; sear spends equilibrium instead, so the pessimistic in-flight guard
   -- belongs on cure.equilibrium now -- the same timer penitence and `perform hands` arm --
   -- or canAttack()'s eq check never sees the in-flight window and the double-send this
   -- guard exists to close comes right back, just on the other resource.
   ok(not emunah.timers.ready("cure.equilibrium"),
      "sending angel sear arms the in-flight guard on cure.equilibrium")
   ok(emunah.timers.ready("attack.balance"),
      "...and leaves attack.balance alone -- sear never touches it")

   -- THE DOUBLE-SEND, on equilibrium this time. The game has not executed our attack yet,
   -- so Char.Vitals goes on truthfully reporting equilibrium as available until it does.
   mock.sent = {}
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })   -- the game's own pre-execution state
   eq(#mock.sent, 0, "a second angel sear is NOT sent while the first is still in flight",
      table.concat(mock.sent, " | "))

   -- The game's own announcement replaces the pessimistic guard with the real figure, via
   -- the SAME global "Equilibrium used:" trigger perform hands and penitence already rely
   -- on -- no sear-specific trigger needed in priest.lua.
   mock.line("Equilibrium used: 2.50s.")
   ok(not emunah.class.canAttack(), "the announced cooldown still blocks attacking immediately")
   mock.advance(2.50)
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
   ok(emunah.class.canAttack(), "equilibrium recovers on schedule with the announced cost")

   emunah.timers.stopAll()

   -- ------------------------------------------------------------------------
   -- Rite of Desolation
   -- ------------------------------------------------------------------------

   local priest = emunah.class.active

   -- Insufficient rage: HELP DESOLATION states the exact cost as 36, and nothing below it
   -- is enough.
   mock.feed("Char.Vitals", { charstats = { "Rage: 35", "Devotion: 100%" } })
   ok(not priest.shouldDesolation("999"), "35 rage is not enough -- HELP states the cost as 36")

   mock.feed("Char.Vitals", { charstats = { "Rage: 36", "Devotion: 100%" } })
   ok(priest.shouldDesolation("999"), "36 rage is exactly enough")

   -- Its own cooldown, not balance or equilibrium: still blocked even with both free,
   -- because HELP states 23s as a flat ability cooldown, not "of balance"/"of equilibrium".
   emunah.timers.start("bashing.desolation", 23.0)
   ok(not priest.shouldDesolation("999"), "on its own cooldown, desolation is refused")

   -- Regression: confirmed live 2026-08-04 -- Achaea announces the cooldown's end directly,
   -- unprompted, rather than leaving it to the flat 23.00s guess alone. "You can use
   -- Desolation again." clears the guard early.
   mock.line("You can use Desolation again.")
   ok(priest.shouldDesolation("999"),
      "the announcement clears the cooldown guard, whatever the flat guess said")

   -- The OTHER announcement means the same thing for the cooldown -- it too says the 23s is
   -- over -- but adds that rage specifically is what is missing. shouldDesolation()'s own
   -- rage floor already covers that independently, so this still clears the same guard.
   emunah.timers.start("bashing.desolation", 23.0)
   mock.feed("Char.Vitals", { charstats = { "Rage: 10", "Devotion: 100%" } })
   mock.line("Your Desolation ability could be used again but you lack the necessary Rage.")
   ok(emunah.timers.ready("bashing.desolation"),
      "the cooldown guard clears on this announcement too")
   ok(not priest.shouldDesolation("999"),
      "...but shouldDesolation still refuses -- 10 rage is not the 36 the ability needs")
   mock.feed("Char.Vitals", { charstats = { "Rage: 36", "Devotion: 100%" } })

   emunah.timers.stop("bashing.desolation")

   -- Opt-out, same shape as bashing.penitence.
   emunah.config.set("bashing.desolation", false)
   ok(not priest.shouldDesolation("999"), "bashing.desolation=false disables it")
   emunah.config.set("bashing.desolation", true)

   ok(priest.shouldDesolation("999"),
      "eligible again once rage, cooldown and the toggle all allow it")

   mock.sent = {}
   ok(priest.desolation("999"), "desolation() sends successfully")
   local desoSent = table.concat(mock.sent, " | ")
   ok(desoSent:find("perform rite of desolation on 999"),
      "sends the exact PERFORM RITE OF DESOLATION ON <target> syntax from HELP DESOLATION",
      desoSent)
   ok(not emunah.timers.ready("bashing.desolation"), "sending it arms its own 23s cooldown")
   eq(emunah.timers.remaining("bashing.desolation"), 23.0,
      "...for the flat figure HELP states -- there is no game announcement to wait for")

   emunah.timers.stopAll()

   -- ------------------------------------------------------------------------
   -- Sequencing: sent BEFORE the next angel sear, exactly as asked for -- the same
   -- "amplify first, then return" slot penitence occupies in bashing.tick().
   -- ------------------------------------------------------------------------

   den2.clearEngaged()
   mock.feed("Room.Info", { num = 900, name = "Rage room", area = "Minia", exits = { n = 901 } })
   mock.feed("Char.Items.List", {
      location = "room",
      items = { { id = "424242", name = "a pixie", attrib = "m" } },
   })
   den2.setWanted("a pixie", true)
   mock.feed("Char.Vitals", {
      hp = "4000", maxhp = "4000", bal = "1", eq = "1",
      charstats = { "Rage: 40", "Devotion: 100%" },
   })

   mock.sent = {}
   ok(bash.start(), "bashing starts with a fresh target")
   local firstTick = table.concat(mock.sent, " | ")
   ok(firstTick:find("perform rite of desolation on 424242"),
      "desolation goes out first, ahead of the attack it was asked to precede", firstTick)
   ok(not firstTick:find("angel sear"),
      "...and angel sear does not also go out the same tick", firstTick)

   -- Next tick: desolation is now on its own cooldown, so the attack it was blocking goes
   -- out in its place.
   mock.sent = {}
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
   local secondTick = table.concat(mock.sent, " | ")
   ok(secondTick:find("angel sear 424242"),
      "angel sear follows once desolation is on cooldown", secondTick)

   -- Regression: reported live 2026-08-04 -- "eq back but the follow-on attack doesn't
   -- happen for a bit". bashing's immediate-retick wiring only listened for attack.balance
   -- to expire, which was invisible while smite (spends balance) was the only attack ever
   -- configured. Angel Sear spends equilibrium instead and guards cure.equilibrium, so the
   -- follow-on attack sat waiting for some UNRELATED event to produce the next prompt --
   -- the exact "three quarters of a second per swing, for nothing" bug already fixed once
   -- for attack.balance, recurring on the other resource. Same shape as the equivalent
   -- smite/attack.balance regression test above.
   emunah.timers.stopAll()
   mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })
   emunah.class.attack("424242")   -- arms cure.equilibrium's pessimistic guard
   mock.line("Equilibrium used: 2.50s.")   -- the real cost, same as live play
   ok(not emunah.class.canAttack(), "the announced cooldown blocks attacking right after")

   -- Simulate the exact failure mode: vitals.eq reporting ready again -- from the server's
   -- own honest recovery -- before any OTHER Char.Vitals push happens to arrive and give
   -- bashing a reason to look.
   emunah.gmcp.vitals.eq = true
   ok(not emunah.class.canAttack(),
      "...even when vitals.eq itself says ready, the announced cooldown still blocks it")

   mock.sent = {}
   mock.advance(2.50)   -- the timer lapsing alone must wake bashing -- no Char.Vitals push
   local wokeOnLapse = table.concat(mock.sent, " | ")
   ok(wokeOnLapse:find("angel sear 424242"),
      "the cooldown lapsing attacks immediately, without waiting for an unrelated prompt",
      wokeOnLapse)

   bash.stop("test")
   emunah.timers.stopAll()
end

-- ===========================================================================
suite("Zeal verses (Guilt, Condemnation)")

-- Scoped: Lua 5.1 caps a function at 200 active locals, and this file is one chunk. Reuses
-- the outer `bash`, `pvp`, `den2` locals declared earlier in the file rather than
-- redeclaring them.
do
   local priest = emunah.class.active
   bash.stop("test")
   pvp.stop("test")
   emunah.timers.stopAll()

   mock.feed("Char.Skills.Groups", { { name = "Zeal", rank = "Adept" } })
   mock.feed("Char.Skills.List", { group = "Zeal", list = { "Guilt", "Condemnation" } })
   ok(emunah.have.skill("guilt"), "guilt is known")
   ok(emunah.have.skill("condemnation"), "condemnation is known")

   mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })

   -- An unmodeled verse (everything past Unflinching, at last check) is refused outright --
   -- M.VERSES only lists what has actually been confirmed live.
   ok(not priest.canRecite("ash"), "an unmodeled verse is refused before anything is sent")

   -- canRecite() actually goes through have.skill(), not its own bookkeeping -- the same
   -- denial override the clotting tests already exercise (see M.denySkill()).
   emunah.have.denySkill("guilt")
   ok(not priest.canRecite("guilt"), "a denied skill refuses even though the index lists it")
   emunah.event.raise("skills.complete")   -- a fresh index round trip clears every denial
   ok(priest.canRecite("guilt"), "...and the denial clears with it")

   -- SENDING: exact syntax from HELP CONDEMNATION, confirmed live 2026-08-05.
   mock.sent = {}
   ok(priest.recite("condemnation", "Ashden"), "recite() sends successfully")
   local recited = table.concat(mock.sent, " | ")
   ok(recited:find("recite condemnation Ashden"),
      "sends the exact RECITE CONDEMNATION <target> syntax from HELP CONDEMNATION", recited)

   -- PRAYER BALANCE IS ITS OWN RESOURCE -- arming its guard must not touch attack.balance or
   -- cure.equilibrium, which the attack itself still needs; both can go out the same tick.
   ok(not emunah.timers.ready("pvp.prayer"), "reciting arms the pvp.prayer guard")
   ok(emunah.timers.ready("attack.balance"), "...and leaves attack.balance alone")
   ok(emunah.timers.ready("cure.equilibrium"), "...and leaves cure.equilibrium alone too")
   ok(not priest.canRecite("guilt"),
      "the same prayer-balance guard blocks every verse, not just the one just sent")

   -- NOT a "Balance used: N.NNs." announcement -- confirmed live, neither cast produced one.
   -- The real confirmation is "You may speak another holy verse.", the same shape as the
   -- herb/elixir readiness lines, and it clears the guard early exactly like every other
   -- announced cost in this file.
   mock.line("You may speak another holy verse.")
   ok(priest.canRecite("guilt"), "the real confirmation clears the guard early")

   -- ANOINT ASH IS A PREREQUISITE, NOT A COST. Confirmed live 2026-08-05: this refusal
   -- produced no "You may speak another holy verse." either time -- nothing was spent, so the
   -- guard should not be held for its full pessimistic duration.
   mock.sent = {}
   priest.recite("guilt", "Ashden")
   ok(not emunah.timers.ready("pvp.prayer"), "sending still arms the pessimistic guard first")
   mock.echoed = {}
   mock.line("You have not anointed yourself with holy ash; see AB ZEAL ANOINT for the path "
      .. "you must walk.")
   ok(emunah.timers.ready("pvp.prayer"), "the anoint refusal clears the guard -- nothing spent")
   ok(table.concat(mock.echoed, " "):find("not anointed"),
      "...and says why, once, rather than failing silently forever",
      table.concat(mock.echoed, " "))

   emunah.timers.stopAll()

   -- ------------------------------------------------------------------------
   -- pvp.lua: verses fire alongside the attack, on an independent resource
   -- ------------------------------------------------------------------------

   den2.clearEngaged()
   mock.feed("Room.Info", { num = 950, name = "Zeal room", area = "Minia", exits = {} })
   mock.feed("Room.Players", {})
   mock.feed("Char.Vitals", {
      hp = "4000", maxhp = "4000", mp = "3000", maxmp = "3000",
      bal = "1", eq = "1", charstats = { "Devotion: 100%" },
   })
   emunah.config.set("bashing.attack", "smite")
   emunah.config.set("bashing.balance", "both")
   emunah.config.set("bashing.consumes", "bal")

   mock.sent = {}
   ok(pvp.start(), "pvp starts")
   pvp.setTarget("Ashden")
   -- The attack is a finisher now, not the kill route -- gated on the opponent's tracked
   -- affliction load (not health; IRE.Target.Info does not report a player's vitals), so it
   -- needs enough tracked before it fires at all (see pvp.lua).
   emunah.curing.detect.opponent.assert("ashden", "guilt")
   emunah.curing.detect.opponent.assert("ashden", "justice")
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
   local bothSent = table.concat(mock.sent, " | ")
   ok(bothSent:find("smite ashden"), "the attack still goes out", bothSent)
   ok(bothSent:find("recite condemnation ashden"),
      "...and a verse goes out the SAME tick -- different resources, no conflict", bothSent)
   eq(pvp.report().recited, 1, "the recite is counted")

   -- Condemnation is preferred over guilt whenever both are ready -- HELP states its
   -- affliction outright, where guilt's payoff depends on the target choosing to focus.
   emunah.timers.stopAll()
   mock.sent = {}
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
   ok(table.concat(mock.sent, " | "):find("recite condemnation"),
      "condemnation is tried first when both verses are ready",
      table.concat(mock.sent, " | "))

   -- The opt-out, same shape as bashing.penitence / bashing.desolation.
   emunah.timers.stopAll()
   emunah.config.set("pvp.verses", false)
   mock.sent = {}
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
   ok(not table.concat(mock.sent, " | "):find("recite"),
      "pvp.verses=false disables reciting entirely", table.concat(mock.sent, " | "))
   emunah.config.set("pvp.verses", true)

   pvp.stop("test")
   emunah.timers.stopAll()

   -- ------------------------------------------------------------------------
   -- The attack yields to `perform hands` rather than starving it
   -- ------------------------------------------------------------------------
   --
   -- The attack sends directly the instant its own resources are free, bypassing the
   -- priority queue perform hands shares with every other cure -- so an active PvP session
   -- attacking every tick could keep re-claiming equilibrium before the queue ever got a
   -- turn to send the heal it already wanted.

   emunah.config.set("bashing.attack", "smite")
   emunah.config.set("bashing.balance", "both")
   emunah.config.set("bashing.consumes", "bal")
   -- Disabled so pvp's OWN health-threshold stop (unsafe(), default 60%) cannot fire first
   -- and confound what this is actually testing -- the attack yielding to a queued heal
   -- while still fully engaged, not the separate safety stop.
   emunah.config.set("pvp.stopBelowHealth", 0)
   local handsAt = tonumber(emunah.config.get("curing.handsThreshold", 50)) or 50

   mock.feed("Char.Vitals", {
      hp = tostring(handsAt + 10), maxhp = "100", bal = "1", eq = "1",
   })
   pvp.start()
   pvp.setTarget("Ashden")
   emunah.curing.detect.opponent.assert("ashden", "guilt")
   emunah.curing.detect.opponent.assert("ashden", "justice")
   mock.sent = {}
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
   ok(table.concat(mock.sent, " | "):find("smite"),
      "above the hands threshold, the attack goes out as normal", table.concat(mock.sent, " | "))

   mock.feed("Char.Vitals", { hp = tostring(handsAt - 10), maxhp = "100" })
   mock.sent = {}
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
   ok(not table.concat(mock.sent, " | "):find("smite"),
      "below the hands threshold, the attack yields instead of re-claiming equilibrium",
      table.concat(mock.sent, " | "))

   pvp.stop("test")
   emunah.timers.stopAll()
   emunah.config.set("pvp.stopBelowHealth", 60)
   emunah.config.set("bashing.attack", "angel sear")
   emunah.config.set("bashing.balance", "both")
   emunah.config.set("bashing.consumes", "eq")
   mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })
end

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

-- Guilt's cure line, confirmed live 2026-08-05 (see class/priest.lua's Zeal-verses header).
mock.line("Ashena straightens, as if some great burden had been lifted from her shoulders.")
ok(not opponent.has("ashena", "guilt"), "the real guilt cure pattern retracts rather than asserts")
opponent.assert("ashena", "guilt")
mock.line("Ashena straightens, as if some great burden had been lifted from her shoulders.")
ok(not opponent.has("ashena", "guilt"), "...and actually retracts an asserted guilt")

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
ok(table.concat(mock.echoed, " "):find("emset keys.numpad true", 1, true),
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
-- Action keys: Ctrl+F5 reload, F11 hunt on, F12 hunt off. Independent of keys.numpad and of
-- the Keypad modifier -- see keys.buildActions(). Own registry, own count().
eq(emunah.keys.actionCount(), 3, "reload, hunt on, hunt off all bound")

-- Scoped: Lua 5.1 caps a function at 200 active locals, and this file is one chunk.
do
   -- Stub rather than let it really re-run the loader chunk mid-suite: a real emreload here
   -- would swap out every emunah.* module table in place, and every suite from here on holds
   -- locals captured before that point.
   local realReload = _G.emunahReload
   local reloadCalls = 0
   _G.emunahReload = function() reloadCalls = reloadCalls + 1 end
   ok(mock.press(mudlet.keymodifier.Control, mudlet.key.F5), "Ctrl+F5 is bound")
   eq(reloadCalls, 1, "Ctrl+F5 calls emunahReload()")
   _G.emunahReload = realReload
end

ok(not mock.press(mudlet.keymodifier.None, mudlet.key.F5),
   "plain F5 (no Control modifier) is NOT bound -- only Ctrl+F5 is")

-- F11 starts the hunt (walk + bash together); F12 stops both. The keys just dispatch
-- `emunah hunt` / `emunah hunt off`, so this is really exercising that command.
mock.feed("Room.Info", { num = 1, name = "Room 1", area = "Test", exits = { e = 2 } })
mock.feed("Char.Items.List", {
   location = "room",
   items = { { id = "9002", name = "a pixie", attrib = "m" } },
})
mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })
ok(not emunah.walker.enabled and not emunah.bashing.enabled, "hunt is off to start")
mock.press(mudlet.keymodifier.None, mudlet.key.F11)
ok(emunah.walker.enabled and emunah.bashing.enabled, "F11 starts the hunt")

mock.press(mudlet.keymodifier.None, mudlet.key.F12)
ok(not emunah.walker.enabled and not emunah.bashing.enabled, "F12 stops the hunt")

-- Nothing running: says so rather than doing nothing silently, same fix as plain
-- `emunah hunt off`.
mock.echoed = {}
mock.press(mudlet.keymodifier.None, mudlet.key.F12)
ok(table.concat(mock.echoed, " "):find("not running"),
   "F12 with nothing running says so", table.concat(mock.echoed, " "))

-- ===========================================================================
suite("commands")

for _, command in ipairs({ "status", "affs", "have", "detect", "defs", "help", "shop" }) do
   local commandOk, commandErr = pcall(emunah.commands.dispatch, command)
   ok(commandOk, "emunah " .. command .. " runs", commandErr)
end

ok(pcall(emunah.commands.dispatch, ""), "bare dispatch (the quick reference) runs")

-- GMCP tracing. Its own switch rather than part of the debug level: Char.Vitals arrives with
-- every prompt, so folding it in would bury whatever you turned debug on to see. Defaults OFF
-- (module state, not persisted config -- see the note in core/log.lua) -- a fresh session
-- used to open with the firehose already running before anyone asked for it.
eq(emunah.log.traceGmcp, false, "GMCP tracing is off by default")
emunah.commands.dispatch("debug gmcp")
eq(emunah.log.traceGmcp, true, "...and 'emunah debug gmcp' turns it on")

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
suite("a malformed GMCP payload cannot break its own trace")

-- Comm.Channel.Text carries RAW ANSI, including IRE's own ESC...EOT terminator that
-- gmcp/comm.lua documents having to strip before render (see its header comment). log.gmcp
-- used to hand the raw payload straight to cecho, which reads a bare "<" as colour markup
-- and cannot be trusted with a raw control byte either. Reported from play: with tracing
-- on (the default), channel messages rendered NOWHERE -- not the trace line, not the chat
-- window -- and turning tracing off was the whole fix from the outside. That is because the
-- failure happened inside log.gmcp itself, in the wrapper `event.gmcp()` builds, which
-- calls it BEFORE the real handler -- so a cecho that throws here takes onText() down with
-- it, and the message never reaches gmcp/comm.lua's own history buffer either.
--
-- Reproduced with a fake cecho that fails on exactly the bytes that broke the real one, so
-- this test would have caught the original report and fails again if sanitize() is ever
-- weakened back to a straight cecho(summarise(payload)).
do
   emunah.log.traceGmcp = true
   local realCecho = _G.cecho
   _G.cecho = function(text)
      -- Every log line has a deliberate leading "\n" (see core/log.lua); only control bytes
      -- past it are the ones a real payload could have smuggled in.
      if tostring(text):sub(2):find("%c") then
         error("simulated cecho failure on a raw control byte", 0)
      end
      realCecho(text)
   end

   local historyBefore = #emunah.gmcp.comm.history
   local succeeded = pcall(mock.feed, "Comm.Channel.Text", {
      channel = "ct",
      talker  = "Someone",
      -- A stray "<" (anything a channel message can contain) plus IRE's own ESC...EOT
      -- terminator, verbatim.
      text    = "hello < there" .. string.char(27) .. "[0m" .. string.char(4),
   })
   ok(succeeded,
      "a payload cecho cannot render does not take the GMCP handler down with it")
   eq(#emunah.gmcp.comm.history, historyBefore + 1,
      "...and the message is still captured into history regardless")

   _G.cecho = realCecho
   emunah.commands.dispatch("debug gmcp")
   eq(emunah.log.traceGmcp, false, "tracing left off, as the rest of the suite expects")
end

-- ===========================================================================
suite("ui/echo.lua: combatEcho, oecho, createLineGradient, eventLabel")

-- Wrapped in its own function, not a bare `do...end` block: this file is one giant chunk
-- and Lua 5.1 caps a single function at 200 local variables. A `do...end` block is not a
-- function -- its locals still count against the enclosing chunk's budget -- so a real
-- (immediately-invoked) function is what actually resets the count.
;(function()
   local echo = emunah.ui.echo

   ok(pcall(echo.combatEcho, "you have been slain", "red"),
      "combatEcho runs without error")
   ok(pcall(echo.combatEcho, ""), "combatEcho on an empty string is a no-op, not an error")

   local gradient = echo.createLineGradient(true, 5)
   eq(select(2, gradient:gsub("|c%x%x%x%x%x%x%-", "")), 5,
      "createLineGradient emits one |cRRGGBB- escape per requested width")

   ok(pcall(echo.oecho, "keep-up on", "defence"), "oecho runs without error")

   -- eventLabel/clearEventLabel need Geyser; refreshPauseBanner is exercised separately
   -- below, once curing/defkeepup exist to read state from.
   mock.installGeyser()

   local widget = echo.eventLabel("test", "hello", { colour = "danger" })
   ok(widget ~= nil, "eventLabel builds a Geyser.Label")
   ok(mock.widgets["emunah.eventlabel.test"] ~= nil,
      "...under a name derived from its key")
   ok(mock.widgets["emunah.eventlabel.test"].shown, "...and shows it")

   echo.eventLabel("test", "updated", { colour = "danger" })
   local count = 0
   for name in pairs(mock.widgets) do
      if name == "emunah.eventlabel.test" then count = count + 1 end
   end
   eq(count, 1, "a second call with the same key updates the label rather than duplicating it")

   ok(echo.clearEventLabel("test"), "clearEventLabel removes the tracked label")
   ok(not mock.widgets["emunah.eventlabel.test"].shown,
      "...and hides the underlying widget")
   ok(not echo.clearEventLabel("test"), "clearEventLabel on an already-cleared key reports false")

   -- Width tracks the string, not a fixed box: a short label stays small, a long one gets
   -- the room it needs.
   echo.eventLabel("short", "*PAUSED*")
   echo.eventLabel("long", "*PAUSED* (curing + keep-up)")
   ok(mock.widgets["emunah.eventlabel.long"].cons.width
      > mock.widgets["emunah.eventlabel.short"].cons.width,
      "eventLabel width scales with the length of the text")
   echo.clearEventLabel("short")
   echo.clearEventLabel("long")

   -- Centred on the game console (between the left afflictions panel and the right
   -- chat/room panel, 17%/26% of the 1920px mock window), not on the window as a whole --
   -- otherwise the banner sits visibly right of the text it is meant to be sitting over,
   -- since the right panel is wider than the left one.
   echo.eventLabel("centred", "** PAUSED **")
   local w = mock.widgets["emunah.eventlabel.centred"]
   local labelCentre = w.cons.x + w.cons.width / 2
   ok(math.abs(labelCentre - 873.6) < 2,
      "eventLabel is centred on the console gap, not the full window", labelCentre)
   ok(math.abs(labelCentre - 960) > 50,
      "...which is measurably off the window's own centre", labelCentre)
   echo.clearEventLabel("centred")

   -- The *PAUSED* banner: on with both curing and keep-up running, on again the instant
   -- either one stops.
   emunah.curing.engine.start()
   emunah.curing.defkeepup.start()
   echo.refreshPauseBanner()
   ok(not (mock.widgets["emunah.eventlabel.paused"]
      and mock.widgets["emunah.eventlabel.paused"].shown),
      "no paused banner while curing and keep-up are both on")

   emunah.curing.engine.stop()
   ok(mock.widgets["emunah.eventlabel.paused"] and mock.widgets["emunah.eventlabel.paused"].shown,
      "stopping curing alone raises the paused banner (event-driven, not a manual refresh)")
   ok(mock.widgets["emunah.eventlabel.paused"].contents:find("** PAUSED **", 1, true) ~= nil,
      "...and it says ** PAUSED **")

   emunah.curing.defkeepup.stop()
   echo.refreshPauseBanner()
   ok(mock.widgets["emunah.eventlabel.paused"].contents:find("** PAUSED **", 1, true) ~= nil
      and not mock.widgets["emunah.eventlabel.paused"].contents:find("curing", 1, true),
      "...same fixed text whether one or both are off, never naming which")

   emunah.curing.defkeepup.start()
   emunah.curing.engine.start()
   ok(not mock.widgets["emunah.eventlabel.paused"].shown,
      "resuming curing clears the banner again")

   mock.uninstallGeyser()
end)()

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

-- ONE PREFIX. `emunah` was the long form of emset; it is gone like `!` before it, and the
-- old bare shortcuts with it. All of them now go to the game untouched.
for _, word in ipairs({ "emunah", "emunah status", "pp", "emdefs", "ndb", "pipes", "manna",
                        "affpop" }) do
   ok(not mock.command(word), ("'%s' is no longer claimed"):format(word))
end
eq(#dispatched, 0, "none of them reached the dispatcher")

-- THERE IS NO `!` PREFIX, and this asserts its absence rather than merely not testing it.
--
-- It used to be a second universal prefix meaning exactly what `emunah` means. Two spellings
-- for every command meant everything documenting one had to pick a side, and they picked
-- differently -- the in-game help said `!`, the website said `emunah`, the README said both.
-- Removing it is what makes `emhelp` able to state one syntax per command.
--
-- `!` must now fall through to the game untouched, like any other unclaimed input. A stale
-- alias surviving a reload would be invisible otherwise: it would keep working, and nothing
-- would notice the two prefixes had diverged again.
dispatched = {}
ok(not mock.command("!"), "bare '!' is no longer an alias -- it goes to the game")
ok(not mock.command("!status"), "'!status' is not claimed either")
ok(not mock.command("! status"), "...nor '! status'")
eq(#dispatched, 0, "none of them reached the dispatcher")

-- `emset` is what replaced it: the same dispatcher under a word rather than punctuation,
-- in the `em` family this package already owns (emhelp, emdefs, emreload).
dispatched = {}
ok(mock.command("emset"), "bare 'emset' is matched by an alias")
eq(dispatched[#dispatched], "", "bare 'emset' dispatches with an empty argument")

ok(mock.command("emset status"), "'emset status' is matched")
eq(dispatched[#dispatched], "status", "argument is captured")

ok(mock.command("emset prio paralysis herb 1"), "multi-word arguments are matched")
eq(dispatched[#dispatched], "prio paralysis herb 1", "full argument string is captured")

-- It must not swallow the bare commands that merely start with the same letters.
dispatched = {}
ok(not mock.command("emsetting nonsense"), "'emsetting' is not claimed by the emset alias")
eq(#dispatched, 0, "...and did not reach the dispatcher")

emunah.commands.dispatch = realDispatch

-- 'pp' pauses/resumes curing AND defence keep-up together (M.handlers.pause in
-- commands.lua) -- replaces the old 'ec' alias, which only touched curing.
emunah.curing.engine.start()
emunah.curing.defkeepup.start()
ok(mock.command("emset pause"), "'emset pause' is matched")
ok(not emunah.curing.engine.enabled, "pp pauses curing when both were on")
ok(not emunah.curing.defkeepup.enabled, "pp pauses defence keep-up when both were on")

ok(mock.command("emset pause"), "'pp' toggles back")
ok(emunah.curing.engine.enabled, "pp resumes curing")
ok(emunah.curing.defkeepup.enabled, "pp resumes defence keep-up")

-- pp treats "either one off" as paused, so one call always lands on a clean state rather
-- than drifting further apart.
emunah.curing.engine.stop()
emunah.curing.defkeepup.start()
mock.command("emset pause")
ok(emunah.curing.engine.enabled, "pp resumes curing when only curing was off")
ok(emunah.curing.defkeepup.enabled, "pp leaves defence keep-up on when only curing was off")
ok(not mock.command("emote waves"), "an unrelated command is NOT swallowed by our aliases")

-- ===========================================================================
suite("loot: the room is held until the gold is off the floor")

-- LAST SUITE ON PURPOSE. It drives bashing and the walker through a real kill-and-loot
-- cycle, which leaves the walker mid-route and denizens marked dealt-with -- state that a
-- following suite would inherit. Isolating it here is cheaper and clearer than unpicking
-- every field it touches.

-- Wrapped in a function of its own: the main chunk is at Lua 5.1's 200-local ceiling, and
-- a closure gets its own scope and its own budget.
;(function()

local bash = emunah.bashing
local den2 = emunah.denizens

-- ===========================================================================
-- DO NOT WALK OUT ON THE GOLD.
--
-- Reported in play as "we don't pick up gold after killing all mobs and leaving the room",
-- and it was a race rather than a broken pickup. The last kill clears the room and spills
-- the gold in the same instant, but GET costs the balance and equilibrium the killing blow
-- has just spent -- so M.take() is refused and the retry waits on `balance.gained`. Bashing
-- meanwhile declared the room clear on the very next prompt and the walker left, so the
-- retry fired in the room we had walked into. Every kill's gold was abandoned unless the
-- balance happened to already be back.
do
   mock.installMap(20)          -- rooms 1..20; anything outside that cannot be walked
   bash.stop("test")
   emunah.walker.stop("test", true)   -- emergency: no walk home to leave in flight

   emunah.loot.attempted = {}
   emunah.loot.creditUntil = nil
   emunah.config.set("loot.gold", true)
   -- The narrow rule is off by default; assert against the shipped behaviour.
   emunah.config.set("loot.ownKillsOnly", false)

   -- START WITH SOMETHING TO KILL. An empty room is declared clear by the tick inside
   -- bash.start() itself, which asks the walker to move before any gold could exist -- so a
   -- test set up that way never reaches the hold at all. The real sequence is a denizen
   -- dying and the corpse spilling in the same burst of Char.Items messages, ahead of the
   -- next prompt, which is what this models.
   mock.feed("Room.Info", { num = 5, name = "Gold room", area = "Test", exits = { e = 6 } })
   mock.feed("Char.Items.List", {
      location = "room",
      items = { { id = "80001", name = "a pixie", attrib = "m" } },
   })
   mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })

   den2.setWanted("a pixie", true)
   -- Walker first, then bashing -- the order the rest of this suite uses. Starting the
   -- walker after bashing has claimed it leaves a step timer scheduled that outlives this
   -- block and auto-steps inside a later test.
   emunah.walker.start()
   bash.start()

   -- Without these the "is it held?" assertions below would pass for the wrong reason:
   -- roomClear() returns early whenever the walker is not running.
   ok(bash.enabled, "bashing is running, so roomClear() is actually reachable")
   ok(emunah.walker.enabled, "...and the walker is enabled, so a move could really happen")

   local left = false
   emunah.event.register("emunah.walker.move", function() left = true end, "test.loot")

   -- The kill lands: the denizen leaves the room, the killing blow has spent balance and
   -- equilibrium -- which is exactly what GET needs -- and then the corpse spills.
   --
   -- The spend is fed explicitly rather than left to whatever the attack happened to do,
   -- so this asserts the behaviour under a KNOWN state. Note the prompt in the middle: it
   -- declares the room clear before the gold exists, which is the harder of the two
   -- orderings and the one the movedFrom guard used to swallow.
   mock.feed("Char.Items.Remove", { location = "room", item = { id = "80001" } })
   mock.feed("Char.Vitals", { bal = "0", eq = "0" })
   mock.feed("Char.Items.Add", {
      location = "room",
      item = { id = "90001", name = "a few golden sovereigns", attrib = "t" },
   })

   ok(emunah.loot.pending(), "gold on the floor is pending while it cannot yet be lifted")

   -- THE REGRESSION. Before the fix this prompt raised walker.move and the gold was lost.
   left = false
   mock.sent = {}
   mock.feed("Char.Vitals", { bal = "0", eq = "0" })
   ok(not left, "the room is HELD rather than handed back to the walker")
   ok(not emunah.util.contains(mock.sent, "get 90001"),
      "...and no GET goes out while the resources for it are spent")

   -- Balance and equilibrium return: the pickup becomes possible, and the room stops being
   -- worth holding, both on this same prompt.
   left = false
   mock.sent = {}
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
   ok(emunah.util.contains(mock.sent, "get 90001"),
      "the pile is taken the moment balance and equilibrium are back",
      table.concat(mock.sent, " | "))
   ok(not emunah.loot.pending(), "nothing left pending once it has been taken")
   ok(left, "...and only THEN is the walker told to move on")

   -- THE HOLD IS BOUNDED. loot.pending() answers false for anything permanently refused,
   -- but a miscategorised case must cost seconds, not the rest of the session -- the same
   -- argument as the attempt budgets in curing/engine.lua.
   bash.stop("test")
   emunah.walker.stop("test", true)   -- emergency: no walk home to leave in flight
   emunah.loot.attempted = {}
   mock.feed("Room.Info", { num = 8, name = "Stuck room", area = "Test", exits = { e = 9 } })
   mock.feed("Char.Items.List", {
      location = "room",
      items = { { id = "80002", name = "a pixie", attrib = "m" } },
   })
   mock.feed("Char.Vitals", { hp = "4000", maxhp = "4000", bal = "1", eq = "1" })
   emunah.walker.start()
   bash.start()

   -- This sub-test isolates the BOUND rather than the kill sequence, so the state is set up
   -- directly: room clear, gold down, and the resources GET needs never coming back. The
   -- spend is fed before the pile so the first sweep is refused -- with balance up the gold
   -- is simply taken, which is the other test.
   mock.feed("Char.Items.Remove", { location = "room", item = { id = "80002" } })
   mock.feed("Char.Vitals", { bal = "0", eq = "0" })
   mock.feed("Char.Items.Add", {
      location = "room",
      item = { id = "90002", name = "a pile of gold sovereigns", attrib = "t" },
   })
   ok(emunah.loot.pending(), "the pile is pending, so the bound has something to bound")

   left = false
   mock.feed("Char.Vitals", { bal = "0", eq = "0" })
   ok(not left, "still held inside the bound")

   -- Cleared BEFORE the advance: timers firing inside it can drive a prompt of their own,
   -- and the move we are asserting on is allowed to happen there rather than on the feed.
   left = false
   mock.advance(bash.LOOT_WAIT + 0.5)
   mock.feed("Char.Vitals", { bal = "0", eq = "0" })
   ok(left, "the hold expires -- gold is never allowed to stall the hunt")

   -- A pile nobody may take is not worth holding for at all, or the hunt would stop dead
   -- for four seconds in every room containing somebody else's loot.
   emunah.config.set("loot.ownKillsOnly", true)
   emunah.loot.creditUntil = nil          -- no kill of ours credited it
   emunah.loot.attempted = {}
   ok(not emunah.loot.pending(),
      "gold that is not ours is not pending, so the room is never held for it")
   emunah.config.set("loot.ownKillsOnly", false)

   bash.stop("test")
   emunah.walker.stop("test", true)   -- emergency: no walk home to leave in flight
   emunah.event.kill("test.loot")
end

end)()

-- ===========================================================================
suite("D4: log.toggled() -- the on/off confirmation line, shared")

-- Six modules (curing, defence keep-up, bashing, PvP, name highlighting) had already
-- converged independently on "<Label> <green>on<yellow>." / "<Label> <red>off<yellow>.".
-- commands.lua's `ui`/`debug` handlers and curing/detect/init.lua's learn/affpop messages
-- each had their own different wording; all four now go through this one helper.
;(function()
mock.echoed = {}
emunah.log.toggled("Curing", true)
local onLine = table.concat(mock.echoed, " ")
ok(onLine:find("Curing <ansi_light_green>on<ansi_yellow>%.", 1, false)
   or onLine:find("Curing <ansi_light_green>on<ansi_yellow>."),
   "log.toggled(label, true) matches the pattern six modules already use", onLine)

mock.echoed = {}
emunah.log.toggled("Curing", false)
local offLine = table.concat(mock.echoed, " ")
ok(offLine:find("Curing <ansi_light_red>off<ansi_yellow>."),
   "log.toggled(label, false) uses red for off", offLine)

mock.echoed = {}
emunah.log.toggled("GMCP tracing", true, " Every message sent and received.")
local suffixLine = table.concat(mock.echoed, " ")
ok(suffixLine:find("GMCP tracing <ansi_light_green>on<ansi_yellow>%. Every message"),
   "an optional suffix is appended after the colour resets to yellow", suffixLine)
end)()

-- ===========================================================================
suite("D5: usage lines say `emset`, and `prio` goes through log.warn like everything else")

-- Nine usage lines said "Usage: emunah <cmd> ..." while help.lua itself states `emset` is
-- "what you type" -- the long form is for scripts, the short one is what every other usage
-- line in this file already used. `prio` was also the one handler bypassing log.warn for a
-- bespoke, inconsistently-coloured cecho pair; it now uses the same helper as the rest.
;(function()
mock.echoed = {}
emunah.commands.dispatch("prio")
local prioNoArgs = table.concat(mock.echoed, " ")
ok(prioNoArgs:find("Usage: emset prio"), "`prio` with no arguments warns via log.warn now",
   prioNoArgs)

mock.echoed = {}
emunah.commands.dispatch("prio paralysis notanumber")
local prioBadArg = table.concat(mock.echoed, " ")
ok(prioBadArg:find("Usage: emset prio"),
   "...and so does a malformed vector/rank, with the same wording", prioBadArg)

mock.echoed = {}
emunah.commands.dispatch("whois")
ok(table.concat(mock.echoed, " "):find("Usage: emset whois"),
   "a sibling handler's usage line also says `emset`, not `emunah`")
end)()

-- ===========================================================================
suite("D6: one rendering dialect -- header/row/flag now sit on decho + theme, not cecho")

-- Roughly a hundred `row(...)` call sites across fifteen handlers passed the old fixed
-- `<ansi_*>` colour names. header()/row()/flag() were rewritten to render through decho and
-- the theme palette (the same primitives `ndbTitle`/`ndbGrid` already used for the name
-- database and defence grid) WITHOUT changing any of those call sites -- ROW_COLOUR maps
-- every legacy name that was ever passed to its palette equivalent.
;(function()
mock.echoed = {}
emunah.commands.dispatch("status")
local statusOutput = table.concat(mock.echoed, "\n")
ok(not statusOutput:find("<ansi_", 1, true),
   "a report built from header()/row() no longer contains any <ansi_*> cecho tag",
   statusOutput:sub(1, 200))
ok(statusOutput:find("%d+,%d+,%d+"),
   "...and does contain decho's <r,g,b> triples instead")

-- Every legacy colour name row() was ever called with still resolves to something, rather
-- than falling through to a literal, unresolved key. `defs`'s row() lines (MISSING/up) are
-- decho now; its separate hint/warning lines (log.warn, and the standalone "nothing
-- configured" cecho) are a different system entirely and legitimately still `<ansi_*>` --
-- D6 covers header()/row()/flag(), not every cecho call in the file.
local keepup = emunah.curing.defkeepup
keepup.add("rebounding")
mock.echoed = {}
emunah.commands.dispatch("defs")
local defsRowLine = nil
for _, line in ipairs(mock.echoed) do
   if line:find("rebounding", 1, true) then defsRowLine = line end
end
ok(defsRowLine and not defsRowLine:find("<ansi_", 1, true),
   "the defs report's row() line (MISSING/up) is decho, not cecho", defsRowLine)
keepup.drop("rebounding")
end)()

-- ===========================================================================
suite("D7: `pp` prints one confirmation line, not two plus a banner")

-- `pp` used to call engine.stop() and keepup.stop() plain, and each logged its own "Curing
-- off."/"Defence keep-up off." independently -- two lines with two different feature names
-- for what pp's own design intent (see the handler's comment) calls one action. Both now
-- take a `silent` flag pp passes, and pp prints its own single line instead.
;(function()
local engine = emunah.curing.engine
local keepup = emunah.curing.defkeepup
engine.start(); keepup.start()

mock.echoed = {}
mock.command("emset pause")
local pausedLines = {}
for _, line in ipairs(mock.echoed) do
   if line:find("Curing", 1, true) or line:find("Defence keep%-up", 1, true)
      or line:find("Paused", 1, true) then
      pausedLines[#pausedLines + 1] = line
   end
end
eq(#pausedLines, 1, "pausing both via pp prints exactly one relevant line",
   table.concat(pausedLines, " | "))
ok(pausedLines[1] and pausedLines[1]:find("Paused", 1, true),
   "...and it says Paused", pausedLines[1])
ok(not engine.enabled and not keepup.enabled, "...and both are actually off")

mock.echoed = {}
mock.command("emset pause")
local resumedLines = {}
for _, line in ipairs(mock.echoed) do
   if line:find("Curing", 1, true) or line:find("Defence keep%-up", 1, true)
      or line:find("Resumed", 1, true) then
      resumedLines[#resumedLines + 1] = line
   end
end
eq(#resumedLines, 1, "resuming both via pp also prints exactly one relevant line",
   table.concat(resumedLines, " | "))
ok(resumedLines[1] and resumedLines[1]:find("Resumed", 1, true),
   "...and it says Resumed", resumedLines[1])

-- Direct, single-module calls are unaffected -- `emunah cure on` still logs its own line.
mock.echoed = {}
engine.stop()
ok(table.concat(mock.echoed, " "):find("Curing"),
   "calling engine.stop() directly (not through pp) still logs its own line")
engine.start(); keepup.start()
end)()

-- ===========================================================================
suite("D8: bare `cure` reports status, like `defs`, instead of toggling")

-- `cure` and `defs` used to disagree on what bare invocation means: bare `emunah cure`
-- toggled curing on/off (`else emunah.curing.engine.toggle() end`), bare `emunah defs`
-- showed the list. One rule now applies everywhere: bare or unrecognised shows the report,
-- and only an explicit `on`/`off` mutates anything.
;(function()
local engine = emunah.curing.engine
engine.stop()

mock.echoed = {}
emunah.commands.dispatch("curing")
ok(not engine.enabled, "bare `cure` does not toggle curing on", tostring(engine.enabled))
local bareOutput = table.concat(mock.echoed, " ")
ok(bareOutput:find("Curing"), "...and shows a status report instead", bareOutput)

mock.echoed = {}
emunah.commands.dispatch("curing sttaus")
ok(not engine.enabled, "an unrecognised `cure` argument does not toggle it either")
ok(table.concat(mock.echoed, " "):find("Unknown"),
   "...and warns that the argument was not recognised")

mock.echoed = {}
emunah.commands.dispatch("curing on")
ok(engine.enabled, "`cure on` still turns it on")
emunah.commands.dispatch("curing off")
ok(not engine.enabled, "`cure off` still turns it off")
end)()

-- ===========================================================================
suite("D9: `hunt` no longer starts on an unrecognised argument")

-- Documented syntax is exactly `emset hunt [off]`. `arg == "off" or arg == "stop"` stopped
-- it; everything else -- including a typo like `emset hunt stpo` -- fell through to the
-- start branch and silently started bashing and walking. Stopping required an exact word;
-- starting accepted anything. Only bare, "start", "off" and "stop" do anything now.
;(function()
emunah.walker.stop("test"); emunah.bashing.stop("test")

mock.echoed = {}
emunah.commands.dispatch("hunt stpo")
ok(not emunah.walker.enabled, "a typo does not start the walker", tostring(emunah.walker.enabled))
ok(not emunah.bashing.enabled, "...nor bashing", tostring(emunah.bashing.enabled))
ok(table.concat(mock.echoed, " "):find("Unknown"), "...and warns instead")

mock.echoed = {}
emunah.commands.dispatch("hunt off")
ok(table.concat(mock.echoed, " "):find("not running"),
   "`hunt off` when nothing is running still says so, not silently")
end)()

-- ===========================================================================
suite("never act without the balance AND the state to do it (svof gates)")

;(function()
local engine = emunah.curing.engine
local queue  = emunah.queue
local detect = emunah.curing.detect
local act    = emunah.act
local have   = emunah.have

local function reset()
   engine.clear(); queue.reset(); emunah.timers.stopAll()
   mock.feed("Char.Afflictions.List", {})
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", mp = "1000", maxmp = "1000",
                              wp = "1000", maxwp = "1000", bal = "1", eq = "1" })
   if detect.isProne() then mock.line("You stand up.") end
   mock.sent = {}
end
local function sent() return table.concat(mock.sent, " | ") end

-- A CURE QUEUED BEFORE THE BLOCK LANDED. The block was only consulted when the cure was
-- chosen, so an `eat` waiting in its slot went out into anorexia anyway.
reset()
queue.push("herb", "eat kelp", { tag = "asthma" })
engine.add("anorexia", "trigger")
eq(queue.flush(), 0, "a queued eat is held once anorexia lands")
ok(queue.pending("herb"), "...held, not dropped", tostring(queue.pending("herb")))
engine.remove("anorexia")
queue.flush()
ok(sent():find("eat kelp"), "...and goes out once the block clears", sent())

-- Anorexia shuts sipping too (svof check_sip).
reset()
engine.add("anorexia", "trigger")
queue.push("elixir", "drink health", { tag = "health" })
eq(queue.flush(), 0, "no sip while anorexic")

-- Mucous shuts smoking, detected from its own refusal line.
reset()
mock.line("Your lungs are too clogged with mucous for you to attempt smoking.")
ok(engine.has("mucous"), "the mucous refusal is detected")
queue.push("smoke", "smoke pipe", { tag = "aeon" })
eq(queue.flush(), 0, "no smoke while mucous")
mock.line("You manage to cough away the mucous filling your lungs.")
ok(not engine.has("mucous"), "...and it wears off on the cough line")

-- FOCUS needs willpower (svof: > 75), and is shut by inquisition.
reset()
mock.feed("Char.Vitals", { wp = "50", maxwp = "1000" })
queue.push("focus", "focus", { tag = "stupidity" })
eq(queue.flush(), 0, "no focus on 50 willpower")
reset()
engine.add("inquisition", "trigger")
queue.push("focus", "focus", { tag = "stupidity" })
eq(queue.flush(), 0, "no focus under inquisition")

-- TOUCH TREE: not while entangled, and not with a numb arm.
for _, name in ipairs({ "webbed", "numbedleftarm" }) do
   reset()
   engine.add(name, "trigger")
   queue.push("tree", "touch tree", { tag = "tree" })
   eq(queue.flush(), 0, "no touch tree while " .. name)
end

-- DIRECT SENDS: attacks, movement and loot go through act, not the queue.
reset()
engine.add("paralysis", "trigger")
eq(act.blocked({ standing = true, bal = true }), "paralysed", "an attack is held while paralysed")
eq(act.blocked({}), nil, "...a command needing nothing is not")
reset()
engine.add("webbed", "trigger")
eq(act.blocked({ standing = true, bal = true, eq = true }), "entangled",
   "walking is held while webbed")
eq(act.blocked({ bal = true }), nil, "...a cure that needs no footing is not")

-- STAND: needs balance AND equilibrium, and working legs, and no entanglement (svof).
reset()
mock.feed("Char.Vitals", { bal = "1", eq = "0" })
mock.feed("Char.Afflictions.Add", { name = "prone", cure = "STAND" })
mock.feed("Char.Vitals", { bal = "1", eq = "0" })
ok(not sent():find("stand"), "no STAND without equilibrium", sent())
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(sent():find("stand"), "...and it goes out when equilibrium returns", sent())
reset()
engine.add("crippledleftleg", "trigger")
mock.feed("Char.Afflictions.Add", { name = "prone", cure = "STAND" })
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(not sent():find("stand"), "no STAND on a crippled leg", sent())
reset()
engine.add("webbed", "trigger")
mock.feed("Char.Afflictions.Add", { name = "prone", cure = "STAND" })
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(not sent():find("stand"), "no STAND while webbed", sent())

-- WRITHE ONCE, THEN WAIT (HELP ENTANGLEMENT). It was re-sent every confirm timeout.
reset()
engine.enabled = true
engine.add("webbed", "trigger")
engine.tick(); queue.flush()
eq(sent(), "writhe", "the first WRITHE goes out")
mock.line("You begin to struggle free of your entanglement.")
mock.sent = {}
for _ = 1, 5 do
   mock.advance(1.0)
   engine.tick(); queue.flush()
end
eq(sent(), "", "no second WRITHE while the first is under way, past the confirm timeout")
mock.line("You have writhed free of your entanglement by webs.")
mock.feed("Char.Afflictions.Remove", { "webbed" })
engine.add("transfixed", "trigger")
engine.tick(); queue.flush()
eq(sent(), "writhe", "...but the NEXT entanglement gets its own writhe once free")

-- Writhing with nothing to writhe from: the tracked entanglement was not real.
reset()
engine.add("roped", "trigger")
mock.line("You begin to writhe helplessly, throwing your body off balance.")
ok(not engine.has("roped"), "a helpless writhe clears the phantom entanglement")
engine.enabled = false

-- WAKE ONCE, THEN WAIT (HELP SLEEPING).
reset()
detect.onWake()
mock.feed("Char.Afflictions.Add", { name = "sleeping", cure = "" })
ok(sent():find("wake"), "WAKE goes out on falling asleep", sent())
mock.line("You begin your struggle to escape from the dreamworld.")
mock.sent = {}
for _ = 1, 5 do
   mock.advance(detect.WAKE_GUARD + 0.01)
   mock.feed("Char.Vitals", { bal = "1", eq = "1" })
end
ok(not sent():find("wake"), "no WAKE resent once the struggle has begun", sent())
mock.line("You open your eyes and yawn mightily.")
ok(not detect.isAsleep(), "svof's wake line ends the sleep")

-- UNCONSCIOUS: held like stun, cleared by svof's wear-off line or its 7s backstop.
reset()
mock.line("Your legs collapse from under you and consciousness leaves you as you pass out from extreme hunger.")
eq(act.blocked(), "unconscious", "unconscious holds even a command that needs nothing")
queue.push("herb", "eat kelp", { tag = "asthma" })
eq(queue.flush(), 0, "...and every cure")
mock.line("You regain consciousness with a start.")
eq(act.blocked(), nil, "...until consciousness returns")
mock.line("Your legs collapse from under you and consciousness leaves you as you pass out from extreme hunger.")
mock.advance(detect.UNCONSCIOUS_GUARD + 0.01)
eq(act.blocked(), nil, "...or the backstop lapses")

-- ARM BALANCE: every bal/eq action waits for both arms (svof check_balanceful_acts).
reset()
mock.line("You unleash a powerful hook towards a rat.")
eq(act.blocked({ bal = true }), "arm off balance", "a spent arm holds a balance action")
eq(act.blocked({}), nil, "...but not one that needs no balance")
mock.line("You have recovered balance on your left arm.")
eq(act.blocked({ bal = true }), nil, "...until that arm recovers")
mock.line("You unleash a powerful hook towards a rat.")
mock.line("You unleash a powerful hook towards a rat.")
ok(not detect.armBalance.left and not detect.armBalance.right, "a second strike spends the other arm")
mock.line("You have recovered balance on all limbs.")
ok(detect.armsBalanced(), "the all-limbs line restores both")
mock.line("You unleash a powerful hook towards a rat.")
mock.advance(detect.ARM_GUARD + 0.01)
ok(detect.armsBalanced(), "a missed recovery line is bounded by the backstop")

-- FEAR: COMPOSE first (HELP AFFLICTIONS, svof dict.fear.misc).
reset()
engine.enabled = true
mock.feed("Char.Afflictions.Add", { name = "fear", cure = "COMPOSE" })
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(sent():find("compose"), "fear is composed away", sent())

-- DISRUPTED: CONCENTRATE, but never while confused (HELP COMPOSE, svof dict.disrupt).
reset()
engine.add("disrupted", "trigger")
engine.tick(); queue.flush()
ok(sent():find("concentrate"), "disrupted equilibrium is concentrated back", sent())
reset()
engine.add("disrupted", "trigger")
engine.add("confusion", "trigger")
engine.tick(); queue.flush()
ok(not sent():find("concentrate"), "...but not while confused", sent())

-- THE SERVER'S NAMES (svof gamename): `blind` is the affliction, cured like blindness.
reset()
mock.feed("Char.Items.List", { location = "inv", items = {
   { id = "31", name = "an epidermal salve", attrib = "e" },
} })
mock.feed("IRE.Rift.List", {})
mock.feed("Char.Afflictions.Add", { name = "blind", cure = "APPLY EPIDERMAL" })
mock.feed("Char.Vitals", { bal = "1", eq = "1" })
ok(sent():find("apply epidermal"), "`blind` is cured from the table, not left unknown", sent())
engine.enabled = false

-- SVOF'S PER-CURE CONDITIONS (afflist.CONDITIONS).
for name in pairs(emunah.curing.afflist.CONDITIONS) do
   ok(emunah.curing.afflist.known(name), name .. " in CONDITIONS is in the cure table")
end
local have = emunah.have
local function option(name, vector)
   return emunah.curing.afflist.curesVia(name, vector)[1]
end
reset()
engine.add("whisperingmadness", "gmcp")
ok(not have.cure(option("confusion", "focus")), "no focusing confusion under whispering madness")
reset()
engine.add("hypochondria", "gmcp")
ok(not have.cure(option("impatience", "herb")), "impatience waits for hypochondria (else re-applied)")
reset()
engine.add("mangledleftleg", "gmcp")
ok(not have.cure(option("brokenleftleg", "salve")), "a broken leg waits for the mangled one")
ok(not have.cure(option("damagedrightleg", "salve")), "...as does a damaged one on either leg")
reset()
queue.push("focus", "focus", { tag = "stupidity", confirm = 5 })
emunah.have.recover("focus")
queue.flush()
local okHerb, why = have.cure(option("dizziness", "herb"))
ok(not okHerb and tostring(why):find("focus"), "no goldenseal while a focus is in flight", why)
eq(#emunah.curing.afflist.curesVia("fear", "focus"), 0, "fear is never focused (svof has it off)")
reset()
mock.feed("Char.Vitals", { mp = "300", maxmp = "1000" })
queue.push("focus", "focus", { tag = "stupidity" })
eq(queue.flush(), 0, "no focus at 30% mana (svof manause, 35%)")
mock.feed("Char.Vitals", { mp = "1000", maxmp = "1000" })

-- DEATH PAUSES EVERYTHING (user's rule), and curing resumes on revival.
reset()
emunah.bashing.enabled = true
queue.push("herb", "eat kelp", { tag = "asthma" })
mock.feed("Char.Vitals", { hp = "0", maxhp = "1000" })
eq(act.blocked(), "dead", "dead holds even a command that needs nothing")
ok(not queue.pending("herb"), "dying drops what was queued")
ok(not emunah.bashing.enabled, "dying stops the hunt")
mock.feed("Char.Vitals", { hp = "500", maxhp = "1000" })
eq(act.blocked(), nil, "alive again, commands flow")
ok(not emunah.bashing.enabled, "...but the hunt stays off until restarted")
reset()
end)()

suite("pipes: our own housekeeping is gagged, and still fully parsed")

;(function()
local pipes = emunah.pipes
emunah.timers.stopAll()
pipes.forget()
emunah.config.set("pipes.enabled", true)   -- the pipes suite leaves it switched off
mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })

-- Only this suite's lines: earlier suites left identical PIPELIST text further up.
local start = #mock.buffer
local function inBuffer(text)
   for index = start + 1, #mock.buffer do if mock.buffer[index] == text then return true end end
   return false
end

-- The transcript that asked for this, 13:04:56-13:05:27: a poll, then three lights.
mock.sent, mock.echoed_sends = {}, {}
pipes.poll(true)
eq(mock.sent[#mock.sent], "pipelist", "our poll goes out")
eq(mock.echoed_sends[#mock.echoed_sends], false, "...without echoing the command")

local rows = {
   "Status  Pipe         Contents                       Puffs Months ",
   "-------------------------------------------------------------------------------",
   "out     pipe367581   a skullcap flower              8     195",
   "out     pipe408402   slippery elm                   9     195",
   "out     pipe422328   a valerian leaf                9     195",
   "-------------------------------------------------------------------------------",
}
mock.line("The celestial flowers of the aurora bloom and fade slowly, their rhythm steady and soothing.")
for _, row in ipairs(rows) do mock.line(row) end
-- THE REGRESSION THAT BANNED GAGGING HERE: every row must be parsed, not just the first.
eq(#pipes.list(), 3, "all three rows parsed while being gagged")
mock.advance(0)
for _, row in ipairs(rows) do
   ok(not inBuffer(row), "gagged: " .. row)
end
ok(inBuffer("The celestial flowers of the aurora bloom and fade slowly, their rhythm steady and soothing."),
   "...and the unrelated line around them is left alone")

-- A LIGHT of ours: the tinderbox and the success line go.
mock.sent, mock.echoed_sends = {}, {}
pipes.keep()
eq(mock.sent[1], "light pipe367581", "the first cold pipe is lit")
eq(mock.echoed_sends[1], false, "...quietly")
mock.line("You use a soot-blackened tinderbox to make fire.")
mock.line("You carefully light your treasured pipe until it is smoking nicely.")
eq(pipes.pipes["367581"].status, "lit", "the light is still recorded")
mock.advance(0)
ok(not inBuffer("You use a soot-blackened tinderbox to make fire."), "tinderbox line gagged")
ok(not inBuffer("You carefully light your treasured pipe until it is smoking nicely."),
   "lit line gagged")

-- THE LAST LINE IS ALWAYS A CURRENT PROMPT. Reported 13:23:14.92-13:23:17.41: five bare
-- prompts in a row, one per relight, because only the replies were gagged. Now a run of
-- our housekeeping collapses into one prompt -- the newest -- at the bottom of the window.
local p1 = "H:100% M:100% E:100% W:100%  ex-  T:  13:23:14.92-"
local p2 = "H:100% M:100% E:100% W:100%  ex-  T:  13:23:15.13-"
local p3 = "H:100% M:100% E:100% W:100%  ex-  T:  13:23:15.90-"
local visitor = "Glancing around for the Iron Carnival, a lost visitor enters from the southwest."
local function relight(id)
   emunah.timers.stop("pipes.action")
   emunah.timers.stop("pipes.pipe." .. id)
   pipes.pipes[id].status = "out"
   pipes.keep()
   mock.line("You use a soot-blackened tinderbox to make fire.")
   mock.line("You carefully light your treasured pipe until it is smoking nicely.")
end
mock.prompt(p1)
relight("408402")
mock.prompt(p2)
mock.advance(0)
relight("422328")
mock.prompt(p3)
mock.advance(0)
ok(not inBuffer(p1) and not inBuffer(p2), "the prompts our relights stranded are removed")
eq(mock.buffer[#mock.buffer], p3, "...and the newest prompt is the last line in the window")

-- TWO RELIGHTS IN FLIGHT AT ONCE. The first reply used to clear the single "ours" slot, so
-- the second pipe's tinderbox and success lines were shown. Each kind now counts its own.
pipes.pipes["408402"].status = "out"
pipes.pipes["422328"].status = "out"
emunah.timers.stop("pipes.action")
emunah.timers.stop("pipes.pipe.408402")
emunah.timers.stop("pipes.pipe.422328")
pipes.keep()
emunah.timers.stop("pipes.action")
pipes.keep()
local both = {
   "You use a soot-blackened tinderbox to make fire.",
   "You carefully light your treasured pipe until it is smoking nicely.",
   "You use a soot-blackened tinderbox to make fire.",
   "You carefully light your treasured pipe until it is smoking nicely.",
}
local before = #mock.buffer
for _, line in ipairs(both) do mock.line(line) end
mock.advance(0)
eq(#mock.buffer, before, "both relights' lines are gagged, not just the first one's")

-- A relight sent in the middle of our PIPELIST does not un-gag the rest of the listing.
emunah.timers.stop("pipes.poll")
pipes.poll(true)
before = #mock.buffer
mock.line("Status  Pipe         Contents                       Puffs Months ")
mock.line("-------------------------------------------------------------------------------")
mock.line("out     pipe367581   a skullcap flower              8     195")
pipes.quietly("light")
mock.line("lit     pipe408402   slippery elm                   9     195")
mock.line("-------------------------------------------------------------------------------")
mock.advance(0)
eq(#mock.buffer, before, "a relight mid-listing leaves the whole listing gagged")

-- A block with anything else in it keeps its prompt.
mock.line(visitor)
local p4 = "H:100% M:100% E:100% W:100%  ex-  T:  13:23:17.41-"
mock.prompt(p4)
mock.advance(0)
ok(inBuffer(visitor) and inBuffer(p3), "an ordinary block leaves the prompt before it alone")
eq(mock.buffer[#mock.buffer], p4, "...and ends on its own prompt")

-- A prompt you typed a command onto is yours, and stays.
mock.typedEcho("score")
relight("367581")
local p5 = "H:100% M:100% E:100% W:100%  ex-  T:  13:23:18.20-"
mock.prompt(p5)
mock.advance(0)
ok(inBuffer(p4 .. "score"), "a prompt carrying a typed command is never removed")
eq(mock.buffer[#mock.buffer], p5, "...and the newest prompt is still last")

-- YOURS ARE NOT: a PIPELIST you typed, or `emunah pipes now`, is shown in full.
mock.advance(pipes.QUIET_WINDOW + 0.1)
local before = #mock.buffer
for _, row in ipairs(rows) do mock.line(row) end
mock.advance(0)
eq(#mock.buffer, before + #rows, "a PIPELIST we did not send is not gagged")
mock.sent, mock.echoed_sends = {}, {}
emunah.timers.stop("pipes.poll")
pipes.poll(true, true)
eq(mock.echoed_sends[#mock.echoed_sends], true, "`emunah pipes now` echoes, as asked for")
emunah.timers.stopAll()
end)()

suite("EmunahTriggers.xml: svof's lines, feeding Emunah")

;(function()
local engine = emunah.curing.engine
local detect = emunah.curing.detect
local afflist = emunah.curing.afflist

local function reset()
   engine.clear(); emunah.queue.reset(); emunah.timers.stopAll()
   mock.feed("Char.Afflictions.List", {})
   mock.feed("Char.Vitals", { hp = "1000", maxhp = "1000", bal = "1", eq = "1" })
end
-- The end of a block of output: Achaea sends Char.Vitals with every prompt.
local function prompt() mock.feed("Char.Vitals", { bal = "1", eq = "1" }) end

-- LAYER 1: NOTHING COUNTS UNTIL THE PROMPT.
reset()
detect.textGain("paralysis")
ok(not engine.has("paralysis"), "a text report waits for the prompt")
prompt()
ok(engine.has("paralysis"), "...and is applied on it")

-- LAYER 2: ONE ILLUSION SPOILS THE BLOCK -- everything reported with it is discarded.
reset()
detect.textGain("paralysis")
detect.textState("stunned", true)
detect.textIllusion("test pair")
prompt()
ok(not engine.has("paralysis"), "an illusion in the block discards its afflictions")
eq(emunah.act.blocked(), nil, "...and its states")
detect.textGain("paralysis")
prompt()
ok(engine.has("paralysis"), "...but only that block: the next one counts again")

-- LAYER 3: A CURE LINE NEEDS A CURE IN PROGRESS.
reset()
engine.add("paranoia", "gmcp")
detect.textCure("paranoia", "herb")
prompt()
ok(engine.has("paranoia"), "a herb cure line with no herb being eaten is an illusion")
emunah.queue.push("herb", "eat ash", { tag = "paranoia", confirm = 5 })
emunah.have.recover("herb")
emunah.queue.flush()
mock.latency = 0.4
detect.textCure("paranoia", "herb")
prompt()
ok(engine.has("paranoia"), "...so is one faster than half the ping after the eat")
mock.advance(0.3)
detect.textCure("paranoia", "herb")
prompt()
ok(not engine.has("paranoia"), "...and one that fits is believed")
mock.latency = 0
reset()
engine.add("stupidity", "gmcp")
emunah.queue.push("herb", "eat goldenseal", { tag = "stupidity", confirm = 5 })
emunah.have.recover("herb")
emunah.queue.flush()
detect.textCure("dizziness", "herb")
prompt()
ok(not engine.has("dizziness"), "a cure for something we do not have is ignored, not applied")
detect.textCure("paranoia")
prompt()   -- a wear-off / general cure needs no action in flight; must not error

-- THE PROMPT TRIGGER: closes the block, and stands in for a missing Char.Vitals.
reset()
detect.textGain("paralysis")
detect.textLine(); detect.textLine()
eq(detect.paragraphLength, 2, "every non-prompt line is counted, as svof's paragraph_length")
local ticks = emunah.gmcp.vitals.ticks
detect.textPrompt()   -- reset() sent a Char.Vitals, so this prompt already had one
ok(engine.has("paralysis"), "the prompt applies the block")
eq(detect.paragraphLength, 0, "...and resets the count")
eq(emunah.gmcp.vitals.ticks, ticks, "a prompt that came with Char.Vitals does not tick again")
detect.textPrompt()
eq(emunah.gmcp.vitals.ticks, ticks + 1, "no Char.Vitals since the last prompt: the prompt runs the heartbeat")
prompt()
ticks = emunah.gmcp.vitals.ticks
detect.textPrompt()
eq(emunah.gmcp.vitals.ticks, ticks, "...but not when Char.Vitals already did")

-- LAYER 4 (PROBATION). A text report the server never confirms is dropped: that is an illusion, and
-- before this a trigger-asserted affliction survived every reconcile.
reset()
engine.enabled = true
detect.textGain("paralysis")
prompt()
ok(engine.has("paralysis"), "a text report is tracked once its block ends")
mock.advance(engine.TEXT_CONFIRM + 0.1)
engine.tick()
ok(not engine.has("paralysis"), "...and dropped when the server never confirms it")

reset()
detect.textGain("paralysis")
mock.feed("Char.Afflictions.Add", { name = "paralysis", cure = "EAT BLOODROOT" })
mock.advance(engine.TEXT_CONFIRM + 0.1)
engine.tick()
ok(engine.has("paralysis"), "a confirmed report stays")

reset()
engine.add("blackout", "gmcp")
detect.textGain("stupidity")
prompt()
mock.advance(engine.TEXT_CONFIRM + 5)
engine.tick()
ok(engine.has("stupidity"), "while blacked out the text is all there is, so it is kept")
engine.enabled = false

-- STATES go straight in, like the native patterns.
reset()
detect.textState("stunned", true)
prompt()
eq(emunah.act.blocked(), "stunned", "textState stunned holds everything")
detect.textState("stunned", false)
prompt()
eq(emunah.act.blocked(), nil, "...and clears")
detect.textCure("nothingtracked")   -- must not error on something we are not tracking

-- THE PACKAGE ITSELF. Every script must compile, run against the real modules, and name
-- only afflictions and states Emunah acts on -- a name it does not know could never be
-- cured and would only be dropped again.
local handle = io.open("EmunahTriggers.xml", "r")
ok(handle ~= nil, "EmunahTriggers.xml exists at the repository root")
if handle then
   local xml = handle:read("*a"); handle:close()
   local function unescape(text)
      return (text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
                  :gsub("&apos;", "'"):gsub("&amp;", "&"))
   end
   local scripts, bad, unknownNames = 0, {}, {}
   local states = { stunned = true, prone = true, sleeping = true, unconscious = true }
   for script in xml:gmatch("<Trigger [^>]*>%s*<name>[^<]*</name>%s*<script>(.-)</script>") do
      scripts = scripts + 1
      local code = unescape(script)
      local fn, err = loadstring(code)
      if not fn then
         bad[#bad + 1] = err
      else
         reset()
         local okRun, runErr = pcall(fn)
         if not okRun then bad[#bad + 1] = runErr end
      end
      for kind, name in code:gmatch('text(%a+)%("([%w]+)"') do
         if kind == "Illusion" then
            -- a reason, not a name
         elseif kind == "State" then
            if not states[name] then unknownNames[#unknownNames + 1] = name end
         elseif not (afflist.known(name) or afflist.isWrithe(name)
                     or #afflist.blockedVectors(name) > 0 or afflist.wearsOff[name]) then
            unknownNames[#unknownNames + 1] = name
         end
      end
   end
   ok(scripts > 500, "the package carries svof's lines (" .. scripts .. " triggers)")
   eq(#bad, 0, "every trigger script compiles and runs", table.concat(bad, " | "))
   eq(#unknownNames, 0, "every name it reports is one Emunah acts on",
      table.concat(unknownNames, ", "))
   ok(not xml:find("svo%."), "no svof code survives into the package")
   ok(xml:find("<name>Emunah prompt</name>", 1, true)
      and xml:find("isPrompt()", 1, true), "the package carries svof's prompt trigger")
   ok(xml:find("textIllusion", 1, true), "...and svof's illusion catchers")
end
reset()
end)()

suite("docs stay in sync with the code, and with each other")

-- Duplicated figures across README/website/docs/performance.md have drifted before: three
-- different values for the same "modules" figure, two different pairs of numbers for the
-- same engine.tick() benchmark, and website/commands.html silently missing commands the
-- code already had (the `!`-vs-`emunah` split described in commands.lua's own comment).
-- These checks exist so drift fails the suite instead of shipping quietly.

;(function()
local function readFile(path)
   local f = assert(io.open(path, "r"), "could not open " .. path)
   local content = f:read("*a")
   f:close()
   return content
end

local function decodeEntities(s)
   return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end

-- MODULE COUNT: the number of entries in emunah.lua's MANIFEST is ground truth.
local emunahLua = readFile("src/emunah.lua")
local manifestCount = 0
for _ in emunahLua:gmatch("as%s*=") do manifestCount = manifestCount + 1 end
ok(manifestCount > 40, "MANIFEST has a plausible number of entries", manifestCount)

local readme = readFile("README.md")
local readmeModules = tonumber(readme:match("v0%.1%.0 loaded %-%- (%d+) modules"))
eq(readmeModules, manifestCount, "README's module count matches emunah.lua's MANIFEST")

local indexHtml = readFile("website/index.html")
local indexModules = tonumber(indexHtml:match('badge">(%d+) modules'))
eq(indexModules, manifestCount, "website/index.html's module count matches MANIFEST")

local gettingStarted = readFile("website/getting-started.html")
local gsModules = tonumber(gettingStarted:match("v0%.1%.0 loaded %-%- (%d+) modules"))
eq(gsModules, manifestCount, "website/getting-started.html's module count matches MANIFEST")

-- TEST COUNT: README is treated as the source of truth the website copies from.
local readmeTests = tonumber(readme:match("(%d+) behavioural tests"))
ok(readmeTests and readmeTests > 1000, "README states a plausible test count", readmeTests)

local architectureHtml = readFile("website/architecture.html")
local archTests = tonumber(architectureHtml:match("(%d+) behavioural tests"))
eq(archTests, readmeTests, "website/architecture.html's test count matches README")

local gsTests = tonumber(gettingStarted:match("(%d+) behavioural tests"))
eq(gsTests, readmeTests, "website/getting-started.html's test count matches README")

local indexTests = tonumber(indexHtml:match('badge">(%d+) automated tests'))
eq(indexTests, readmeTests, "website/index.html's test count matches README")

-- PERFORMANCE NUMBERS: docs/performance.md is where a benchmark actually gets re-measured;
-- README and the website copy the engine.tick() headline from it.
local perfDoc = readFile("docs/performance.md")
local perfBefore, perfAfter =
   perfDoc:match("|%s*`engine%.tick%(%)`%s*|%s*([%d%.]+) µs%s*|%s*%*%*([%d%.]+) µs%*%*%s*|")
ok(perfBefore and perfAfter, "docs/performance.md states an engine.tick() before/after pair",
   tostring(perfBefore) .. " -> " .. tostring(perfAfter))

local readmeAfter, readmeBefore =
   readme:match("costs %*%*([%d%.]+) µs%*%*, down from ([%d%.]+) µs")
eq(readmeAfter, perfAfter, "README's engine.tick() figure matches docs/performance.md")
eq(readmeBefore, perfBefore, "README's engine.tick() baseline matches docs/performance.md")

local perfHtml = readFile("website/performance.html")
local htmlBefore, htmlAfter = perfHtml:match(
   "<code>engine%.tick%(%)</code></td><td>([%d%.]+) µs</td><td><strong>([%d%.]+) µs</strong>")
eq(htmlBefore, perfBefore,
   "website/performance.html's engine.tick() baseline matches docs/performance.md")
eq(htmlAfter, perfAfter,
   "website/performance.html's engine.tick() figure matches docs/performance.md")

-- COMMAND TABLE: website/commands.html must not silently drift from what help.lua
-- documents -- the exact failure mode this project was already burned by once.
local help = emunah.help
local documentedSyntax = {}
for _, row in ipairs(help.commands()) do
   documentedSyntax[row.command.syntax] = true
end

local commandsHtml = readFile("website/commands.html")
local webSyntax = {}
for span in commandsHtml:gmatch('cmd%-syntax">(.-)</span>') do
   webSyntax[decodeEntities(span)] = true
end

local missingFromWeb = {}
for syntax in pairs(documentedSyntax) do
   if not webSyntax[syntax] then missingFromWeb[#missingFromWeb + 1] = syntax end
end
table.sort(missingFromWeb)
eq(#missingFromWeb, 0, "every help.lua command form appears on website/commands.html",
   table.concat(missingFromWeb, " | "))

local staleOnWeb = {}
for syntax in pairs(webSyntax) do
   if not documentedSyntax[syntax] then staleOnWeb[#staleOnWeb + 1] = syntax end
end
table.sort(staleOnWeb)
eq(#staleOnWeb, 0, "website/commands.html documents no command form that help.lua does not",
   table.concat(staleOnWeb, " | "))
end)()

-- ===========================================================================

io.write("\n", string.rep("-", 60), "\n")
io.write(string.format("%d passed, %d failed\n", passed, failed))
if failed > 0 then
   io.write("\nFailures:\n")
   for _, failure in ipairs(failures) do io.write("  ", failure, "\n") end
   os.exit(1)
end
os.exit(0)

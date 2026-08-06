--- Emunah performance benchmark.
---
--- Achaea combat is decided on round trips, and every prompt drives one engine tick. This
--- measures the tick under a realistic fight: a handful of afflictions up, herbs in hand,
--- vitals below the healing thresholds -- the state where the engine does the MOST work,
--- because that is the state where being slow actually costs the fight.
---
--- Reports wall time per tick and bytes of garbage per tick. The second number matters as
--- much as the first: Mudlet runs one Lua state for every package the user has installed,
--- so garbage produced here is collection latency paid by the whole client, at the exact
--- moment the character is being locked.
---
--- Usage: lua test/bench.lua [iterations]

local ROOT = (arg and arg[0] or ""):match("^(.*)/test/bench%.lua$") or "."
package.path = ROOT .. "/test/?.lua;" .. package.path

local mock = require("mock_mudlet")
mock.install(ROOT)
_G.EMUNAH_ROOT = ROOT
dofile(ROOT .. "/src/emunah.lua")

local N = tonumber(arg and arg[1]) or 20000

--- REAL wall time, not the mock's clock.
---
--- mock.install() replaces os.clock() with the manually-advanced test clock, so that
--- cooldown maths is deterministic. Timing against it measures the fake clock and reports
--- whatever the benchmark itself advanced -- the first version of this file dutifully
--- printed "250000 us/call" because it stepped the clock 0.25s per iteration.
local clock = mock.realClock or os.clock

-- ---------------------------------------------------------------------------
-- A realistic fight state.
-- ---------------------------------------------------------------------------

-- Carry the herbs, so cures resolve as performable rather than short-circuiting on supply.
mock.feed("Char.Items.List", {
   location = "inv",
   items = {
      { id = "1",  name = "some bloodroot",   attrib = "" },
      { id = "2",  name = "some kelp",        attrib = "" },
      { id = "3",  name = "some goldenseal",  attrib = "" },
      { id = "4",  name = "some lobelia",     attrib = "" },
      { id = "5",  name = "some ginseng",     attrib = "" },
      { id = "6",  name = "some valerian",    attrib = "" },
      { id = "7",  name = "some irid moss",   attrib = "" },
      { id = "8",  name = "an epidermal salve", attrib = "" },
      { id = "9",  name = "some ash",         attrib = "" },
      { id = "10", name = "some myrrh",       attrib = "" },
   },
})

-- Vitals: balance and equilibrium up, health and mana low enough to engage every healing
-- branch the tick has.
mock.feed("Char.Vitals", {
   hp = "2400", maxhp = "6000",
   mp = "2200", maxmp = "5000",
   ep = "20000", maxep = "30000",
   wp = "20000", maxwp = "30000",
   bal = "1", eq = "1",
})

-- Eight afflictions, spread across vectors, which is an ordinary lock in PvP.
mock.feed("Char.Afflictions.List", {
   { name = "paralysis" },   { name = "stupidity" },   { name = "anorexia" },
   { name = "asthma" },      { name = "slickness" },   { name = "clumsiness" },
   { name = "weariness" },   { name = "recklessness" },
})

local engine = emunah.curing.engine
engine.enabled = true

-- ---------------------------------------------------------------------------
-- Measure.
-- ---------------------------------------------------------------------------

local function bench(label, fn, iterations)
   -- Warm up, so first-call costs (memoisation, lazily built tables) are not attributed
   -- to the steady state this is meant to describe.
   for _ = 1, 200 do fn() end

   collectgarbage("collect")
   collectgarbage("collect")

   -- THE COLLECTOR IS STOPPED FOR THE MEASURED LOOP, and without this the byte column is
   -- noise. `collectgarbage("count")` reports what is live now, not what was allocated: if
   -- the GC runs partway through the loop -- and over tens of thousands of iterations it
   -- always does -- the delta is "allocated minus whatever happened to be collected", which
   -- varied between 194 and 732 bytes per call across consecutive runs of the SAME code.
   -- With the collector stopped nothing is reclaimed, so the delta is the true allocation.
   collectgarbage("stop")
   local kbBefore = collectgarbage("count")
   local started  = clock()

   for _ = 1, iterations do fn() end

   local elapsed = clock() - started
   local kbAfter = collectgarbage("count")
   collectgarbage("restart")

   local usPerCall    = (elapsed / iterations) * 1e6
   local bytesPerCall = ((kbAfter - kbBefore) * 1024) / iterations

   print(string.format("%-34s %8.2f us/call  %9.0f bytes/call", label, usPerCall, bytesPerCall))
   return usPerCall, bytesPerCall
end

print(string.format("Emunah benchmark -- %d iterations, %d afflictions tracked\n",
   N, engine.count()))

bench("engine.tick()", function()
   -- Advance the clock so guard windows and confirmation timers behave as they would
   -- across real prompts rather than all landing inside one frozen instant.
   mock.clock = mock.clock + 0.25
   engine.tick()
end, N)

bench("config.get('curing.confirmWait')", function()
   emunah.config.get("curing.confirmWait", 2.0)
end, N)

bench("afflist.priority('paralysis','herb')", function()
   emunah.curing.afflist.priority("paralysis", "herb")
end, N)

bench("afflist.curesVia('paralysis','herb')", function()
   emunah.curing.afflist.curesVia("paralysis", "herb")
end, N)

bench("have.cure(bloodroot option)", function()
   emunah.have.cure(emunah.curing.afflist.curesVia("paralysis", "herb")[1])
end, N)

bench("engine.has('paralysis')", function()
   engine.has("paralysis")
end, N)

bench("curelist.restockables()", function()
   emunah.curing.curelist.restockables()
end, N)

-- ---------------------------------------------------------------------------
-- THE PER-LINE PATH.
--
-- The blind spot that let a 5.1us-per-line name scan sit on the hot path unnoticed for as
-- long as it did: everything above measures work done ONCE PER PROMPT, and this file had no
-- case at all for work done once per LINE. A busy room produces 30-60 lines per combat
-- round, so a microsecond here is worth roughly fifty up there.
--
-- Measured through mock.line(), not by calling the handlers, because the thing under test is
-- which triggers MATCH. Calling names.onLine() directly is what the old tests did, and it is
-- exactly why the regression was invisible.
-- ---------------------------------------------------------------------------

print("")

-- A realistic roster. The cost of the old `[A-Z][a-z]` scan was driven by the number of
-- capitalised words on the line rather than the size of the database, so a small database is
-- not a kind fixture -- it is the ordinary one.
for _, person in ipairs({
   "Aeowynn", "Akri", "Aletheia", "Amira", "Arivar", "Aultorius", "Ceredia", "Clodhna",
   "Crixos", "Elius", "Erishka", "Giddieon", "Jexa", "Kaellyn", "Kassie", "Khalayx",
   "Kimora", "Llewell", "Lokri", "Majin", "Meldia", "Milabar", "Miriew", "Mycen",
   "Naz", "Oxton", "Saibel", "Shiora", "Telox", "Thelek", "Tsia", "Ulvin", "Veldrin",
   "Vesperyn", "Xarya", "Xorr", "Zalydd", "Zargoth",
}) do
   emunah.namedb.record(person)
end
emunah.ui.names.enabled = true
-- Guarded so `git stash push -- src/` still runs this file against the PREVIOUS generation
-- of the code, which is the only way to get an honest baseline. rebuild() is new; the old
-- version registered one fixed trigger at load and had nothing to rebuild.
if emunah.ui.names.rebuild then emunah.ui.names.rebuild(true) end

-- WHAT IS MEASURED HERE IS A COUNT, NOT A TIME, and that is deliberate.
--
-- In Mudlet a trigger pattern is matched in C++ before any Lua runs, so the per-line cost we
-- control is not "how long did matching take" -- it is "how often did a Lua callback run at
-- all". mock.line() cannot tell us the first (it matches with string.find against a
-- translated pattern, which is nothing like PCRE's cost) and answers the second exactly.
--
-- Timing this through the mock is the same trap as timing against the stubbed os.clock: a
-- confident number that describes the harness. The count transfers to Mudlet; the time does
-- not.
local function callbacks(label, line)
   local fired = 0
   local realOnLine = emunah.ui.names.onLine
   emunah.ui.names.onLine = function() fired = fired + 1 return realOnLine() end
   mock.line(line)
   emunah.ui.names.onLine = realOnLine
   print(string.format("%-34s %8d highlighter callback%s", label, fired, fired == 1 and "" or "s"))
   return fired
end

-- Ordinary game output with capitalised words in it and nobody named. This is the common
-- line, and under the old `[A-Z][a-z]` pattern every one of them reached Lua.
callbacks("line: prose, nobody named", "A Pedestal of Iron stands here, beneath a Chalice.")

-- Combat text: long, busy, and the shape that arrives in floods.
callbacks("line: combat text", "You slash at the sentinel with your blade, striking it heavily.")

-- The line the highlighter actually exists for. This one SHOULD cost a callback.
callbacks("line: names a known person", "Erishka arrives from the north, followed by Lokri.")

print("")

-- And what one callback costs when it does fire, which is the other half of the budget.
bench("names.onLine() on a named line", function()
   mock.setLine("Erishka arrives from the north, followed by Lokri.")
   emunah.ui.names.onLine()
end, N)

if emunah.namedb.capture.recent then
   bench("capture.recent(1) from the ring", function()
      emunah.namedb.capture.recent(1)
   end, N)
end

-- ---------------------------------------------------------------------------
-- THE CHYRON, which is not prompt-driven at all.
--
-- It re-renders 12.5 times a second for as long as any message is up, independent of
-- anything the game does -- so it is invisible to every other case in this file and was the
-- largest single producer of garbage in the codebase. One scroll step used to allocate one
-- single-byte string PER VISIBLE CHARACTER, around 140 of them, plus four concatenations of
-- the whole reel.
-- ---------------------------------------------------------------------------

mock.installGeyser()
emunah.ui.layout.build()
emunah.ui.chyron.build()
emunah.ui.chyron.send("Anzerloi has entered the arena.", "warning")
emunah.ui.chyron.send("Health below 40 percent.", "danger")

print("")
bench("chyron: one scroll step", function()
   mock.advance(emunah.ui.chyron.TICK_INTERVAL)
end, math.min(N, 5000))
print(string.format("%-34s %8d characters wide", "chyron: strip", emunah.ui.chyron.width()))

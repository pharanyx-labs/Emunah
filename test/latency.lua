--- Emunah latency harness: how long from the game telling us something to the command going out.
---
--- bench.lua measures what one function costs. This measures what a FIGHT is decided on: the
--- gap between a packet arriving and send() being called, end to end, through every handler
--- the real client would run -- GMCP parsing, the trigger callbacks, the UI, defence keep-up,
--- the tick -- not just engine.tick().
---
--- Two kinds of delay, measured two ways, because they are different problems:
---
---   PROCESSING -- CPU spent inside one packet before the command is sent. Measured in real
---     wall time (mock.realClock), and as a COUNT of Qt draw calls made before the send. The
---     count is the part that transfers to Mudlet: against the Geyser stub a decho costs a
---     string assignment, under Mudlet it is a rich-text parse on the same thread that has
---     not sent the cure yet. See docs/performance.md on why draws are counted, not timed.
---
---   LOGIC -- a command held back by the system's own rules: waiting on a fallback timer
---     when the game already announced the balance, waiting for the next prompt when this
---     one already had what it needed, a guard outliving the cure it guarded. Measured in
---     SIMULATED seconds on the mock clock against a scripted server, because the delay is
---     a property of the decision, not of the CPU. These are the ones worth milliseconds --
---     often hundreds of them.
---
--- Usage: lua5.1 test/latency.lua [iterations]
---
--- Runs against whatever tree it lives in (ROOT is taken from its own path), so the same
--- file run from a copy of the previous code gives the honest baseline.

local ROOT = (arg and arg[0] or ""):match("^(.*)/test/latency%.lua$") or "."
package.path = ROOT .. "/test/?.lua;" .. package.path

local mock = require("mock_mudlet")
mock.install(ROOT)
_G.EMUNAH_ROOT = ROOT
dofile(ROOT .. "/src/emunah.lua")

local N = tonumber(arg and arg[1]) or 5000
local clock = mock.realClock or os.clock

local engine = emunah.curing.engine
local detect = emunah.curing.detect
local queue  = emunah.queue
local have   = emunah.have

-- The UI is part of the path: build it, so its handlers do their real Lua work and their
-- draw calls are counted.
mock.installGeyser()
emunah.ui.layout.build()

local lastInventory = nil

--- Carry these. Fed only when it differs from what is already carried: Char.Items.List
--- invalidates the memoised counts, and a real fight does not re-list inventory every packet,
--- so re-feeding it per iteration would measure a cache miss that does not happen.
local function inventory(extra)
   local signature = ""
   for _, item in ipairs(extra or {}) do signature = signature .. item.id .. item.name end
   if signature == lastInventory then return end
   lastInventory = signature
   local items = {
      { id = "1",  name = "some bloodroot" },  { id = "2",  name = "some kelp" },
      { id = "3",  name = "some goldenseal" }, { id = "4",  name = "some lobelia" },
      { id = "5",  name = "some ginseng" },    { id = "6",  name = "some valerian" },
      { id = "7",  name = "some irid moss" },  { id = "9",  name = "some ash" },
      { id = "10", name = "some myrrh" },
   }
   for _, item in ipairs(extra or {}) do items[#items + 1] = item end
   for _, item in ipairs(items) do item.attrib = item.attrib or "" end
   mock.feed("Char.Items.List", { location = "inv", items = items })
end

local function vitals(hp)
   mock.feed("Char.Vitals", {
      hp = tostring(hp or 5400), maxhp = "6000", mp = "4600", maxmp = "5000",
      ep = "20000", maxep = "30000", wp = "20000", maxwp = "30000",
      bal = "1", eq = "1",
   })
end

--- One prompt with nothing in it, so per-prompt state settles between scenarios.
local function quiet()
   vitals()
   detect.textPrompt()
end

--- Back to a clean fight: nothing tracked, every balance back, nothing queued.
local function fresh(extraInventory)
   queue.reset()
   engine.clear()
   mock.feed("Char.Afflictions.List", {})
   for _, vector in ipairs({ "herb", "salve", "smoke", "elixir", "focus", "tree", "moss",
                             "special", "rift" }) do
      have.recover(vector)
   end
   emunah.timers.stop("cure.equilibrium")
   inventory(extraInventory)
   quiet()
   mock.sent = {}
end

engine.enabled = true

-- ---------------------------------------------------------------------------
-- Instrumentation
-- ---------------------------------------------------------------------------

local realSend = _G.send
local firstSendAt, drawsAtFirstSend

_G.send = function(command, echo)
   if not firstSendAt then
      firstSendAt = clock() - mock.matchTime
      drawsAtFirstSend = mock.draws.draw + mock.draws.clear + mock.draws.style + mock.draws.value
   end
   return realSend(command, echo)
end

--- Feed one packet the way Mudlet would: GMCP and lines in stream order, the generated
--- package's prompt trigger on every line, then control back to the event loop (zero-delay
--- timers -- Mudlet runs those once the read has been handled).
local function deliver(packet)
   for _, step in ipairs(packet) do
      local kind = step[1]
      if kind == "gmcp" then
         mock.feed(step[2], step[3])
      elseif kind == "line" then
         detect.textLine()
         mock.line(step[2])
      elseif kind == "prompt" then
         mock.prompt(step[2] or "6000h, 5000m ex-")
         detect.textPrompt()
      end
   end
   mock.advance(0)
end

--- Run a packet `iterations` times. Returns microseconds to the first send, microseconds for
--- the whole packet, draw calls before the first send, draw calls in total, and what was sent.
local function measure(setup, packet, iterations)
   local toSend, total, drawsBefore, drawsTotal, sent = 0, 0, 0, 0, nil
   local missed = 0
   for _ = 1, iterations do
      setup()
      -- Let setup's own deferred paints run now, or the measured packet is charged for them.
      mock.advance(0)
      mock.sent = {}
      local draws = mock.countDraws()
      firstSendAt, drawsAtFirstSend = nil, nil
      collectgarbage("stop")
      mock.matchTime = 0
      local started = clock()
      deliver(packet)
      local finished = clock() - mock.matchTime
      collectgarbage("restart")
      if firstSendAt then
         toSend = toSend + (firstSendAt - started)
         drawsBefore = drawsBefore + drawsAtFirstSend
      else
         missed = missed + 1
      end
      total = total + (finished - started)
      drawsTotal = drawsTotal + draws.draw + draws.clear + draws.style + draws.value
      sent = sent or table.concat(mock.sent, " | ")
   end
   local hits = iterations - missed
   return {
      toSend      = hits > 0 and toSend / hits * 1e6 or nil,
      total       = total / iterations * 1e6,
      drawsBefore = hits > 0 and drawsBefore / hits or nil,
      drawsTotal  = drawsTotal / iterations,
      sent        = (sent and sent ~= "") and sent or "(nothing)",
   }
end

local function report(label, r)
   print(string.format("%-46s %s  %9.1f us packet  %5s draws before send  %5.1f in packet",
      label,
      r.toSend and string.format("%9.1f us to send", r.toSend) or "      NOT SENT     ",
      r.total,
      r.drawsBefore and string.format("%.1f", r.drawsBefore) or "-",
      r.drawsTotal))
   print(string.format("%-46s   sent: %s", "", r.sent))
end

-- ---------------------------------------------------------------------------
-- PROCESSING: one packet, real CPU time
-- ---------------------------------------------------------------------------

print(string.format("Emunah latency -- %d iterations per packet\n", N))
print("PROCESSING (real wall time of our Lua, the mock's trigger matching subtracted;")
print("            draws are Qt work Mudlet adds on top, on the same thread)\n")

-- 1. An affliction lands. The common case in a fight: Char.Afflictions.Add inline with the
--    attack text, Char.Vitals with the damage, the prompt.
report("affliction lands (paralysis + asthma)", measure(function()
   fresh()
end, {
   { "line", "Zalydd jabs you with a needle." },
   { "gmcp", "Char.Afflictions.Add", { name = "paralysis", cure = "EAT BLOODROOT", desc = "" } },
   { "line", "Zalydd throws a dart at you." },
   { "gmcp", "Char.Afflictions.Add", { name = "asthma", cure = "EAT KELP", desc = "" } },
   { "gmcp", "Char.Vitals", { hp = "4100", maxhp = "6000", mp = "4600", maxmp = "5000",
                               ep = "20000", maxep = "30000", wp = "20000", maxwp = "30000" } },
   { "prompt" },
}, N))

-- 2. The herb balance comes back with paralysis still up.
local function herbDown()
   fresh()
   mock.feed("Char.Afflictions.Add", { name = "paralysis", cure = "EAT BLOODROOT", desc = "" })
   quiet()
   -- That prompt ate the bloodroot. The balance coming back is a herb balance later, and
   -- the 1.5s same-affliction guard has long lapsed by then; the clock here has not moved.
   engine.forgetIneffective()
   have.spend("herb")
   queue.reset()
   mock.sent = {}
end

report("herb balance back, line before Char.Vitals", measure(herbDown, {
   { "line", "You may eat another plant or mineral." },
   { "gmcp", "Char.Vitals", { hp = "5400", maxhp = "6000" } },
   { "prompt" },
}, N))

-- 3. The same, with Char.Vitals ahead of the line in the stream. Whether Achaea ever orders
--    a block this way is not established; what is established (test/run.lua, "THE PROMPT
--    TRIGGER") is that the code applied such a line at the prompt WITHOUT ticking.
report("herb balance back, Char.Vitals before line", measure(herbDown, {
   { "gmcp", "Char.Vitals", { hp = "5400", maxhp = "6000" } },
   { "line", "You may eat another plant or mineral." },
   { "prompt" },
}, N))

-- 4. Nothing to do: the floor every prompt pays.
report("idle prompt (nothing to cure)", measure(function() fresh() end, {
   { "gmcp", "Char.Vitals", { hp = "6000", maxhp = "6000" } },
   { "prompt" },
}, N))

-- ---------------------------------------------------------------------------
-- LOGIC: simulated time against a scripted server
-- ---------------------------------------------------------------------------
--
-- The server here does three things and nothing else: it announces a balance at the moment
-- the scenario says the balance really returns; it rejects, one round trip later, a command
-- sent on that balance before then; and it puts a prompt behind each. Everything else is the
-- real code.

local RTT = 0.1
local STEP = 0.01

--- Simulate one balance cycle. The vector was spent at t=0; the game returns it at `actual`
--- and says so with `announce`. Returns the time the cure command went out, or nil.
local function simulate(spec)
   fresh(spec.inventory)
   -- The balance was spent on something else; THEN the affliction lands. Spending it after a
   -- setup tick instead would leave that tick's cure for this same affliction in flight, and
   -- the 1.5s same-affliction guard would be measured instead of the balance.
   have.spend(spec.vector)
   for _, name in ipairs(spec.afflictions) do
      mock.feed("Char.Afflictions.Add", { name = name, cure = "", desc = "" })
   end
   quiet()
   mock.sent = {}

   local t, sentAt = 0, nil
   local events = {}   -- { at, packet }
   events[#events + 1] = { at = spec.actual,
      packet = { { "line", spec.announce }, { "gmcp", "Char.Vitals", { hp = "5400" } }, { "prompt" } } }

   local seen = 0
   local horizon = spec.horizon or (spec.actual + 6)
   while t < horizon do
      t = t + STEP
      mock.advance(STEP)
      -- Server: deliver anything due.
      table.sort(events, function(a, b) return a.at < b.at end)
      while events[1] and events[1].at <= t + 1e-9 do
         local event = table.remove(events, 1)
         deliver(event.packet)
      end
      -- Server: read what the client sent since we last looked.
      while seen < #mock.sent do
         seen = seen + 1
         local command = mock.sent[seen]
         if command:find(spec.match, 1, true) then
            if t + RTT / 2 < spec.actual then
               -- Arrives before the balance does: refused one round trip later.
               events[#events + 1] = { at = t + RTT,
                  packet = { { "line", spec.reject }, { "prompt" } } }
            elseif not sentAt then
               sentAt = t
            end
         end
      end
      if sentAt then break end
   end
   return sentAt
end

local function timeline(label, spec)
   local at = simulate(spec)
   local late = at and (at - spec.actual) or nil
   print(string.format("%-52s balance back at %5.2fs  cure sent at %s  -> %s",
      label, spec.actual,
      at and string.format("%5.2fs", at) or "  never",
      late and string.format("%4d ms after the game allowed it", math.floor(late * 1000 + 0.5))
            or "not within the window"))
end

print("\nLOGIC (simulated seconds; scripted server, RTT " .. RTT .. "s)\n")

-- A broken leg: salve is its only cure, so nothing but the salve balance is measured. (Anorexia
-- also cures by focus, which takes it while the salve is down.)
local salve = {
   vector = "salve", afflictions = { "brokenleftleg" },
   inventory = { { id = "8", name = "a mending salve" } },
   match = "apply mending",
   announce = "You may apply another salve to yourself.",
   reject = "You have not yet regained balance for applying salves.",
}
local focus = {
   vector = "focus", afflictions = { "anorexia" },   -- no epidermal held: focus is the cure
   match = "focus",
   announce = "Your mind is able to focus once again.",
   reject = "You have not yet regained your mental balance.",
}
local herb = {
   vector = "herb", afflictions = { "paralysis" },
   match = "eat bloodroot",
   announce = "You may eat another plant or mineral.",
   reject = "You must regain balance first.",
}

local function with(base, actual)
   local out = {}
   for k, v in pairs(base) do out[k] = v end
   out.actual = actual
   return out
end

-- The real durations are not known to this harness -- they depend on the character -- so
-- each vector is run with the game returning the balance both before and after the fallback
-- estimate (curelist.lua: salve 1.8s, focus 4.5s, herb 3.5s).
timeline("salve: game faster than the 1.8s estimate",  with(salve, 1.2))
timeline("salve: game slower than the 1.8s estimate",  with(salve, 2.2))
timeline("focus: game faster than the 4.5s estimate",  with(focus, 3.0))
timeline("focus: game slower than the 4.5s estimate",  with(focus, 5.0))
timeline("herb (control -- already announced)",         with(herb, 1.6))

-- Voyria while hurt. Its cure is an affliction-healing elixir, and health sipping wants a slot
-- too. The scripted server gives the sip back after 5s (the elixir comment in curelist.lua:
-- "around five seconds after the sip") and keeps health low, as a poison would.
do
   fresh({ { id = "5", name = "an elixir of immunity" } })
   local SIP = 5.0
   local events, seen, t = {}, 0, 0
   local healthAt, immunityAt
   mock.feed("Char.Afflictions.Add", { name = "voyria", cure = "DRINK IMMUNITY", desc = "" })
   deliver({ { "gmcp", "Char.Vitals", { hp = "3000" } }, { "prompt" } })
   while t < 20 and not immunityAt do
      while seen < #mock.sent do
         seen = seen + 1
         local command = mock.sent[seen]
         if command == "drink health" then
            healthAt = healthAt or t
            events[#events + 1] = { at = t + SIP, packet = {
               { "line", "You may drink another health or mana elixir." },
               { "gmcp", "Char.Vitals", { hp = "3000" } }, { "prompt" } } }
         elseif command == "drink immunity" then
            immunityAt = t
         end
      end
      t = t + STEP
      mock.advance(STEP)
      table.sort(events, function(a, b) return a.at < b.at end)
      while events[1] and events[1].at <= t + 1e-9 do deliver(table.remove(events, 1).packet) end
   end
   print(string.format("%-52s health sip at %s  voyria cure at %s",
      "voyria at 50% health",
      healthAt and string.format("%5.2fs", healthAt) or "never",
      immunityAt and string.format("%5.2fs", immunityAt) or "never in 20s"))
end

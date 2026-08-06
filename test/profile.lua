--- Sampling profiler for one engine tick. Diagnostic only; not part of the suite.
--- Usage: lua test/profile.lua [iterations]

local ROOT = (arg and arg[0] or ""):match("^(.*)/test/profile%.lua$") or "."
package.path = ROOT .. "/test/?.lua;" .. package.path

local mock = require("mock_mudlet")
mock.install(ROOT)
_G.EMUNAH_ROOT = ROOT
dofile(ROOT .. "/src/emunah.lua")

mock.feed("Char.Items.List", {
   location = "inv",
   items = {
      { id = "1", name = "some bloodroot", attrib = "" },
      { id = "2", name = "some kelp", attrib = "" },
      { id = "3", name = "some goldenseal", attrib = "" },
      { id = "7", name = "some irid moss", attrib = "" },
   },
})
mock.feed("Char.Vitals", {
   hp = "2400", maxhp = "6000", mp = "2200", maxmp = "5000",
   ep = "20000", maxep = "30000", wp = "20000", maxwp = "30000",
   bal = "1", eq = "1",
})
mock.feed("Char.Afflictions.List", {
   { name = "paralysis" }, { name = "stupidity" }, { name = "anorexia" },
   { name = "asthma" }, { name = "slickness" }, { name = "clumsiness" },
   { name = "weariness" }, { name = "recklessness" },
})

local engine = emunah.curing.engine
engine.enabled = true
print("tracked:", engine.count())

local N = tonumber(arg and arg[1]) or 200

local counts = {}
debug.sethook(function()
   local info = debug.getinfo(2, "Sl")
   if not info then return end
   local key = info.short_src .. ":" .. tostring(info.currentline)
   counts[key] = (counts[key] or 0) + 1
end, "", 1000)

local started = os.clock()
for _ = 1, N do
   mock.clock = mock.clock + 0.25
   engine.tick()
end
local elapsed = os.clock() - started

debug.sethook()

print(string.format("\n%.2f us/tick over %d ticks\n", elapsed / N * 1e6, N))

local rows = {}
for key, n in pairs(counts) do rows[#rows + 1] = { key = key, n = n } end
table.sort(rows, function(a, b) return a.n > b.n end)
print("hottest lines (sample counts):")
for i = 1, math.min(#rows, 25) do
   print(string.format("  %7d  %s", rows[i].n, rows[i].key))
end

print(string.format("\nmock timers outstanding: %d", (function()
   local n = 0
   for _ in pairs(mock.timers) do n = n + 1 end
   return n
end)()))

-- Turn a pasted fight log into a summary: what hit you, what each curing balance was spent
-- on, how long each balance sat idle once the game said it was back, and what was held.
--
--     lua tools/fight-report.lua fight.log
--     lua tools/fight-report.lua < fight.log
--
-- Best with `emset debug` and `emset debug gmcp` on, and a prompt that carries `*s`
-- (CONFIG PROMPT CUSTOM) -- the timestamps are what everything below is measured from.
--
-- WHAT A TIMESTAMP MEANS HERE. Only prompts carry one. A game line belongs to the block its
-- prompt closes, so it takes the NEXT prompt's time. Emunah's own lines and typed commands
-- come right after a prompt and take the LAST one's. Sends made while a later block's GMCP is
-- being read are therefore up to one block early -- around a tenth of a second in a fight.
-- Good enough to see a balance going unused for a second; not good enough to argue about
-- milliseconds.
--
-- Also loadable as a module (test/run.lua does): `dofile("tools/fight-report.lua")` returns
-- { parse = fn(lines) -> fight, render = fn(fight) -> text }.

local M = {}

local PROMPT = "H:(%d+)%% M:(%d+)%% E:%d+%% W:%d+%%.-T:%s+(%d+):(%d+):([%d%.]+)"

-- The game's own "your balance is back" lines, per curing balance (docs/game/balance.md).
local RECOVERED = {
   { vector = "herb",   line = "You may eat another plant or mineral." },
   { vector = "moss",   line = "You may eat another bit of irid moss or potash." },
   { vector = "elixir", line = "You may drink another health or mana elixir." },
   { vector = "purgative", line = "You may drink another affliction-healing elixir." },
   { vector = "salve",  line = "You may apply another salve to yourself." },
   { vector = "equilibrium", line = "You have recovered equilibrium." },
}

local function seconds(h, m, s)
   return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
end

local function clock(t)
   if not t then return "--:--:--.--" end
   local h = math.floor(t / 3600)
   local m = math.floor((t - h * 3600) / 60)
   return string.format("%02d:%02d:%05.2f", h, m, t - h * 3600 - m * 60)
end

local function bump(map, key, by)
   map[key] = (map[key] or 0) + (by or 1)
end

--- Join GMCP trace entries Mudlet wrapped over several lines: an entry runs until its braces
--- balance.
local function unwrap(lines)
   local out, open = {}, nil
   for _, line in ipairs(lines) do
      if open then
         open = open .. line
         local _, l = open:gsub("{", ""); local _, r = open:gsub("}", "")
         if l <= r then out[#out + 1] = open; open = nil end
      elseif line:find("^%[gmcp%] <<") then
         local _, l = line:gsub("{", ""); local _, r = line:gsub("}", "")
         if l > r then open = line else out[#out + 1] = line end
      else
         out[#out + 1] = line
      end
   end
   if open then out[#out + 1] = open end
   return out
end

--- Read a log into a fight record.
function M.parse(lines)
   lines = unwrap(lines)

   -- Each line's time: next prompt for game text, last prompt for our own lines.
   local nextPrompt, lastPrompt = {}, {}
   local upcoming
   for index = #lines, 1, -1 do
      local h, mp, hh, mm, ss = lines[index]:match(PROMPT)
      if hh then upcoming = seconds(hh, mm, ss) end
      nextPrompt[index] = upcoming
   end
   local seen
   for index = 1, #lines do
      local hh, mm, ss = select(3, lines[index]:match(PROMPT))
      if hh then seen = seconds(hh, mm, ss) end
      lastPrompt[index] = seen
   end

   local fight = {
      first = nil, last = nil, lowest = nil, lowestAt = nil, died = nil,
      damage = {}, damageTotal = 0,
      sends = {}, sendOrder = {},
      gained = {}, gainedOrder = {},
      held = {}, heldOrder = {},
      idle = {},
   }
   local waiting = {}   -- vector -> time the game said it was back

   for index, line in ipairs(lines) do
      local hp, _, hh, mm, ss = line:match(PROMPT)
      if hh then
         local t = seconds(hh, mm, ss)
         fight.first = fight.first or t
         fight.last = t
         hp = tonumber(hp)
         if not fight.lowest or hp < fight.lowest then fight.lowest, fight.lowestAt = hp, t end
      end

      local gameTime = nextPrompt[index] or lastPrompt[index]
      local ourTime  = lastPrompt[index] or nextPrompt[index]

      local amount, kind = line:match("^Health lost: (%d+) %((.-)%)")
      if amount then
         bump(fight.damage, kind, tonumber(amount))
         fight.damageTotal = fight.damageTotal + tonumber(amount)
      end

      if line:find("You have been slain by", 1, true) or line:find("^You have died") then
         fight.died = gameTime
      end

      for _, balance in ipairs(RECOVERED) do
         if line:find(balance.line, 1, true) then waiting[balance.vector] = gameTime end
      end

      local vector, command, tag = line:match("^%[emunah%] Sent %[(%w+)%] (.-) %((.-)%)$")
      if vector then
         local key = vector .. ": " .. command .. " (" .. tag .. ")"
         if not fight.sends[key] then fight.sendOrder[#fight.sendOrder + 1] = key end
         bump(fight.sends, key)
         local back = waiting[vector]
         if back and ourTime then
            local record = fight.idle[vector] or { count = 0, total = 0, worst = 0 }
            fight.idle[vector] = record
            local gap = math.max(ourTime - back, 0)
            record.count, record.total = record.count + 1, record.total + gap
            if gap > record.worst then record.worst, record.worstAt = gap, ourTime end
            waiting[vector] = nil
         end
      end

      local name = line:match("^%[gmcp%] << Char%.Afflictions%.Add .-name=\"([%w_]+)\"")
      if name then
         if not fight.gained[name] then fight.gainedOrder[#fight.gainedOrder + 1] = name end
         bump(fight.gained, name)
      end

      local what = line:match("^%[emunah%] (Cannot cure .-%.)$")
         or line:match("^%[emunah%] (Holding .-%.)$")
      if what then
         -- One entry per fact, with when it was first said and how often.
         if not fight.held[what] then
            fight.heldOrder[#fight.heldOrder + 1] = what
            fight.held[what] = { first = ourTime, count = 0 }
         end
         fight.held[what].count = fight.held[what].count + 1
      end
   end

   -- A balance announced and never used before the log ended is idle to the end.
   for vector, back in pairs(waiting) do
      if fight.last and back then
         local record = fight.idle[vector] or { count = 0, total = 0, worst = 0 }
         fight.idle[vector] = record
         local gap = fight.last - back
         if gap > record.worst then
            record.worst, record.worstAt, record.unused = gap, back, true
         end
      end
   end
   return fight
end

local function sortedKeys(map, byValue)
   local keys = {}
   for key in pairs(map) do keys[#keys + 1] = key end
   table.sort(keys, function(a, b)
      if byValue and map[a] ~= map[b] then return map[a] > map[b] end
      return a < b
   end)
   return keys
end

--- A fight record as text.
function M.render(fight)
   local out = {}
   local function say(...) out[#out + 1] = string.format(...) end

   if not fight.first then
      say("No timestamped prompts found. Add *s to the prompt (CONFIG PROMPT CUSTOM).")
      return table.concat(out, "\n")
   end
   say("Fight %s - %s (%.1fs)%s", clock(fight.first), clock(fight.last),
      fight.last - fight.first, fight.died and ("  -- died at " .. clock(fight.died)) or "")
   if fight.lowest then say("Lowest health %d%% at %s", fight.lowest, clock(fight.lowestAt)) end

   say("")
   say("Damage taken: %d", fight.damageTotal)
   for _, kind in ipairs(sortedKeys(fight.damage, true)) do
      say("  %6d  %s", fight.damage[kind], kind)
   end

   say("")
   say("Sent, by balance:")
   local byVector = {}
   for _, key in ipairs(fight.sendOrder) do
      local vector = key:match("^(%w+):")
      byVector[vector] = byVector[vector] or {}
      table.insert(byVector[vector], key)
   end
   for _, vector in ipairs(sortedKeys(byVector)) do
      local total = 0
      for _, key in ipairs(byVector[vector]) do total = total + fight.sends[key] end
      say("  %s (%d)", vector, total)
      table.sort(byVector[vector], function(a, b) return fight.sends[a] > fight.sends[b] end)
      for _, key in ipairs(byVector[vector]) do
         say("    %3d  %s", fight.sends[key], key:match("^%w+: (.*)$"))
      end
   end

   say("")
   say("Balance back -> next send on it (idle time):")
   for _, vector in ipairs(sortedKeys(fight.idle)) do
      local r = fight.idle[vector]
      local mean = r.count > 0 and r.total / r.count or 0
      say("  %-12s %2d sends, mean %.2fs, worst %.2fs%s%s", vector, r.count, mean, r.worst,
         r.worstAt and (" at " .. clock(r.worstAt)) or "",
         r.unused and " (never used before the log ended)" or "")
   end

   if #fight.gainedOrder > 0 then
      say("")
      say("Afflictions gained (Char.Afflictions.Add):")
      for _, name in ipairs(sortedKeys(fight.gained, true)) do
         say("  %3d  %s", fight.gained[name], name)
      end
   end

   if #fight.heldOrder > 0 then
      say("")
      say("Held or refused (first said, times said):")
      for _, what in ipairs(fight.heldOrder) do
         local r = fight.held[what]
         say("  %s  x%-3d %s", clock(r.first), r.count, what)
      end
   end
   return table.concat(out, "\n")
end

-- Run from the command line; return the module when loaded with dofile().
local running = arg and arg[0] and arg[0]:find("fight%-report%.lua$")
if running and not M.__noMain then
   local handle = arg[1] and assert(io.open(arg[1], "r")) or io.stdin
   local lines = {}
   for line in handle:lines() do lines[#lines + 1] = (line:gsub("\r$", "")) end
   if handle ~= io.stdin then handle:close() end
   io.write(M.render(M.parse(lines)), "\n")
end

return M

--- Small helpers shared across the system. No dependencies beyond Mudlet.

local util = {}

-- ---------------------------------------------------------------------------
-- GMCP value coercion
-- ---------------------------------------------------------------------------

--- Interpret a GMCP boolean.
---
--- IRE sends booleans as the *strings* "1" and "0" (Char.Vitals.bal, Char.Vitals.eq,
--- and most class flags). In Lua the string "0" is truthy, so `if gmcp.Char.Vitals.bal`
--- is true even when you have no balance. That single mistake is the most common bug in
--- Achaea systems -- it makes the system fire attacks off balance and silently swallow
--- the "You must regain balance first" rejection. Always route through this.
--- @param value any raw GMCP field
--- @return boolean
function util.bool(value)
   if type(value) == "boolean" then return value end
   if type(value) == "number" then return value ~= 0 end
   if type(value) == "string" then
      return value == "1" or value == "true" or value == "yes"
   end
   return false
end

--- Coerce a GMCP field to a number, tolerating strings and nil.
--- @param value any
--- @param default number|nil returned when the value will not convert
--- @return number|nil
function util.num(value, default)
   if type(value) == "number" then return value end
   if type(value) == "string" then
      local n = tonumber((value:gsub("[^%-%d%.]", "")))
      if n then return n end
   end
   return default
end

--- Percentage of current against max, clamped to 0-100. Guards the divide-by-zero that
--- happens on the very first Char.Vitals before maxhp is populated.
--- @return number
function util.percent(current, max)
   current, max = util.num(current, 0), util.num(max, 0)
   if max <= 0 then return 0 end
   local pct = (current / max) * 100
   if pct < 0 then return 0 end
   if pct > 100 then return 100 end
   return pct
end

-- ---------------------------------------------------------------------------
-- strings
-- ---------------------------------------------------------------------------

function util.trim(s)
   if type(s) ~= "string" then return "" end
   return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split on a Lua pattern.
--- @return table
function util.split(s, sep)
   local out = {}
   if type(s) ~= "string" then return out end
   sep = sep or "%s"
   for piece in s:gmatch("([^" .. sep .. "]+)") do
      out[#out + 1] = piece
   end
   return out
end

function util.capitalise(s)
   if type(s) ~= "string" or s == "" then return s end
   return s:sub(1, 1):upper() .. s:sub(2):lower()
end

--- Format a number with thousands separators (gold, experience).
function util.comma(n)
   n = util.num(n, 0)
   local whole = tostring(math.floor(n))
   local out = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse()
   return (out:gsub("^,", ""))
end

--- Seconds as a compact duration: 4.2s, 1m12s, 2h05m.
function util.duration(seconds)
   seconds = util.num(seconds, 0)
   if seconds < 60 then return string.format("%.1fs", seconds) end
   if seconds < 3600 then
      return string.format("%dm%02ds", math.floor(seconds / 60), math.floor(seconds % 60))
   end
   return string.format("%dh%02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

-- ---------------------------------------------------------------------------
-- tables
-- ---------------------------------------------------------------------------

function util.contains(tbl, value)
   if type(tbl) ~= "table" then return false end
   for _, v in pairs(tbl) do
      if v == value then return true end
   end
   return false
end

function util.count(tbl)
   if type(tbl) ~= "table" then return 0 end
   local n = 0
   for _ in pairs(tbl) do n = n + 1 end
   return n
end

function util.keys(tbl)
   local out = {}
   if type(tbl) ~= "table" then return out end
   for k in pairs(tbl) do out[#out + 1] = k end
   table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
   return out
end

function util.copy(tbl)
   if type(tbl) ~= "table" then return tbl end
   local out = {}
   for k, v in pairs(tbl) do
      out[k] = type(v) == "table" and util.copy(v) or v
   end
   return out
end

--- Shallow-merge `overrides` onto a copy of `base`.
function util.merge(base, overrides)
   local out = util.copy(base) or {}
   for k, v in pairs(overrides or {}) do out[k] = v end
   return out
end

--- Set difference on set-shaped tables ({ [key] = true }): keys in a but not in b.
function util.missing(a, b)
   local out = {}
   for k in pairs(a or {}) do
      if not (b or {})[k] then out[#out + 1] = k end
   end
   table.sort(out)
   return out
end

--- Build a set from an array. Handy for membership tests on GMCP lists.
function util.set(list)
   local out = {}
   for _, v in ipairs(list or {}) do out[v] = true end
   return out
end

--- Wall-clock seconds, as a float.
---
--- NOT os.clock(), which returns CPU time. Mudlet spends almost all of its life idle, so
--- CPU seconds accrue far slower than real ones -- a "0.6 seconds since the last step"
--- check written against os.clock() can take many real seconds to come true, and one
--- written as a retry loop defers itself indefinitely. That was the walker taking ages
--- between rooms.
---
--- Mudlet's getEpoch() is the wall clock with sub-second precision; os.time() is the
--- portable fallback but only whole seconds, so it is a last resort rather than a peer.
function util.now()
   if type(getEpoch) == "function" then
      local ok, value = pcall(getEpoch)
      if ok and tonumber(value) then return tonumber(value) end
   end
   return os.time()
end

return util

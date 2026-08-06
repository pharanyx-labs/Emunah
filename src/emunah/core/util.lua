--- Small helpers shared across the system. No dependencies beyond Mudlet.

local M = {}

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
function M.bool(value)
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
function M.num(value, default)
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
function M.percent(current, max)
   current, max = M.num(current, 0), M.num(max, 0)
   if max <= 0 then return 0 end
   local pct = (current / max) * 100
   if pct < 0 then return 0 end
   if pct > 100 then return 100 end
   return pct
end

-- ---------------------------------------------------------------------------
-- strings
-- ---------------------------------------------------------------------------

--- One `match`, not two chained `gsub`s.
---
--- `s:gsub(...):gsub(...)` builds an intermediate string and then a second one, and returns
--- a count alongside each that the parens then throw away. A single anchored lazy match does
--- the same job with one allocation -- and none at all when there is no whitespace to trim,
--- because Lua hands back the interned original rather than a copy. This is called from the
--- charstats parse on every prompt and from every command handler that reads an argument.
function M.trim(s)
   if type(s) ~= "string" then return "" end
   return s:match("^%s*(.-)%s*$")
end

--- Split on a Lua pattern.
--- @return table
function M.split(s, sep)
   local out = {}
   if type(s) ~= "string" then return out end
   sep = sep or "%s"
   for piece in s:gmatch("([^" .. sep .. "]+)") do
      out[#out + 1] = piece
   end
   return out
end

function M.capitalise(s)
   if type(s) ~= "string" or s == "" then return s end
   return s:sub(1, 1):upper() .. s:sub(2):lower()
end

--- Format a number with thousands separators (gold, experience).
function M.comma(n)
   n = M.num(n, 0)
   local whole = tostring(math.floor(n))
   local out = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse()
   return (out:gsub("^,", ""))
end

--- Seconds as a compact duration: 4.2s, 1m12s, 2h05m.
function M.duration(seconds)
   seconds = M.num(seconds, 0)
   if seconds < 60 then return string.format("%.1fs", seconds) end
   if seconds < 3600 then
      return string.format("%dm%02ds", math.floor(seconds / 60), math.floor(seconds % 60))
   end
   return string.format("%dh%02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

-- ---------------------------------------------------------------------------
-- tables
-- ---------------------------------------------------------------------------

function M.contains(tbl, value)
   if type(tbl) ~= "table" then return false end
   for _, v in pairs(tbl) do
      if v == value then return true end
   end
   return false
end

function M.count(tbl)
   if type(tbl) ~= "table" then return 0 end
   local n = 0
   for _ in pairs(tbl) do n = n + 1 end
   return n
end

function M.keys(tbl)
   local out = {}
   if type(tbl) ~= "table" then return out end
   for k in pairs(tbl) do out[#out + 1] = k end
   table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
   return out
end

function M.copy(tbl)
   if type(tbl) ~= "table" then return tbl end
   local out = {}
   for k, v in pairs(tbl) do
      out[k] = type(v) == "table" and M.copy(v) or v
   end
   return out
end

--- Shallow-merge `overrides` onto a copy of `base`.
function M.merge(base, overrides)
   local out = M.copy(base) or {}
   for k, v in pairs(overrides or {}) do out[k] = v end
   return out
end

--- Set difference on set-shaped tables ({ [key] = true }): keys in a but not in b.
function M.missing(a, b)
   local out = {}
   for k in pairs(a or {}) do
      if not (b or {})[k] then out[#out + 1] = k end
   end
   table.sort(out)
   return out
end

--- Build a set from an array. Handy for membership tests on GMCP lists.
function M.set(list)
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
function M.now()
   if type(getEpoch) == "function" then
      local ok, value = pcall(getEpoch)
      if ok and tonumber(value) then return tonumber(value) end
   end
   return os.time()
end

-- ---------------------------------------------------------------------------
-- destructive-action confirmation
-- ---------------------------------------------------------------------------

local pendingConfirms = {}

--- Two-step confirmation for anything that discards user data with no way back. The first
--- call for a given `key` returns false (asking) and starts the clock; a second call for
--- the same key within `window` seconds returns true (confirmed) and clears it. A repeat
--- past the window starts over rather than confirming, so a stale "yes" from an unrelated
--- moment can never land.
---
--- `key` distinguishes independent pending confirmations sharing one clock, e.g.
--- "ndb.forgetAll" vs. "ndb.unnoteAll.anzerloi" -- confirming one must never confirm another.
--- @param key string
--- @param window number|nil seconds to wait for the repeat; default 15
--- @return boolean confirmed
function M.confirm(key, window)
   window = window or 15
   local now = M.now()
   if pendingConfirms[key] and (now - pendingConfirms[key]) < window then
      pendingConfirms[key] = nil
      return true
   end
   pendingConfirms[key] = now
   return false
end

return M

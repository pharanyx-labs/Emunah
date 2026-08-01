--- Char.StatusVars and Char.Status -- the character sheet.
---
--- StatusVars is a one-time map of internal key -> human caption, e.g.
---   { name = "Name", level = "Level", class = "Class", gold = "Gold", ... }
--- Status then carries values against those internal keys, and arrives both in full and
--- as partial updates (a single { gold = "1234" } when you sell something).
---
--- The captions matter: they are what makes a generic status panel possible without
--- hardcoding Achaea's field list, and they change between IRE games and between
--- classes, so we render from them rather than from our own labels.

local M = {}

local util  = emunah.util
local event = emunah.event

--- internal key -> caption
M.vars = {}
--- internal key -> current value (string, as the game sends it)
M.values = {}

local function onStatusVars()
   local vars = gmcp.Char.StatusVars
   if type(vars) ~= "table" then return end
   M.vars = {}
   for key, caption in pairs(vars) do
      M.vars[key] = tostring(caption)
   end
   event.raise("status.vars", M.vars)
end

local function onStatus()
   local status = gmcp.Char.Status
   if type(status) ~= "table" then return end

   local changed = {}
   for key, value in pairs(status) do
      value = (value ~= nil) and tostring(value) or nil
      if M.values[key] ~= value then
         changed[key] = value
         M.values[key] = value
      end
   end

   if next(changed) then
      event.raise("status", changed)
   end
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

--- Raw value for an internal key: status.get("class"), status.get("gold").
function M.get(key, fallback)
   local value = M.values[key]
   if value == nil then return fallback end
   return value
end

--- Numeric value for a key. Achaea sends gold and experience with no separators, but
--- other fields (bank balances in some contexts) can carry commas.
function M.number(key, fallback)
   return util.num(M.values[key], fallback)
end

--- Human caption for a key, falling back to a title-cased version of the key itself so
--- the UI always has something to print.
function M.caption(key)
   return M.vars[key] or util.capitalise(tostring(key))
end

--- Frequently used fields, named so callers do not have to remember Achaea's key
--- spellings. All are nil-safe before the first Char.Status arrives.
function M.name()      return M.get("name") end
function M.class()     return M.get("class") end
function M.level()     return M.number("level", 0) end
function M.city()      return M.get("city") end
function M.house()     return M.get("house") end
function M.order()     return M.get("order") end
function M.gold()      return M.number("gold", 0) end
function M.bank()      return M.number("bank", 0) end
function M.race()      return M.get("race") end
function M.xprank()    return M.get("xprank") end
function M.explorer()  return M.get("explorerrank") end
function M.target()    return M.get("target") end

--- Everything, keyed by caption rather than internal key -- what a status panel wants.
function M.captioned()
   local out = {}
   for key, value in pairs(M.values) do
      out[M.caption(key)] = value
   end
   return out
end

function M.all()
   return util.copy(M.values)
end

event.gmcp("Char.StatusVars", onStatusVars, "gmcp.status")
event.gmcp("Char.Status",     onStatus,     "gmcp.status")

if gmcp and gmcp.Char then
   if gmcp.Char.StatusVars then onStatusVars() end
   if gmcp.Char.Status then onStatus() end
end

return M

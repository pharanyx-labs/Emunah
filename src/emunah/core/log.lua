--- Levelled console output.
---
--- Everything the system says to the user goes through here so that a single setting
--- controls verbosity, and so debug chatter can be left in the code permanently instead
--- of being commented in and out.

local log = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4, silent = 99 }

local STYLE = {
   debug = { tag = "ansi_light_black", text = "ansi_light_black" },
   info  = { tag = "ansi_cyan",        text = "reset"            },
   warn  = { tag = "ansi_yellow",      text = "ansi_yellow"      },
   error = { tag = "ansi_red",         text = "ansi_light_red"   },
}

--- Current threshold. Set via `emunah.log.setLevel("debug")` or the config module.
log.level = "info"

function log.setLevel(level)
   if not LEVELS[level] then
      log.warn(("Unknown log level %q -- keeping %q."):format(tostring(level), log.level))
      return false
   end
   log.level = level
   return true
end

local function emit(level, message)
   if LEVELS[level] < LEVELS[log.level or "info"] then return end
   local style = STYLE[level] or STYLE.info
   cecho(string.format(
      "\n<ansi_light_black>[<reset><%s>emunah<reset><ansi_light_black>]<reset> <%s>%s<reset>",
      style.tag, style.text, message))
end

local function format(fmt, ...)
   if select("#", ...) == 0 then return tostring(fmt) end
   local ok, result = pcall(string.format, tostring(fmt), ...)
   -- A logging call must never be the thing that breaks a curing tick.
   return ok and result or tostring(fmt)
end

function log.debug(fmt, ...) emit("debug", format(fmt, ...)) end
function log.info(fmt, ...)  emit("info",  format(fmt, ...)) end
function log.warn(fmt, ...)  emit("warn",  format(fmt, ...)) end
function log.error(fmt, ...) emit("error", format(fmt, ...)) end

--- Print a table to the console for inspection. Thin wrapper over Mudlet's display()
--- that keeps the emunah prefix so output is attributable.
function log.dump(label, value)
   emit("info", tostring(label) .. ":")
   display(value)
end

-- ---------------------------------------------------------------------------
-- GMCP tracing
-- ---------------------------------------------------------------------------
--
-- Deliberately its own switch rather than part of the debug level. Achaea sends Char.Vitals
-- with every prompt and several more messages per room change, so folding this into
-- `emunah debug` would bury the thing you turned debug on to see. `emunah debug gmcp` opts
-- into the firehose separately.

log.traceGmcp = false

--- One-line summary of a GMCP payload. Full tables go to display() only on request --
--- printing them inline for every prompt is unreadable, and the shape is usually enough to
--- tell "arrived and empty" from "never arrived".
local function summarise(value, depth)
   depth = depth or 0
   local kind = type(value)
   if kind ~= "table" then
      if kind == "string" then return ("%q"):format(value) end
      return tostring(value)
   end
   if depth >= 2 then return "{...}" end

   -- Arrays report their length; that is the interesting part of an item or affliction list.
   if #value > 0 then return ("[%d]"):format(#value) end

   local parts, n = {}, 0
   for k, v in pairs(value) do
      n = n + 1
      if n > 6 then parts[#parts + 1] = "..." break end
      parts[#parts + 1] = tostring(k) .. "=" .. summarise(v, depth + 1)
   end
   if n == 0 then return "{}" end
   table.sort(parts)
   return "{" .. table.concat(parts, " ") .. "}"
end

log.summarise = summarise

--- Trace one GMCP message. `direction` is "<<" for received, ">>" for sent.
function log.gmcp(direction, message, payload)
   if not log.traceGmcp then return end
   local detail = payload ~= nil and (" " .. summarise(payload)) or ""
   cecho(string.format(
      "\n<ansi_light_black>[<reset><ansi_magenta>gmcp<reset><ansi_light_black>]<reset> " ..
      "<ansi_light_black>%s<reset> <ansi_cyan>%s<reset><ansi_light_black>%s<reset>",
      direction, tostring(message), detail))
end

return log

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

--- Would a message at this level actually print?
---
--- THE GUARD HAS TO COME BEFORE format(), not inside emit(). Every log call used to build
--- its message first and discard it in emit() a moment later, and the debug calls are the
--- ones that matter: engine.tick() reaches log.debug several times per prompt -- once per
--- resolved cure, once per queue push that loses its slot, once per command sent, once per
--- command held -- and each one ran a pcall and a string.format whose result nothing ever
--- saw, because the default level is `info`.
---
--- That is per-prompt work in the one code path that cannot afford any, and it is paid by
--- every user who is not actively debugging. Formatting is now the caller's cost only when
--- something will be printed.
function log.enabled(level)
   return LEVELS[level or "info"] >= LEVELS[log.level or "info"]
end

local enabled = log.enabled

function log.debug(fmt, ...) if enabled("debug") then emit("debug", format(fmt, ...)) end end
function log.info(fmt, ...)  if enabled("info")  then emit("info",  format(fmt, ...)) end end
function log.warn(fmt, ...)  if enabled("warn")  then emit("warn",  format(fmt, ...)) end end
function log.error(fmt, ...) if enabled("error") then emit("error", format(fmt, ...)) end end

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
--
-- Defaults OFF: Char.Vitals alone fires on every prompt, so a fresh session opened this
-- with the firehose already running before anyone asked for it. This is not persisted
-- config (module state is deliberately NOT carried across a reload, see emunah.lua's
-- loader), so every session starts from whatever is hardcoded here regardless. `emunah
-- debug gmcp` (or `! debug gmcp`) turns it on for the rest of the session.

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

--- Make a traced payload safe to hand to cecho.
---
--- Every other GMCP field traced here is clean JSON. `Comm.Channel.Text` is not: it
--- carries RAW ANSI, including IRE's own ESC...EOT terminator that `gmcp/comm.lua`
--- documents having to strip before render. cecho reads a bare "<" as the start of colour
--- markup, and a raw ESC or EOT byte or an unescaped "<" in a channel message (a smiley, a
--- comparison, anything) broke cecho's parser outright -- confirmed live: with tracing on,
--- Comm.Channel.Text rendered nowhere, not the trace line and not the chat window, because
--- the failure happened inside this call, before onText() in gmcp/comm.lua ever ran and
--- before the message reached its own history buffer. Turning tracing off was the whole
--- fix from the outside. `<<` is cecho's own escape for a literal "<"; control bytes are
--- dropped outright since none of them are meant to be seen in a one-line trace anyway.
local function sanitize(text)
   text = tostring(text):gsub("%c", "")
   return (text:gsub("<", "<<"))
end

--- Trace one GMCP message. `direction` is "<<" for received, ">>" for sent.
function log.gmcp(direction, message, payload)
   if not log.traceGmcp then return end
   local detail = payload ~= nil and (" " .. sanitize(summarise(payload))) or ""
   -- A logging call must never be the thing that breaks a GMCP handler -- sanitize()
   -- covers every case found in play, but pcall is the backstop for whatever it does not.
   local ok = pcall(cecho, string.format(
      "\n<ansi_light_black>[<reset><ansi_magenta>gmcp<reset><ansi_light_black>]<reset> " ..
      "<ansi_light_black>%s<reset> <ansi_cyan>%s<reset><ansi_light_black>%s<reset>",
      direction, tostring(message), detail))
   if not ok then
      cecho(string.format(
         "\n<ansi_light_black>[<reset><ansi_magenta>gmcp<reset><ansi_light_black>]<reset> " ..
         "%s %s (payload could not be traced)\n", direction, tostring(message)))
   end
end

return log

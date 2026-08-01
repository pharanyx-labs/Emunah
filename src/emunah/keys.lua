--- Numpad movement keybindings.
---
---   7 nw    8 n     9 ne
---   4 w     5 look  6 e
---   1 sw    2 s     3 se
---   0 in    . out   + up    - down
---
--- NUM LOCK IS THE WHOLE PROBLEM
--- ----------------------------
--- A numpad key does not send one key code. With Num Lock ON it sends the digit
--- (mudlet.key["8"]); with Num Lock OFF it sends the navigation key the numpad shares that
--- position with (mudlet.key.Up). Binding only the digits gives you a keypad that works
--- until someone taps Num Lock and then silently does nothing -- which reads as "the
--- bindings broke" rather than "the keyboard changed mode".
---
--- So every direction is bound TWICE, once for each state. Both carry
--- mudlet.keymodifier.Keypad, which is what distinguishes numpad 8 from the 8 above the
--- letters -- without it, typing 8 in a sentence would walk you north.
---
--- Bindings are tracked on _persist and killed before re-registering, for the same reason
--- event handlers and aliases are: Mudlet keeps them alive independently of the Lua state
--- that created them, so a reload would otherwise stack a second set and send every
--- direction twice.

local M = {}

local log   = emunah.log
local event = emunah.event

--- direction -> { numlockOn, numlockOff } key names in mudlet.key.
--- The second column is the navigation key that shares each numpad position.
M.LAYOUT = {
   { command = "nw",   on = "7", off = "Home"     },
   { command = "n",    on = "8", off = "Up"       },
   { command = "ne",   on = "9", off = "PageUp"   },
   { command = "w",    on = "4", off = "Left"     },
   { command = "look", on = "5", off = "Clear"    },
   { command = "e",    on = "6", off = "Right"    },
   { command = "sw",   on = "1", off = "End"      },
   { command = "s",    on = "2", off = "Down"     },
   { command = "se",   on = "3", off = "PageDown" },
   { command = "in",   on = "0", off = "Insert"   },
   { command = "out",  on = "Period", off = "Delete" },
   { command = "up",   on = "Plus"  },
   { command = "down", on = "Minus" },
}

--- Directions that move you. `look` does not, so it must not interrupt a walk.
local MOVEMENT = {
   n = true, ne = true, e = true, se = true, s = true, sw = true, w = true, nw = true,
   ["in"] = true, out = true, up = true, down = true,
}

local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.keyBindings = emunah._persist.keyBindings or {}
   return emunah._persist.keyBindings
end

--- Remove every binding we own.
function M.killAll()
   local reg = registry()
   local n = 0
   for _, id in ipairs(reg) do
      if killKey(id) then n = n + 1 end
   end
   emunah._persist.keyBindings = {}
   return n
end

--- Send a direction.
---
--- A manual movement key takes control back from automation. Pressing a direction while an
--- automated walk is running otherwise means two things steering at once, and the walker
--- wins the next time it ticks, so the keypress appears to do nothing.
---
--- It stops BOTH the walker and bashing, and says so at info level. Stopping only the
--- walker left bashing running with nothing to move it, which looked like the hunt had
--- died for no reason; and doing it silently meant a single stray keypress ended a hunt
--- with no explanation anywhere -- "Walk finished: 0 visited (manual movement)" is only
--- obvious once you know a numpad key can cause it.
function M.go(command)
   if MOVEMENT[command] then
      local stopped = {}
      if emunah.bashing and emunah.bashing.enabled then
         emunah.bashing.stop("manual movement")
         stopped[#stopped + 1] = "bashing"
      end
      if emunah.walker and emunah.walker.enabled then
         emunah.walker.stop("manual movement")
         stopped[#stopped + 1] = "the walk"
      end
      if #stopped > 0 then
         emunah.log.info("Stopped %s -- you moved manually (%s).",
            table.concat(stopped, " and "), command)
      end
   end
   send(command)
end

local function available()
   return type(tempKey) == "function"
      and type(mudlet) == "table"
      and type(mudlet.key) == "table"
      and type(mudlet.keymodifier) == "table"
end

--- Install the bindings.
function M.build()
   if not emunah.config.get("keys.numpad", true) then
      log.debug("Numpad bindings disabled in settings.")
      return false
   end

   if not available() then
      log.debug("tempKey/mudlet.key unavailable -- numpad bindings not installed.")
      return false
   end

   M.killAll()

   local reg = registry()
   local keypad = mudlet.keymodifier.Keypad
   local bound, missing = 0, {}

   for _, entry in ipairs(M.LAYOUT) do
      -- Both Num Lock states map to the same command.
      for _, field in ipairs({ "on", "off" }) do
         local keyName = entry[field]
         if keyName then
            local code = mudlet.key[keyName]
            if code then
               local ok, id = pcall(tempKey, keypad, code, function()
                  M.go(entry.command)
               end)
               if ok and id then
                  table.insert(reg, id)
                  bound = bound + 1
               end
            else
               missing[#missing + 1] = keyName
            end
         end
      end
   end

   if #missing > 0 then
      log.warn("Unknown key names, not bound: %s", table.concat(missing, ", "))
   end

   log.debug("Numpad: %d bindings for %d directions.", bound, #M.LAYOUT)
   return bound > 0
end

function M.setEnabled(enabled)
   emunah.config.set("keys.numpad", enabled)
   emunah.config.save()
   if enabled then
      M.build()
   else
      M.killAll()
   end
   log.info("Numpad movement %s.",
      enabled and "<ansi_light_green>on<ansi_yellow>" or "<ansi_light_red>off<ansi_yellow>")
   return enabled
end

function M.toggle()
   return M.setEnabled(not emunah.config.get("keys.numpad", true))
end

--- What is bound, for `emunah keys`.
function M.list()
   local out = {}
   for _, entry in ipairs(M.LAYOUT) do
      out[#out + 1] = {
         command = entry.command,
         numlockOn = entry.on,
         numlockOff = entry.off,
      }
   end
   return out
end

function M.count()
   return #registry()
end

event.register("sysDisconnectionEvent", function()
   -- Bindings are harmless while disconnected, but a stale walker reference is not.
end, "keys")

M.build()

return M

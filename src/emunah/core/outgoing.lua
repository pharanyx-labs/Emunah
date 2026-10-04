--- What has been sent to the game recently: typed by you, or sent by Emunah.
---
--- WHY THIS EXISTS
--- ---------------
--- Several questions come down to "did we just ask for this?":
---
---   * ANTI-ILLUSION. A line describing something we did is only believable if we did it.
---     The quit prayer answered with INR ALL, and stopped restocking for the session, on
---     the strength of one line anybody can fake; it only ever follows a QUIT (the user,
---     2026-10-04), so it is believed only after one. svof applies the same test throughout
---     ("Didn't send the 'angel sacrifice' command recently.").
---   * ANTITHEFT. An item leaving the inventory is ordinary when we just sent GIVE, PUT,
---     DROP, SELL or EAT, and alarming when nothing we sent explains it.
---   * QUITTING. QUIT or QQ typed means the client is closing (the user, 2026-10-04).
---
--- Mudlet raises sysDataSendRequest for every command bound for the game, typed or
--- send(), after aliases have had their turn -- so this sees exactly what the server
--- receives, and nothing an alias swallowed.

local M = {}

--- How long a command is remembered. Long enough for any confirmation to arrive, short
--- enough that the list stays a few entries long.
M.WINDOW = 10.0

--- { at = seconds, command = lowercased command }, newest last.
M.recent = {}

--- When QUIT or QQ was last sent, or nil.
M.quitAt = nil

--- Did we send a command matching this Lua pattern within `window` seconds?
--- @param pattern string Lua pattern, matched against the lowercased, trimmed command
--- @param window number|nil seconds; defaults to M.WINDOW
--- @return boolean
function M.sentRecently(pattern, window)
   local since = emunah.util.now() - (tonumber(window) or M.WINDOW)
   for index = #M.recent, 1, -1 do
      local entry = M.recent[index]
      if entry.at < since then return false end
      if entry.command:find(pattern) then return true end
   end
   return false
end

--- When the newest command satisfying `test` (a function of the lowercased command) went
--- out, or nil if none is remembered.
function M.lastSent(test)
   for index = #M.recent, 1, -1 do
      local entry = M.recent[index]
      if test(entry.command) then return entry.at end
   end
   return nil
end

--- Is this command QUIT, or its QQ shortcut? Exact words only: `quit` inside some longer
--- command (a tell, `quit` as an argument) is not leaving.
function M.isQuit(command)
   command = tostring(command or ""):lower():match("^%s*(.-)%s*$")
   return command == "quit" or command == "qq"
end

function M.record(command)
   command = tostring(command or ""):lower():match("^%s*(.-)%s*$")
   if command == "" then return end
   local now = emunah.util.now()
   local recent = M.recent
   -- Typed by you, or sent by Emunah: everything automated goes through act.send(), which
   -- flags itself for the duration of the send.
   local typed = not (emunah.act and emunah.act.sending)
   recent[#recent + 1] = { at = now, command = command, typed = typed }
   -- Trim from the front once something has aged out; bounded either way.
   while #recent > 64 or (recent[1] and recent[1].at < now - M.WINDOW) do
      table.remove(recent, 1)
   end
   emunah.event.raise("sent", command, typed)
   if M.isQuit(command) then
      M.quitAt = now
      emunah.event.raise("quitting", command)
   end
end

emunah.event.register("sysDataSendRequest", function(_, command)
   M.record(command)
end, "outgoing")

return M

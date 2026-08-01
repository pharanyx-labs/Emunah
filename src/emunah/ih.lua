--- Linkify IH: room denizen listings become clickable, toggleable lines that flip a
--- kind's wanted state directly from the game window, without going through the room
--- panel or `emunah mobs`.
---
--- `ih` is Achaea's own scripting-oriented room listing -- distinct from the plain-English
--- room description -- shaped as a short noun glued directly to a replica number, padded,
--- then the full description:
---
---   wildcat338261       a wildcat soldier
---   sheep595016         a plump sheep
---   wildcat430877       an adult wildcat
---
--- PATTERN PROVENANCE
--- -------------------
--- The pattern below is a first cut from one real transcript, not yet exercised against a
--- wide range of IH output. Same discipline as curing/detect/patterns.lua: if it misses
--- real lines or over-matches something else, grow/tighten it from what you actually see
--- rather than guessing a fix.
---
--- WHY deleteLine() + cechoLink() RATHER THAN A SEPARATE ECHO
--- ------------------------------------------------------------
--- Leaving the original line in place and echoing a second, clickable copy under it would
--- double every listing. deleteLine() removes the line that just fired the trigger (id and
--- padding included), and the replacement is echoed in its place -- same visual line,
--- now clickable.

local M = {}

--- One capture group per piece: noun, replica id, padding, description.
local PATTERN = [[^([a-zA-Z]+)(\d+)(\s+)(.+)$]]

local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.ihTriggers = emunah._persist.ihTriggers or {}
   return emunah._persist.ihTriggers
end

--- Remove every trigger this module owns, so a reload does not stack duplicates -- same
--- problem, and same fix, as curing/detect/init.lua and core/event.lua.
function M.killAll()
   local reg = registry()
   local n = 0
   for _, id in ipairs(reg) do
      if killTrigger(id) then n = n + 1 end
   end
   emunah._persist.ihTriggers = {}
   return n
end

local function onLine()
   local prefix      = matches and matches[2]   -- e.g. "wildcat"
   local replicaId    = matches and matches[3]   -- e.g. "338261"
   local padding      = matches and matches[4]
   local name         = matches and matches[5]   -- e.g. "a wildcat soldier"
   if type(name) ~= "string" or name == "" then return end

   local den  = emunah.denizens
   local area = den.area()

   -- ih is independent of GMCP's Char.Items tracking -- typing it does not guarantee the
   -- same denizen is already recorded (Char.Items.Room can go unanswered for a room GMCP
   -- has not caught up on yet; ih's own text is at least as reliable a source). Record it
   -- here too, same "first sighting defaults to not wanted, already-known is left alone"
   -- rule as the GMCP-driven recordRoom(), so the link this line becomes always has
   -- something real to toggle.
   local wasKnown = den.known(name, area)
   local forceWanted = nil
   if not wasKnown then forceWanted = false end
   den.add(name, area, forceWanted, nil)

   local wanted = den.wanted(name, area)
   local mark   = wanted and "+" or " "
   local colour = wanted and "<ansi_light_green>" or "<ansi_light_black>"

   local text = string.format("%s%s%s%s%s<reset>\n",
      tostring(prefix) .. tostring(replicaId) .. tostring(padding), colour, mark, name, "")
   local command = string.format(
      "emunah.denizens.toggleWanted(%q, %q)", name, tostring(area))
   local hint = wanted and "Click to stop killing this." or "Click to allow killing this."

   deleteLine()
   cechoLink(text, command, hint, true)
end

-- Drop the previous generation before installing this one.
M.killAll()

table.insert(registry(), tempRegexTrigger(PATTERN, onLine))

return M

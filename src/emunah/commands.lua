--- Aliases: the user-facing command surface.
---
--- One dispatcher under a single `emunah` prefix, rather than a scatter of top-level
--- aliases. Two reasons: Achaea has a large command vocabulary of its own and colliding
--- with it is easy, and a single entry point means `emunah` with no arguments can list
--- everything the system can do -- which is the only documentation most people will read.
---
--- Aliases are registered through tempAlias and tracked on _persist, so a reload replaces
--- them rather than stacking duplicates. (A duplicated alias in Mudlet fires once per
--- copy, so `emunah cure on` after three reloads would toggle curing three times and end
--- up off.)

local M = {}

local util = emunah.util
local log  = emunah.log

local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.commandAliases = emunah._persist.commandAliases or {}
   return emunah._persist.commandAliases
end

local function killAll()
   local reg = registry()
   for _, id in ipairs(reg) do killAlias(id) end
   emunah._persist.commandAliases = {}
end

-- ---------------------------------------------------------------------------
-- output helpers
-- ---------------------------------------------------------------------------

local function header(text)
   cecho(string.format("\n<ansi_light_black>-- <reset><ansi_cyan>%s<reset>", text))
end

local function row(label, value, colour)
   cecho(string.format("\n  <ansi_light_black>%-18s<reset> <%s>%s<reset>",
      label, colour or "reset", tostring(value)))
end

local function flag(value)
   return value and "<ansi_light_green>on" or "<ansi_light_red>off"
end

-- ---------------------------------------------------------------------------
-- commands
-- ---------------------------------------------------------------------------

M.handlers = {}

M.handlers.status = function()
   header("Emunah " .. (emunah._version or "?"))
   -- gmcp/init.lua is published AS emunah.gmcp, so its fields hang off that directly.
   row("character", emunah.gmcp.character or emunah.gmcp.status.name() or "-")
   row("class", emunah.gmcp.status.class() or "-")
   row("curing", flag(emunah.curing.engine.enabled))
   row("defence keep-up", flag(emunah.curing.defkeepup.enabled))
   row("UI", flag(emunah.config.get("ui.enabled", true)))
   row("cure method", emunah.config.get("curing.method", "herbs"))
   row("afflictions tracked", emunah.curing.engine.count())
   row("skills indexed", emunah.gmcp.skills.complete and
      (#emunah.gmcp.skills.all() .. " abilities") or "pending")
   row("inventory", emunah.gmcp.items.count("inv") .. " items")
   row("log level", emunah.log.level)
end

M.handlers.cure = function(arg)
   if arg == "on" then emunah.curing.engine.start()
   elseif arg == "off" then emunah.curing.engine.stop()
   else emunah.curing.engine.toggle() end
   emunah.config.save()
end

M.handlers.defs = function(arg, rest)
   local keepup = emunah.curing.defkeepup
   if arg == "on" then keepup.start(); emunah.config.save()
   elseif arg == "off" then keepup.stop(); emunah.config.save()
   elseif arg == "add" and rest then
      -- `emunah defs add <name>` for anything already known, or
      -- `emunah defs add <name> <command>` to supply one -- the form tattoos need, where
      -- the Char.Defences name has to be read from the game rather than assumed.
      local name, command = rest:match("^(%S+)%s+(.+)$")
      keepup.add(name or rest, command)
   elseif arg == "remove" or arg == "drop" then keepup.drop(rest)
   elseif arg == "list" or not arg then
      header("Defence keep-up (" .. (keepup.enabled and "on" or "off") .. ")")
      local wanted = keepup.wanted()
      if #wanted == 0 then
         cecho("\n  <ansi_light_black>nothing configured -- try: emunah defs add rebounding<reset>")
      end
      local missing = util.set(keepup.missing())
      for _, name in ipairs(wanted) do
         row(name, missing[name] and "MISSING" or "up",
            missing[name] and "ansi_light_red" or "ansi_light_green")
      end
   else
      keepup.toggle()
   end
end

M.handlers.affs = function()
   local engine = emunah.curing.engine
   header("Afflictions (" .. engine.count() .. ")")
   local tracked = engine.list()
   if #tracked == 0 then
      cecho("\n  <ansi_light_green>clear<reset>")
      return
   end
   if not engine.enabled then
      cecho("\n  <ansi_light_red>curing is OFF<reset> <ansi_light_black>-- "
         .. "`emunah cure on`. Nothing below is being acted on.<reset>")
   end
   for _, record in ipairs(tracked) do
      local vectors = table.concat(emunah.curing.afflist.vectorsFor(record.name), ", ")
      row(record.name, string.format("%s  [%s, %.0fs]",
         vectors ~= "" and vectors or "no known cure", record.source,
         emunah.util.now() - record.since))
      -- The reason it is still here, when there is one. An affliction with a cure that
      -- cannot currently be performed looks exactly like one being ignored.
      local refusal = engine.refusals[record.name]
      if refusal then
         cecho(string.format("\n  %-18s <ansi_light_red>%s<reset>", "", refusal))
      elseif vectors == "" then
         cecho(string.format("\n  %-18s <ansi_yellow>%s<reset>", "",
            "no cure defined -- it will sit here until it wears off"))
      end
   end
end

--- Chat diagnostics: which half is working.
---
--- Capture and rendering are separate modules so they fail independently, which only helps
--- if you can see which one went. "Chat stopped" is the same symptom for three different
--- causes -- the game stopped sending, the console broke, or no console was ever built --
--- and this distinguishes them in one line.
M.handlers.chat = function(arg)
   local comm = emunah.gmcp.comm
   local chat = emunah.ui.chat

   if arg == "rebuild" then
      chat.rebuilt = false
      local ok, built = pcall(chat.build)
      log.info("Chat rebuild: %s", (ok and built) and "ok" or "failed")
      return
   end

   header("Chat")
   row("captured", string.format("%d message%s", #comm.history,
      #comm.history == 1 and "" or "s"))
   local last = comm.history[#comm.history]
   row("last captured", last and (os.date("%H:%M:%S", last.at) .. "  [" .. last.tab .. "] "
      .. (last.talker or "")) or "(nothing yet)")
   row("render mode", chat.mode,
      chat.mode == "none" and "ansi_light_red" or "ansi_light_green")
   row("console", chat.console and "present" or "MISSING",
      chat.console and "ansi_light_green" or "ansi_light_red")
   if chat.broken then row("state", "NOT ACCEPTING OUTPUT", "ansi_light_red") end
   if (chat.dropped or 0) > 0 then
      row("dropped", tostring(chat.dropped) .. " (captured, never rendered)", "ansi_yellow")
   end

   cecho("\n  <ansi_light_black>Messages captured but not shown means the window; "
      .. "nothing captured means the feed.<reset>")
   cecho("\n  <ansi_light_black>emunah chat rebuild -- rebuild just the chat console.<reset>")
end

M.handlers.gmcp = function(arg)
   if arg == "refresh" then
      emunah.gmcp.refresh()
      log.info("Requested a full GMCP refresh.")
      return
   end
   header("GMCP state")
   display(emunah.gmcp.snapshot())
end

M.handlers.have = function(arg)
   if arg then
      -- Ad-hoc lookup: `emunah have kelp` answers the question the engine asks.
      header("have " .. arg)
      row("skill", emunah.have.skill(arg) and "yes" or "no")
      row("in inventory", emunah.have.item(arg))
      row("in rift", emunah.have.inRift(arg))
      row("defence up", emunah.have.def(arg) and "yes" or "no")
      return
   end
   header("Capabilities")
   local report = emunah.have.report()
   row("skills indexed", report.skillsIndexed and "yes" or "no")
   row("inventory items", report.inventory)
   row("rift entries", report.riftEntries)
   for vector, ready in pairs(report.balances) do
      local blocked = report.blocked[vector]
      row(vector, blocked and ("BLOCKED by " .. blocked) or (ready and "ready" or "recovering"),
         blocked and "ansi_light_red" or (ready and "ansi_light_green" or "ansi_yellow"))
   end
end

M.handlers.learn = function(arg)
   local detect = emunah.curing.detect
   if arg == "on" then detect.startLearning()
   elseif arg == "off" then detect.stopLearning()
   else detect.toggleLearning() end
end

M.handlers.detect = function()
   local coverage = emunah.curing.detect.coverage()
   header("Detection coverage")
   row("afflictions known", coverage.totalKnown)
   row("with gain patterns", coverage.withGain)
   row("with cure patterns", coverage.withCure)
   cecho("\n  <ansi_light_black>GMCP covers the rest. Use 'emunah learn on' to grow the pattern set.<reset>")
end

M.handlers.ui = function(arg, rest)
   if arg == "rebuild" then
      emunah.ui.layout.build()
      log.info("UI rebuilt.")
   elseif arg == "reset" then
      -- For a panel that is off-screen, zero-sized, or stuck hidden by saved state.
      emunah.ui.layout.reset()
   elseif arg == "show" then
      emunah.ui.layout.show()
      log.info("UI shown.")
   elseif arg == "map" then
      local map = emunah.ui.map
      -- Bare `emunah ui map` REPORTS rather than toggles. Toggling on a bare word is a
      -- trap: the natural thing to type when the map is missing is `emunah ui map`, and
      -- if that flipped the setting it would turn the map off and look like confirmation
      -- that it is broken.
      if rest == "on" then
         map.setEnabled(true)
      elseif rest == "off" then
         map.setEnabled(false)
      elseif rest == "centre" or rest == "center" then
         map.centre()
      elseif rest == "rebuild" then
         map.build(); map.show()
         log.info("Map rebuilt.")
      elseif rest == "float" then
         map.float()
      elseif rest == "embed" then
         map.embed()
      elseif rest == "raw" then
         map.raw()
      elseif rest and rest:match("^height%s") then
         map.setHeight(rest:match("^height%s+(%S+)"))
      else
         local d = map.diagnose()
         header("Map")
         row("setting ui.map", tostring(d.setting), d.setting and "ansi_light_green" or "ansi_light_red")
         row("Geyser", d.hasGeyser and "yes" or "no", d.hasGeyser and "reset" or "ansi_light_red")
         row("Geyser.Mapper", d.hasMapper and "yes" or "no", d.hasMapper and "reset" or "ansi_light_red")
         row("createMapper()", d.hasCreate and "yes" or "no", d.hasCreate and "reset" or "ansi_light_red")
         row("right container", d.hasContainer and "yes" or "no", d.hasContainer and "reset" or "ansi_light_red")
         row("widget created", d.widget and "yes" or "no", d.widget and "ansi_light_green" or "ansi_light_red")
         if d.widget then
            row("embedded", tostring(d.embedded), d.embedded and "reset" or "ansi_yellow")
            row("hidden", tostring(d.hidden), d.hidden and "ansi_light_red" or "reset")
            row("geometry", string.format("x=%s y=%s w=%s h=%s",
               tostring(d.x), tostring(d.y), tostring(d.width), tostring(d.height)))
         end
         if d.containerW then
            row("container", string.format("x=%s y=%s w=%s h=%s",
               tostring(d.containerX), tostring(d.containerY),
               tostring(d.containerW), tostring(d.containerH)))
         end

         -- The decisive line: a healthy widget over an empty database looks exactly like
         -- a widget that never appeared.
         local hasData = (d.rooms or 0) > 0
         row("areas in map", tostring(d.areas or "?"), hasData and "reset" or "ansi_light_red")
         row("rooms in map", tostring(d.rooms or "?"), hasData and "ansi_light_green" or "ansi_light_red")
         row("current room", tostring(d.currentRoom or "-"))
         row("room on map", tostring(d.currentRoomKnown),
            d.currentRoomKnown and "ansi_light_green" or "ansi_yellow")

         if not hasData then
            cecho("\n  <ansi_light_red>Your Mudlet map database is empty -- there is nothing to draw.<reset>")
            cecho("\n  <ansi_light_black>Download Achaea's map first; the widget itself is fine.<reset>")
         end
         local px = { emunah.ui.map.pixels() }
         row("raw px would be", string.format("x=%d y=%d w=%d h=%d", px[1], px[2], px[3], px[4]))
         row("region height", emunah.ui.layout.mapHeightPct() .. "% of window")
         cecho("\n  <ansi_light_black>emunah ui map height <n>|on|off|rebuild|centre|float|embed|raw<reset>")
         cecho("\n  <ansi_light_black>'raw'   calls createMapper directly, bypassing Geyser (decisive test)<reset>")
         cecho("\n  <ansi_light_black>'float' detaches it into its own dock widget<reset>")
      end
   else
      local enabled = emunah.ui.layout.toggle()
      log.info("UI %s.", enabled and "on" or "off")
   end
end

M.handlers.set = function(arg, rest)
   if not arg then
      header("Settings")
      display(emunah.config.data)
      return
   end
   if rest == nil then
      row(arg, tostring(emunah.config.get(arg, "(unset)")))
      return
   end
   -- Coerce the obvious types so `emunah set curing.confirmWait 1.5` stores a number.
   local value = rest
   if rest == "true" then value = true
   elseif rest == "false" then value = false
   elseif tonumber(rest) then value = tonumber(rest) end

   emunah.config.set(arg, value)
   emunah.config.save()
   log.info("%s = %s", arg, tostring(value))
end

M.handlers.prio = function(affliction, rest)
   if not affliction or not rest then
      cecho("\n  <ansi_light_black>usage: emunah prio <affliction> <vector> <rank><reset>")
      return
   end
   local vector, rank = rest:match("^(%S+)%s+(%d+)$")
   if not vector then
      cecho("\n  <ansi_light_red>usage: emunah prio <affliction> <vector> <rank><reset>")
      return
   end
   local priorities = emunah.config.get("priorities", {})
   priorities[affliction:lower()] = priorities[affliction:lower()] or {}
   priorities[affliction:lower()][vector] = tonumber(rank)
   emunah.config.set("priorities", priorities)
   emunah.config.save()
   log.info("%s via %s is now priority %s", affliction, vector, rank)
end

M.handlers.walk = function(arg, rest)
   local walker = emunah.walker
   if arg == "start" or arg == "area" then
      walker.start()
   elseif arg == "stop" then
      walker.stop("requested")
   elseif arg == "pause" then
      walker.pause()
   elseif arg == "resume" then
      walker.resume()
   elseif arg == "move" or arg == "next" then
      walker.move()
   elseif arg == "avoid" then
      if walker.avoidRoom(rest) then
         log.info("Avoiding room %s.", tostring(rest))
      end
   elseif arg == "unavoid" then
      walker.unavoidRoom(rest)
   elseif arg == "auto" then
      walker.setAuto(rest ~= "off")
   elseif arg == "delay" then
      walker.setDelay(rest)
   elseif arg == "return" then
      walker.config.returnToStart = not walker.config.returnToStart
      log.info("Return to start: %s", tostring(walker.config.returnToStart))
   else
      local report = walker.report()
      header("Walker")
      row("running", report.running and (report.paused and "paused" or "yes") or "no")
      row("area", tostring(report.area or "-"))
      row("remaining", report.remaining)
      row("visited", report.visited)
      row("unreachable", report.failed)
      row("avoided rooms", report.avoided)
      row("paced by", tostring(report.claimedBy or "itself"),
         report.claimedBy and "ansi_cyan" or "reset")
      row("auto-step", emunah.config.get("walker.auto", true) and "on" or "off",
         emunah.config.get("walker.auto", true) and "ansi_light_green" or "ansi_yellow")
      row("step delay", emunah.config.get("walker.stepDelay", 0.6) .. "s")
      if report.running then row("elapsed", util.duration(report.elapsed)) end
      cecho("\n  <ansi_light_black>emunah walk start|stop|pause|resume|move|auto on|off|delay <s>|avoid <id><reset>")
   end
end

M.handlers.debug = function(arg)
   if arg == "handlers" then
      header("Event handlers")
      display(emunah.event.list())
   elseif arg == "timers" then
      header("Timers")
      display(emunah.timers.list())
   elseif arg == "queue" then
      header("Queue")
      display(emunah.queue.snapshot())
   elseif arg == "gmcp" then
      emunah.log.traceGmcp = not emunah.log.traceGmcp
      log.info("GMCP tracing %s%s.", flag(emunah.log.traceGmcp),
         emunah.log.traceGmcp and " -- every message sent and received" or "")
   else
      local on = emunah.log.level ~= "debug"
      emunah.log.setLevel(on and "debug" or "info")
      log.info("Debug logging %s%s.", flag(on),
         on and " -- includes every command sent to the game" or "")
   end
end

--- Walk and kill: the two together, which is what "go hunting" means. Kept separate
--- underneath because each is useful alone (clear one room; explore without fighting).
M.handlers.hunt = function(arg)
   if arg == "off" or arg == "stop" then
      emunah.bashing.stop("requested")
      emunah.walker.stop("requested")
      return
   end
   -- Walker first: bashing runs a tick as it starts, and that tick decides whether the
   -- room is clear and whether to hand movement on. With no walk running yet it has
   -- nothing to hand to.
   if not emunah.walker.enabled then
      if not emunah.walker.start() then return end
   end
   if not emunah.bashing.start() then
      emunah.walker.stop("bashing would not start")
   end
end

M.handlers.bash = function(arg, rest)
   local bash = emunah.bashing
   if arg == "on" or arg == "start" then bash.start()
   elseif arg == "off" or arg == "stop" then bash.stop("requested")
   elseif arg == "attack" and rest then
      emunah.config.set("bashing.attack", rest); emunah.config.save()
      log.info("Attack command: %s", rest)
   elseif arg == "balance" and rest then
      if rest ~= "eq" and rest ~= "bal" and rest ~= "both" then
         log.warn("Usage: emunah bash balance eq|bal|both")
      else
         emunah.config.set("bashing.balance", rest); emunah.config.save()
         log.info("Attack uses: %s", rest)
      end
   elseif arg == "health" and rest then
      emunah.config.set("bashing.stopBelowHealth", tonumber(rest) or 50); emunah.config.save()
      log.info("Stops below %s%% health.", rest)
   else
      local r = bash.report()
      header("Bashing")
      row("running", r.running and "yes" or "no", r.running and "ansi_light_green" or "reset")
      row("class module", tostring(r.classLoaded or "NONE"),
         r.classLoaded and "ansi_light_green" or "ansi_light_red")
      row("attack", r.attack .. " <replica>")
      row("costs", r.balance)
      row("current target", tostring(r.target or "-"))
      row("target health", r.targetHealth and (r.targetHealth .. "%") or "-")
      -- nil means its health is not moving, which is the useful reading: the attack is
      -- wrong for this creature rather than merely slow.
      row("kill in", r.killIn and (r.killIn .. " more") or "unknown",
         r.killIn and "reset" or "ansi_yellow")
      row("here to kill", r.pending)
      row("killed", r.killed)
      row("attacks sent", r.attacks)
      row("damage dealt", r.dealt)
      row("damage taken", r.taken)
      row("rooms cleared", r.rooms)
      if r.running then row("elapsed", util.duration(r.elapsed)) end
      cecho("\n  <ansi_light_black>emunah bash on|off|attack <cmd>|balance eq|bal|both|health <n><reset>")
      row("walker", emunah.walker.enabled and "running" or "stopped",
         emunah.walker.enabled and "ansi_light_green" or "ansi_yellow")
      row("room items", emunah.gmcp.items.roomFresh() and "current" or "WAITING",
         emunah.gmcp.items.roomFresh() and "ansi_light_green" or "ansi_yellow")
      cecho("\n  <ansi_light_black>emunah hunt  = walk + bash together<reset>")
   end
end

M.handlers.pvp = function(arg, rest)
   local pvp = emunah.pvp
   if arg == "on" or arg == "start" then pvp.start()
   elseif arg == "off" or arg == "stop" then pvp.stop("requested")
   elseif arg == "target" and rest then
      if rest == "off" or rest == "clear" or rest == "none" then
         pvp.clearTarget()
      else
         pvp.setTarget(rest)
      end
   else
      local r = pvp.report()
      header("PvP")
      row("running", r.running and "yes" or "no", r.running and "ansi_light_green" or "reset")
      row("class module", tostring(r.classLoaded or "NONE"),
         r.classLoaded and "ansi_light_green" or "ansi_light_red")
      row("target", tostring(r.target or "none -- set one with 'emunah pvp target <name>'"))
      if r.target then
         local afflictions = emunah.curing.detect.opponent.list(r.target)
         row("target afflictions", #afflictions > 0 and table.concat(afflictions, ", ") or "-")
      end
      row("attacks sent", r.attacks)
      if r.running then row("elapsed", util.duration(r.elapsed)) end
      local here = emunah.gmcp.room.playerNames()
      row("players here", #here > 0 and table.concat(here, ", ") or "-",
         "ansi_light_black")
      cecho("\n  <ansi_light_black>emunah pvp on|off|target <name>|target off  -- never auto-targets<reset>")
   end
end

M.handlers.loot = function(arg)
   if arg == "on" then emunah.loot.setEnabled(true)
   elseif arg == "off" then emunah.loot.setEnabled(false)
   elseif arg == "now" then
      local n = emunah.loot.sweep()
      log.info("Swept the room: %d item(s) taken.", n)
   else
      header("Loot")
      row("gold pickup", emunah.config.get("loot.gold", true) and "on" or "off",
         emunah.config.get("loot.gold", true) and "ansi_light_green" or "ansi_light_red")
      row("picked up", emunah.loot.stats.picked)
      cecho("\n  <ansi_light_black>emunah loot on|off|now<reset>")
   end
end

M.handlers.mobs = function(arg, rest)
   local den = emunah.denizens
   local area = den.area()

   if arg == "add" and rest then
      den.add(rest, area); den.save()
      log.info("Added %q to %s.", rest, tostring(area))
   elseif (arg == "remove" or arg == "forget") and rest then
      log.info(den.remove(rest, area) and "Forgot %q." or "%q was not recorded.", rest)
   elseif arg == "skip" and rest then
      -- Keeps it recorded but off the kill list, so auto-record does not re-add it.
      log.info(den.setWanted(rest, false, area) and "Skipping %q." or "%q not recorded here.", rest)
   elseif arg == "kill" and rest then
      log.info(den.setWanted(rest, true, area) and "Will kill %q." or "%q not recorded here.", rest)
   elseif arg == "here" then
      header("Denizens here")
      local here = den.here()
      if #here == 0 then
         cecho("\n  <ansi_light_black>none (or none flagged as creatures by GMCP)<reset>")
      end
      for _, d in ipairs(here) do
         local state = den.isEngaged(d.id) and "  [done]" or ""
         local colour = "ansi_light_black"
         if den.wanted(d.name) then
            colour = den.isEngaged(d.id) and "ansi_yellow" or "ansi_light_green"
         end
         row(d.id, d.name .. state, colour)
      end
      cecho("\n  <ansi_light_black>left column is the REPLICA NUMBER -- target that, never the name<reset>")
      cecho("\n  <ansi_light_black>green = to kill, yellow = already dealt with, grey = skipped<reset>")
   elseif arg == "target" then
      if not den.target() then log.warn("Nothing here left to kill.") end
   elseif arg == "done" then
      -- Mark the current target dealt with so the next target() picks a different one.
      local t = den.next()
      if t then den.engage(t.id); log.info("Marked %s (%s) done.", t.name, t.id) end
   elseif arg == "reset" then
      den.clearEngaged()
      log.info("Cleared the dealt-with list for this room.")
   elseif arg == "areas" then
      header("Areas with recorded denizens")
      for _, name in ipairs(den.areaNames()) do
         row(name, #den.forArea(name) .. " kinds")
      end
   else
      header("Denizens -- " .. (area or "unknown area"))
      local list = den.forArea(area)
      if #list == 0 then
         cecho("\n  <ansi_light_black>nothing recorded here yet<reset>")
      end
      for _, entry in ipairs(list) do
         local hereNow = den.hereCount(entry.name)
         row(entry.name, string.format("killed %d%s%s",
            entry.killed or 0,
            hereNow > 0 and ("   here " .. hereNow) or "",
            entry.wanted == false and "   [skip]" or ""),
            entry.wanted == false and "ansi_light_black" or "ansi_light_green")
      end
      row("here now", den.count() .. " to kill")
      cecho("\n  <ansi_light_black>emunah mobs here|target|done|reset|add|skip|kill|forget|areas<reset>")
   end
end

M.handlers.keys = function(arg)
   local keys = emunah.keys
   if arg == "on" then keys.setEnabled(true)
   elseif arg == "off" then keys.setEnabled(false)
   else
      header("Numpad movement (" ..
         (emunah.config.get("keys.numpad", true) and "on" or "off") .. ")")
      row("bindings active", keys.count())
      cecho("\n  <ansi_light_black>  7 nw    8 n     9 ne<reset>")
      cecho("\n  <ansi_light_black>  4 w     5 look  6 e<reset>")
      cecho("\n  <ansi_light_black>  1 sw    2 s     3 se<reset>")
      cecho("\n  <ansi_light_black>  0 in    . out   + up   - down<reset>")
      cecho("\n  <ansi_light_black>bound for both Num Lock states; a movement key stops the walker<reset>")
      cecho("\n  <ansi_light_black>emunah keys on|off<reset>")
   end
end

M.handlers.reload = function()
   emunahReload()
end

M.handlers.help = function()
   header("Emunah commands")
   local lines = {
      { "emunah",                  "this summary" },
      { "emunah status",           "system and character state" },
      { "emunah cure on|off",      "toggle the curing engine" },
      { "emunah affs",             "tracked afflictions and their cure vectors" },
      { "emunah defs ...",         "on|off|add <def>|remove <def>|list" },
      { "emunah have [thing]",     "capability report, or check one item/skill" },
      { "emunah gmcp [refresh]",   "tracked GMCP state" },
      { "emunah chat [rebuild]",   "chat capture vs rendering -- which half is working" },
      { "emunah learn on|off",     "log candidate affliction messages to a file" },
      { "emunah detect",           "detection pattern coverage" },
      { "emunah walk ...",         "start|stop|pause|auto on|off|delay <s>|avoid <id>" },
      { "emunah keys [on|off]",    "numpad movement bindings" },
      { "emunah mobs ...",         "here|target|add|skip|kill|forget|areas" },
      { "emunah hunt [off]",       "walk the area AND kill things" },
      { "emunah bash ...",         "on|off|attack <cmd>|balance|health <n>" },
      { "emunah pvp ...",          "on|off|target <name>|target off (never auto-targets)" },
      { "emunah loot [on|off|now]", "pick up gold from corpses" },
      { "emunah prio <aff> <vec> <n>", "override a cure priority" },
      { "emunah set [key] [value]", "read or write a setting" },
      { "emunah ui [rebuild|reset|show]", "toggle, rebuild or reset the interface" },
      { "emunah ui map [height <n>|on|off|centre|raw]", "map status, size, or control" },
      { "emunah debug", "toggle verbose logging, including every command sent to the game" },
      { "emunah debug gmcp", "toggle a trace of every GMCP message sent and received" },
      { "emunah debug handlers|timers|queue", "internals" },
      { "emreload",                "reload all modules from disk" },
   }
   for _, line in ipairs(lines) do
      cecho(string.format("\n  <ansi_cyan>%-32s<reset> <ansi_light_black>%s<reset>", line[1], line[2]))
   end
end

-- ---------------------------------------------------------------------------
-- dispatch
-- ---------------------------------------------------------------------------

function M.dispatch(input)
   input = util.trim(input or "")
   if input == "" then
      M.handlers.help()
      return
   end

   local command, remainder = input:match("^(%S+)%s*(.*)$")
   command = (command or ""):lower()
   remainder = util.trim(remainder)

   local handler = M.handlers[command]
   if not handler then
      log.warn("Unknown command %q. Try 'emunah' for the list.", command)
      return
   end

   -- Handlers take (first argument, everything after it).
   local first, rest = remainder:match("^(%S+)%s*(.*)$")
   rest = (rest and rest ~= "") and rest or nil

   local ok, err = pcall(handler, first, rest)
   if not ok then
      log.error("Command %q failed: %s", command, tostring(err))
   end
end

killAll()

-- tempAlias takes a PCRE REGEX, not a Lua pattern.
--
-- This is easy to get wrong because the rest of the codebase uses Lua patterns and they
-- look similar. `^emunah%s*(.*)$` is a valid Lua pattern but as a regex it means "emunah"
-- followed by a literal `%` and zero-or-more `s` -- so a bare `emunah` does not match, the
-- alias never fires, and the word is sent to the game, which replies "Emunah is not a
-- valid command". Whitespace is `\s` here, never `%s`.
table.insert(registry(), tempAlias([[^emunah\s*(.*)$]], function()
   M.dispatch(matches[2])
end))

-- Short form for the thing you toggle most in a fight.
table.insert(registry(), tempAlias("^ec$", function()
   emunah.curing.engine.toggle()
end))

return M

--- The map window.
---
--- Occupies the bottom of the right-hand column, below the room panel. Uses Mudlet's
--- built-in mapper rather than drawing anything ourselves -- it already knows how to
--- render Achaea's areas, handles clicking to walk, and shares its map data with
--- `getPath`/`doSpeedWalk`, which is what src/emunah/walker.lua drives.
---
--- THINGS ABOUT Geyser.Mapper THAT ARE NOT OBVIOUS
--- -----------------------------------------------
---
--- 1. It is EMBEDDED by default. With no `embedded` or `dockPosition` in the constructor
---    table, Geyser.Mapper sets `embedded = true` and calls `createMapper(...)`, drawing
---    inside our container. Passing `dockPosition` instead would detach it into a
---    floating/docked widget outside the layout entirely -- not what we want here.
---
--- 2. It is effectively a SINGLETON per profile. Mudlet has one map widget; Geyser.Mapper
---    is a handle onto it, and its own source notes there is no true delete (`type_delete`
---    just calls closeMapWidget). Creating it again does not produce a second map -- it
---    repositions the existing one. That makes reload safe, but it also means we must not
---    treat a stale handle as "no map".
---
--- 3. Hiding it collapses it to zero size (`createMapper(name, x, y, 0, 0)`) rather than
---    destroying it. If a rebuild ever failed after a hide, the map would be left at 0x0
---    and look permanently gone. So we only ever hide it as part of hiding the whole UI,
---    and `emunah map on` can always bring it back.
---
--- 4. Geyser's automatic reposition-on-resize is unreliable for the map widget (its own
---    source says so). We therefore re-issue the geometry on sysWindowResizeEvent
---    ourselves rather than trusting the container to cascade.

local M = {}

local log    = emunah.log
local theme  = emunah.ui.theme
local layout = emunah.ui.layout

M.widget = nil

--- Is the Mudlet mapper available at all? A profile with no mapper support (or a headless
--- test environment) has no Geyser.Mapper and no createMapper.
---
--- Note there is no container requirement: the map is positioned on the Geyser root, not
--- inside a container. See the header comment in ui/layout.lua for why.
local function available()
   return type(Geyser) == "table"
      and type(Geyser.Mapper) == "table"
      and type(createMapper) == "function"
end

function M.build()
   if not emunah.config.get("ui.map", true) then
      log.debug("Map disabled in settings; skipping.")
      return false
   end

   if not available() then
      -- Not an error: plenty of setups have no mapper, and the rest of the UI is fine
      -- without one. Say it once at debug level rather than warning every reload.
      log.debug("Geyser.Mapper unavailable -- map not built.")
      return false
   end

   -- Positioned on the Geyser ROOT, not in a container: passing no parent makes x/y
   -- window-relative. A container would only put its background label on top of us.
   local top = layout.mapTop()
   local height = string.format("%d%%",
      100 - layout.percentOf(layout.HEIGHT_BOTTOM) - layout.percentOf(top))

   local ok, widget = pcall(function()
      return Geyser.Mapper:new({
         name = "emunah.map",
         x = "-" .. layout.WIDTH_RIGHT, y = top,
         width = layout.WIDTH_RIGHT, height = height,
         -- embedded is left unset on purpose: the constructor defaults it to true, which
         -- draws the map into the main window at these coordinates. Setting dockPosition
         -- would detach it into a floating widget instead.
      })
   end)

   if not ok or not widget then
      log.error("Could not create the map: %s", tostring(widget))
      return false
   end

   M.widget = widget
   emunah._persist.uiMap = widget

   -- Raise it above the container's own background label.
   --
   -- createMapper() draws a native widget at absolute coordinates; it is not a Qt child
   -- of the Adjustable.Container, it merely sits where the container happens to be. The
   -- container's adjLabel covers that same area, so whichever was raised last wins. We
   -- create the map after the containers, which usually puts it on top -- but
   -- Adjustable.Container raises itself on click (raiseOnClick defaults true), and a
   -- rebuild can reorder things. Raising explicitly here removes the ambiguity.
   pcall(function() widget:raise() end)

   log.debug("Map built at %s of the right column.", top)
   return true
end

--- Full diagnostic. Backs `emunah ui map`, and exists because "the map is not showing"
--- has at least five distinct causes that look identical from the outside: the setting is
--- off, this Mudlet has no mapper, the widget was never created, it was created at a
--- degenerate size, or it is behind the container label.
function M.diagnose()
   local out = {
      setting      = emunah.config.get("ui.map", true),
      hasGeyser    = type(Geyser) == "table",
      hasMapper    = type(Geyser) == "table" and type(Geyser.Mapper) == "table",
      hasCreate    = type(createMapper) == "function",
      hasContainer = layout.container("right") ~= nil,
      widget       = M.widget ~= nil,
   }

   if M.widget then
      local function measure(method)
         local ok, value = pcall(function() return M.widget[method](M.widget) end)
         return ok and value or nil
      end
      out.x, out.y = measure("get_x"), measure("get_y")
      out.width, out.height = measure("get_width"), measure("get_height")
      out.embedded = M.widget.embedded
      out.hidden = M.widget.hidden or M.widget.auto_hidden or false
   end

   local container = layout.container("right")
   if container then
      local function measure(method)
         local ok, value = pcall(function() return container[method](container) end)
         return ok and value or nil
      end
      out.containerX, out.containerY = measure("get_x"), measure("get_y")
      out.containerW, out.containerH = measure("get_width"), measure("get_height")
   end

   -- Is there anything to DRAW?
   --
   -- A correctly built mapper over an empty map database renders as a blank rectangle,
   -- which is indistinguishable from "the widget never appeared" -- and it is the more
   -- likely of the two on a fresh profile, because Mudlet ships no Achaea map. Counting
   -- rooms separates the two cases outright.
   local ok, areas = pcall(getAreaTable)
   if ok and type(areas) == "table" then
      out.areas = 0
      for _ in pairs(areas) do out.areas = out.areas + 1 end
   end

   local roomsOk, rooms = pcall(getRooms)
   if roomsOk and type(rooms) == "table" then
      out.rooms = 0
      for _ in pairs(rooms) do out.rooms = out.rooms + 1 end
   end

   -- Is the room we are standing in actually on the map? A populated database that does
   -- not contain the current room still draws nothing useful.
   local room = emunah.gmcp.room
   out.currentRoom = room and room.num or nil
   if out.currentRoom and type(getRoomName) == "function" then
      local nameOk, name = pcall(getRoomName, out.currentRoom)
      out.currentRoomKnown = (nameOk and name ~= nil and name ~= "") or false
   end

   return out
end

--- Integer pixel geometry for the map region, computed from the window size.
---
--- Geyser hands createMapper whatever its constraint solver produces, which is a FLOAT
--- (we measured x=1428.8, y=576.7362). createMapper's parameters are integers on the C++
--- side, and the documented example passes plain integers. Rounding here removes that as
--- a variable.
function M.pixels()
   local width, height = getMainWindowSize()
   local rightPct  = layout.percentOf(layout.WIDTH_RIGHT) / 100
   local topPct    = layout.percentOf(layout.mapTop()) / 100
   local bottomPct = layout.percentOf(layout.HEIGHT_BOTTOM) / 100

   local x = math.floor(width - (width * rightPct))
   local y = math.floor(height * topPct)
   local w = math.floor(width * rightPct)
   local h = math.floor(height * (1 - topPct - bottomPct))
   return x, y, w, h
end

--- Call createMapper directly, bypassing Geyser.
---
--- This exists as a decisive test, not as a workaround. Geyser.Mapper calls
--- `createMapper(me.windowname, x, y, w, h)` -- the FIVE-argument userwindow form, with
--- "main" as the window name -- while the documented example is the four-argument form.
--- If the raw call produces a visible map and the Geyser one does not, the difference is
--- the windowname argument, and we should stop routing through Geyser.Mapper.
---
--- If NEITHER produces a map, the mapper is hidden at the Mudlet level: the docs note the
--- toolbar Map button toggles visibility for a createMapper-created mapper too, so a
--- previous toggle can leave it hidden no matter how correctly we create it.
function M.raw()
   if type(createMapper) ~= "function" then
      log.error("createMapper is unavailable in this Mudlet build.")
      return false
   end

   local x, y, w, h = M.pixels()

   -- Drop the Geyser-managed one first: only one mapper can exist at a time.
   M.widget = nil

   local ok, err = pcall(createMapper, x, y, w, h)
   if not ok then
      log.error("Raw createMapper(%d, %d, %d, %d) failed: %s", x, y, w, h, tostring(err))
      return false
   end

   log.info("Raw createMapper(%d, %d, %d, %d) called -- four-argument form, no Geyser.", x, y, w, h)
   log.info("If a map is visible now, Geyser.Mapper's windowname argument was the problem.")
   return true
end

--- Detach the map into a floating/docked widget instead of embedding it.
---
--- Two purposes. It is a decisive z-order experiment: if the map is invisible embedded
--- but visible floating, nothing is wrong with the widget or the map data -- it is being
--- covered by the container's background label. And it is a genuine fallback for anyone
--- who would rather have the map in its own dock.
function M.float()
   if M.widget then
      pcall(function() M.widget:hide() end)
      M.widget = nil
   end
   if type(openMapWidget) ~= "function" then
      log.warn("openMapWidget is unavailable in this Mudlet build.")
      return false
   end
   emunah.config.set("ui.mapFloat", true)
   emunah.config.save()
   pcall(openMapWidget)
   log.info("Map detached into its own widget. 'emunah ui map embed' to put it back.")
   return true
end

--- Put the map back inside the layout.
function M.embed()
   if type(closeMapWidget) == "function" then pcall(closeMapWidget) end
   emunah.config.set("ui.mapFloat", false)
   emunah.config.save()
   M.widget = nil
   local built = M.build()
   log.info("Map re-embedded in the right column.")
   return built
end

--- Re-issue the map's geometry.
---
--- Geyser's own source notes that automatic repositioning does not work reliably for the
--- map widget, so we drive it explicitly rather than assuming the container cascades.
function M.refresh()
   if not M.widget then return false end
   local ok, err = pcall(function() M.widget:reposition() end)
   if not ok then
      log.debug("Map reposition failed: %s", tostring(err))
      return false
   end
   return true
end

function M.show()
   if not M.widget then return M.build() end
   pcall(function() M.widget:show() end)
   return true
end

function M.hide()
   if not M.widget then return false end
   pcall(function() M.widget:hide() end)
   return true
end

--- Turn the map on or off and remember the choice.
--- Turning the map on or off changes how tall the right-hand container is, so the whole
--- layout has to be rebuilt -- otherwise switching the map off leaves a dead strip where
--- it used to be, and switching it on paints it over the room panel.
function M.setEnabled(enabled)
   emunah.config.set("ui.map", enabled)
   emunah.config.save()
   if not enabled then M.hide() end
   emunah.ui.layout.build()
   log.info("Map %s.", enabled and "<ansi_light_green>on<ansi_yellow>" or "<ansi_light_red>off<ansi_yellow>")
   return enabled
end

function M.toggle()
   return M.setEnabled(not emunah.config.get("ui.map", true))
end

--- Resize the map region. Percent of the window height; the right-hand container takes
--- whatever is left, so this trades map height against chat and the room panel.
function M.setHeight(pct)
   pct = tonumber(pct)
   if not pct then
      log.warn("Usage: emunah ui map height <percent of window, 10-70>")
      return false
   end
   emunah.config.set("ui.mapHeight", pct)
   emunah.config.save()

   -- Rebuilding the layout resizes the right container to match; without that the map
   -- would grow into the room panel rather than pushing it up.
   emunah.ui.layout.build()

   local actual = emunah.ui.layout.mapHeightPct()
   if actual ~= math.floor(pct) then
      log.info("Map height clamped to %d%% (allowed range 10-70).", actual)
   else
      log.info("Map height %d%% of the window.", actual)
   end
   return actual
end

--- Centre the map on the current room. Useful after a teleport or a long walk, when the
--- mapper's view has drifted away from where you actually are.
function M.centre()
   local room = emunah.gmcp.room
   if not (room and room.num) then
      log.warn("No current room to centre the map on.")
      return false
   end
   if type(centerview) ~= "function" then return false end
   local ok = pcall(centerview, room.num)
   return ok
end

-- Rebuild alongside the rest of the UI.
emunah.event.register("emunah.ui.built", function() M.build() end, "ui.map")

-- The map does not reliably follow its container on resize; re-issue geometry.
emunah.event.register("sysWindowResizeEvent", function() M.refresh() end, "ui.map")

M.build()

return M

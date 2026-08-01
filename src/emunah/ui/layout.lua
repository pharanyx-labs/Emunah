--- The window layout.
---
--- Three Adjustable.Containers -- left, right, bottom -- with the main console resized to
--- sit between them. Adjustable.Container gives drag, resize, minimise, snap-to-border and
--- a right-click menu for free, and persists its own geometry, so the user can rearrange
--- the interface without touching the code and keep it that way.
---
--- RELOAD BEHAVIOUR
--- ----------------
--- Geyser objects are not garbage: creating a second container with the same name leaves
--- the first one on screen forever, and after a few reloads the profile is a stack of
--- dead panels that cannot be removed without restarting Mudlet. So every container is
--- registered in _persist and explicitly hidden and dropped before the new generation is
--- built. This is the UI equivalent of the handler-leak problem in core/event.lua and it
--- bites much more visibly.

local M = {}

local log   = emunah.log
local theme = emunah.ui.theme

--- Fractions of the window given to each region.
---
--- Layout:
---
---   +----------+---------------------------+-------------+
---   | left     |                           | CHAT (top)  |
---   | affs +   |      main game console    |  ---------  |
---   | defences |                           | room/items  |
---   |          |                           |  + target   |
---   |          |                           |  ---------  |
---   |          |                           |  MAP        |
---   +----------+---------------------------+-------------+
---   |            vitals strip (HP MP EP WP, balances)     |
---   +-----------------------------------------------------+
---
--- The vitals strip is deliberately the full width at the very bottom, so it sits
--- directly under the last line of game text -- i.e. immediately above the prompt, where
--- you are already looking during a fight. Health you have to glance away for is health
--- you notice too late.
M.WIDTH_LEFT    = "17%"
M.WIDTH_RIGHT   = "26%"
M.HEIGHT_BOTTOM = "9%"

--- Default height of the map region, as a percentage of the whole window.
--- Overridable at runtime with `emunah ui map height <n>`.
M.HEIGHT_MAP_DEFAULT = 42

--- Height the map region actually gets, in whole percent of the window.
--- Zero when the map is switched off, so its space reverts to the right container.
function M.mapHeightPct()
   if not emunah.config.get("ui.map", true) then return 0 end
   local pct = tonumber(emunah.config.get("ui.mapHeight", M.HEIGHT_MAP_DEFAULT))
      or M.HEIGHT_MAP_DEFAULT
   -- Clamped so a stray value cannot squeeze chat and the room panel out of existence
   -- or push the map through the vitals strip.
   if pct < 10 then pct = 10 end
   if pct > 70 then pct = 70 end
   return math.floor(pct)
end

--- Where the chat console ends inside the right-hand container, as a percentage OF THAT
--- CONTAINER. Chat above, room/items/target below.
M.CHAT_SPLIT = "57%"

--- THE MAP IS NOT IN A CONTAINER, AND THAT IS DELIBERATE
--- ----------------------------------------------------
--- createMapper() draws a native widget at absolute window coordinates. It is not a Qt
--- child of anything Geyser makes -- putting it "in" an Adjustable.Container only meant
--- it happened to sit where that container was, *underneath* the container's background
--- label, which covers the same rectangle. The map was built correctly every time and was
--- simply painted over. Geyser.Mapper:raise() hardcodes raiseWindow("mapper") and does not
--- reliably win that fight.
---
--- So the right-hand container stops above the map region, and ui/map.lua positions the
--- map on the Geyser root in the gap. Nothing overlaps it, so nothing can hide it.
---
---   right container   0            -> rightHeight()   chat + room/items/target
---   map region        rightHeight()-> 100 - BOTTOM    (Geyser root, no container)
---   vitals strip      100 - BOTTOM -> 100

--- Height of the right-hand container, which depends on whether the map is showing.
--- Without a map it simply extends down to the vitals strip.
function M.rightHeight()
   return string.format("%d%%", 100 - M.percentOf(M.HEIGHT_BOTTOM) - M.mapHeightPct())
end

--- Top edge of the map region, as a window percentage.
function M.mapTop()
   return M.rightHeight()
end

M.containers = {}

--- Tear down the previous generation of Geyser objects.
local function teardown()
   emunah._persist = emunah._persist or {}
   local previous = emunah._persist.uiContainers
   if not previous then return 0 end

   local n = 0
   for _, container in pairs(previous) do
      -- pcall throughout: a container from an older version of the code may not have the
      -- methods this version expects, and a failure here must not stop the rebuild.
      pcall(function() container:hide() end)
      n = n + 1
   end
   emunah._persist.uiContainers = nil
   return n
end

--- Is the UI available? Mudlet without a GUI (headless tests, some CI) has no Geyser.
local function available()
   return type(Geyser) == "table" and type(Adjustable) == "table" and Adjustable.Container ~= nil
end

--- Build the containers.
function M.build()
   if not emunah.config.get("ui.enabled", true) then
      log.debug("UI disabled in settings; skipping layout.")
      return false
   end

   if not available() then
      log.warn("Geyser or Adjustable.Container unavailable -- UI not built.")
      return false
   end

   local removed = teardown()
   if removed > 0 then
      log.debug("Removed %d container(s) from the previous load.", removed)
   end

   M.containers = {}

   local common = {
      adjLabelstyle  = theme.panelStyle(),
      buttonstyle    = string.format("background-color: %s; border-radius: 3px;", theme.colour.raised),
      titleTxtColor  = theme.colour.textDim,
      padding        = 4,
      -- Persist geometry per profile so a rearranged layout survives restarts.
      autoSave       = true,
      autoLoad       = true,
   }

   local function make(name, spec)
      local options = {}
      for key, value in pairs(common) do options[key] = value end
      for key, value in pairs(spec) do options[key] = value end
      options.name = name

      -- Colon call, not dot. Adjustable.Container:new(cons, container) immediately does
      -- `self.parent:new(...)`, so invoking it as `.new(options)` binds options to self
      -- and dies on `self.parent` being nil. Geyser constructors are all method-style.
      local ok, container = pcall(function()
         return Adjustable.Container:new(options)
      end)
      if not ok or not container then
         log.error("Could not create container %s: %s", name, tostring(container))
         return nil
      end

      -- Force visible.
      --
      -- Two mechanisms conspire to leave a container invisible forever, and neither
      -- reports anything:
      --
      --   1. Adjustable.Container:new inherits `hidden` from an existing container of the
      --      same name. teardown() above hides the previous generation on every rebuild,
      --      so each reload hands the new container a hidden flag.
      --   2. autoSave writes that flag to disk on exit and autoLoad restores it, so once
      --      a session ends while hidden, every future session starts hidden.
      --
      -- Visibility is our state, not Adjustable's: it follows `ui.enabled` and nothing
      -- else. Restoring position and size from disk is wanted; restoring "invisible" is
      -- not.
      pcall(function() container:show() end)

      M.containers[name] = container
      return container
   end

   -- Columns stop above the vitals strip rather than running the full height, so the
   -- strip spans the whole window and nothing overlaps it.
   local columnHeight = string.format("%d%%", 100 - M.percentOf(M.HEIGHT_BOTTOM))

   make("emunah.left", {
      x = 0, y = 0, width = M.WIDTH_LEFT, height = columnHeight,
      titleText = "Afflictions",
   })

   -- Stops above the map region so the container's background label cannot paint over it.
   make("emunah.right", {
      x = "-" .. M.WIDTH_RIGHT, y = 0, width = M.WIDTH_RIGHT, height = M.rightHeight(),
      titleText = "Chat / Room",
   })

   make("emunah.bottom", {
      x = 0, y = "-" .. M.HEIGHT_BOTTOM, width = "100%", height = M.HEIGHT_BOTTOM,
      titleText = "Vitals",
   })

   emunah._persist.uiContainers = M.containers

   M.resizeConsole()

   log.debug("Layout built: %d containers.", emunah.util.count(M.containers))
   emunah.event.raise("ui.built")
   return true
end

--- Push the main console out of the way of the containers.
---
--- setBorder* is global to the profile, so this is the one piece of UI state that has to
--- be undone explicitly on teardown -- otherwise disabling the UI leaves the game text
--- squeezed into the middle of the screen with nothing around it.
--- Numeric percentage from a "17%" style spec.
function M.percentOf(spec)
   return tonumber(tostring(spec):match("(%d+)%%")) or 0
end

function M.resizeConsole()
   local width, height = getMainWindowSize()
   local function fraction(spec)
      return M.percentOf(spec) / 100
   end

   setBorderLeft(math.floor(width * fraction(M.WIDTH_LEFT)))
   setBorderRight(math.floor(width * fraction(M.WIDTH_RIGHT)))
   setBorderBottom(math.floor(height * fraction(M.HEIGHT_BOTTOM)))
   setBorderTop(0)
end

function M.clearConsoleBorders()
   setBorderLeft(0)
   setBorderRight(0)
   setBorderBottom(0)
   setBorderTop(0)
end

--- Fetch a container by short name ("left", "right", "bottom"). Panels use this rather
--- than reaching into M.containers so the naming scheme stays in one place.
function M.container(which)
   return M.containers["emunah." .. tostring(which)]
end

function M.show()
   for _, container in pairs(M.containers) do
      pcall(function() container:show() end)
   end
   M.resizeConsole()
end

function M.hide()
   for _, container in pairs(M.containers) do
      pcall(function() container:hide() end)
   end
   M.clearConsoleBorders()
end

function M.toggle()
   local enabled = not emunah.config.get("ui.enabled", true)
   emunah.config.set("ui.enabled", enabled)
   emunah.config.save()
   if enabled then M.build() else M.hide() end
   return enabled
end

--- Names of the containers we own, used for save-file cleanup.
M.NAMES = { "emunah.left", "emunah.right", "emunah.bottom" }

--- Delete the saved geometry and rebuild from defaults.
---
--- Adjustable.Container persists position, size and visibility per container name under
--- <profile>/AdjustableContainer/. That is usually what you want, but it is also how a
--- panel gets stuck: dragged off-screen, resized to nothing, or saved while hidden. There
--- is no in-game way to recover from that, so this is the escape hatch.
function M.reset()
   local directory = getMudletHomeDir() .. "/AdjustableContainer/"
   local removed = 0

   for _, name in ipairs(M.NAMES) do
      local container = M.containers[name]
      -- deleteSaveFile is the supported way; fall back to os.remove if it is unavailable.
      if container and container.deleteSaveFile then
         if pcall(function() container:deleteSaveFile() end) then removed = removed + 1 end
      elseif os.remove(directory .. name .. ".lua") then
         removed = removed + 1
      end
   end

   -- Drop our handles so the rebuild does not inherit state from the current generation.
   emunah._persist.uiContainers = nil
   M.containers = {}

   log.info("Cleared %d saved container layout(s); rebuilding from defaults.", removed)
   return M.build()
end

-- Keep the console borders correct when the window is resized. The containers handle
-- themselves; the borders do not.
emunah.event.register("sysWindowResizeEvent", function()
   if emunah.config.get("ui.enabled", true) then M.resizeConsole() end
end, "ui.layout")

M.build()

return M

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

-- State for the left column's content-sized layout (see "Sizing the left column" below).
-- Declared up here, above M.build() and M.section(), which reset and write it.
M.sections = {}
--- key -> { lines at density 1, lines at density 2, ... }
local needs = {}
--- key -> the density chosen
local density = {}
--- key -> "y:height" last applied, so an unchanged section is not moved
local placed = {}
--- Whether the room console's scrollbar is on.
local scrolling = nil

--- Fractions of the window given to each region.
---
--- Layout:
---
---   +------------+---------------------------+-------------+
---   | ROOM       |  chyron (console width)   |             |
---   |  name/area |---------------------------+   CHAT      |
---   |  exits     |                           |   (tabs)    |
---   |  players   |                           |             |
---   |  denizens  |     main game console     |-------------|
---   |  items     |                           |             |
---   |------------|                           |   MAP       |
---   | AFFLICTIONS|                           |             |
---   |  cure plan |                           |             |
---   |------------|                           |             |
---   | DEFENCES   |                           |             |
---   +------------+---------------------------+-------------+
---   | Combat                                                        |
---   | [HUNT][PAUSE] [TARGET 42%] | pvp, warnings, in flight         |
---   | HP ====  | MP ====  | EP ====  | WP ====                     |
---   | BAL EQ HERB .. TREE | CURE DEFS BASH        | XP  | stats    |
---   +---------------------------------------------------------------+
---
--- Everything about YOU is in one column: where you are, what is wrong, what is up. The
--- other side is everyone else: chat and the map. The combat HUD is the full width at the
--- very bottom, directly under the last line of game text -- immediately above the prompt,
--- where you are already looking during a fight. Health you have to glance away for is
--- health you notice too late. The target's own health belongs in that same eyeline.
---
--- The chyron is scoped to the console's own width rather than the full window, because it
--- sits directly above the side columns' own content. See ui/chyron.lua.
M.WIDTH_LEFT    = "19%"
M.WIDTH_RIGHT   = "26%"
--- The combat HUD's share of the window: just what its three rows need (ui/vitals.lua), and
--- the container's "Combat" title above the first of them, in whole percent of the window as
--- it is now. The title has a line of its own because the hunt and pause buttons sit under
--- it, at the start of row 1 (the user's request, 2026-10-04). A fixed 11% was too little at 768px, where the
--- balance row was cut off, and too much at 1080px, where the slack became a gap between
--- the HUD and the command line. M.fit() recomputes it; every consumer reads
--- M.HEIGHT_BOTTOM after that.
M.HUD_PX = 104
M.HEIGHT_BOTTOM = "9%"

function M.fit()
   local _, height = getMainWindowSize()
   local pct = 9
   if tonumber(height) and height > 0 then
      pct = math.ceil(M.HUD_PX * 100 / height)
   end
   M.HEIGHT_BOTTOM = string.format("%d%%", pct)
   return M.HEIGHT_BOTTOM
end
--- One line plus padding for the scrolling chyron. Reserved like HEIGHT_BOTTOM is -- it
--- pushes the console down rather than floating over its top line of text.
M.HEIGHT_TOP    = "5%"

--- The left column's three sections, top to bottom, as percentages OF THAT COLUMN. Room
--- gets the most: it is the only one whose length the game decides (a crowded room, a pile
--- of loot). Afflictions next, because it is what changes in a fight.
---
--- The column has no title of its own (the sections are titled), so they start right under
--- the container's top padding.
M.LEFT_SECTIONS = {
   { key = "room",        title = "Room",        y = 1,  height = 41 },
   { key = "afflictions", title = "Afflictions", y = 42, height = 31 },
   { key = "defences",    title = "Defences",    y = 73, height = 27 },
}

--- Height of a section's title bar, in pixels.
M.HEADER_PX = 20
--- Where a title bar sits from the top of its column: the left column's sections start 4px
--- down (M.reflow()) and draw their bar 2px into the section. The chat's bar matches it.
M.TITLE_Y = 6
--- Where a titled panel's content starts: under its bar, with the same 2px gap.
M.TITLED_TOP = M.TITLE_Y + M.HEADER_PX + 2

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
---   right container   0            -> rightHeight()   chat
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

--- Widgets the previous UI created and this one does not. Mudlet keeps them, by name, for
--- the life of the profile -- and an Adjustable.Container rebuilt under the same name is the
--- SAME Qt widget, so an old panel's children reappear inside the new one. They are hidden
--- on every build. (The old mini-consoles named here are also why the new panels must not
--- reuse their names: see M.section().)
M.LEGACY = {
   "emunah.afflictions", "emunah.defences",
   "emunah.balance", "emunah.equilibrium", "emunah.vectors",
}

local function hideLegacy()
   if type(hideWindow) ~= "function" then return end
   for _, name in ipairs(M.LEGACY) do pcall(hideWindow, name) end
end

--- Bumped whenever the default geometry changes. Adjustable.Container restores each panel's
--- saved size and position, so a layout change is otherwise invisible to anyone who has run
--- the old one -- and worse than invisible: the old bottom strip (16% of the window) came back
--- over a console bordered for the new one (11%), and hid the last lines of game text.
---
--- 3: the HUD grew a line for its title, so the buttons under it clear the word.
M.LAYOUT_VERSION = 3

local function discardStaleGeometry()
   if emunah.config.get("ui.layoutVersion", 1) == M.LAYOUT_VERSION then return end
   local directory = getMudletHomeDir() .. "/AdjustableContainer/"
   for _, name in ipairs(M.NAMES or {}) do os.remove(directory .. name .. ".lua") end
   emunah.config.set("ui.layoutVersion", M.LAYOUT_VERSION)
   emunah.config.save()
   log.info("The interface layout changed -- panel positions reset to the new defaults.")
end

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

   M.fit()
   -- New widgets: nothing has been placed, and the room console starts without a scrollbar.
   M.sections, placed, scrolling = {}, {}, nil
   discardStaleGeometry()
   hideLegacy()
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

   -- Console-width only -- see the module header. Anchored off WIDTH_LEFT/WIDTH_RIGHT so a
   -- change to either one cannot silently leave the chyron overlapping a side column.
   local consoleWidth = string.format("%d%%",
      100 - M.percentOf(M.WIDTH_LEFT) - M.percentOf(M.WIDTH_RIGHT))
   make("emunah.top", {
      x = M.WIDTH_LEFT, y = 0, width = consoleWidth, height = M.HEIGHT_TOP,
      titleText = "Chyron",
   })

   make("emunah.left", {
      x = 0, y = 0, width = M.WIDTH_LEFT, height = columnHeight,
      -- No title: each section carries its own, and a column label over them was noise.
      titleText = "",
   })

   -- Stops above the map region so the container's background label cannot paint over it.
   -- Untitled for the same reason as the left column: the chat carries a title bar like the
   -- left column's sections, so the two sides read alike (the user's request).
   make("emunah.right", {
      x = "-" .. M.WIDTH_RIGHT, y = 0, width = M.WIDTH_RIGHT, height = M.rightHeight(),
      titleText = "",
   })
   if M.container("right") then
      M.titleBar(M.container("right"), "chat", "Chat",
         { x = 4, y = M.TITLE_Y, width = "-8px" })
   end

   make("emunah.bottom", {
      x = 0, y = "-" .. M.HEIGHT_BOTTOM, width = "100%", height = M.HEIGHT_BOTTOM,
      titleText = "Combat",
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

--- One of our containers' live geometry, in pixels, or nil if it cannot be read.
local function measured(which, method)
   local container = M.container(which)
   if not container or type(container[method]) ~= "function" then return nil end
   local ok, value = pcall(container[method], container)
   return ok and tonumber(value) or nil
end

--- Set the console borders from where the containers ACTUALLY are.
---
--- Computing them from the layout's percentages assumed the containers were there too. They
--- are not, whenever Adjustable.Container restores a saved size or the user drags an edge:
--- the bottom strip came back taller than the border made room for, and covered the last
--- lines of game text. So each border is measured off its container where that can be read,
--- with a few pixels to spare, and the percentage is only the fallback.
function M.resizeConsole()
   local width, height = getMainWindowSize()
   local function fraction(spec)
      return M.percentOf(spec) / 100
   end
   local SPARE = 2

   local left = width * fraction(M.WIDTH_LEFT)
   local lx, lw = measured("left", "get_x"), measured("left", "get_width")
   if lx and lw then left = lx + lw + SPARE end

   local right = width * fraction(M.WIDTH_RIGHT)
   local rx = measured("right", "get_x")
   if rx then right = width - rx + SPARE end

   local bottom = height * fraction(M.HEIGHT_BOTTOM)
   local by = measured("bottom", "get_y")
   if by then bottom = height - by + SPARE end

   local top = height * fraction(M.HEIGHT_TOP)
   local ty, th = measured("top", "get_y"), measured("top", "get_height")
   if ty and th then top = ty + th + SPARE end

   setBorderLeft(math.floor(left))
   setBorderRight(math.floor(right))
   setBorderBottom(math.floor(bottom))
   setBorderTop(math.floor(top))
end

function M.clearConsoleBorders()
   setBorderLeft(0)
   setBorderRight(0)
   setBorderBottom(0)
   setBorderTop(0)
end

--- A titled section: a Geyser.Container holding a header bar and a body below it.
---
--- Every panel in the left column is one of these, so they share one look -- the same bar,
--- the same rule under it, the same padding -- and a panel only decides what goes IN it.
--- @param parent table the Adjustable.Container to build in
--- @param spec table { key, title, y, height (percent of parent), body = "label"|"console",
---   cons = extra MiniConsole fields }
--- @return table|nil { box, header, body }
function M.section(parent, spec)
   if not parent then return nil end
   local box = Geyser.Container:new({
      name = "emunah.section." .. spec.key,
      x = 4, y = string.format("%d%%", spec.y),
      width = "-8px", height = string.format("%d%%", spec.height),
   }, parent)

   local header = M.titleBar(box, spec.key, nil, { x = 0, y = 2, width = "100%" })

   local body
   if spec.body == "console" then
      local cons = {
         name = "emunah." .. spec.key,
         x = 0, y = M.HEADER_PX + 2, width = "100%", height = "-4px",
      }
      for key, value in pairs(spec.cons or {}) do cons[key] = value end
      body = Geyser.MiniConsole:new(theme.consoleCons(cons), box)
   else
      -- NOT "emunah.<key>". Mudlet keeps windows by name across a reload, and echo() looks a
      -- name up among mini-consoles BEFORE labels: the previous UI's afflictions and
      -- defences were mini-consoles of exactly those names, so this label's rich text was
      -- printed into the old console as raw HTML -- and the defences into one nobody could
      -- see. A name never used for a console cannot collide.
      body = Geyser.Label:new({
         name = "emunah.panel." .. spec.key,
         x = 0, y = M.HEADER_PX + 2, width = "100%", height = "-4px",
      }, box)
      body:setStyleSheet(theme.bodyStyle())
   end

   -- New, empty widgets: whatever the paint caches say describes the ones they replaced.
   theme.forgetPainted("body." .. spec.key)
   M.header(spec.key, header, spec.title)

   local section = { box = box, header = header, body = body, kind = spec.body,
                     refresh = spec.refresh }
   M.sections[spec.key] = section
   placed[spec.key] = nil
   return section
end

--- A title bar: the accent square, the title, and room for a summary beside it. Every panel
--- has one -- the left column's sections, the chat, the map -- so the two sides read alike.
--- @param parent table|nil the container to build in; nil puts it on the window itself
--- @param key string names the label ("emunah.header.<key>") and its paint cache
--- @param title string|nil drawn now if given; M.header() redraws it with a summary
--- @param geometry table x, y and width; the height is always HEADER_PX
function M.titleBar(parent, key, title, geometry)
   local header = Geyser.Label:new({
      name = "emunah.header." .. key,
      x = geometry.x, y = geometry.y, width = geometry.width, height = M.HEADER_PX,
   }, parent)
   header:setStyleSheet(theme.headerStyle())
   -- A new, empty widget: whatever the paint cache says describes the one it replaced.
   theme.forgetPainted("header." .. key)
   if title then M.header(key, header, title) end
   return header
end

-- ---------------------------------------------------------------------------
-- Sizing the left column to its content
-- ---------------------------------------------------------------------------
--
-- Fixed shares were wrong in both directions at once: a room with a dozen things on the floor
-- ran off the bottom of its section while the defences below sat on empty space, and twenty
-- defences up showed a count in the title and nothing under it. "We need to see all data in
-- every window." So each section says how many lines it has, and the column is divided by
-- that, in pixels:
--
--   1. Every section is offered its lines in full. If they fit, the room takes any space left
--      over (it is the one that grows when you walk somewhere busy).
--   2. If they do not, sections lay themselves out more densely, in a fixed order -- defences
--      to three columns, then room items to two -- until they fit.
--   3. If even that will not fit, afflictions and defences keep their full height (a label
--      cannot scroll) and the room takes what is left, with a scrollbar: still all there.
--
-- A section reports a list of line counts, one per density it can do, most spacious first,
-- and reads back the density it was given with M.compact(). It is repainted only when that
-- changes, so this settles in one pass.


--- Order in which sections give up space, densest first. Afflictions never do: it is the one
--- that matters in a fight, and it is short.
M.COMPACT_ORDER = { "defences", "room" }

--- Pixel height of one line of panel text, at the panels' font size: point size at 96 dpi,
--- with line spacing. Slightly generous on purpose -- an estimate that is short cuts the last
--- row off, one that is long costs a few pixels of space.
function M.lineHeight()
   return math.ceil(theme.font.small * 96 / 72 * 1.5)
end

--- Report a section's line counts. Lays the column out again once this packet is done.
function M.need(key, levels)
   local previous = needs[key]
   if previous and #previous == #levels then
      local same = true
      for index = 1, #levels do
         if previous[index] ~= levels[index] then same = false break end
      end
      -- The clock repaints afflictions five times a second; their line count rarely moves.
      if same then return end
   end
   needs[key] = levels
   theme.later("layout.reflow", M.reflow)
end

--- The density a section should render at (1 = most spacious).
function M.compact(key)
   return density[key] or 1
end

local function columnHeight()
   local container = M.container("left")
   if container and type(container.get_height) == "function" then
      local ok, value = pcall(container.get_height, container)
      if ok and tonumber(value) and value > 0 then return value - 8 end
   end
   local _, height = getMainWindowSize()
   return math.floor(height * (100 - M.percentOf(M.HEIGHT_BOTTOM)) / 100) - 8
end

--- Lay the left column out from what its sections reported.
function M.reflow()
   local available = columnHeight()
   local line = M.lineHeight()
   local chrome = M.HEADER_PX + 12       -- title bar, the gap under it, the body's padding

   local level = {}
   for _, spec in ipairs(M.LEFT_SECTIONS) do level[spec.key] = 1 end

   local function height(key)
      local levels = needs[key]
      local lines = levels and (levels[level[key]] or levels[#levels]) or 1
      return chrome + math.max(lines, 1) * line
   end
   local function total()
      local sum = 0
      for _, spec in ipairs(M.LEFT_SECTIONS) do sum = sum + height(spec.key) end
      return sum
   end

   for _, key in ipairs(M.COMPACT_ORDER) do
      while total() > available and needs[key] and level[key] < #needs[key] do
         level[key] = level[key] + 1
      end
   end

   local heights = {}
   for _, spec in ipairs(M.LEFT_SECTIONS) do heights[spec.key] = height(spec.key) end
   local roomNeed = heights.room
   local others = total() - roomNeed
   local minimum = chrome + 2 * line
   heights.room = math.max(available - others, minimum)
   local overflow = heights.room < roomNeed
   if heights.room + others > available then
      -- Nothing left to give: defences hand back what they must, so the room keeps a minimum.
      heights.defences = math.max(chrome + line, available - heights.room - heights.afflictions)
   end

   local y = 4
   for _, spec in ipairs(M.LEFT_SECTIONS) do
      local key = spec.key
      local section = M.sections[key]
      local h = heights[key]
      local signature = y .. ":" .. h
      if section and placed[key] ~= signature then
         placed[key] = signature
         section.box:move(4, y)
         section.box:resize("-8px", h)
         section.body:resize("100%", h - M.HEADER_PX - 4)
      end
      y = y + h
   end

   local room = M.sections.room
   if room and room.kind == "console" and scrolling ~= overflow then
      scrolling = overflow
      if overflow then room.body:enableScrollBar() else room.body:disableScrollBar() end
   end

   for key, chosen in pairs(level) do
      if density[key] ~= chosen then
         density[key] = chosen
         local section = M.sections[key]
         if section and section.refresh then theme.later("section." .. key, section.refresh) end
      end
   end
end

--- Set a section's title bar. Drawn only when it changes.
function M.header(key, header, title, summary, summaryColour)
   return theme.paintLabel(header, "header." .. key, theme.headerHTML(title, summary, summaryColour))
end

--- The spec for one of the left column's sections, by key.
function M.leftSection(key)
   for _, spec in ipairs(M.LEFT_SECTIONS) do
      if spec.key == key then return spec end
   end
   return nil
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
M.NAMES = { "emunah.top", "emunah.left", "emunah.right", "emunah.bottom" }

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

-- A container dragged or resized by hand moves an edge the borders were measured from.
emunah.event.register("AdjustableContainerRepositionFinish", function(_, name)
   if type(name) == "string" and name:sub(1, 7) == "emunah." and emunah.config.get("ui.enabled", true) then
      M.resizeConsole()
   end
end, "ui.layout")

-- Keep the console borders correct when the window is resized. The containers handle
-- themselves; the borders do not.
emunah.event.register("sysWindowResizeEvent", function()
   if emunah.config.get("ui.enabled", true) then M.resizeConsole() end
end, "ui.layout")

M.build()

return M

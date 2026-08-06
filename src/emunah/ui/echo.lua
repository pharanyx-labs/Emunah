--- One-off announcements: a boxed console banner, a single highlighted line, and small
--- floating status labels anchored to the top of the window.
---
--- Rewritten from Outpost's ui.lua (combatEcho, oecho, createLineGradient, eventLabel,
--- eventLabelLoop -- <https://github.com/SynecticLabs/Outpost/blob/master/ui.lua>) onto
--- this codebase's own foundations rather than a straight port:
---
---   * Geyser.Label instead of the raw createLabel/moveWindow/resizeWindow/showWindow
---     calls -- this codebase builds every panel on Geyser (see ui/vitals.lua,
---     ui/affpanel.lua) and mixing in the legacy label API would be a second, inconsistent
---     way of doing the same thing.
---   * theme.lua's palette instead of hardcoded colour names, so a retheme stays a
---     one-file change.
---   * cecho/decho and hecho used exactly as theme.lua documents them: decho for RGB
---     triples (theme.dc), hecho for the `|cRRGGBB` gradient escapes.
---   * eventLabel is keyed rather than anonymous. Outpost minted a random window name on
---     every call, so a label created with no duration was never reclaimed. A second call
---     with the same key updates the existing label instead of stacking a new one.
---   * eventLabelLoop is self-scheduling (one tempTimer, rearmed only while a timed label
---     is outstanding) instead of a loop the caller has to keep invoking forever.

local M = {}

local theme = emunah.ui.theme
local util  = emunah.util

-- ---------------------------------------------------------------------------
-- combatEcho -- a boxed, centred banner in the main console
-- ---------------------------------------------------------------------------

local COMBAT_COLOURS = {
   red    = "danger",
   green  = "defence",
   blue   = "mana",
   yellow = "warning",
   purple = "equilibrium",
   orange = "endurance",
}

--- @param text string
--- @param colour string|nil one of COMBAT_COLOURS' keys, default "yellow"
--- @param width number|nil minimum banner width in characters, default 100
function M.combatEcho(text, colour, width)
   text = tostring(text or "")
   if text == "" then return end

   -- Letter-spaced and upper-cased, the way Outpost's version reads as a klaxon rather
   -- than a sentence.
   text = text:gsub("%a", "%1 "):sub(1, -2)
   text = "+    +    +    " .. text:upper() .. "    +    +    +"

   width = width or 100
   if #text + 4 > width then width = #text + 4 end

   local lindent = math.floor(((width - #text) / 2) - 1)
   local rindent = math.ceil(((width - #text) / 2) - 1)

   local fg = theme.dc(COMBAT_COLOURS[colour] or "warning")
   local border = fg .. "+" .. string.rep("-", width - 2) .. "+"

   decho("\n" .. border)
   decho("\n" .. fg .. "|" .. string.rep(" ", lindent) .. text .. string.rep(" ", rindent) .. "|")
   decho("\n" .. border)
end

-- ---------------------------------------------------------------------------
-- createLineGradient / oecho -- a highlighted line framed by a short colour fade
-- ---------------------------------------------------------------------------

--- A run of `width` gradient dashes via hecho's `|cRRGGBB` escapes, stepping from a dim
--- shade of `accent` up to `accent` itself (or back down, when `left` is false). Outpost's
--- version stepped through a fixed set of grey hex digits, which only worked because it
--- happened to look like a ramp; this shades a real theme colour instead, so any accent
--- can be used and the direction is a genuine fade rather than a coincidence of hex digits.
--- @param left boolean fading in (true) or fading out (false)
--- @param width number|nil dash count, default 10
--- @param accent string|nil a hex colour, default theme.colour.textDim
function M.createLineGradient(left, width, accent)
   width = width or 10
   accent = accent or theme.colour.textDim

   local gradient = {}
   for step = 1, width do
      local factor = left and (step / width) or (1 - ((step - 1) / width))
      local hex = theme.shade(accent, 0.2 + factor * 0.8)
      gradient[#gradient + 1] = "|c" .. hex:sub(2) .. "-"
   end
   return table.concat(gradient)
end

--- One highlighted line, framed by a short gradient on each side. Replaces the current
--- line first (deleteLine(), the same idiom ih.lua and shop.lua use for re-rendering a
--- line in place) rather than appending a duplicate.
--- @param text string
--- @param colour string|nil a theme.colour key, default "warning"
--- @param pleft number|nil percent of `width` given to the left gradient, default 90
--- @param width number|nil total width in characters, default 100
function M.oecho(text, colour, pleft, width)
   deleteLine()
   text = tostring(text or "")
   colour = colour or "warning"
   width = width or 100
   pleft = pleft or 90
   local pright = width - pleft

   local left  = M.createLineGradient(true, math.max(pleft - #text, 0)) .. "[ "
   local right = " ]" .. M.createLineGradient(false, pright)

   hecho("\n" .. left)
   decho(theme.dc(colour) .. text)
   hecho(right)
end

-- ---------------------------------------------------------------------------
-- eventLabel / eventLabelLoop -- small floating status labels at the top of the window
-- ---------------------------------------------------------------------------

M.labels = {}

local FONT_SIZE     = 22
local LABEL_HEIGHT  = math.floor(FONT_SIZE * 1.7)   -- pixels; room above/below the glyphs
local Y_FRACTION    = 0.4                           -- fraction of window height for the first
                                                     -- row -- close to centre so it cannot be
                                                     -- missed, but off it enough that it does
                                                     -- not sit on top of whatever is happening
                                                     -- in the middle of the room
local ROW_GAP       = 10                            -- pixels between stacked labels
local CHAR_WIDTH    = FONT_SIZE * 0.72              -- rough average glyph width at this size,
                                                     -- padded up so a bold/wide font never
                                                     -- overflows a box sized from this estimate
local MIN_WIDTH     = 90
local TICK_INTERVAL = 0.5
local tickId = nil

local function available()
   return type(Geyser) == "table"
end

--- Top edge for the first stacked row, a fixed fraction down the window rather than a fixed
--- pixel offset -- so it stays in the same relative spot regardless of window size.
local function baseY()
   local _, winHeight = getMainWindowSize()
   return math.floor((winHeight or 1080) * Y_FRACTION)
end

--- Left/right edges of the main game console, as fractions of the whole window -- i.e. the
--- gap ui/layout.lua leaves between the left afflictions panel and the right chat/room
--- panel. Centring on the WINDOW rather than this gap looks centred in an empty profile and
--- visibly off (toward the left panel) in the real layout, because the right panel
--- (WIDTH_RIGHT) is wider than the left one (WIDTH_LEFT). Read from ui.layout rather than
--- duplicating its percentages here, so a layout change cannot silently throw this off.
--- Falls back to the whole window if layout has not loaded (e.g. headless/no UI).
local function consoleFractions()
   local layout = emunah.ui and emunah.ui.layout
   if not layout then return 0, 1 end
   local left  = layout.percentOf(layout.WIDTH_LEFT) / 100
   local right = 1 - layout.percentOf(layout.WIDTH_RIGHT) / 100
   return left, right
end

--- Width in pixels for a label showing `text`, so a short "*PAUSED*" stays small and a
--- longer message gets the room it needs -- clamped to the game console (not the whole
--- window) so a long string cannot run out from under the console and over a side panel.
local function labelWidth(text)
   local winWidth = getMainWindowSize() or 1920
   local left, right = consoleFractions()
   local consoleWidth = winWidth * (right - left)
   local width = math.max(#text * CHAR_WIDTH + 60, MIN_WIDTH)
   if width > consoleWidth - 40 then width = consoleWidth - 40 end
   return math.floor(width)
end

local function anyTimed()
   for _, entry in pairs(M.labels) do
      if entry.expiresAt then return true end
   end
   return false
end

local function scheduleTick()
   if tickId or not anyTimed() then return end
   tickId = tempTimer(TICK_INTERVAL, function()
      tickId = nil
      M.eventLabelLoop()
   end)
end

--- Create or update a small status label docked to the top of the window. A second call
--- with the same `key` restyles the existing widget rather than creating another one.
--- @param key string stable identity for this label
--- @param text string
--- @param opts table|nil { colour = theme.colour key, duration = seconds, or nil to
---        persist until clearEventLabel() }
--- @return table|nil the Geyser.Label, or nil if the UI is unavailable
function M.eventLabel(key, text, opts)
   if not available() or not key then return nil end
   opts = opts or {}
   text = tostring(text or "")

   local winWidth = getMainWindowSize() or 1920
   local width = labelWidth(text)
   local left, right = consoleFractions()
   local centreX = winWidth * (left + right) / 2
   local x = math.floor(centreX - width / 2)

   local entry = M.labels[key]
   if not entry then
      local row = 0
      for _ in pairs(M.labels) do row = row + 1 end
      local y = baseY() + row * (LABEL_HEIGHT + ROW_GAP)
      local ok, widget = pcall(function()
         return Geyser.Label:new({
            name   = "emunah.eventlabel." .. key,
            x = x, y = y, width = width, height = LABEL_HEIGHT,
         })
      end)
      if not ok or not widget then return nil end
      entry = { widget = widget, row = row, width = width }
      M.labels[key] = entry
   elseif width ~= entry.width then
      -- The text got longer or shorter than last time -- resize and re-centre in place.
      -- Standard Geyser.Container methods (inherited by Label); the test mock does not
      -- model them, so this pcall is a no-op under test, which is fine -- only the label's
      -- text and visibility are asserted there, not its geometry.
      local y = baseY() + entry.row * (LABEL_HEIGHT + ROW_GAP)
      pcall(function() entry.widget:resize(width, LABEL_HEIGHT) end)
      pcall(function() entry.widget:move(x, y) end)
      entry.width = width
   end

   entry.expiresAt = opts.duration and (util.now() + tonumber(opts.duration)) or nil

   local colourHex = theme.colour[opts.colour] or theme.colour.textBright
   pcall(function()
      -- qproperty-alignment rather than :setAlignment(): the same centring idiom
      -- theme.headerStyle() already relies on, so it is verified against this codebase's
      -- own usage rather than guessed at.
      entry.widget:setStyleSheet(string.format([[
         background-color: %s;
         border: 2px solid %s;
         border-radius: 6px;
         qproperty-alignment: 'AlignCenter';
      ]], theme.colour.panel, colourHex))
   end)
   pcall(function() entry.widget:setFontSize(FONT_SIZE) end)
   entry.widget:clear()
   entry.widget:decho(theme.dc(opts.colour or "textBright") .. text)
   entry.widget:show()

   if entry.expiresAt then scheduleTick() end
   return entry.widget
end

--- Remove a label immediately, regardless of any duration it was given.
function M.clearEventLabel(key)
   local entry = M.labels[key]
   if not entry then return false end
   pcall(function() entry.widget:hide() end)
   M.labels[key] = nil
   return true
end

--- Sweep expired labels and, if any timed label is still outstanding, rearm the tick.
--- Self-scheduling: nothing needs to call this on a loop, eventLabel() starts the chain
--- and it stops itself once nothing has a duration left.
function M.eventLabelLoop()
   local now = util.now()
   local expired = {}
   for key, entry in pairs(M.labels) do
      if entry.expiresAt and now >= entry.expiresAt then
         expired[#expired + 1] = key
      end
   end
   for _, key in ipairs(expired) do M.clearEventLabel(key) end
   scheduleTick()
end

-- ---------------------------------------------------------------------------
-- the *PAUSED* banner
-- ---------------------------------------------------------------------------

--- Curing and defence keep-up are both independently pausable (see `pp` in commands.lua,
--- which pauses/resumes them together as one action), and a system silently doing nothing
--- is exactly the failure mode a banner like this exists to make impossible to miss.
--- Persistent (no duration) -- it stays up for as long as either one is actually off.
---
--- Text is fixed rather than naming which of the two is off: which one hardly matters at a
--- glance mid-fight, and a banner whose width changes with its own contents was the thing
--- that needed fixing here in the first place.
function M.refreshPauseBanner()
   local curing = emunah.curing and emunah.curing.engine
   local keepup = emunah.curing and emunah.curing.defkeepup
   local curingOff = curing ~= nil and not curing.enabled
   local keepupOff = keepup ~= nil and not keepup.enabled

   if not curingOff and not keepupOff then
      M.clearEventLabel("paused")
      return
   end

   M.eventLabel("paused", "** PAUSED **", { colour = "danger" })
end

emunah.event.registerAll({
   "emunah.curing.enabled", "emunah.curing.disabled",
   "emunah.defkeepup.enabled", "emunah.defkeepup.disabled",
}, function() M.refreshPauseBanner() end, "ui.echo")

return M

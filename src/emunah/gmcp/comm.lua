--- Comm.Channel -- communication channels.
---
--- Messages:
---   Comm.Channel.List     array of { name, caption, command }
---   Comm.Channel.Text     { channel, talker, text }
---   Comm.Channel.Players  array of { name, channels }
---   Comm.Channel.Start    channel name (you began listening)
---   Comm.Channel.End      channel name
---
--- This module classifies incoming channel text, keeps it, and re-broadcasts it; ui/chat.lua
--- does the rendering. Keeping them apart means chat capture keeps working (and keeps feeding
--- logs and any custom handlers) even with the UI disabled.
---
--- On the text itself: Comm.Channel.Text carries raw ANSI, and IRE terminates it with an
--- ESC ... EOT sequence that ansi2decho does not strip. Left in place it renders as
--- garbage at the end of every line, so it is stripped below.
---
--- KEPT PER TAB, AND ACROSS A RELOAD. Every message goes into one ring for the All tab and
--- one for its own tab, each bounded. One shared buffer let a busy market push the last tell
--- out of memory; a ring per tab keeps a quiet tab's history however loud the others are.
--- The rings live on _persist, so `emreload` keeps the conversation instead of blanking it.
--- Each message carries a sequence number, which is how ui/chat.lua knows what a tab has not
--- drawn yet.

local M = {}

local util  = emunah.util
local event = emunah.event

--- channel name -> { name, caption, command }
M.channels = {}

--- Ordered classification rules: the first pattern that matches the channel name wins.
--- Patterns are Lua patterns matched against the lower-cased channel name.
---
--- Achaea's channel names are terse ("ct" for city, "ht" for house) and there are a lot
--- of clan channels with arbitrary names, so anything unmatched lands in Misc rather
--- than being dropped. `emset chat route` sends one channel somewhere else (ui.chatRoutes).
M.ROUTES = {
   { tab = "Tells",  patterns = { "^tell" } },
   { tab = "City",   patterns = { "^ct$", "^cnt$", "^city" } },
   { tab = "House",  patterns = { "^ht$", "^hnt$", "^house", "^gt$", "^gnt$", "^guild" } },
   { tab = "Market", patterns = { "^market", "^trade", "^newbie" } },
   { tab = "Says",   patterns = { "^say", "^shout", "^yell", "^whisper", "^emote" } },
}

M.FALLBACK_TAB = "Misc"

--- Messages kept for the All tab, and for each tab of its own.
M.HISTORY_LIMIT = 500
M.TAB_LIMIT     = 300

-- ---------------------------------------------------------------------------
-- rings
-- ---------------------------------------------------------------------------
--
-- A ring is { first, last, limit, [first..last] = message }. Pushing past the limit drops
-- the oldest by clearing one slot: no table.remove(t, 1), which moves every entry down one
-- on every message.

local function ring(limit)
   return { first = 1, last = 0, limit = limit }
end

local function push(r, item)
   r.last = r.last + 1
   r[r.last] = item
   if r.last - r.first + 1 > r.limit then
      r[r.first] = nil
      r.first = r.first + 1
   end
end

local function store()
   emunah._persist = emunah._persist or {}
   local kept = emunah._persist.comm
   if not kept then
      kept = { seq = 0, all = ring(M.HISTORY_LIMIT), tabs = {} }
      emunah._persist.comm = kept
   end
   return kept
end

local function tabRing(tab)
   local kept = store()
   local r = kept.tabs[tab]
   if not r then
      r = ring(M.TAB_LIMIT)
      kept.tabs[tab] = r
   end
   return r
end

-- ---------------------------------------------------------------------------
-- settings: which tabs, where a channel goes, what is muted
-- ---------------------------------------------------------------------------
--
-- Read on every message, so each is parsed once per distinct value: config.get hands back
-- the same string or table until the setting changes, and that is the cache key.

--- A list setting, as a string ("a, b") or an array, to an array of trimmed items.
local function listOf(raw)
   local out = {}
   if type(raw) == "table" then
      for _, item in ipairs(raw) do
         item = util.trim(tostring(item))
         if item ~= "" then out[#out + 1] = item end
      end
   elseif type(raw) == "string" then
      for item in raw:gmatch("[^,]+") do
         item = util.trim(item)
         if item ~= "" then out[#out + 1] = item end
      end
   end
   return out
end

local function cached(key, fallback, parse)
   local slot = { raw = {}, value = nil }
   return function()
      local raw = emunah.config.get(key, fallback)
      if raw ~= slot.raw then slot.raw, slot.value = raw, parse(raw) end
      return slot.value
   end
end

--- The tabs to show, in order, from ui.chatTabs: { list = {...}, lower = { city = "City" } }.
--- The fallback is always among them, last if the setting leaves it out, so a channel never
--- routes to a tab that is not there.
local shownTabs = cached("ui.chatTabs", nil, function(raw)
   local list, lower = {}, {}
   local items = listOf(raw)
   if #items == 0 then
      for _, route in ipairs(M.ROUTES) do items[#items + 1] = route.tab end
   end
   for _, tab in ipairs(items) do
      local key = tab:lower()
      if key ~= "all" and not lower[key] then
         tab = util.capitalise(tab)
         list[#list + 1] = tab
         lower[key] = tab
      end
   end
   local fallback = M.FALLBACK_TAB:lower()
   if not lower[fallback] then
      list[#list + 1] = M.FALLBACK_TAB
      lower[fallback] = M.FALLBACK_TAB
   end
   return { list = list, lower = lower }
end)

--- ui.chatRoutes, "channel=Tab" items, as { channel = "tab" } (both lower case).
local routeOverrides = cached("ui.chatRoutes", nil, function(raw)
   local out = {}
   for _, item in ipairs(listOf(raw)) do
      local channel, tab = item:match("^(.-)%s*=%s*(.+)$")
      if channel and channel ~= "" then out[channel:lower()] = tab:lower() end
   end
   return out
end)

--- ui.chatMute as a set of lower-cased channel names.
local mutedSet = cached("ui.chatMute", nil, function(raw)
   local out = {}
   for _, channel in ipairs(listOf(raw)) do out[channel:lower()] = true end
   return out
end)

--- Classify a channel name into one of the shown tabs.
function M.tabFor(channel)
   local name = tostring(channel or ""):lower()
   local shown = shownTabs().lower
   local override = routeOverrides()[name]
   if override and shown[override] then return shown[override] end
   for _, route in ipairs(M.ROUTES) do
      for _, pattern in ipairs(route.patterns) do
         if name:find(pattern) then
            return shown[route.tab:lower()] or M.FALLBACK_TAB
         end
      end
   end
   return M.FALLBACK_TAB
end

--- Whether a channel is muted: kept, but not drawn.
function M.muted(channel)
   return mutedSet()[tostring(channel or ""):lower()] == true
end

--- The muted channels, sorted.
function M.mutes()
   return util.keys(mutedSet())
end

--- The route overrides, as { channel = "tab" }.
function M.routes()
   return routeOverrides()
end

--- Mute or unmute a channel. Saves the setting.
function M.setMuted(channel, muted)
   channel = tostring(channel or ""):lower()
   if channel == "" then return false end
   local set = util.copy(mutedSet())
   set[channel] = muted and true or nil
   emunah.config.set("ui.chatMute", table.concat(util.keys(set), ", "))
   emunah.config.save()
   return true
end

--- Send a channel to a tab, or back to its default with a nil tab. Saves the setting.
--- @return string|nil the tab it now goes to; nil and a reason when the tab is not shown
function M.setRoute(channel, tab)
   channel = tostring(channel or ""):lower()
   if channel == "" or channel:find("[,=]") then return nil, "not a channel name" end
   local routes = util.copy(routeOverrides())
   if tab then
      local shown = shownTabs().lower[tostring(tab):lower()]
      if not shown then return nil, "no tab called " .. tostring(tab) end
      routes[channel] = shown:lower()
   else
      routes[channel] = nil
   end
   local items = {}
   for _, name in ipairs(util.keys(routes)) do items[#items + 1] = name .. "=" .. routes[name] end
   emunah.config.set("ui.chatRoutes", table.concat(items, ", "))
   emunah.config.save()
   return M.tabFor(channel)
end

-- ---------------------------------------------------------------------------
-- capture
-- ---------------------------------------------------------------------------

--- Convert IRE channel text to decho-ready markup.
function M.render(text)
   if type(text) ~= "string" then return "" end
   local out = ansi2decho(text)
   -- Strip IRE's trailing ESC ... EOT sequence, which ansi2decho leaves behind.
   out = out:gsub(string.char(27) .. ".-" .. string.char(4), "")
   -- Channel text frequently arrives wrapped in a leading quote character.
   out = out:gsub('^"', "")
   return out
end

local function onList()
   local list = gmcp.Comm.Channel.List
   if type(list) ~= "table" then return end
   M.channels = {}
   for _, channel in ipairs(list) do
      if channel.name then
         M.channels[tostring(channel.name):lower()] = {
            name    = tostring(channel.name),
            caption = channel.caption and tostring(channel.caption) or tostring(channel.name),
            command = channel.command and tostring(channel.command) or nil,
         }
      end
   end
   event.raise("comm.channels", util.keys(M.channels))
end

local function onText()
   local payload = gmcp.Comm.Channel.Text
   if type(payload) ~= "table" then return end

   local kept = store()
   kept.seq = kept.seq + 1
   local channel = payload.channel and tostring(payload.channel) or ""
   local message = {
      seq     = kept.seq,
      channel = channel,
      talker  = payload.talker and tostring(payload.talker) or nil,
      text    = M.render(payload.text),
      raw     = payload.text and tostring(payload.text) or "",
      tab     = M.tabFor(channel),
      muted   = M.muted(channel) or nil,
      at      = os.time(),
   }

   push(kept.all, message)
   push(tabRing(message.tab), message)

   -- ui/chat.lua listens for this.
   event.raise("comm.text", message)
end

local function onPlayers()
   local players = gmcp.Comm.Channel.Players
   if type(players) ~= "table" then return end
   M.players = {}
   for _, player in ipairs(players) do
      if player.name then
         M.players[tostring(player.name)] = player.channels or {}
      end
   end
   event.raise("comm.players", util.count(M.players))
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

--- Known channel names, sorted.
function M.names()
   return util.keys(M.channels)
end

--- The command used to talk on a channel, e.g. commandFor("ct") -> "ct".
function M.commandFor(channel)
   local entry = M.channels[tostring(channel or ""):lower()]
   return entry and entry.command or nil
end

--- The tabs to show, in order, with the fallback last if ui.chatTabs left it out.
--- ui/chat.lua builds one tab per entry, plus All.
function M.tabs()
   return util.copy(shownTabs().list)
end

--- The sequence number of the newest message; 0 before any.
function M.seq()
   return store().seq
end

--- Messages newer than `after`, oldest first, at most `limit` of the newest. A tab name
--- reads that tab's ring; nil reads All's.
function M.since(after, tab, limit)
   local kept = store()
   local r = tab and kept.tabs[tab] or (not tab and kept.all)
   local out = {}
   if not r then return out end
   after, limit = after or 0, limit or math.huge
   local index = r.last
   while index >= r.first and #out < limit do
      local message = r[index]
      if message.seq <= after then break end
      out[#out + 1] = message
      index = index - 1
   end
   -- Collected newest first; hand them back in reading order.
   local n = #out
   for i = 1, math.floor(n / 2) do out[i], out[n - i + 1] = out[n - i + 1], out[i] end
   return out
end

--- Recent messages, optionally from one tab, oldest first.
function M.recent(count, tab)
   return M.since(0, tab, count or 20)
end

--- How many messages are kept, for All or for one tab.
function M.count(tab)
   local kept = store()
   local r = tab and kept.tabs[tab] or (not tab and kept.all)
   return r and (r.last - r.first + 1) or 0
end

event.gmcp("Comm.Channel.List",    onList,    "gmcp.comm")
event.gmcp("Comm.Channel.Text",    onText,    "gmcp.comm")
event.gmcp("Comm.Channel.Players", onPlayers, "gmcp.comm")

if gmcp and gmcp.Comm and gmcp.Comm.Channel and gmcp.Comm.Channel.List then
   onList()
end

return M

--- Comm.Channel -- communication channels.
---
--- Messages:
---   Comm.Channel.List     array of { name, caption, command }
---   Comm.Channel.Text     { channel, talker, text }
---   Comm.Channel.Players  array of { name, channels }
---   Comm.Channel.Start    channel name (you began listening)
---   Comm.Channel.End      channel name
---
--- This module classifies incoming channel text and re-broadcasts it; ui/chat.lua does
--- the rendering. Keeping them apart means chat capture keeps working (and keeps feeding
--- logs and any custom handlers) even with the UI disabled.
---
--- On the text itself: Comm.Channel.Text carries raw ANSI, and IRE terminates it with an
--- ESC ... EOT sequence that ansi2decho does not strip. Left in place it renders as
--- garbage at the end of every line, so it is stripped below.

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
--- than being dropped.
M.ROUTES = {
   { tab = "Tells",  patterns = { "^tell" } },
   { tab = "City",   patterns = { "^ct$", "^cnt$", "^city" } },
   { tab = "House",  patterns = { "^ht$", "^hnt$", "^house", "^gt$", "^gnt$", "^guild" } },
   { tab = "Market", patterns = { "^market", "^trade", "^newbie" } },
   { tab = "Says",   patterns = { "^say", "^shout", "^yell", "^whisper", "^emote" } },
}

M.FALLBACK_TAB = "Misc"

--- Most recent lines, newest last. Bounded so a long session cannot grow without limit.
M.history = {}
M.HISTORY_LIMIT = 500

--- Classify a channel name into a tab.
function M.tabFor(channel)
   local name = tostring(channel or ""):lower()
   for _, route in ipairs(M.ROUTES) do
      for _, pattern in ipairs(route.patterns) do
         if name:find(pattern) then return route.tab end
      end
   end
   return M.FALLBACK_TAB
end

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

   local message = {
      channel = payload.channel and tostring(payload.channel) or "",
      talker  = payload.talker and tostring(payload.talker) or nil,
      text    = M.render(payload.text),
      raw     = payload.text and tostring(payload.text) or "",
      tab     = M.tabFor(payload.channel),
      at      = os.time(),
   }

   M.history[#M.history + 1] = message
   if #M.history > M.HISTORY_LIMIT then
      table.remove(M.history, 1)
   end

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

--- Distinct tab names in route order, with the fallback last. ui/chat.lua builds its
--- EMCO from this, so adding a route automatically adds a tab.
function M.tabs()
   local out, seen = {}, {}
   for _, route in ipairs(M.ROUTES) do
      if not seen[route.tab] then
         seen[route.tab] = true
         out[#out + 1] = route.tab
      end
   end
   if not seen[M.FALLBACK_TAB] then out[#out + 1] = M.FALLBACK_TAB end
   return out
end

--- Recent messages, optionally filtered to one tab.
function M.recent(count, tab)
   count = count or 20
   local out = {}
   for index = #M.history, 1, -1 do
      local message = M.history[index]
      if not tab or message.tab == tab then
         table.insert(out, 1, message)
         if #out >= count then break end
      end
   end
   return out
end

event.gmcp("Comm.Channel.List",    onList,    "gmcp.comm")
event.gmcp("Comm.Channel.Text",    onText,    "gmcp.comm")
event.gmcp("Comm.Channel.Players", onPlayers, "gmcp.comm")

if gmcp and gmcp.Comm and gmcp.Comm.Channel and gmcp.Comm.Channel.List then
   onList()
end

return M

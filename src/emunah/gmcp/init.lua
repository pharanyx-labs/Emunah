--- GMCP tracking layer -- negotiation and shared plumbing.
---
--- IMPORTANT NAMING NOTE
--- ---------------------
--- `emunah.gmcp` (this table) is *our tracked state*. The bare global `gmcp` is Mudlet's
--- raw incoming feed. They are different things and must never be aliased to each other.
--- Read from the global only inside the handler for the message you are servicing;
--- everything else in the system reads our tracked state, which is normalised, typed and
--- stable between messages. The raw feed is neither -- IRE sends partial updates, so
--- gmcp.Char.Vitals.bal may simply not be present in a given message.

local M = {}

local log   = emunah.log
local event = emunah.event

-- Trace outgoing GMCP by wrapping the global once, rather than editing the ~20 call sites
-- that use it. Wrapping is guarded on _persist because a reload re-runs this file: without
-- the guard each reload would wrap the previous wrapper, and after three reloads one
-- sendGMCP would print three times. The wrapper resolves emunah.log at call time for the
-- same reason -- the module table it captured at wrap time is replaced on every reload.
emunah._persist = emunah._persist or {}
if not emunah._persist.gmcpSendWrapped and type(sendGMCP) == "function" then
   local raw = sendGMCP
   emunah._persist.rawSendGMCP = raw
   _G.sendGMCP = function(payload)
      if emunah.log and emunah.log.traceGmcp then
         emunah.log.gmcp(">>", payload)
      end
      return raw(payload)
   end
   emunah._persist.gmcpSendWrapped = true
end

--- Modules we want the game to send us, with version numbers.
---
--- Sent as Core.Supports.Add rather than Core.Supports.Set: Mudlet negotiates its own
--- list on connect (it needs Room for the mapper, among others) and a Set would replace
--- that list wholesale, silently breaking the built-in mapper. Add is additive and
--- idempotent, so re-sending after a reload is harmless.
M.MODULES = {
   "Char 1",
   "Char.Skills 1",
   "Char.Items 1",
   "Char.Afflictions 1",
   "Char.Defences 1",
   "Comm.Channel 1",
   "Room 1",
   "IRE.Rift 1",
   "IRE.Target 1",
   "IRE.Time 1",
   "IRE.Misc 1",
}

--- True once we have seen enough traffic to trust our state.
M.ready = false

--- Ask the game for the modules we need.
function M.negotiate()
   local payload = yajl.to_string(M.MODULES)
   sendGMCP("Core.Supports.Add " .. payload)
   log.debug("Requested %d GMCP modules.", #M.MODULES)
end

--- IRE drops idle connections, so a repeating Core.KeepAlive holds them open. The timer
--- id is parked in the shared registry so a reload cancels the previous one instead of
--- stacking a second heartbeat.
function M.keepAlive()
   sendGMCP("Core.KeepAlive")
end

function M.startKeepAlive(interval)
   interval = interval or 60
   emunah.timers.start("gmcp.keepalive", interval, function()
      M.keepAlive()
      M.startKeepAlive(interval)   -- re-arm; tempTimer is one-shot
   end)
end

--- Request a full refresh of everything we track. Used on login, after a reconnect, and
--- from the `emunah gmcp refresh` alias when state looks wrong.
---
--- These are all pull requests; the game answers with the corresponding List messages,
--- which our per-module handlers pick up as normal.
function M.refresh()
   sendGMCP("Char.Items.Inv")
   sendGMCP("Char.Items.Room")
   sendGMCP("Comm.Channel.Players")
   sendGMCP("IRE.Rift.Request")
   sendGMCP("IRE.Time.Request")
   if emunah.gmcp.skills and emunah.gmcp.skills.requestAll then
      emunah.gmcp.skills.requestAll()
   end
   log.debug("Requested a full GMCP state refresh.")
end

--- Everything we know, as one table. Backs `emunah gmcp` and is the fastest way to see
--- whether a tracking problem is us or the game.
function M.snapshot()
   local g = emunah.gmcp
   return {
      vitals      = g.vitals and g.vitals.snapshot(),
      status      = g.status and g.status.all(),
      afflictions = g.afflictions and g.afflictions.list(),
      defences    = g.defences and g.defences.list(),
      room        = g.room and g.room.current(),
      target      = g.ire and g.ire.target,
      rift        = g.ire and g.ire.rift,
      time        = g.ire and g.ire.time,
      inventory   = g.items and g.items.count("inv"),
      skills      = g.skills and g.skills.groupNames(),
   }
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------

event.register("sysConnectionEvent", function()
   M.ready = false
   M.negotiate()
   M.startKeepAlive(60)
end, "gmcp")

event.register("sysDisconnectionEvent", function()
   M.ready = false
   emunah.timers.stop("gmcp.keepalive")
end, "gmcp")

-- Char.Name arrives right after login and is the earliest reliable "we are in the game
-- now" signal; Char.Vitals can precede it on a reconnect but carries no identity.
event.gmcp("Char.Name", function()
   M.character = gmcp.Char.Name and gmcp.Char.Name.name
   M.fullname  = gmcp.Char.Name and gmcp.Char.Name.fullname
   M.ready = true
   log.info("Tracking %s.", M.character or "character")
   -- Small delay: the game is still pushing login spam, and skill group requests issued
   -- inside that window are frequently dropped.
   tempTimer(2, function() M.refresh() end)
   event.raise("character.identified", M.character)
end, "gmcp")

-- If we reload mid-session there is no fresh sysConnectionEvent to hang negotiation off,
-- so re-negotiate immediately when the profile is already connected.
if M.character or (gmcp and gmcp.Char and gmcp.Char.Vitals) then
   M.negotiate()
   M.startKeepAlive(60)
   M.ready = true
   -- And ask for the state again, which negotiation alone does not do. A reload re-executes
   -- every module, so inventory and rift counts start empty against a character that is
   -- still carrying everything -- and until something asks, nothing corrects it. Only
   -- Char.Name triggered a refresh before, which does not fire on a mid-session reload:
   -- after `emreload` at 12:05:52 the first stock decision was made against an empty
   -- inventory. Delayed for the same reason the login refresh is -- requests issued into
   -- the reload's own traffic get dropped.
   tempTimer(1, function() M.refresh() end)
end

return M

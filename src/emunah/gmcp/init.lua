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

-- ---------------------------------------------------------------------------
-- Outgoing requests are paced, not burst
-- ---------------------------------------------------------------------------
--
-- Observed live:
--
--     <JSON decoder error:> parse error: trailing garbage
--         'll fight until the end." ] }Char.Skills.List { "group": "av
--                                     ^
--
-- Two GMCP messages arriving as one payload. The decoder reads the first object, finds the
-- second one appended where the input should have ended, and throws away the lot -- so the
-- failure is not a cosmetic error line, it is a message silently never delivered.
--
-- We provoke it. M.refresh() sends five requests, and skills.requestAll() then sends one
-- per skill group -- around twenty for a class, all in the same frame. The answers come
-- back faster than they can be framed separately, and the message the error names is
-- Char.Skills.List: the tail of that burst.
--
-- The cost of losing one is not obvious either. A dropped Char.Skills.List leaves the skill
-- index incomplete, have.skill() answers false for an ability the character has, and every
-- cure gated on that skill is refused for a reason nothing reports.
--
-- So requests go out one at a time, spaced. Nothing here is latency-sensitive: these are
-- state reads issued on login, on reload and after death, and a full refresh finishing
-- three seconds later than it might is worth more than a refresh that loses a message.
M.REQUEST_INTERVAL = 0.15

local outbox = {}

--- Are we inside the interval after a send?
---
--- This has to be a flag rather than "is the queue empty". The queue empties on every send,
--- so a check on emptiness makes each new request look like the first one and go straight
--- out -- which is the burst this exists to prevent, reproduced exactly.
local sending = false

local function drain()
   local payload = table.remove(outbox, 1)
   if not payload then
      sending = false
      return
   end
   sendGMCP(payload)
   sending = true
   -- Armed after every send, empty queue or not: the interval is a cooldown on the wire,
   -- not a schedule for work already waiting.
   emunah.timers.start("gmcp.outbox", M.REQUEST_INTERVAL, drain)
end

--- Queue a GMCP request. Use this for anything the game answers with a payload.
---
--- Goes out immediately when nothing has been sent recently, so a single request is never
--- delayed; only a burst is spread out.
function M.request(payload)
   outbox[#outbox + 1] = tostring(payload)

   -- The cooldown lives in a timer, and timers are cancelled wholesale on reload and on
   -- disconnect (timers.stopAll). Without this check `sending` would stay true with nothing
   -- left to clear it, and every GMCP request for the rest of the session would queue and
   -- never go out -- a system that looks alive and asks the game for nothing.
   if sending and emunah.timers.ready("gmcp.outbox") then sending = false end

   if not sending then drain() end
end

--- Drop anything queued. A reconnect re-requests state from scratch, and replaying stale
--- requests into a fresh session is at best noise.
function M.clearRequests()
   outbox = {}
   sending = false
end

--- How many requests are still waiting. For `emunah gmcp` and the tests.
function M.queued()
   return #outbox
end

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
   M.request("Char.Items.Inv")
   M.request("Char.Items.Room")
   M.request("Comm.Channel.Players")
   M.request("IRE.Rift.Request")
   M.request("IRE.Time.Request")
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

-- NEGOTIATE ONCE GMCP IS UP, NOT ON CONNECT. sysConnectionEvent fires on the TCP connect
-- (Mudlet ctelnet.cpp, slot_socketConnected), before the server has offered GMCP. Mudlet
-- answers that offer later with its own Core.Supports.Set -- Char, Char.Skills, Char.Items,
-- Room, IRE.Rift, IRE.Composer, Client.Media, Char.Login, and no Comm.Channel -- and a Set
-- replaces the list. So an Add sent on connect was gone before the first prompt, and every
-- fresh login came up with no channel text. The chat window's own logs show it: Mudlet
-- restarted at 16:03:19 on 2026-09-28 in the middle of a conversation (tells at 16:03:08
-- and 16:03:17) and nothing was captured until 16:15:28; on 2026-10-03 the logins at
-- 13:49, 14:18 and 18:31 captured nothing until 19:01:39. A reload sends the Add while
-- GMCP is already up, which is why `emreload` brought chat back.
--
-- sysProtocolEnabled "GMCP" is raised straight after Mudlet sends its Set, so the Add lands
-- on top of it.
event.register("sysConnectionEvent", function()
   M.ready = false
   M.startKeepAlive(60)
end, "gmcp")

event.register("sysProtocolEnabled", function(_, protocol)
   if protocol ~= "GMCP" then return end
   M.negotiate()
end, "gmcp")

event.register("sysDisconnectionEvent", function()
   M.ready = false
   emunah.timers.stop("gmcp.keepalive")
   M.clearRequests()
end, "gmcp")

-- Char.Name arrives right after login and is the earliest reliable "we are in the game
-- now" signal; Char.Vitals can precede it on a reconnect but carries no identity.
event.gmcp("Char.Name", function()
   M.character = gmcp.Char.Name and gmcp.Char.Name.name
   M.fullname  = gmcp.Char.Name and gmcp.Char.Name.fullname
   M.ready = true
   log.info("Tracking %s.", M.character or "character")
   -- Again, now that the server is answering under Mudlet's Set. Add is idempotent, and
   -- this holds even if sysProtocolEnabled was missed or raced the Set.
   M.negotiate()
   -- OUTR DOES NOT WAIT ON THE SKILL INDEX. The two-second pause below is there because
   -- skill-group requests issued into login spam are frequently dropped. Inventory and
   -- the rift are not skill groups, and prerift cannot start until both lists have been
   -- seen. svof's canoutr is false only while webbed, bound, transfixed, roped, impaled,
   -- or both arms are crippled -- never for equilibrium. Asking now, and asking again
   -- inside the delayed refresh, means a dropped early reply is retried and a delivered
   -- one lets the pull chain start the moment sight is back (17:31:34.08) instead of
   -- when mindseye's equilibrium happens to return (17:31:37.10).
   if emunah.gmcp.items and emunah.gmcp.items.refreshInventory then
      emunah.gmcp.items.refreshInventory()
   end
   if emunah.gmcp.ire and emunah.gmcp.ire.requestRift then
      emunah.gmcp.ire.requestRift()
   end
   -- Small delay: the game is still pushing login spam, and skill group requests issued
   -- inside that window are frequently dropped.
   tempTimer(2, function() M.refresh() end)
   event.raise("character.identified", M.character)
end, "gmcp")

-- DEATH LOSES GMCP STATE, AND THERE IS NO EVENT THAT SAYS SO.
--
-- Reported from play: channel capture stops after dying and does not come back on its own.
-- Nothing in this codebase tears the handlers down -- they are ordinary Mudlet anonymous
-- handlers and survive anything short of a reload -- so whatever stops is upstream of us:
-- the messages stop arriving, which means the subscription no longer holds.
--
-- Re-negotiating is the cheap half of the fix and is safe to do unconditionally.
-- Core.Supports.Add is additive and idempotent (see M.MODULES), so at worst this is one
-- redundant packet at a moment when the character is already dead and doing nothing else.
--
-- Both edges, deliberately. If the subscription drops at the moment of death, the death
-- edge restores it; if it drops as part of being restored to life, the revival edge does.
-- Doing only one leaves whichever case it is not silently broken, and the symptom -- chat
-- that is quiet rather than obviously broken -- is one nobody notices for hours.
--
-- Delayed for the same reason the login refresh is: requests issued into the middle of the
-- game's own burst of death or resurrection traffic get dropped.
local function reestablish(reason)
   log.debug("Re-establishing GMCP after %s.", reason)
   tempTimer(2, function()
      M.negotiate()
      M.refresh()
   end)
end

event.register("emunah.character.died", function() reestablish("death") end, "gmcp")
event.register("emunah.character.revived", function() reestablish("revival") end, "gmcp")

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

--- The mount: keeps it with you, keeps you on it if asked, and says so on the prompt when it
--- is not with you.
---
--- WHAT IS KNOWN, all from one GMCP trace (the user, 2026-10-04, 10:09:37-10:10:28):
---
---   vault horse368644       "You easily vault onto the back of a heavy horse."
---                           "Balance used: 1.0s."  -- the prompt lost its `x`
---   dismount                "You step down off of a heavy horse."  -- free
---   order horse368644 follow me
---                           "Your order is obeyed."
---                           "A heavy horse obediently falls into line behind you."  -- free
---   lose horse              "You move about quickly and lose a heavy horse."
---                           "Balance used: 0.5s."
---
--- The user's character tops out at VAULT in Riding (AB RIDING), and the user named the
--- follow syntax as `order 368644 follow me`. MOUNTS costs 4.00s of equilibrium (09:47:01),
--- so nothing here ever sends it.
---
--- WHERE THE MOUNT IS comes from Char.Items for the room, by replica number, and costs
--- nothing to ask. The horse is listed in the room while ridden (10:09:48, the room walked
--- into on horseback) and while following (10:10:12), and missing once lost (10:10:28). So
--- "in the room" is "with me", whichever of the two it is doing.
---
--- WHETHER WE ARE RIDING is NOT in GMCP: vaulting produced no Char.Defences message, only
--- Char.Vitals. It is tracked from the lines above and svof's (raw-svo.defs.lua
--- defs_data.riding, and the lost_riding / "riding already on" triggers), and settled by a
--- DEFENCES listing ("You are riding (.+)." [svof defr]) -- which defkeepup already sends
--- after a reload. Until one of those says, it is unknown, and an unknown state never spends
--- a balance: the user's rule is that keeping the mount never wastes one.
---
--- NEVER WASTING A BALANCE, concretely:
---   * the follow order is the only thing sent unprompted, and it is free;
---   * the vault (1.0s of balance) goes only when we KNOW we are not riding, the mount is in
---     the room to be vaulted, nothing is waiting to be cured, and neither bashing nor PvP
---     owns the balance;
---   * it waits in the queue's balance slot behind anything more important, and is re-checked
---     at the moment it would go out;
---   * a vault that does not take is retried a bounded number of times, then left alone.

local M = {}

local log   = emunah.log
local event = emunah.event

--- Seconds to wait for the answer to an order or a vault before trying again. Well over a
--- round trip, as detect.REPLY_WINDOW is.
M.GUARD = 3.0

--- Tries without the state moving before giving up, the shape of pipes.ATTEMPTS and the
--- restocker's STOCK_ATTEMPTS: when the model is wrong, stop and say so rather than send
--- the same command forever.
M.ATTEMPTS = 3

--- Below the curing engine and the defences (defkeepup.PRIORITY) on the balance slot:
--- the mount is the least urgent thing that ever wants the balance.
M.PRIORITY = 150

--- The chyron-free warning, appended to the prompt. Plain text so tests can find it.
M.TAG = "no %s"

--- svof's riding isadvisable() refusals beyond what `needs` already covers (prone,
--- paralysis, entanglement, balance): you cannot vault with these.
M.CANNOT_VAULT = {
   "hamstring", "crippledleftarm", "crippledrightarm", "mangledleftarm", "mangledrightarm",
   "mutilatedleftarm", "mutilatedrightarm", "unknowncrippledleg", "parestolegs", "pinshot",
}

-- Carried across a reload, like pipes' state: reloading Emunah does not take you off a
-- horse. A disconnect forgets it (see the bottom of this file).
emunah._persist = emunah._persist or {}
emunah._persist.riding = emunah._persist.riding or {}
local state = emunah._persist.riding

--- true / false / nil (not known)
function M.riding() return state.riding end
--- true / false / nil (not known). Only meaningful while not riding.
function M.following() return state.following end

local orders = { at = nil, count = 0 }
local vaults = { count = 0, warned = false }

local function config(key, default)
   return emunah.config.get(key, default)
end

function M.keepupOn() return config("riding.keepup", false) == true end
function M.followOn() return config("riding.follow", true) ~= false end

--- The mount as VAULT wants it ("horse368644"), its bare replica number ("368644", which
--- is how Char.Items and ORDER name it), and the word for the prompt ("horse").
function M.mount()
   local token = tostring(config("riding.mount", "horse368644") or "")
   if token == "" or token == "(unset)" then return nil end
   local id = token:match("(%d+)$")
   local word = token:match("^(%a+)") or "mount"
   return token, id, word
end

-- ---------------------------------------------------------------------------
-- where the mount is
-- ---------------------------------------------------------------------------

--- Is the mount in the room? true / false, or nil when the room list cannot be trusted:
--- none yet, one belonging to the room we just left (items.roomFresh), or blind without
--- mindseye, when Char.Items goes quiet (items.sighted).
function M.present()
   local _, id = M.mount()
   if not id then return nil end
   local items = emunah.gmcp.items
   if not (items and items.locations and items.locations.room) then return nil end
   if not (items.roomFresh() and items.sighted()) then return nil end
   for _, item in ipairs(items.at("room")) do
      if item.id == id then return true, item end
   end
   return false
end

--- Does a name from a line ("A heavy horse", "a heavy horse") name our mount? Compared with
--- what Char.Items calls it, so a horse that is not ours in the same room is not mistaken
--- for it. With no name to compare against (the mount is not in the room), it is not ours.
local function isOurs(name)
   local here, item = M.present()
   if not (here and item and item.name) then return false end
   return tostring(name):lower() == tostring(item.name):lower()
end

-- ---------------------------------------------------------------------------
-- state changes, from lines (see the triggers at the bottom)
-- ---------------------------------------------------------------------------

function M.setRiding(riding)
   if state.riding == riding then return end
   state.riding = riding
   -- Getting on or off is the state moving: a fresh budget for both commands.
   vaults.count, vaults.warned = 0, false
   orders.count, orders.at = 0, nil
   -- Off the horse, nothing says it is following any more: ask again (free).
   if riding == false then state.following = nil end
   local queue = emunah.queue
   if riding and queue then
      local action = queue.awaiting("balance")
      if action and action.tag == "riding" then queue.confirm("balance") end
   end
   M.check()
end

function M.setFollowing(following)
   state.following = following
   if following then orders.count, orders.at = 0, nil end
end

-- ---------------------------------------------------------------------------
-- keeping it
-- ---------------------------------------------------------------------------

--- Order the mount to follow, if it is here, not ridden and not already following. Free
--- (10:09:54 -> 10:10:08: no balance line, prompt flags unchanged).
local function order()
   if not M.followOn() then return end
   if state.riding == true or state.following == true then return end
   local _, id = M.mount()
   if not id or M.present() ~= true then return end
   if orders.at and emunah.util.now() - orders.at < M.GUARD then return end
   -- Once only while we do not know whether we are riding: what an order to a horse you
   -- are sitting on answers has never been seen. Free, but three of them at login is noise.
   if orders.count >= (state.riding == nil and 1 or M.ATTEMPTS) then return end
   -- Ordinary blocks only, as WIELDED and PIPELIST: it costs no balance.
   if emunah.act.send("order " .. id .. " follow me", {}) then
      orders.at = emunah.util.now()
      orders.count = orders.count + 1
   end
end

local function cannotVault()
   local act = emunah.act
   for _, name in ipairs(M.CANNOT_VAULT) do
      if act.afflicted(name) then return name end
   end
   return nil
end

--- Why the vault cannot go now, or nil if it can. Asked when queueing it and again at the
--- moment it would go out (queue `valid`), since any of these can change while it waits.
function M.vaultHeld()
   if not M.keepupOn() then return "riding keep-up is off" end
   if state.riding ~= false then
      return state.riding and "already riding" or "not known whether riding"
   end
   if not M.mount() then return "no mount set" end
   if M.present() ~= true then return "the mount is not here" end
   local engine = emunah.curing and emunah.curing.engine
   if engine and engine.leaving then return "quitting" end
   if engine and engine.enabled and engine.curableCount() > 0 then return "curing first" end
   if emunah.bashing and emunah.bashing.enabled then return "bashing owns the balance" end
   if emunah.pvp and emunah.pvp.enabled then return "pvp owns the balance" end
   local why = cannotVault()
   if why then return why end
   return nil
end

local function vault()
   if M.vaultHeld() then return end
   local queue = emunah.queue
   if queue.pending("balance") or queue.awaiting("balance") then return end
   if vaults.count >= M.ATTEMPTS then
      if not vaults.warned then
         vaults.warned = true
         log.warn("Vaulted %d times and never saw it land -- not trying again until you "
            .. "get on or off yourself.", vaults.count)
      end
      return
   end
   local token = M.mount()
   queue.push("balance", "vault " .. token, {
      priority = M.PRIORITY,
      tag      = "riding",
      -- Spends balance (10:09:42 "Balance used: 1.0s."). Equilibrium too, until a transcript
      -- shows otherwise -- HELP's default for balance abilities, and CLAUDE.md's. Standing:
      -- svof's isadvisable refuses it while prone, and `standing` also holds it through
      -- paralysis and entanglement.
      needs    = { bal = true, eq = true, standing = true },
      valid    = function() return M.vaultHeld() == nil end,
      confirm  = M.GUARD,
      onSent   = function()
         vaults.count = vaults.count + 1
         -- Char.Vitals omits an unchanged bal, so mark it spent until the game says.
         emunah.gmcp.vitals.spend("bal")
      end,
   })
   queue.flush()
end

--- Act on what we know now. Called on every room change, on the tick, and when a line
--- changes the state.
function M.check()
   local vitals = emunah.gmcp and emunah.gmcp.vitals
   if vitals and vitals.live and not vitals.live() then return end
   local here = M.present()
   if here == false then
      -- Not in the room we are in: it is not following, and we cannot be on it.
      state.following = false
      if state.riding then state.riding = false end
      orders.count, orders.at = 0, nil
      return
   end
   if here ~= true then return end
   vault()
   order()
end

-- ---------------------------------------------------------------------------
-- the prompt
-- ---------------------------------------------------------------------------

--- The warning for the end of the prompt, or nil. Only when the room list says, for
--- certain, that the mount is not here: an unknown says nothing rather than something
--- stale.
function M.warning()
   if not M.followOn() then return nil end
   local _, _, word = M.mount()
   if not word then return nil end
   if M.present() == false then return string.format(M.TAG, word) end
   return nil
end

local function onPrompt()
   local text = M.warning()
   if not text then return end
   local theme = emunah.ui and emunah.ui.theme
   if theme and type(decho) == "function" then
      decho(" " .. theme.dc("textDim") .. "(" .. theme.dc("warning") .. text
         .. theme.dc("textDim") .. ")")
   end
end

-- ---------------------------------------------------------------------------
-- switching
-- ---------------------------------------------------------------------------

function M.start()
   emunah.config.set("riding.keepup", true)
   vaults.count, vaults.warned = 0, false
   log.info("Riding keep-up <ansi_light_green>on<ansi_yellow>.")
   M.check()
end

function M.stop()
   emunah.config.set("riding.keepup", false)
   local queue = emunah.queue
   local pending = queue and queue.pending("balance")
   if pending and pending.tag == "riding" then queue.clear("balance") end
   log.info("Riding keep-up <ansi_light_red>off<ansi_yellow>.")
end

function M.toggle()
   if M.keepupOn() then M.stop() else M.start() end
   return M.keepupOn()
end

-- ---------------------------------------------------------------------------
-- triggers
-- ---------------------------------------------------------------------------

do
   for _, id in ipairs(emunah._persist.ridingTriggers or {}) do killTrigger(id) end
   emunah._persist.ridingTriggers = {}

   local function keep(id)
      if id then table.insert(emunah._persist.ridingTriggers, id) end
   end

   local detect = emunah.curing.detect

   --- A line that answers a command is believed only after one (detect layer 5). VAULT or
   --- MOUNT: the user vaults, but svof's lines answer either, and Lua patterns have no
   --- alternation for detect.reply() to take.
   local function mountingReply(what, fn)
      local viaVault = detect.reply("^vault", what, fn)
      return function(...)
         local outgoing = emunah.outgoing
         if outgoing and outgoing.sentRecently("^mount", detect.REPLY_WINDOW) then
            return fn(...)
         end
         return viaVault(...)
      end
   end

   -- ON. Verbatim at 10:09:42; svof's onr has both.
   keep(tempRegexTrigger([[^You easily vault onto the back of (.+)\.$]],
      mountingReply("a vault landed", function() M.setRiding(true) end)))
   keep(tempRegexTrigger([[^You climb up on (.+)\.$]],
      mountingReply("a mount landed", function() M.setRiding(true) end)))

   -- ALREADY ON: svof's "riding already on" trigger, answering a VAULT/MOUNT.
   for _, line in ipairs({
      [[^You must dismount before you can mount anything else\.$]],
      [[^You must dismount from what you are currently riding before you can mount anything else\.$]],
   }) do
      keep(tempRegexTrigger(line,
         mountingReply("already riding", function() M.setRiding(true) end)))
   end
   -- The same trigger's third line answers anything, not only a mount.
   keep(tempRegexTrigger([[^You cannot do that while mounted\.$]],
      detect.reply(nil, "mounted", function() M.setRiding(true) end)))

   -- OFF, by choice. Verbatim at 10:09:54.
   keep(tempRegexTrigger([[^You step down off of (.+)\.$]],
      detect.reply("^dismount", "a dismount", function() M.setRiding(false) end)))
   for _, line in ipairs({
      [[^You are not currently riding anything\.$]],
      [[^You are not currently riding that\.$]],
   }) do
      keep(tempRegexTrigger(line,
         detect.reply(nil, "not riding", function() M.setRiding(false) end)))
   end

   -- OFF, not by choice: svof's defs_data.riding off/offr and its lost_riding triggers. No
   -- command to wait for -- they are attacks -- so believed as they come, as svof does. A
   -- faked one costs at most a vault the game refuses with "You must dismount...", which
   -- puts the state right.
   for _, line in ipairs({
      [[^You clamber off of your mount\.$]],
      [[^You lose purchase on .+\.$]],
      [[^You are thrown from the room by the sheer force of the fiery blast\.$]],
      [[^You're drawn screaming into its hellish maw\.$]],
      [[^The ring of shining metal carries you up into the skies\.$]],
      [[^\w+ gives a yell and slaps .+, who powerfully kicks you with its hind legs and sends you sailing \w+ with arms flailing\.$]],
      [[^You are sent tumbling off your \w+ and your weapon goes flying in the air\.$]],
      [[^Your mounts collide with great force and your weapons viciously skewer each other, causing you both to fall off your mounts as your weapons fly into the air\.$]],
      [[^A falcon flies up to your mount, startling it to buck and jump, and you are thrown to the side like a rag doll\.$]],
      [[^You are thrown to the ground!$]],
      [[^A series of shockwaves jolts through you, toppling you off your mount onto your feet\.$]],
      [[^\w+ darts to your mount's flank in a rapid dash\. Grabbing your ankle and executing a graceful twist, s?he sends you tumbling from the saddle\.$]],
      [[^\w+ deftly hooks .+ behind your foot and sends you tumbling off .+ before driving the point of the weapon into your (?:right|left) leg\.$]],
   }) do
      keep(tempRegexTrigger(line, function() M.setRiding(false) end))
   end

   -- FOLLOWING. Verbatim at 10:10:08 and 10:10:27.
   keep(tempRegexTrigger([[^(.+) obediently falls into line behind you\.$]],
      detect.reply("^order", "a follow order obeyed", function()
         if isOurs(matches[2]) then M.setFollowing(true) end
      end)))
   keep(tempRegexTrigger([[^You move about quickly and lose (.+)\.$]],
      detect.reply("^lose", "a follower lost", function()
         if isOurs(matches[2]) then M.setFollowing(false) end
      end)))

   -- DEFENCES settles it either way: "You are riding X." among the lines, or not [svof
   -- defr]. patterns.lua reads the same listing for the defences themselves.
   local listing = nil
   keep(tempRegexTrigger([[^You have the following defences:]], function()
      listing = { riding = false }
   end))
   keep(tempRegexTrigger([[^You are riding (.+)\.$]], function()
      if listing then listing.riding = true end
   end))
   keep(tempRegexTrigger([[^You are protected by ]], function()
      if not listing then return end
      local riding = listing.riding
      listing = nil
      M.setRiding(riding)
   end))
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

local function onRoom(_, location)
   if location == "room" then M.check() end
end

event.register("emunah.items.list",    onRoom, "riding")
event.register("emunah.items.added",   onRoom, "riding")
event.register("emunah.items.removed", onRoom, "riding")
event.register("emunah.tick", function() M.check() end, "riding")
event.register("emunah.prompt", onPrompt, "riding")

-- A session boundary is what can change all of this.
event.register("sysDisconnectionEvent", function()
   state.riding, state.following = nil, nil
   orders.count, orders.at = 0, nil
   vaults.count, vaults.warned = 0, false
end, "riding")

return M

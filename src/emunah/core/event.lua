--- Event registration with reload-safe teardown.
---
--- Why this module exists
--- ----------------------
--- The obvious thing is to call registerAnonymousEventHandler at module scope:
---
---     registerAnonymousEventHandler("gmcp.Room.Players", "GMCP.UpdatePlayers")
---
--- Mudlet keeps that handler alive for the life of the profile. Re-running the loader
--- re-registers it without removing the old one, so after three reloads a single
--- gmcp.Room.Players message invokes the handler three times. In a curing system that
--- means three cures queued for one affliction, and it is invisible until you are
--- already in combat wondering why you ate three bloodroot.
---
--- Every handler in Emunah is registered through this module. The id registry lives on
--- `emunah._handlers`, which the loader carries across reloads specifically so that the
--- *new* generation can kill the *old* one before registering itself.

local M = {}

local function registry()
   emunah._handlers = emunah._handlers or {}
   return emunah._handlers
end

--- Register a handler for a Mudlet event.
--- @param name string event name, e.g. "gmcp.Char.Vitals"
--- @param fn function|string handler function, or the name of a global function
--- @param owner string|nil grouping key so a single module can drop all of its handlers
--- @return number|nil handler id
function M.register(name, fn, owner)
   local id = registerAnonymousEventHandler(name, fn)
   if not id then
      emunah.log.error("Failed to register a handler for %s", name)
      return nil
   end
   local reg = registry()
   owner = owner or "anonymous"
   reg[owner] = reg[owner] or {}
   table.insert(reg[owner], { id = id, name = name })
   return id
end

--- Register handlers for several events sharing one callback.
--- @param names table array of event names
function M.registerAll(names, fn, owner)
   local ids = {}
   for _, name in ipairs(names or {}) do
      ids[#ids + 1] = M.register(name, fn, owner)
   end
   return ids
end

--- Register a handler for a GMCP message, e.g. event.gmcp("Char.Vitals", fn, "vitals")
--- listens on "gmcp.Char.Vitals".
---
--- Every registration is wrapped so `emunah debug gmcp` can show what actually arrived,
--- with the payload as the handler sees it. Tracing here rather than at each handler means
--- a message is reported even when its handler bails out early on a malformed payload --
--- "it arrived and we ignored it" and "it never arrived" are otherwise indistinguishable
--- from the outside, and that distinction is usually the whole question.
function M.gmcp(message, fn, owner)
   return M.register("gmcp." .. message, function(...)
      if emunah.log.traceGmcp then
         -- Resolve the live table by walking the message path: "Char.Vitals" -> gmcp.Char.Vitals
         local node = gmcp
         for part in tostring(message):gmatch("[^.]+") do
            if type(node) ~= "table" then node = nil break end
            node = node[part]
         end
         emunah.log.gmcp("<<", message, node)
      end
      return fn(...)
   end, owner)
end

--- Drop every handler belonging to one owner. Called by modules that rebuild their own
--- registrations without a full system reload.
--- @return number handlers removed
function M.kill(owner)
   local reg = registry()
   local handlers = reg[owner]
   if not handlers then return 0 end
   local n = 0
   for _, handler in ipairs(handlers) do
      if killAnonymousEventHandler(handler.id) then n = n + 1 end
   end
   reg[owner] = nil
   return n
end

--- Drop every handler the system owns. Called by the loader immediately before a reload
--- rebuilds the namespace.
--- @return number handlers removed
function M.killAll()
   local reg = registry()
   local n = 0
   for owner in pairs(reg) do
      n = n + M.kill(owner)
   end
   emunah._handlers = {}
   return n
end

--- Currently registered handlers, grouped by owner. For `emunah debug handlers`.
function M.list()
   local out = {}
   for owner, handlers in pairs(registry()) do
      local names = {}
      for _, handler in ipairs(handlers) do names[#names + 1] = handler.name end
      table.sort(names)
      out[owner] = names
   end
   return out
end

--- Raise a namespaced system event. Keeps the "emunah." prefix in one place so external
--- scripts have a stable surface to hook.
function M.raise(name, ...)
   raiseEvent("emunah." .. name, ...)
end

return M

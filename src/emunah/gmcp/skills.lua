--- Char.Skills -- what your character actually knows.
---
--- Messages:
---   Char.Skills.Groups  array of { name, rank }        -- your skillsets and their ranks
---   Char.Skills.List    { group, list = {...}, descs } -- abilities within one group
---   Char.Skills.Info    { group, skill, info }         -- one ability's help text
---
--- The Groups message arrives unprompted on login, but List does not: you have to ask
--- for each group with Char.Skills.Get. Doing that once at login builds a flat index of
--- every ability the character has, which is what makes emunah.have.skill() possible --
--- and that in turn is what stops the curing engine from queueing a cure the character
--- cannot actually perform.
---
--- Names in the flat index are lower-cased and stripped of the leading "* " marker that
--- Achaea uses for abilities you have not yet learned the lesson for.

local M = {}

local util  = emunah.util
local event = emunah.event
local log   = emunah.log

--- group name (lower) -> { name, rank, skills = { ... } }
M.groups = {}

--- skill name (lower) -> group name (lower). The flat index.
M.index = {}

--- Have we finished pulling every group?
M.complete = false

local pending = {}   -- group names we have asked for but not yet received

local function onGroups()
   local groups = gmcp.Char.Skills.Groups
   if type(groups) ~= "table" then return end

   M.groups   = {}
   M.index    = {}
   M.complete = false
   pending    = {}

   for _, group in ipairs(groups) do
      if group.name then
         local key = tostring(group.name):lower()
         M.groups[key] = {
            name   = tostring(group.name),
            rank   = group.rank and tostring(group.rank) or "",
            skills = {},
         }
      end
   end

   event.raise("skills.groups", util.keys(M.groups))
end

local function onList()
   local payload = gmcp.Char.Skills.List
   if type(payload) ~= "table" or not payload.group then return end

   local key = tostring(payload.group):lower()
   local group = M.groups[key]
   if not group then
      group = { name = tostring(payload.group), rank = "", skills = {} }
      M.groups[key] = group
   end

   group.skills = {}
   for position, entry in ipairs(payload.list or {}) do
      -- Achaea prefixes not-yet-available abilities with "* ".
      local skill = tostring(entry):gsub("^%*%s*", "")
      skill = util.trim(skill):lower()
      if skill ~= "" then
         group.skills[#group.skills + 1] = skill
         M.index[skill] = key
         if payload.descs and payload.descs[position] then
            group.descs = group.descs or {}
            group.descs[skill] = tostring(payload.descs[position])
         end
      end
   end

   pending[key] = nil
   if not next(pending) then
      M.complete = true
      log.debug("Skill index complete: %d abilities across %d groups.",
         util.count(M.index), util.count(M.groups))
      event.raise("skills.complete", util.count(M.index))
   end

   event.raise("skills.list", key, #group.skills)
end

--- Ask for one group's ability list.
function M.request(group)
   if not group then return false end
   local key = tostring(group):lower()
   pending[key] = true
   -- The payload is a JSON object: Char.Skills.Get {"group": "survival"}
   -- Paced: requestAll() below asks for every group at once, and the answers coalesce
   -- into a single unparseable payload if they go out in one frame. See gmcp/init.lua.
   emunah.gmcp.request("Char.Skills.Get " .. yajl.to_string({ group = tostring(group) }))
   return true
end

--- Ask for every group we know about. Called from gmcp/init.lua's refresh.
function M.requestAll()
   if not next(M.groups) then
      -- Groups have not arrived yet; ask for them and let onGroups re-drive this.
      emunah.gmcp.request("Char.Skills.Get " .. yajl.to_string({}))
      return false
   end
   M.complete = false
   for key, group in pairs(M.groups) do
      M.request(group.name or key)
   end
   return true
end

--- Ask for one ability's description.
function M.info(group, skill)
   emunah.gmcp.request("Char.Skills.Get "
      .. yajl.to_string({ group = tostring(group), name = tostring(skill) }))
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

--- Does the character know this ability? The workhorse behind emunah.have.skill().
--- A single hash lookup rather than a walk over every skillset, which matters when the
--- curing engine asks per tick.
function M.has(skill)
   if not skill then return false end
   return M.index[tostring(skill):lower()] ~= nil
end

--- Which skillset an ability belongs to, or nil.
function M.groupOf(skill)
   if not skill then return nil end
   return M.index[tostring(skill):lower()]
end

--- Rank string for a skillset, e.g. "Transcendent".
function M.rank(group)
   local entry = M.groups[tostring(group or ""):lower()]
   return entry and entry.rank or nil
end

--- Do we have a skillset at all? Cheap class inference: a character with "Kaido" is a
--- Monk, one with "Devotion" is a Priest.
function M.hasGroup(group)
   return M.groups[tostring(group or ""):lower()] ~= nil
end

function M.groupNames()
   return util.keys(M.groups)
end

--- Every known ability, sorted.
function M.all()
   return util.keys(M.index)
end

-- ---------------------------------------------------------------------------
-- ability text, and the dump
-- ---------------------------------------------------------------------------
--
-- `emset skills dump` (the user, 2026-10-15: "you can get my current abilities from gmcp")
-- asks for every ability's AB text, Char.Skills.Info, and writes it with the index to
-- emunah-abilities.txt in the profile -- readable without pasting AB output, and worth
-- re-running when abilities change ("they may change randomly, albeit rarely"). The
-- requests are paced by gmcp/init.lua's outbox, one every REQUEST_INTERVAL.

--- "group/skill" (lower) -> the ability's help text, as Char.Skills.Info gave it.
M.infos = {}

M.DUMP_FILE = "emunah-abilities.txt"

local dumping = nil   -- { order, waiting, wanted, got, timer } while a dump is under way

local function keyOf(group, skill)
   return tostring(group or ""):lower() .. "/" .. tostring(skill or ""):lower()
end

local function writeDump()
   local job = dumping
   if not job then return end
   dumping = nil
   if job.timer then killTimer(job.timer) end

   local path = getMudletHomeDir() .. "/" .. M.DUMP_FILE
   local file, err = io.open(path, "w")
   if not file then
      log.error("Could not write %s: %s", path, tostring(err))
      return
   end
   file:write(("Emunah ability dump, %s. %d of %d abilities answered.\n\n")
      :format(os.date("%Y-%m-%d %H:%M"), job.got, job.wanted))
   for _, key in ipairs(job.order) do
      local group = M.groups[key]
      file:write(("==== %s (%s) ====\n"):format(group.name, group.rank))
      for _, skill in ipairs(group.skills) do
         file:write(("\n---- %s\n%s\n"):format(skill,
            M.infos[keyOf(key, skill)] or "(no answer)"))
      end
      file:write("\n")
   end
   file:close()
   log.info("Wrote %d of %d abilities to %s.", job.got, job.wanted, path)
   event.raise("skills.dumped", path, job.got, job.wanted)
end

local function onInfo()
   local payload = gmcp.Char.Skills.Info
   if type(payload) ~= "table" or not payload.skill then return end
   local key = keyOf(payload.group, payload.skill)
   M.infos[key] = tostring(payload.info or "")
   if not (dumping and dumping.waiting[key]) then return end
   dumping.waiting[key] = nil
   dumping.got = dumping.got + 1
   if dumping.got >= dumping.wanted then writeDump() end
end

--- Skillsets asked for whose ability list has not arrived, sorted.
function M.pendingGroups()
   local out = util.keys(pending)
   table.sort(out)
   return out
end

--- Ask for the text of every ability in `groups` (all when empty), then write the dump.
--- Written when every answer is in, or after a generous timeout with whatever arrived.
---
--- It does not wait for the whole index: a skillset whose list never came (2026-10-15
--- 19:10:16, "The skill list is not in yet" with nothing to say which) would block it
--- forever. It dumps what has arrived, asks again for what has not, and names it.
function M.dump(groups)
   local missing = M.pendingGroups()
   if #missing > 0 then
      log.warn("Still waiting on the ability list for: %s. Asked again; dumping the rest.",
         table.concat(missing, ", "))
      for _, key in ipairs(missing) do M.request((M.groups[key] or {}).name or key) end
   end
   local order = {}
   if groups and #groups > 0 then
      for _, name in ipairs(groups) do
         local key = tostring(name):lower()
         if M.groups[key] then order[#order + 1] = key
         else log.warn("No skillset called %s.", tostring(name)) end
      end
   else
      for key, group in pairs(M.groups) do
         if #group.skills > 0 then order[#order + 1] = key end
      end
   end
   table.sort(order)
   if #order == 0 then
      log.warn("No ability lists have arrived from the game yet.")
      return false
   end

   if dumping and dumping.timer then killTimer(dumping.timer) end
   local job = { order = order, waiting = {}, wanted = 0, got = 0 }
   dumping = job
   for _, key in ipairs(order) do
      local group = M.groups[key]
      for _, skill in ipairs(group.skills) do
         job.waiting[keyOf(key, skill)] = true
         job.wanted = job.wanted + 1
         M.info(group.name, skill)
      end
   end
   if job.wanted == 0 then writeDump() return true end

   local seconds = job.wanted * (emunah.gmcp.REQUEST_INTERVAL or 0.15) + 10
   job.timer = tempTimer(seconds, writeDump)
   log.info("Asking the game for %d abilities' text -- about %ds.", job.wanted,
      math.ceil(seconds - 10))
   return true
end

event.gmcp("Char.Skills.Info",   onInfo,   "gmcp.skills")
event.gmcp("Char.Skills.Groups", onGroups, "gmcp.skills")
event.gmcp("Char.Skills.List",   onList,   "gmcp.skills")

-- Once the group list lands, pull each group's abilities automatically.
event.register("emunah.skills.groups", function()
   M.requestAll()
end, "gmcp.skills")

event.register("sysDisconnectionEvent", function()
   M.complete = false
end, "gmcp.skills")

if gmcp and gmcp.Char and gmcp.Char.Skills and gmcp.Char.Skills.Groups then
   onGroups()
end

return M

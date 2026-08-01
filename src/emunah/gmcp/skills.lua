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
   sendGMCP("Char.Skills.Get " .. yajl.to_string({ group = tostring(group) }))
   return true
end

--- Ask for every group we know about. Called from gmcp/init.lua's refresh.
function M.requestAll()
   if not next(M.groups) then
      -- Groups have not arrived yet; ask for them and let onGroups re-drive this.
      sendGMCP("Char.Skills.Get " .. yajl.to_string({}))
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
   sendGMCP("Char.Skills.Get " .. yajl.to_string({ group = tostring(group), name = tostring(skill) }))
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

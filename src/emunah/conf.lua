--- conf/*.conf: settings kept in plain files in the checkout, alongside `emset`.
---
--- Every file is `key = value` lines; `#` starts a comment. They ship with every line
--- commented out, so shipping them changes nothing: uncomment a line to pin it. Read on
--- every load and every `emreload`.
---
---   healing.conf, curing.conf, defences.conf, ...   any documented setting (help.lua), by
---       its dotted name: `curing.healthThreshold = 75`. A pinned setting wins over the
---       saved one (config.overlay), and `emset` on it warns rather than appearing to work.
---       Always in force.
---
---   priorities.conf   fixed cure ranks: `<affliction>.<balance> = <rank>`, lower sooner.
---   situations.conf   the situational rules (curing/situations.lua): `<rule> = off`, or
---       `<rule>.<affliction>.<balance> = <rank>` to change or add a rank a rule gives.
---       These two are in force only while `emset ownprios` is on -- the one switch, so
---       the user's own ranks can be tried and dropped without editing anything.
---
--- WHY A FIXED LIST OF FILES rather than whatever is in the folder: Mudlet has
--- LuaFileSystem but the test mock does not, and a stray editor backup (`healing.conf~`)
--- read as configuration is exactly the kind of surprise a settings file must not spring.

local M = {}

local log    = emunah.log
local config = emunah.config

--- The files read, in order. A key set in two files: the later one wins, and both are
--- reported.
M.FILES = {
   "system", "interface", "healing", "curing", "defences", "hunting", "pvp", "loot",
   "antitheft", "pipes", "riding", "people", "priorities", "situations",
}

--- The files `emset ownprios` switches.
M.PRIOS = { priorities = true, situations = true }

--- Settings no file may pin: the switch for the files themselves, and the shapes that are
--- not one value (maps and lists, which have their own commands).
M.UNPINNABLE = {
   ["curing.ownprios"] = "it is the switch for priorities.conf and situations.conf",
   ["priorities"] = "use priorities.conf",
   ["schema"] = "it is the config file's own version",
}

--- What the last apply() found: key -> "file.conf:line", and the problems it reported.
M.sources, M.problems = {}, {}
M.summary = { settings = 0, priorities = 0, situations = 0, ownprios = false }

function M.dir()
   return (emunah._root or ".") .. "/conf"
end

--- "75" -> 75, "on"/"true" -> true, "off"/"false" -> false, quotes stripped.
function M.coerce(raw)
   raw = tostring(raw)
   if raw == "on" or raw == "true" then return true end
   if raw == "off" or raw == "false" then return false end
   local number = tonumber(raw)
   if number then return number end
   return raw:match('^"(.*)"$') or raw:match("^'(.*)'$") or raw
end

--- One file's text -> { { key, value, line } }, and a problem for each line not understood.
function M.parse(text, file, problems)
   local entries = {}
   local number = 0
   for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
      number = number + 1
      local body = line:gsub("%s*#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
      if body ~= "" then
         local key, value = body:match("^([%w%._%-<>]+)%s*=%s*(.-)$")
         if key and value ~= "" then
            entries[#entries + 1] = { key = key, value = M.coerce(value), line = number }
         elseif problems then
            problems[#problems + 1] = ("%s.conf:%d: not `key = value`: %s"):format(file, number,
               body)
         end
      end
   end
   return entries
end

local function read(file)
   local handle = io.open(M.dir() .. "/" .. file .. ".conf", "r")
   if not handle then return nil end
   local text = handle:read("*a")
   handle:close()
   return text
end

local TYPES = { number = "number", boolean = "boolean", string = "string" }

--- Read the files and put them in force.
--- @param texts table|nil file -> text, in place of reading the disk (the tests)
--- @return table M.summary
function M.apply(texts)
   local help       = emunah.help
   local afflist    = emunah.curing.afflist
   local situations = emunah.curing.situations
   local problems, sources, overlay = {}, {}, {}
   local priorities, disabled, ranks = {}, {}, {}
   local counts = { settings = 0, priorities = 0, situations = 0 }

   local function note(fmt, ...) problems[#problems + 1] = fmt:format(...) end

   for _, file in ipairs(M.FILES) do
      local text
      if texts then text = texts[file] else text = read(file) end
      for _, entry in ipairs(text and M.parse(text, file, problems) or {}) do
         local at = ("%s.conf:%d"):format(file, entry.line)
         local key, value = entry.key, entry.value

         if file == "priorities" then
            local affliction, vector = key:lower():match("^([%w_]+)%.([%w_]+)$")
            if not affliction then
               note("%s: expected <affliction>.<balance> = <rank>, got %s", at, key)
            elseif type(value) ~= "number" then
               note("%s: %s needs a number, not %s", at, key, tostring(value))
            elseif not afflist.known(affliction) then
               note("%s: no affliction called %s", at, affliction)
            elseif not afflist.curesVia(affliction, vector)[1] then
               note("%s: %s is not cured by %s", at, affliction, vector)
            else
               priorities[affliction] = priorities[affliction] or {}
               priorities[affliction][vector] = value
               counts.priorities = counts.priorities + 1
               sources["priorities." .. key:lower()] = at
            end

         elseif file == "situations" then
            local rule, rest = key:lower():match("^([%w%-]+)%.?(.*)$")
            if not (rule and situations.find(rule)) then
               note("%s: no situational rule called %s", at, tostring(rule or key))
            elseif rest == "" then
               if type(value) ~= "boolean" then
                  note("%s: %s takes on or off", at, rule)
               elseif value == false then
                  disabled[rule] = true
                  counts.situations = counts.situations + 1
                  sources["situations." .. rule] = at
               end
            else
               local affliction, vector = rest:match("^([%w_]+)%.([%w_]+)$")
               if not affliction or type(value) ~= "number" then
                  note("%s: expected %s.<affliction>.<balance> = <rank>", at, rule)
               elseif not afflist.known(affliction) then
                  note("%s: no affliction called %s", at, affliction)
               elseif not afflist.curesVia(affliction, vector)[1] then
                  note("%s: %s is not cured by %s", at, affliction, vector)
               else
                  ranks[rule] = ranks[rule] or {}
                  ranks[rule][affliction] = ranks[rule][affliction] or {}
                  ranks[rule][affliction][vector] = value
                  counts.situations = counts.situations + 1
                  sources["situations." .. key:lower()] = at
               end
            end

         else
            local spec = help and help.setting(key)
            if M.UNPINNABLE[key] then
               note("%s: %s cannot be set in a file -- %s", at, key, M.UNPINNABLE[key])
            elseif not spec then
               note("%s: no setting called %s (emhelp lists them)", at, key)
            elseif TYPES[spec.type] and type(value) ~= spec.type then
               note("%s: %s is a %s, not %s", at, key, spec.type, tostring(value))
            else
               if sources[spec.key] then
                  note("%s: %s is also set at %s; this one wins", at, spec.key, sources[spec.key])
               end
               overlay[spec.key] = value
               sources[spec.key] = at
               counts.settings = counts.settings + 1
            end
         end
      end
   end

   -- THE SWITCH. Read from the SAVED setting, never from a file (M.UNPINNABLE).
   local ownprios = config.stored("curing.ownprios") == true
   if ownprios then
      if next(priorities) ~= nil then
         -- On top of `emset prio`'s own: a copy, so `emset prio` never saves the file's
         -- ranks into the profile as if they had been typed.
         local merged = {}
         for name, byVector in pairs(config.stored("priorities") or {}) do
            merged[name] = {}
            for vector, rank in pairs(byVector) do merged[name][vector] = rank end
         end
         for name, byVector in pairs(priorities) do
            -- Under every name the affliction is tracked by (weariness is weakness).
            local names = { name }
            local target = afflist.ALIASES[name]
            if target then names[2] = target end
            for alias, canonical in pairs(afflist.ALIASES) do
               if canonical == name then names[#names + 1] = alias end
            end
            for _, key in ipairs(names) do
               merged[key] = merged[key] or {}
               for vector, rank in pairs(byVector) do merged[key][vector] = rank end
            end
         end
         overlay["priorities"] = merged
      end
      situations.configure(disabled, ranks)
   else
      situations.configure()
   end

   config.overlay = overlay
   config.invalidate()
   M.sources, M.problems = sources, problems
   M.summary = { settings = counts.settings, priorities = counts.priorities,
                 situations = counts.situations, ownprios = ownprios }
   for _, problem in ipairs(problems) do log.warn("conf/%s", problem) end
   return M.summary
end

--- Where a setting is pinned, as "file.conf:line", or nil.
function M.source(key)
   return M.sources[key]
end

--- `emset ownprios on|off`: the one switch for priorities.conf and situations.conf.
function M.setOwnPrios(on)
   config.set("curing.ownprios", on == true)
   config.save()
   return M.apply()
end

M.apply()

return M

--- Emunah -- an Achaea system for Mudlet.
--- Bootstrap loader.
---
--- The loading model: extend package.path to point at this checkout, drop the
--- package.loaded entries for our modules, require them in order, then restore
--- package.path so we do not leak our search paths into other packages.
---
--- Four rules that are easy to get wrong, and cost a debugging session each when you do:
---
---   1. Only assign a module on success. `local ok, result = pcall(require, name)`
---      followed by an unconditional assignment installs a module that failed to compile
---      *as its own error string*, and every later call into it fails with a confusing
---      "attempt to index a string value" a long way from the actual fault.
---
---   2. package.path is restored on the failure path too, not just the happy path.
---
---   3. Module names are namespaced ("emunah.core.util", not "util"), so we cannot
---      collide with another package's module of the same name in package.loaded.
---
---   4. Event handlers and timers are tracked on a persistent registry that survives
---      reload, and are torn down before re-registering. Calling
---      registerAnonymousEventHandler at module scope means hot-reloading leaves the
---      previous generation of handlers alive -- after N reloads every GMCP message is
---      processed N times. See emunah/core/event.lua.

local VERSION = "0.1.0"

--- How many times this file itself has been executed.
---
--- Not vanity: it is the difference between "the modules were re-required" and "the
--- loader was re-read". emunahReload() below re-executes this file precisely so a change
--- to MANIFEST takes effect, and this counter is how that is asserted in the tests.
_G.EMUNAH_CHUNK_RUNS = (rawget(_G, "EMUNAH_CHUNK_RUNS") or 0) + 1

-- Preserve the pieces of the namespace that must outlive a reload. Everything else is
-- rebuilt from scratch so stale module tables cannot linger.
local CARRIED = {
   _handlers = true,  -- anonymous event handler ids, keyed by owner
   _timers   = true,  -- named timer ids
   _aliases  = true,  -- loader-owned alias ids
   _persist  = true,  -- scratch space modules use to survive reload (settings, UI handles)
}
-- Note: module tables themselves are deliberately NOT carried. assign() below replaces
-- every manifest entry, so anything a module needs to survive a reload has to live on
-- _persist rather than on the module table. core/config.lua is the worked example.

--- Modules, in load order. Order is explicit rather than alphabetical because later
--- modules index earlier ones at load time (ui/* reads theme, curing/* reads afflist).
--- `path` is the require name relative to src/; `as` is the dotted key under `emunah`.
local MANIFEST = {
   -- core: no dependencies beyond Mudlet itself
   { path = "emunah.core.util",          as = "util"          },
   { path = "emunah.core.log",           as = "log"           },
   { path = "emunah.core.event",         as = "event"         },
   { path = "emunah.core.config",        as = "config"        },
   { path = "emunah.core.timers",        as = "timers"        },
   { path = "emunah.core.queue",         as = "queue"         },
   { path = "emunah.core.act",           as = "act"           },
   -- what was recently sent, typed or automated: anti-illusion, antitheft and QUIT ask it
   { path = "emunah.core.outgoing",      as = "outgoing"      },

   -- gmcp: the tracking layer. NOTE the namespace `emunah.gmcp` is *ours*; the bare
   -- global `gmcp` is Mudlet's raw feed. Never alias one to the other.
   { path = "emunah.gmcp.init",          as = "gmcp"          },
   { path = "emunah.gmcp.vitals",        as = "gmcp.vitals"   },
   { path = "emunah.gmcp.status",        as = "gmcp.status"   },
   { path = "emunah.gmcp.afflictions",   as = "gmcp.afflictions" },
   { path = "emunah.gmcp.defences",      as = "gmcp.defences" },
   { path = "emunah.gmcp.items",         as = "gmcp.items"    },
   { path = "emunah.gmcp.skills",        as = "gmcp.skills"   },
   { path = "emunah.gmcp.room",          as = "gmcp.room"     },
   { path = "emunah.gmcp.comm",          as = "gmcp.comm"     },
   { path = "emunah.gmcp.ire",           as = "gmcp.ire"      },

   -- curing data: pure tables, no dependencies. Loaded ahead of the capability layer
   -- because have.cure() resolves cure names through them.
   { path = "emunah.curing.curelist",    as = "curing.curelist" },
   { path = "emunah.curing.afflist",     as = "curing.afflist"  },

   -- capability gate: reads gmcp state and the cure data, so must follow both
   { path = "emunah.have.capabilities",  as = "have"          },

   -- what raises each defence, and which afflictions are somebody's defence held on
   -- purpose. Pure data over afflist and have. Ahead of the engine, which asks it whether
   -- an affliction is one the character wants.
   { path = "emunah.curing.deflist",     as = "curing.deflist" },

   -- ui
   { path = "emunah.ui.theme",           as = "ui.theme"      },
   -- hides lines after their packet is done; pipes and elist both use it
   { path = "emunah.ui.gag",             as = "ui.gag"        },
   { path = "emunah.ui.echo",            as = "ui.echo"       },
   { path = "emunah.ui.alert",           as = "ui.alert"      },
   { path = "emunah.ui.layout",          as = "ui.layout"     },
   { path = "emunah.ui.chyron",          as = "ui.chyron"     },
   { path = "emunah.ui.vitals",          as = "ui.vitals"     },
   { path = "emunah.ui.affpanel",        as = "ui.affpanel"   },
   { path = "emunah.ui.chat",            as = "ui.chat"       },
   { path = "emunah.ui.roompanel",       as = "ui.roompanel"  },
   { path = "emunah.ui.map",             as = "ui.map"        },

   -- curing behaviour (the data half is loaded above)
   { path = "emunah.curing.engine",      as = "curing.engine" },
   { path = "emunah.curing.detect.init", as = "curing.detect" },
   { path = "emunah.curing.detect.opponent", as = "curing.detect.opponent" },
   -- reads DIAG's answer; needs afflist to normalise names and the engine to reconcile
   { path = "emunah.curing.detect.diag",     as = "curing.diag" },
   { path = "emunah.curing.defkeepup",   as = "curing.defkeepup" },

   -- area walker: needs gmcp.room for position and config for its avoid list
   { path = "emunah.walker",             as = "walker"        },

   -- denizen tracking + per-area kill list; needs gmcp.items and gmcp.room
   { path = "emunah.denizens",           as = "denizens"      },

   -- linkifies the `ih` command's output; needs denizens for wanted-state toggling
   { path = "emunah.ih",                 as = "ih"            },

   -- gold pickup; reads gmcp.items
   { path = "emunah.loot",               as = "loot"          },

   -- shop listings and buying by replica number; reads loot.pack() for where gold lives
   -- and gmcp.status for the gold-spent verification, so it follows both
   { path = "emunah.shop",               as = "shop"          },

   -- restyles ELIST and totals its sips; needs ui.theme and outgoing (was it asked for)
   { path = "emunah.elist",              as = "elist"         },

   -- shows WIELDED at login and keeps a chyron notice up while no shield is wielded;
   -- reads gmcp.items and writes to ui.chyron
   { path = "emunah.shield",             as = "shield"        },

   -- antitheft: keeps selfishness up and valuables in the pack, and raises the alarm on an
   -- unexplained loss. Reads loot (the pack), shop (the pay window), outgoing and items;
   -- uses ui.alert, and curing.defkeepup for selfishness, both loaded above.
   { path = "emunah.antitheft",          as = "antitheft"     },

   -- the manna rite as one command; needs act, timers and have.balance
   { path = "emunah.manna",              as = "manna"         },

   -- keeps the pipes filled and lit; needs curing.curelist for the smoked-herb list and
   -- have.item for what is carried, so it loads after both
   { path = "emunah.pipes",              as = "pipes"         },

   -- numpad movement bindings; loaded after the walker because a movement key stops it
   { path = "emunah.keys",               as = "keys"          },

   -- who is a person, and what are they. Loaded before pvp, which asks it whether a name
   -- may be targeted at all.
   { path = "emunah.namedb",             as = "namedb"        },
   -- the Achaea web API, then the game-text listings that feed it names. capture needs
   -- api, and both hang off the namedb table published above them.
   { path = "emunah.namedb.api",         as = "namedb.api"    },
   { path = "emunah.namedb.capture",     as = "namedb.capture" },

   -- name highlighting. Out of the ui block above on purpose: it renders the database, so
   -- it has to follow it.
   { path = "emunah.ui.names",           as = "ui.names"      },

   -- the angel's presences, judged against the database: needs namedb and the alert window
   { path = "emunah.presences",          as = "presences"     },

   -- class adapter (interface + detection; loads emunah/class/<class>.lua when known)
   { path = "emunah.class.adapter",      as = "class"         },

   -- bashing loop: the consumer that joins denizens + class + walker into one behaviour
   { path = "emunah.watch",              as = "watch"         },
   { path = "emunah.bashing",            as = "bashing"       },

   -- PvP targeting: explicit opt-in only, mutually exclusive with bashing via the
   -- emunah.bashing.pause / bashing.started event pair (see pvp.lua's header)
   { path = "emunah.pvp",                as = "pvp"           },

   -- the command reference. Ahead of commands.lua, which renders it; it reads config and
   -- keys at RENDER time rather than load time, so it only needs theme to be present.
   { path = "emunah.help",               as = "help"          },

   -- user-facing aliases. Last, so `emunah status` can report on everything above it.
   { path = "emunah.commands",           as = "commands"      },
}

-- ---------------------------------------------------------------------------
-- bootstrap-time helpers (core.log is not available yet)
-- ---------------------------------------------------------------------------

local function boot(msg, colour)
   cecho(string.format("\n<ansi_light_black>[<reset><%s>emunah<reset><ansi_light_black>]<reset> %s",
      colour or "ansi_cyan", msg))
end

local function bootError(msg)
   cecho(string.format("\n<ansi_light_black>[<reset><ansi_red>emunah<reset><ansi_light_black>]<reset> <ansi_light_red>%s<reset>", msg))
end

--- Where the checkout lives. Override by setting EMUNAH_ROOT before loading, e.g. if you
--- keep the repo outside the Mudlet home directory.
local function resolveRoot()
   local root = EMUNAH_ROOT or (getMudletHomeDir() .. "/EmunahSrc")
   return (root:gsub("\\", "/"):gsub("/+$", ""))
end

local function exists(path)
   local f = io.open(path, "r")
   if f then f:close() return true end
   return false
end

--- Assign `value` at a dotted key path inside `root`, creating intermediate tables.
--- "gmcp.vitals" -> root.gmcp.vitals. Intermediates are never overwritten, so
--- emunah.gmcp (from gmcp/init.lua) survives having .vitals hung off it.
local function assign(root, dotted, value)
   local parts = {}
   for part in dotted:gmatch("[^.]+") do parts[#parts + 1] = part end
   local node = root
   for i = 1, #parts - 1 do
      local key = parts[i]
      if type(node[key]) ~= "table" then node[key] = {} end
      node = node[key]
   end
   node[parts[#parts]] = value
end

-- ---------------------------------------------------------------------------
-- load
-- ---------------------------------------------------------------------------

--- Build (or rebuild) the emunah namespace.
--- @param reloading boolean true when this is a hot reload rather than first load
--- @return boolean ok
local function load(reloading)
   local root = resolveRoot()
   local srcdir = root .. "/src"

   if not exists(srcdir .. "/emunah/core/util.lua") then
      bootError(("Cannot find the Emunah source at %s"):format(srcdir))
      bootError("Clone the repo there, or set EMUNAH_ROOT to the checkout directory.")
      return false
   end

   -- Carry forward the state that must not be rebuilt.
   local carried = {}
   if emunah then
      for key in pairs(CARRIED) do carried[key] = emunah[key] end
   end

   -- Tear down the previous generation before anything new registers itself. This is the
   -- step that is easy to omit; without it, handlers accumulate across reloads.
   if reloading and emunah and emunah.event and emunah.event.killAll then
      local killed = emunah.event.killAll()
      if killed > 0 then
         boot(("Released %d event handler%s from the previous load."):format(killed, killed == 1 and "" or "s"))
      end
   end

   local prevPath, prevCpath = package.path, package.cpath
   package.path = string.format("%s;%s/?.lua;%s/?/init.lua", prevPath, srcdir, srcdir)

   -- Drop our modules so require actually re-reads them from disk. Done as a separate
   -- pass ahead of loading so that a module requiring a sibling directly still gets the
   -- fresh copy rather than a half-updated mix of generations.
   for _, entry in ipairs(MANIFEST) do
      package.loaded[entry.path] = nil
   end

   local fresh = { _version = VERSION, _root = root }
   for key, value in pairs(carried) do fresh[key] = value end
   fresh._handlers = fresh._handlers or {}
   fresh._timers   = fresh._timers or {}
   fresh._aliases  = fresh._aliases or {}
   fresh._persist  = fresh._persist or {}

   -- Publish early: modules reference the global `emunah` at load time to reach the
   -- siblings already loaded above them in the manifest.
   local previous = emunah
   emunah = fresh

   local loaded, failure = 0, nil
   for _, entry in ipairs(MANIFEST) do
      local ok, result = pcall(require, entry.path)
      if not ok then
         failure = { path = entry.path, err = tostring(result) }
         break
      end
      -- Only assign on success: assigning either way silently installs the error string
      -- as the module.
      assign(emunah, entry.as, result)
      loaded = loaded + 1
   end

   package.path, package.cpath = prevPath, prevCpath

   if failure then
      bootError(("Failed to load %s"):format(failure.path))
      bootError(failure.err)
      -- Roll back rather than leave a half-built namespace that looks functional.
      emunah = previous or fresh
      if emunah.event and emunah.event.killAll then emunah.event.killAll() end
      raiseEvent("emunah.loadFailed", failure.path, failure.err)
      return false
   end

   boot(("v%s loaded -- %d modules%s."):format(VERSION, loaded, reloading and " (reload)" or ""),
      "ansi_light_green")

   raiseEvent("emunah.loaded", reloading == true)
   return true
end

--- KEEP THE CHECKOUT CURRENT WITH MAIN, so `emreload` is the whole update: asked for on
--- 2026-09-28 ("i just want to emreload and be sure my current system is current with
--- main") after a day of "git pull, then emreload" -- and of fixes that looked broken in
--- play because the pull had been missed (DIAG still clearing crescendo after the fix for
--- it had merged).
---
--- Fast-forward only, and only on `main`: a checkout with local edits or on another
--- branch is somebody working on it, and is reported rather than touched. A failure never
--- blocks the reload -- whatever is on disk is loaded, and the reason is said. Blocking:
--- Mudlet waits for git, a second or two, so this is for reloads, not mid-fight.
---
--- `emunahGit` runs one git command and returns its output and whether it worked. The test
--- suite sets EMUNAH_GIT_RUNNER so that no test ever runs git; nothing else should.
---
--- Success is read from the OUTPUT, not the exit status: Mudlet's Lua 5.1 does not return
--- a popen's status from close(). git reports failure as "fatal:" or "error:", and a
--- missing git as the shell's "not found" / "not recognized".
function emunahGit(root, args)
   if EMUNAH_GIT_RUNNER then return EMUNAH_GIT_RUNNER(root, args) end
   local handle = io.popen(('git -C "%s" %s 2>&1'):format(root, args))
   if not handle then return "", false end
   local output = (handle:read("*a") or ""):gsub("%s+$", "")
   handle:close()
   local failed = output:find("^fatal:") or output:find("\nfatal:") or output:find("^error:")
      or output:find("\nerror:") or output:find("not found") or output:find("not recognized")
   return output, not failed
end

local function note(msg)
   cecho(string.format("\n<ansi_light_black>[<reset><ansi_cyan>emunah<reset><ansi_light_black>]<reset> %s", msg))
end

function emunahUpdate(root)
   root = root or resolveRoot()
   local config = emunah and emunah.config
   if config and config.get and config.get("system.update", true) == false then return "off" end

   local branch, ok = emunahGit(root, "rev-parse --abbrev-ref HEAD")
   if not ok then
      bootError("Not updating: " .. root .. " is not a git checkout (" .. branch .. ").")
      return "error"
   end
   if not branch:match("^[%w%._/%-]+$") then
      bootError("Not updating: could not read the checkout's branch (" .. branch .. ").")
      return "error"
   end
   if branch ~= "main" then
      note(("Not updating: the checkout is on <ansi_yellow>%s<reset>, not main."):format(branch))
      return "branch"
   end

   local before = emunahGit(root, "rev-parse --short HEAD")
   local output, pulled = emunahGit(root, "pull --ff-only --quiet origin main")
   if not pulled then
      bootError("Could not update from main, loading what is on disk: " .. output)
      return "error"
   end
   local after = emunahGit(root, "rev-parse --short HEAD")
   local subject = emunahGit(root, "log -1 --format=%s")
   if after == before then
      note(("Up to date with main (%s)."):format(after))
      return "current"
   end
   note(("Updated %s -> <ansi_light_green>%s<reset>: %s"):format(before, after, subject))
   return "updated"
end


--- Force a rebuild of the whole namespace from disk.
---
--- This re-executes THIS FILE rather than calling load() directly, and the distinction
--- matters more than it looks.
---
--- load() is a closure over the MANIFEST local above. Calling it re-requires every module
--- the manifest already lists, but the manifest itself -- and the loader code around it --
--- are whatever was read when this chunk was last executed. So a reload that only calls
--- load() picks up edits to existing modules and silently ignores a NEWLY ADDED one: the
--- new file is on disk, its entry is in the manifest on disk, and neither is in memory.
--- The failure is confusing because the modules that did reload are visibly up to date,
--- so it looks like the new module is broken rather than absent.
---
--- Re-running the file rebuilds the manifest, the loader, and the namespace together. The
--- chunk's own tail calls load() exactly once, so there is no recursion.
function emunahReload()
   local root = resolveRoot()
   local entry = root .. "/src/emunah.lua"

   emunahUpdate(root)

   if not exists(entry) then
      -- The checkout moved or was deleted. Fall back to reloading the modules we already
      -- know about, which is strictly better than doing nothing.
      bootError(("Cannot re-read %s -- reloading known modules only."):format(entry))
      return load(true)
   end

   local ok, err = pcall(dofile, entry)
   if not ok then
      bootError("Reload failed: " .. tostring(err))
      return false
   end
   return true
end

-- ---------------------------------------------------------------------------
-- entry point
-- ---------------------------------------------------------------------------

-- Re-running the bootstrap over an already-loaded profile is a reload, not a second
-- initialisation.
local isReload = (emunah ~= nil and emunah._version ~= nil)

if load(isReload) then
   -- Reload surface. Owned by the loader so the bootstrap package stays a one-liner, and
   -- torn down first so repeated loads do not stack duplicate aliases.
   for _, id in ipairs(emunah._aliases) do killAlias(id) end
   emunah._aliases = {}

   table.insert(emunah._aliases, tempAlias("^emreload$", function()
      emunahReload()
   end))
end

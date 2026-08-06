--- `emhelp`: the whole command surface, documented in one place.
---
--- WHY THIS IS DATA AND NOT PRINT STATEMENTS
--- -----------------------------------------
--- Help used to be two hardcoded `cecho` loops in commands.lua -- forty-one one-line
--- entries against thirty-three handlers and something like a hundred and eighty distinct
--- command forms. It had already drifted: `sleep` was undocumented, so were `bash consumes`,
--- `pvp attack`, half of `walk`, most of `ndb`, and every single configuration setting.
---
--- Nothing caught that, because there was nothing to catch it WITH. A help system built out
--- of print statements cannot be checked against the code it describes.
---
--- So the help is a table, and test/run.lua asserts against it: every handler in
--- commands.lua appears here, every alias appears here, every shipped config default appears
--- here, and every cross-reference resolves. Adding a command without documenting it now
--- fails the suite, which is the only mechanism that has ever kept documentation current.
---
--- SHAPE
--- -----
---   M.topics    ordered categories, each with ordered entries
---   M.settings  every configuration key, shipped or not, with its default and meaning
---   M.keys      the key bindings, read from keys.lua so they cannot disagree
---
--- An entry:
---
---   syntax    what you type, with <angled> placeholders and a|b alternatives
---   handler   the M.handlers key it dispatches to, or nil for a bare alias
---   alias     the bare alias that reaches it, when there is one (`pp`, `emdefs`, `ndb`)
---   summary   one line, for lists
---   detail    a paragraph, for the card -- why it exists, not what it obviously does
---   args      { { "<name>", "what it means" }, ... }
---   examples  { "emset defs mode rebounding keepup", ... }
---   settings  config keys this reads or writes, cross-referenced into M.settings
---   see       other entries' syntax, cross-referenced into M.topics
---   quick     true if it belongs in the bare `emunah` list

local M = {}

local theme = emunah.ui.theme

-- ---------------------------------------------------------------------------
-- topics
-- ---------------------------------------------------------------------------

M.topics = {

{ id = "core", title = "Core", blurb = "State, settings, reloading and diagnostics.",
  entries = {

  { syntax = "emset", handler = "quick", alias = "emset", quick = true,
    summary = "the short list -- the ten commands a normal session uses",
    detail = "Bare `emset`, with no subcommand. This used to print the full forty-line "
          .. "reference, which is a lot to hand someone who typed nothing but the prefix. "
          .. "`emhelp` has everything.",
    see = { "emhelp", "emset help" } },

  { syntax = "emunah <command>", handler = nil,
    summary = "the long form of the same prefix",
    detail = "Every command in this reference is written `emset ...`, because that is what "
          .. "you type. `emunah ...` is the identical dispatcher under its full name, and is "
          .. "what appears in comments, log lines and scripts, where the extra letters read "
          .. "better than they type. `emset status` and `emunah status` are the same command. "
          .. "There used to be a `!` prefix as well; it has been removed rather than "
          .. "deprecated, and now falls through to the game untouched.",
    examples = { "emunah status", "emunah bash on" },
    see = { "emset", "emhelp" } },

  { syntax = "emhelp", handler = nil, alias = "emhelp", quick = true,
    summary = "this help system -- index, topics, per-command cards, search",
    detail = "With no argument, the index. With a topic name, that topic's commands. With "
          .. "a command, the full card for it: syntax, arguments, examples, the settings it "
          .. "touches and what they are set to right now. Everything printed is clickable.",
    args = {
       { "<topic>", "one of the categories listed by the index" },
       { "<command>", "any command, with or without the `emunah`/`emset` prefix" },
    },
    examples = { "emhelp", "emhelp curing", "emhelp bash", "emhelp search gold" },
    see = { "emhelp search <word>", "emhelp settings", "emhelp keys" } },

  { syntax = "emhelp search <word>", handler = nil,
    summary = "find every command mentioning a word",
    detail = "Matches across syntax, summary, detail text and setting names, so searching "
          .. "for what you want to DO usually finds it even when you do not know what the "
          .. "command is called.",
    examples = { "emhelp search gold", "emhelp search balance" } },

  { syntax = "emhelp settings [topic|key]", handler = nil,
    summary = "every setting, its default, and what it is right now",
    detail = "Includes the keys that are settable but not in the shipped defaults -- there "
          .. "are more of those than there are shipped ones, and none of them were "
          .. "documented anywhere before this. A value differing from its default is "
          .. "marked.",
    examples = { "emhelp settings", "emhelp settings curing", "emhelp settings bashing.attack" },
    see = { "emset set <key> <value>" } },

  { syntax = "emhelp keys", handler = nil,
    summary = "the numpad and function-key bindings",
    detail = "Read from keys.lua's own tables rather than transcribed, so it cannot "
          .. "disagree with what is actually bound.",
    see = { "emset keys [on|off|rebuild]" } },

  { syntax = "emhelp all", handler = nil,
    summary = "every command in every topic, in one page",
    detail = "For reading through, or for searching with Mudlet's own buffer search." },

  { syntax = "emset help", handler = "help",
    summary = "the same index as `emhelp`",
    detail = "Kept because it is what the system has always answered to, and because "
          .. "`emset help` reads better in a script than `emhelp` does.",
    see = { "emhelp" } },

  { syntax = "emset status", handler = "status", quick = true,
    summary = "system and character state on one screen",
    detail = "Version, character, class, whether curing and keep-up and the interface are "
          .. "running, the cure method, how many afflictions are tracked, how many skills "
          .. "and inventory items are indexed, the log level, and the three safety floors -- "
          .. "which are shown in red when set to zero, because a disabled floor looks "
          .. "identical to a low one until it kills you.",
    settings = { "curing.enabled", "defences.enabled", "ui.enabled", "curing.method",
                 "logLevel", "bashing.stopBelowHealth", "pvp.stopBelowHealth", "watch.critical" } },

  { syntax = "emset set", handler = "set", quick = true,
    summary = "dump the whole configuration table",
    detail = "The raw table. `emhelp settings` is the readable version, with defaults and "
          .. "explanations.",
    see = { "emhelp settings", "emset set <key>", "emset set <key> <value>" } },

  { syntax = "emset set <key>", handler = "set",
    summary = "read one setting",
    detail = "Prints `(unset)` when the key has never been written, which is different from "
          .. "a key set to its default.",
    args = { { "<key>", "a dotted path, e.g. curing.confirmWait" } },
    examples = { "emset set curing.confirmWait" } },

  { syntax = "emset set <key> <value>", handler = "set", quick = true,
    summary = "write one setting, and save it",
    detail = "`true`, `false` and numbers are coerced; everything else is stored as a "
          .. "string. Written straight to disk, so it survives a reload and a restart.",
    args = {
       { "<key>", "a dotted path -- see `emhelp settings` for all of them" },
       { "<value>", "true, false, a number, or text" },
    },
    examples = { "emset set curing.healthThreshold 75", "emset set bashing.attack \"angel sear\"" },
    see = { "emhelp settings" } },

  { syntax = "emset reload", handler = "reload",
    summary = "re-read every module from disk",
    detail = "Re-executes the bootstrap, so a newly ADDED module is picked up too -- "
          .. "re-requiring the existing manifest silently would not see it.",
    see = { "emreload" } },

  { syntax = "emreload", handler = nil, alias = "emreload",
    summary = "the same reload, as one word",
    detail = "Owned by the loader rather than commands.lua, so it still works when "
          .. "commands.lua is the module that failed to compile.",
    see = { "emset reload" } },

  { syntax = "emset debug", handler = "debug",
    summary = "toggle verbose logging -- every command sent, and every command held",
    detail = "The single most useful thing to turn on before reporting a problem. The held "
          .. "lines are the valuable half: they say why the system decided NOT to act, which "
          .. "is invisible otherwise and is usually the actual complaint.",
    settings = { "logLevel" } },

  { syntax = "emset debug gmcp", handler = "debug",
    summary = "trace GMCP traffic in and out",
    detail = "Off by default and separately toggled, because it is a lot of output. This is "
          .. "what to paste when the question is what the game actually said." },

  { syntax = "emset debug handlers|timers|queue", handler = "debug",
    summary = "internals: registered handlers, live timers, the action queue",
    detail = "`queue` is the one to reach for when something is not being sent: it shows "
          .. "what is pending on each vector and what is in flight awaiting confirmation." },

  { syntax = "emset gmcp [refresh]", handler = "gmcp",
    summary = "tracked GMCP state, or ask the game to resend it",
    detail = "`refresh` re-requests inventory, rift and skills. Useful after a desync, and "
          .. "the first thing to try when a cure is refused for something you are holding." },

  { syntax = "emset have [thing]", handler = "have",
    summary = "capability report, or check one item or skill",
    detail = "With no argument: how many skills and items are indexed, how many rift "
          .. "entries, and for each cure vector whether it is ready, recovering, or blocked "
          .. "by an affliction. With an argument: whether that is a skill you have, an item "
          .. "in inventory, an entry in the rift, or a defence currently up.",
    args = { { "[thing]", "a skill name, item name or defence name" } },
    examples = { "emset have", "emset have bloodroot", "emset have rebounding" } },

  { syntax = "emset chat [rebuild]", handler = "chat",
    summary = "chat capture vs rendering -- which half is working",
    detail = "Capture and rendering are separate modules and fail independently. \"Chat "
          .. "stopped\" has three different causes -- the game stopped sending, the console "
          .. "broke, or no console was ever built -- and this tells them apart in one line.",
    settings = { "ui.chatTabs" } },

  { syntax = "emset chyron <text> | clear", handler = "chyron",
    summary = "queue an announcement on the scrolling strip at the top",
    detail = "Up to three messages scroll on a loop. The manual entry point to the same "
          .. "call anything else in the codebase would make programmatically.",
    args = { { "<text>", "what to scroll" }, { "clear", "drop everything queued" } },
    examples = { "emset chyron Anzerloi is in the arena", "emset chyron clear" } },

  { syntax = "emset ui [rebuild|reset|show]", handler = "ui", quick = true,
    summary = "toggle, rebuild or reset the interface",
    detail = "With no argument, toggles the whole interface off and on. `rebuild` recreates "
          .. "the containers, `reset` discards saved geometry, `show` un-hides them -- which "
          .. "is the one to try if the interface has gone invisible.",
    settings = { "ui.enabled" } },

  { syntax = "emset ui map [on|off|centre|rebuild|float|embed|raw|height <n>]", handler = "ui",
    summary = "the map: status, size, or where it lives",
    detail = "With no argument it REPORTS and never toggles -- deliberately, because the "
          .. "map has about eight ways to be broken and the report distinguishes them. "
          .. "`float` detaches it into its own dock; `raw` bypasses Geyser entirely.",
    args = { { "height <n>", "percent of the window, 10-70" } },
    settings = { "ui.map", "ui.mapHeight", "ui.mapFloat" } },
}},

{ id = "curing", title = "Curing & defences",
  blurb = "The affliction engine, defence keep-up, and detection.",
  entries = {

  { syntax = "pp", handler = "pause", alias = "pp", quick = true,
    summary = "pause or resume curing AND defence keep-up together",
    detail = "Both, as one action, on purpose. A cure engine paused while keep-up carries on "
          .. "raising defences is not the fight paused, it is half paused -- and the half "
          .. "still running is the half that spends balances. Resuming is defined as "
          .. "\"either one is currently off\", so one press always lands on a clean state.",
    settings = { "curing.enabled", "defences.enabled" },
    see = { "emset cure on|off", "emset defs on|off" } },

  { syntax = "emset cure on|off", handler = "cure",
    summary = "the curing engine alone",
    detail = "Off by default. Curing is opt-in because a system that starts eating herbs "
          .. "the moment it loads is not something to hand someone unannounced.",
    settings = { "curing.enabled" },
    see = { "pp" } },

  { syntax = "emset affs", handler = "affs", quick = true,
    summary = "tracked afflictions, their cure vectors, source and age",
    detail = "Shows why an affliction is NOT being cured when that is the case -- the "
          .. "refusal reason, or \"no cure defined\". Prints a red warning inside the list "
          .. "when curing is switched off, rather than only in the header.",
    see = { "emset detect", "emset prio <aff> <vector> <rank>" } },

  { syntax = "emdefs", handler = "keepup", alias = "emdefs", quick = true,
    summary = "the clickable defence grid",
    detail = "Three states per defence, not two, and that is the point of building a grid "
          .. "rather than printing a list. `[ ]` off, `[o]` defup (raise it once if it is "
          .. "missing), `[x]` keepup (raise it whenever it is missing), `[-]` we hold no "
          .. "command capable of raising it at all. The NAME is coloured by what is actually "
          .. "true right now: green up, red wanted but down, dim down. A defence sitting "
          .. "wanted-but-unraisable looks identical to one that is merely down, and stays "
          .. "that way forever, which is why the fourth state exists.",
    settings = { "defences.keepup", "defences.commands" },
    see = { "emset defs mode <name> defup|keepup|off" } },

  { syntax = "emset defs on|off", handler = "defs",
    summary = "defence keep-up as a whole",
    settings = { "defences.enabled" },
    see = { "pp" } },

  { syntax = "emset defs list", handler = "defs",
    summary = "wanted defences, with mode and whether each is up",
    detail = "`done (lapsed)` means a defup-mode defence was raised once and has since "
          .. "fallen; that is expected, not a fault." },

  { syntax = "emset defs add <name> [command]", handler = "defs",
    summary = "want a defence, optionally supplying how to raise it",
    detail = "The second form is for defences we have no command for -- tattoos, mostly. "
          .. "Without it, a defence can be wanted and unraisable, which the grid shows as "
          .. "`[-]`.",
    args = {
       { "<name>", "a Char.Defences name -- see `emset defs names`" },
       { "[command]", "what raises it, e.g. `touch boar`" },
    },
    examples = { "emset defs add rebounding", "emset defs add insomnia touch moss" },
    settings = { "defences.commands" } },

  { syntax = "emset defs mode <name> defup|keepup|off", handler = "defs",
    summary = "how hard to try for one defence",
    detail = "`defup` raises it once if missing and then leaves it alone. `keepup` raises it "
          .. "whenever it is missing, indefinitely. `off` stops wanting it.",
    args = { { "<name>", "a Char.Defences name" } },
    examples = { "emset defs mode rebounding keepup", "emset defs mode speed defup" },
    settings = { "defences.keepup" } },

  { syntax = "emset defs names", handler = "defs",
    summary = "every name Char.Defences uses, and whether we can raise it",
    detail = "The names the game uses and the names people type diverge more than they "
          .. "should -- a defence is usually known by whatever grants it, and the game names "
          .. "it after what it does. `venom` is the elixir; `poisonresist` is the defence." },

  { syntax = "emset defs remove <name>", handler = "defs",
    summary = "stop wanting a defence (`drop` also works)",
    args = { { "<name>", "a defence currently on the wanted list" } } },

  { syntax = "emset prio <aff> <vector> <rank>", handler = "prio",
    summary = "override a cure priority",
    detail = "Lower ranks are cured first. Per-vector, because the right order to eat herbs "
          .. "in is not the right order to apply salves in.",
    args = {
       { "<aff>", "an affliction name" },
       { "<vector>", "herb, salve, elixir, smoke, focus, tree, writhe or special" },
       { "<rank>", "a number; lower is cured sooner" },
    },
    examples = { "emset prio paralysis herb 1" },
    settings = { "priorities" } },

  { syntax = "emset detect", handler = "detect",
    summary = "detection pattern coverage",
    detail = "How many afflictions are known, how many have gain patterns, how many have "
          .. "cure patterns. The gap between the first and the second is the honest measure "
          .. "of how much of the corpus is written." },

  { syntax = "emset learn on|off", handler = "learn",
    summary = "log candidate affliction messages to a file",
    detail = "For building the pattern corpus: records lines that arrived alongside an "
          .. "affliction change, so a real message can be lifted verbatim rather than "
          .. "guessed at." },

  { syntax = "affpop [on|off]", handler = "affpop", alias = "affpop",
    summary = "walk AFFLICTION LIST and AFFLICTION SHOW into a corpus file",
    detail = "Sends AFFLICTION LIST, answers the MORE prompts itself, then AFFLICTION SHOW "
          .. "for every name it found. One command, several hundred round trips -- run it "
          .. "somewhere quiet.",
    see = { "emset learn on|off" } },
}},

{ id = "combat", title = "Combat & movement",
  blurb = "Bashing, hunting, the area walker, kill lists and PvP.",
  entries = {

  { syntax = "emset bash on|off", handler = "bash", quick = true,
    summary = "the combat loop",
    detail = "Attacks whatever is targeted, retargets when something dies, and stops when "
          .. "health falls below the floor. Does NOT move on its own -- `emset hunt` is the "
          .. "version that walks.",
    settings = { "bashing.attack", "bashing.stopBelowHealth", "bashing.soloOnly" },
    see = { "emset hunt [off]" } },

  { syntax = "emset bash", handler = "bash",
    summary = "the session report",
    detail = "Attack, costs, target and its health, an estimate of the kill, how many "
          .. "killed, damage dealt and taken, rooms cleared, and how fresh the room's item "
          .. "list is -- that last one being the usual reason a loop looks stuck." },

  { syntax = "emset bash attack <command>", handler = "bash",
    summary = "what to attack with",
    detail = "One matched pair of surrounding quotes is stripped, so a multi-word attack "
          .. "can be given either way.",
    examples = { "emset bash attack angel sear", "emset bash attack \"angel sear\"" },
    settings = { "bashing.attack" } },

  { syntax = "emset bash balance eq|bal|both", handler = "bash",
    summary = "what the attack REQUIRES before it can be sent",
    settings = { "bashing.balance" },
    see = { "emset bash consumes eq|bal" } },

  { syntax = "emset bash consumes eq|bal", handler = "bash",
    summary = "what the attack SPENDS when it lands",
    detail = "A distinct axis from `balance`, and getting them confused is why an attack "
          .. "loop stalls: Angel Sear requires both but consumes equilibrium, so a system "
          .. "watching balance for its recovery waits for a signal that never comes.",
    settings = { "bashing.consumes" },
    see = { "emset bash balance eq|bal|both" } },

  { syntax = "emset bash health <n>", handler = "bash",
    summary = "stop attacking below this percentage of health",
    detail = "Zero disables the floor, and `emset status` shows it in red when it is zero.",
    args = { { "<n>", "percent, 0-100" } },
    settings = { "bashing.stopBelowHealth" } },

  { syntax = "emset hunt [off]", handler = "hunt", quick = true,
    summary = "walk the area AND kill things",
    detail = "Starts the walker first and then the bashing loop, in that order deliberately: "
          .. "the reverse attacks whatever is in the room before the walker has decided "
          .. "where it is.",
    see = { "emset bash on|off", "emset walk start" } },

  { syntax = "emset walk start|stop|pause|resume", handler = "walk", quick = true,
    summary = "the area walker on its own, with no fighting",
    settings = { "walker.auto", "walker.stepDelay" } },

  { syntax = "emset walk", handler = "walk",
    summary = "walker report: area, rooms remaining, visited, unreachable, avoided",
    detail = "\"Paced by\" is the useful field -- it says what the walker is currently "
          .. "waiting on, which is usually the answer to why it has stopped." },

  { syntax = "emset walk move|next", handler = "walk",
    summary = "take exactly one step",
    detail = "For when auto-stepping is off, or for stepping through a route by hand to see "
          .. "where it goes wrong." },

  { syntax = "emset walk avoid <id> | unavoid <id>", handler = "walk",
    summary = "never route through a room, or stop avoiding it",
    args = { { "<id>", "a room number, as shown by `emset walk` and the room panel" } },
    settings = { "walker.avoid" } },

  { syntax = "emset walk auto [off]", handler = "walk",
    summary = "step automatically, or only on request",
    detail = "Anything that is not the literal word `off` turns it on.",
    settings = { "walker.auto" } },

  { syntax = "emset walk delay <seconds>", handler = "walk",
    summary = "seconds between steps, 0.1 to 30",
    settings = { "walker.stepDelay" } },

  { syntax = "emset walk return", handler = "walk",
    summary = "toggle returning to the starting room when finished",
    detail = "Session-only -- this one is deliberately not persisted.",
    settings = { "walker.returnToStart" } },

  { syntax = "emset mobs", handler = "mobs",
    summary = "denizens recorded for this area, and which are on the kill list",
    settings = { "denizens.autoRecord" } },

  { syntax = "emset mobs here", handler = "mobs",
    summary = "what is in the room now, by replica number",
    detail = "Green is on the kill list, yellow is already dealt with, grey is skipped. "
          .. "Clickable." },

  { syntax = "emset mobs target|done|reset", handler = "mobs",
    summary = "target the next wanted denizen, mark the current one engaged, or clear the room",
    detail = "`reset` forgets what has been dealt with in this room, which is what to use "
          .. "when the loop thinks a room is clear and it is not." },

  { syntax = "emset mobs add|remove|skip|kill <name>", handler = "mobs",
    summary = "edit the per-area kill list",
    detail = "`skip` keeps the denizen recorded but off the list -- different from `remove`, "
          .. "which forgets it and lets auto-recording add it back.",
    args = { { "<name>", "a denizen name as the game writes it" } } },

  { syntax = "emset mobs areas", handler = "mobs",
    summary = "every area with recorded denizens" },

  { syntax = "emset pvp on|off", handler = "pvp",
    summary = "the PvP loop",
    detail = "NEVER auto-targets. A system that picks its own target in a player fight is "
          .. "one mis-parse away from attacking an ally, so the target is always explicit.",
    settings = { "pvp.stopBelowHealth", "pvp.verses" },
    see = { "emset pvp target <name>" } },

  { syntax = "emset pvp target <name> | target off", handler = "pvp",
    summary = "who to fight",
    detail = "Refuses a name recorded as an ally, and refuses your own.",
    args = { { "<name>", "a player name" } },
    see = { "emset iff <person> ally|enemy|auto" } },

  { syntax = "emset pvp attack <n>", handler = "pvp",
    summary = "how many afflictions to stack before switching to damage",
    args = { { "<n>", "a count" } },
    settings = { "pvp.attackAtAfflictions" } },

  { syntax = "emset keys [on|off|rebuild]", handler = "keys",
    summary = "numpad movement bindings",
    detail = "`rebuild` re-binds everything, which is the fix for \"enabled but nothing is "
          .. "bound\" -- a state the report will tell you about explicitly.",
    settings = { "keys.numpad" },
    see = { "emhelp keys" } },

  { syntax = "sleep", handler = nil, alias = "sleep",
    summary = "SLEEP, and record that you meant it",
    detail = "The one place this system deliberately shadows an Achaea verb, because the "
          .. "collision IS the mechanism. Being asleep is otherwise indistinguishable from "
          .. "an opponent having put you there -- same affliction, same GMCP payload, same "
          .. "blocked state -- and the only evidence that a sleep was wanted is that you "
          .. "asked for it a moment earlier. The command still goes to the game; this "
          .. "records intent, it does not replace the verb. Anchored to a bare SLEEP: "
          .. "`sleep` with an argument is a different command and passes straight through." },
}},

{ id = "economy", title = "Shop, loot & sustenance",
  blurb = "Buying, picking up gold, pipes and the manna rite.",
  entries = {

  { syntax = "emset shop [proprietor]", handler = "shop", quick = true,
    summary = "redraw the last WARES seen -- clickable, buys by replica number",
    detail = "Grouped by category. Clicking an item buys it. The listing is whatever the "
          .. "game last showed, so this is a redraw rather than a fresh query.",
    args = { { "[proprietor]", "a named shop, when more than one has been seen" } },
    settings = { "shop.stowIn" } },

  { syntax = "emset shop spent", handler = "shop",
    summary = "gold spent this session, itemised",
    detail = "Verified against Char.Status rather than assumed from what was sent -- a "
          .. "purchase that was refused should not appear in the ledger." },

  { syntax = "emset shop limit <gp> | off", handler = "shop",
    summary = "hold back any single purchase over <gp>",
    detail = "A click is one keystroke away from a very expensive mistake in a shop that "
          .. "lists by replica number.",
    args = { { "<gp>", "gold, or `off` to clear the limit" } },
    settings = { "shop.confirmAbove" } },

  { syntax = "emset loot [on|off|now]", handler = "loot",
    summary = "pick up gold from corpses",
    detail = "`now` sweeps once regardless of the setting. By default it only lifts gold "
          .. "when alone and from kills it believes are ours.",
    settings = { "loot.gold", "loot.aloneOnly", "loot.ownKillsOnly", "loot.noDenizens",
                 "loot.stowIn" } },

  { syntax = "pipes [on|off]", handler = "pipes", alias = "pipes",
    summary = "keep the pipes filled and lit",
    detail = "The `smoke` cure vector needs a lit pipe with the right herb in it, and "
          .. "nothing else maintains that. Without this, smoke cures are refused for a "
          .. "reason that looks like a missing herb.",
    settings = { "pipes.enabled", "pipes.assign", "pipes.poll" } },

  { syntax = "emset pipes now", handler = "pipes",
    summary = "check the pipes immediately rather than on the next poll" },

  { syntax = "manna", handler = nil, alias = "manna",
    summary = "the sustenance rite: perform, get bowl, drink bowl",
    detail = "Three commands with real waits between them. One word because it is a thing "
          .. "you do several times a day and the sequence is fiddly to type." },
}},

{ id = "people", title = "People",
  blurb = "The name database, dossiers, standing and highlighting.",
  entries = {

  { syntax = "ndb", handler = "ndb", alias = "ndb",
    summary = "the roster",
    detail = "`ndb` works bare, without the `emunah` prefix, deliberately: the database is "
          .. "consulted mid-fight about a name that just walked in, and five extra "
          .. "keystrokes at that moment is the difference between looking someone up and "
          .. "not bothering.",
    see = { "ndb show <person>", "emset whois <person>" } },

  { syntax = "ndb ally|enemy|neutral|dragons|marks|infamous", handler = "ndb",
    summary = "filtered rosters" },

  { syntax = "ndb city|house|order|class <name>", handler = "ndb",
    summary = "everyone recorded with that affiliation",
    examples = { "ndb city Mhaldor", "ndb class Serpent" } },

  { syntax = "ndb here", handler = "ndb",
    summary = "who is in the room, with what we know about them",
    detail = "Unknowns are shown with a `?` and \"not recorded\" rather than omitted -- that "
          .. "someone is present and unrecorded is itself worth seeing." },

  { syntax = "ndb show <person>", handler = "ndb",
    summary = "the full dossier (`who` and `whois` also work)",
    args = { { "<person>", "a name" } },
    see = { "emset whois <person>" } },

  { syntax = "emset whois <person>", handler = "whois", quick = true,
    summary = "the dossier on one person",
    detail = "Falls back to the Achaea web API when the name is not recorded, so this "
          .. "answers for anyone, not only people already seen.",
    args = { { "<person>", "a name" } },
    settings = { "namedb.autoFetch" } },

  { syntax = "ndb stats", handler = "ndb",
    summary = "coverage: standing, cities, and what is still unknown",
    detail = "The gaps are the point -- how many records have no city, no class -- because "
          .. "that is what says whether the database is worth trusting yet." },

  { syntax = "ndb fields", handler = "ndb",
    summary = "the settable field schema",
    see = { "ndb set <person> <field> <value>" } },

  { syntax = "ndb set <person> <field> <value>", handler = "ndb",
    summary = "record a fact by hand",
    args = {
       { "<field>", "one of the names from `ndb fields`" },
    },
    examples = { "ndb set Malefactor city Mhaldor" } },

  { syntax = "ndb note <person> <text>", handler = "ndb",
    summary = "attach a free-text note",
    see = { "ndb unnote <person> [index]" } },

  { syntax = "ndb unnote <person> [index]", handler = "ndb",
    summary = "drop one note, or all of them",
    detail = "With no index, every note on that person goes." },

  { syntax = "emset iff <person> ally|enemy|auto", handler = "iff",
    summary = "declare a standing -- declaration beats derivation",
    detail = "`auto` hands the decision back to the derived rules (city, house and order "
          .. "hostility). An explicit declaration always wins, and survives an import.",
    args = { { "<person>", "a name" } },
    see = { "ndb hostile [off] <kind> <org>" } },

  { syntax = "ndb hostile [off] <kind> <org>", handler = "ndb",
    summary = "treat a whole city, house or order as hostile",
    args = { { "<kind>", "city, house or order" } },
    examples = { "ndb hostile city Mhaldor", "ndb hostile off city Mhaldor" } },

  { syntax = "ndb capture [on|off]", handler = "ndb",
    summary = "which listings are being read, and what each is waiting for",
    detail = "Names are learned from CW, CLWHO, QW, HONOURS and the guardian angel. The "
          .. "report says which of those have produced anything, which is how you tell \"not "
          .. "implemented\" from \"never seen one\".",
    settings = { "namedb.capture" } },

  { syntax = "ndb api [on|off]", handler = "ndb",
    summary = "the Achaea web API: transport, queue, cache, hits and misses",
    detail = "Requests are serialised and cached (six hours for a hit, twenty-four for a "
          .. "miss) because the endpoint sends no rate-limit headers and it seemed unwise to "
          .. "find the limit experimentally.",
    settings = { "namedb.autoFetch" } },

  { syntax = "ndb refresh [<person>|all]", handler = "ndb",
    summary = "re-fetch one person, or everybody, one per second" },

  { syntax = "ndb online", handler = "ndb",
    summary = "who is online now, split into known and new" },

  { syntax = "ndb learn", handler = "ndb",
    summary = "record and enrich everyone currently online",
    detail = "The fastest way to go from an empty database to a useful one." },

  { syntax = "ndb prune [days]", handler = "ndb",
    summary = "drop records that are only a name",
    detail = "Anything declared, noted, or given a single fact by hand survives, so this "
          .. "can never quietly discard judgement.",
    args = { { "[days]", "also require the last sighting to be this old" } } },

  { syntax = "ndb forget <person> | forget all", handler = "ndb",
    summary = "delete one record, or the whole database",
    detail = "`forget all` confirms twice and names the count at stake, with a fifteen-second "
          .. "window on the confirmation." },

  { syntax = "ndb export [fields <a,b,c>] [path]", handler = "ndb",
    summary = "write the database out, optionally as a field subset",
    detail = "Notes are excluded from a field-subset export, since those are yours." },

  { syntax = "ndb import <path>", handler = "ndb",
    summary = "merge somebody else's database into yours",
    detail = "Additive. Their file is evidence about people you have not met, not a "
          .. "correction of judgement you have already recorded -- so your own `iff` and "
          .. "your own notes survive intact." },

  { syntax = "ndb path", handler = "ndb",
    summary = "where the database is stored, and how many records it holds" },

  { syntax = "emset names [on|off]", handler = "names",
    summary = "highlight known names in the game text",
    detail = "With no argument, prints the legend: what each colour and weight means. "
          .. "Colour answers \"where do they stand relative to me\"; weight answers \"is "
          .. "there something notable about this person\". They stack, and each is "
          .. "independently readable.",
    settings = { "names.enabled" } },

  { syntax = "emset names ignore <person> | unignore <person>", handler = "names",
    summary = "keep one name out of the highlighter",
    detail = "For the ally whose name is a common word, or the shopkeeper you see forty "
          .. "times an hour. Forgets nothing else about them." },

  { syntax = "emset names tint on|off", handler = "names",
    summary = "tint neutral names by city",
    settings = { "names.cityTint" } },
}},
}

-- ---------------------------------------------------------------------------
-- settings
-- ---------------------------------------------------------------------------
--
-- `shipped = true` means the key is in config.DEFAULTS and is written to disk on first save.
-- `shipped = false` means it is read with a fallback at its use site and can be set, but
-- will not appear in the config file until you set it. There are more of the second kind
-- than the first, and before this table none of them were documented anywhere.

M.settings = {

-- core
{ key = "logLevel", default = "info", type = "string", topic = "core", shipped = true,
  detail = "debug, info, warn or error. `emset debug` toggles between info and debug." },
{ key = "schema", default = 9, type = "number", topic = "core", shipped = true,
  detail = "Config format version. Managed by the migrations; do not set this by hand." },

-- interface
{ key = "ui.enabled", default = true, type = "boolean", topic = "core", shipped = true,
  detail = "Whether the panel interface is built at all." },
{ key = "ui.map", default = true, type = "boolean", topic = "core", shipped = true },
{ key = "ui.mapHeight", default = 42, type = "number", unit = "% of window", topic = "core",
  shipped = true, detail = "Clamped to 10-70." },
{ key = "ui.mapFloat", default = false, type = "boolean", topic = "core", shipped = false,
  detail = "Written by `emset ui map float` / `embed`." },
{ key = "ui.chatTabs", default = "Tells, City, House, Market, Says, Misc", type = "list",
  topic = "core", shipped = true },

-- curing
{ key = "curing.enabled", default = false, type = "boolean", topic = "curing", shipped = true,
  detail = "Off by default, deliberately. Curing is opt-in." },
{ key = "curing.method", default = "herbs", type = "string", topic = "curing", shipped = true,
  detail = "herbs or minerals. Changes which item every cure resolves to." },
{ key = "curing.confirmWait", default = 2.0, type = "number", unit = "s", topic = "curing",
  shipped = true, detail = "How long a sent cure holds its vector waiting for the game to "
       .. "confirm it, before the vector is re-armed." },
{ key = "curing.reconcileEvery", default = 20, type = "number", unit = "ticks",
  topic = "curing", shipped = true,
  detail = "How often the tracked list is reconciled against Char.Afflictions wholesale." },
{ key = "curing.healthThreshold", default = 80, type = "number", unit = "%", topic = "curing",
  shipped = true, detail = "Sip health below this." },
{ key = "curing.manaThreshold", default = 85, type = "number", unit = "%", topic = "curing",
  shipped = true },
{ key = "curing.iridThreshold", default = 68, type = "number", unit = "%", topic = "curing",
  shipped = true, detail = "Eat irid moss below this, on health or mana." },
{ key = "curing.handsThreshold", default = 50, type = "number", unit = "%", topic = "curing",
  shipped = true, detail = "PERFORM HANDS below this. Costs equilibrium, which attacking "
       .. "also spends, so this is set low on purpose." },
{ key = "curing.irid", default = true, type = "boolean", topic = "curing", shipped = false },
{ key = "curing.diag", default = true, type = "boolean", topic = "curing", shipped = false,
  detail = "Send DIAG when the affliction list is in doubt -- which is what answers `loki`, "
       .. "the one affliction GMCP does not report honestly." },
{ key = "curing.clotThreshold", default = 30, type = "number", topic = "curing",
  shipped = false, detail = "Bleeding above this is clotted." },
{ key = "curing.focusGuilt", default = false, type = "boolean", topic = "curing",
  shipped = false },
{ key = "curing.elixirConfirm", default = 7.0, type = "number", unit = "s", topic = "curing",
  shipped = false },
{ key = "curing.mossConfirm", default = 9.0, type = "number", unit = "s", topic = "curing",
  shipped = false },
{ key = "curing.riftConfirm", default = 1.5, type = "number", unit = "s", topic = "curing",
  shipped = false },
{ key = "curing.restock", default = true, type = "boolean", topic = "curing", shipped = false,
  detail = "Pull consumables out of the rift as they run low." },
{ key = "curing.restockEvery", default = 1, type = "number", unit = "ticks", topic = "curing",
  shipped = false, detail = "Every prompt by default. It used to be every tenth, which made "
       .. "each pull ten prompts apart for no benefit -- only one pull can be in flight "
       .. "anyway." },
{ key = "curing.restockSalves", default = false, type = "boolean", topic = "curing",
  shipped = false },
{ key = "curing.stockTarget", default = 1, type = "number", topic = "curing", shipped = false,
  detail = "How many of each consumable to keep in hand." },
{ key = "curing.recovery.<vector>", default = "per vector", type = "number", unit = "s",
  topic = "curing", shipped = false,
  detail = "Override the fallback recovery time for one vector, e.g. curing.recovery.herb." },
{ key = "priorities", default = "{}", type = "table", topic = "curing", shipped = true,
  detail = "Per-affliction, per-vector rank overrides. Written by `emset prio`." },

-- defences
{ key = "defences.enabled", default = false, type = "boolean", topic = "curing",
  shipped = true },
{ key = "defences.keepup", default = "{}", type = "table", topic = "curing", shipped = true,
  detail = "name -> \"defup\" or \"keepup\". Written by the defence grid." },
{ key = "defences.commands", default = "{}", type = "table", topic = "curing", shipped = false,
  detail = "name -> the command that raises it, for defences we ship no command for." },

-- walker
{ key = "walker.avoid", default = "{}", type = "table", topic = "combat", shipped = true },
{ key = "walker.auto", default = true, type = "boolean", topic = "combat", shipped = true },
{ key = "walker.stepDelay", default = 0.6, type = "number", unit = "s", topic = "combat",
  shipped = true, detail = "0.1 to 30." },
{ key = "walker.returnToStart", default = true, type = "boolean", topic = "combat",
  shipped = false, detail = "Toggled in-session by `emset walk return`; not persisted." },
{ key = "walker.stopBelowHealth", default = 40, type = "number", unit = "%", topic = "combat",
  shipped = false },
{ key = "walker.stopOnPlayer", default = false, type = "boolean", topic = "combat",
  shipped = false },
{ key = "walker.transitTimeout", default = 8.0, type = "number", unit = "s", topic = "combat",
  shipped = false },

-- bashing
{ key = "bashing.attack", default = "angel sear", type = "string", topic = "combat",
  shipped = true },
{ key = "bashing.balance", default = "both", type = "string", topic = "combat", shipped = true,
  detail = "What the attack REQUIRES: eq, bal or both." },
{ key = "bashing.consumes", default = "eq", type = "string", topic = "combat", shipped = true,
  detail = "What the attack SPENDS: eq or bal. Not the same question as `balance`." },
{ key = "bashing.stopBelowHealth", default = 50, type = "number", unit = "%", topic = "combat",
  shipped = true, detail = "Zero disables the floor." },
{ key = "bashing.maxAttempts", default = 40, type = "number", topic = "combat", shipped = true },
{ key = "bashing.walkWhenClear", default = true, type = "boolean", topic = "combat",
  shipped = true },
{ key = "bashing.stopOnPlayer", default = false, type = "boolean", topic = "combat",
  shipped = true },
{ key = "bashing.soloOnly", default = true, type = "boolean", topic = "combat",
  shipped = false },
{ key = "bashing.resumeMargin", default = 10, type = "number", unit = "points",
  topic = "combat", shipped = false,
  detail = "How far above the health floor to recover before resuming." },
{ key = "bashing.penitence", default = true, type = "boolean", topic = "combat",
  shipped = false, detail = "Priest only." },
{ key = "bashing.desolation", default = true, type = "boolean", topic = "combat",
  shipped = false, detail = "Priest only." },

-- pvp
{ key = "pvp.stopBelowHealth", default = 60, type = "number", unit = "%", topic = "combat",
  shipped = true, detail = "Higher than the bashing floor on purpose." },
{ key = "pvp.verses", default = true, type = "boolean", topic = "combat", shipped = false,
  detail = "Recite Zeal verses to apply afflictions." },
{ key = "pvp.attackAtAfflictions", default = 2, type = "number", topic = "combat",
  shipped = false, detail = "Switch from afflicting to damage at this many stacked." },

-- watch
{ key = "watch.critical", default = 30, type = "number", unit = "%", topic = "combat",
  shipped = false, detail = "The floor everything stops at. Zero disables it." },
{ key = "watch.damageSpike", default = 25, type = "number", unit = "%", topic = "combat",
  shipped = false },
{ key = "watch.damageWindow", default = 10, type = "number", unit = "ticks", topic = "combat",
  shipped = false },
{ key = "watch.damageSpikeBelow", default = 60, type = "number", unit = "%", topic = "combat",
  shipped = false },
{ key = "watch.endurance", default = 15, type = "number", unit = "%", topic = "combat",
  shipped = false },
{ key = "watch.willpower", default = 15, type = "number", unit = "%", topic = "combat",
  shipped = false },
{ key = "watch.mana", default = 10, type = "number", unit = "%", topic = "combat",
  shipped = false },
{ key = "watch.resource", default = 10, type = "number", unit = "%", topic = "combat",
  shipped = false },

-- keys, denizens, loot, shop, pipes, namedb, names
{ key = "keys.numpad", default = true, type = "boolean", topic = "combat", shipped = true },
{ key = "denizens.autoRecord", default = true, type = "boolean", topic = "combat",
  shipped = true },
{ key = "loot.gold", default = true, type = "boolean", topic = "economy", shipped = true },
{ key = "loot.aloneOnly", default = true, type = "boolean", topic = "economy",
  shipped = false, detail = "Only lift gold with nobody else in the room." },
{ key = "loot.ownKillsOnly", default = false, type = "boolean", topic = "economy",
  shipped = false },
{ key = "loot.noDenizens", default = true, type = "boolean", topic = "economy",
  shipped = false, detail = "Do not stop to loot while something is still alive." },
{ key = "loot.stowIn", default = "backpack452292", type = "string", topic = "economy",
  shipped = false, detail = "Where gold goes. This default is one character's backpack id "
       .. "and will not be yours." },
{ key = "shop.stowIn", default = "(caller's choice)", type = "string", topic = "economy",
  shipped = false },
{ key = "shop.confirmAbove", default = "(unset)", type = "number", unit = "gp",
  topic = "economy", shipped = false, detail = "Written by `emset shop limit`." },
{ key = "pipes.enabled", default = true, type = "boolean", topic = "economy", shipped = false },
{ key = "pipes.assign", default = "(unset)", type = "table", topic = "economy",
  shipped = false, detail = "Which herb goes in which pipe." },
{ key = "pipes.poll", default = 300, type = "number", unit = "s", topic = "economy",
  shipped = false },
{ key = "namedb.capture", default = true, type = "boolean", topic = "people", shipped = true },
{ key = "namedb.autoFetch", default = true, type = "boolean", topic = "people",
  shipped = true, detail = "Look names up against the Achaea web API automatically." },
{ key = "names.enabled", default = true, type = "boolean", topic = "people", shipped = true },
{ key = "names.cityTint", default = true, type = "boolean", topic = "people", shipped = true },
}

-- ---------------------------------------------------------------------------
-- key bindings
-- ---------------------------------------------------------------------------

--- Read from keys.lua rather than transcribed, so the two cannot disagree. Falls back to an
--- empty table if that module failed to load, which is better than printing a stale copy.
function M.keys()
   local keys = emunah.keys
   return {
      numpad = keys and keys.LAYOUT or {},
      actions = keys and keys.ACTIONS or {},
   }
end

-- ---------------------------------------------------------------------------
-- lookup
-- ---------------------------------------------------------------------------

--- The first word of a syntax string that is not the prefix -- "emset defs mode <n>" -> "defs".
local function keyword(syntax)
   local rest = syntax:gsub("^emset%s+", ""):gsub("^emunah%s+", "")
   return (rest:match("^(%S+)") or ""):lower()
end

--- Every entry, flattened, with its topic attached.
function M.entries()
   local out = {}
   for _, topic in ipairs(M.topics) do
      for _, entry in ipairs(topic.entries) do
         out[#out + 1] = { entry = entry, topic = topic }
      end
   end
   return out
end

function M.topicById(id)
   id = tostring(id or ""):lower()
   for _, topic in ipairs(M.topics) do
      if topic.id == id or topic.title:lower() == id then return topic end
   end
   return nil
end

--- Find entries matching what the user typed.
---
--- Exact syntax first, then exact keyword, then prefix -- so `emhelp defs` lands on the
--- `defs` family rather than on whatever happens to mention the word first.
--- @return table list of entries, table|nil the single exact match
function M.find(query)
   query = tostring(query or ""):lower():gsub("^emset%s+", ""):gsub("^emunah%s+", "")
   if query == "" then return {}, nil end

   local exact, byKeyword, byPrefix = nil, {}, {}
   for _, row in ipairs(M.entries()) do
      local syntax = row.entry.syntax:lower()
      local bare = syntax:gsub("^emset%s+", ""):gsub("^emunah%s+", "")
      if bare == query or syntax == query then
         exact = exact or row
      end
      if keyword(row.entry.syntax) == query or (row.entry.alias or ""):lower() == query then
         byKeyword[#byKeyword + 1] = row
      elseif bare:find(query, 1, true) == 1 then
         byPrefix[#byPrefix + 1] = row
      end
   end

   -- A single match goes straight to the card; several get listed, even when one of them is
   -- an exact hit. `emhelp bash` should show the five bash commands rather than silently
   -- picking the bare report and hiding `attack`, `balance`, `consumes` and `health` --
   -- which is exactly the shape of thing the old help was bad at.
   if #byKeyword > 0 then return byKeyword, (#byKeyword == 1 and byKeyword[1] or nil) end
   if #byPrefix > 0 then return byPrefix, (#byPrefix == 1 and byPrefix[1] or nil) end
   if exact then return { exact }, exact end
   return {}, nil
end

--- Everything mentioning a word, across syntax, summary, detail and settings.
function M.search(word)
   word = tostring(word or ""):lower()
   if word == "" then return {} end

   local out = {}
   for _, row in ipairs(M.entries()) do
      local entry = row.entry
      local haystack = table.concat({
         entry.syntax, entry.summary or "", entry.detail or "",
         table.concat(entry.settings or {}, " "), entry.alias or "",
      }, " "):lower()
      if haystack:find(word, 1, true) then out[#out + 1] = row end
   end
   return out
end

function M.setting(key)
   key = tostring(key or ""):lower()
   for _, spec in ipairs(M.settings) do
      if spec.key:lower() == key then return spec end
   end
   return nil
end

--- Every setting belonging to a topic.
function M.settingsFor(topicId)
   local out = {}
   for _, spec in ipairs(M.settings) do
      if spec.topic == topicId then out[#out + 1] = spec end
   end
   return out
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------
--
-- The decho/theme dialect, matching the name database and the defence grid rather than the
-- sixteen `<ansi_*>` names the older handlers use. ASCII box drawing only, like everything
-- else here.

local WIDTH = 74

local function dim(text)    return theme.dc("textDim") .. tostring(text) end
local function faint(text)  return theme.dc("inactive") .. tostring(text) end
local function bright(text) return theme.dc("textBright") .. tostring(text) end

local function rule()
   decho("\n  " .. faint(string.rep("-", WIDTH)))
end

local function title(text, right)
   local pad = WIDTH - #text - #(right or "") - 4
   if pad < 1 then pad = 1 end
   decho(string.format("\n  %s-- %s %s%s",
      theme.dc("borderLit"), bright(text), faint(string.rep("-", pad)),
      right and (" " .. dim(right)) or ""))
end

--- A clickable `emhelp ...` line. Every list this module prints is navigable, which is the
--- whole argument for a help system in a MUD client rather than a page on a website: the
--- thing you want next is one click away from the thing you are reading.
local function jump(text, target, hint)
   dechoLink(text, string.format("emunah.commands.dispatch(%q)", "emhelp " .. target),
      hint or ("emhelp " .. target), true)
end

--- Wrap a paragraph to the panel width, indented.
local function paragraph(text, indent, colour)
   indent = indent or "  "
   local limit = WIDTH - #indent
   local line = {}
   local length = 0
   decho("\n" .. indent .. (colour or theme.dc("text")))
   for word in tostring(text):gmatch("%S+") do
      if length > 0 and length + #word + 1 > limit then
         decho(table.concat(line, " "))
         decho("\n" .. indent .. (colour or theme.dc("text")))
         line, length = {}, 0
      end
      line[#line + 1] = word
      length = length + #word + 1
   end
   if #line > 0 then decho(table.concat(line, " ")) end
end

--- One entry as a single line in a list.
---
--- The padding is a MINIMUM, not a column: `%-38s` on a syntax longer than 38 characters
--- pads to nothing at all, and "emset mobs add|remove|skip|kill <name>edit the per-area kill
--- list" is what that looks like. A syntax that overruns pushes its summary along rather than
--- running into it.
local SYNTAX_WIDTH = 38

local function listLine(entry)
   local syntax = entry.syntax
   local padded = syntax
   if #padded < SYNTAX_WIDTH then
      padded = padded .. string.rep(" ", SYNTAX_WIDTH - #padded)
   else
      padded = padded .. "  "
   end

   decho("\n  ")
   jump(theme.dc("balance") .. padded, syntax, "Show the full entry for " .. syntax)
   decho(dim(entry.summary or ""))
end

-- ---------------------------------------------------------------------------

--- The index: every topic, with a count and a clickable name.
function M.renderIndex()
   title("Emunah " .. (emunah._version or "?"), "emhelp <topic> | <command> | search <word>")

   local total = 0
   for _, topic in ipairs(M.topics) do
      total = total + #topic.entries
      decho("\n  ")
      jump(string.format("%s%-14s", theme.dc("balance"), topic.id), topic.id,
         "Show the " .. topic.title .. " commands")
      decho(string.format("%s%-3d %s", faint(""), #topic.entries, dim(topic.blurb)))
   end

   rule()
   decho("\n  " .. dim("also  "))
   jump(theme.dc("balance") .. "settings", "settings", "Every setting, with its current value")
   decho(dim("  "))
   jump(theme.dc("balance") .. "keys", "keys", "Key bindings")
   decho(dim("  "))
   jump(theme.dc("balance") .. "all", "all", "Everything, in one page")
   decho(dim("  "))
   jump(theme.dc("balance") .. "search <word>", "search", "Find a command by what it does")

   decho("\n  " .. faint(string.format(
      "%d commands. `emunah` or `emset` -- same dispatcher; a few have a bare form of their own.",
      total)))
end

--- One topic: every command in it, one line each.
function M.renderTopic(topic)
   title(topic.title, string.format("%d commands", #topic.entries))
   paragraph(topic.blurb, "  ", theme.dc("textDim"))
   decho("\n")
   for _, entry in ipairs(topic.entries) do listLine(entry) end

   local settings = M.settingsFor(topic.id)
   if #settings > 0 then
      decho("\n  ")
      jump(theme.dc("balance") .. string.format("%d settings", #settings),
         "settings " .. topic.id, "Settings for " .. topic.title)
   end
end

--- The full card for one command.
function M.renderEntry(entry, topic)
   title(entry.syntax, topic and topic.title or nil)

   if entry.alias then
      decho("\n  " .. dim("bare form   ") .. theme.dc("defence") .. entry.alias)
   end

   if entry.summary then paragraph(entry.summary, "  ", theme.dc("textBright")) end
   if entry.detail then
      decho("\n")
      paragraph(entry.detail, "  ", theme.dc("text"))
   end

   if entry.args and #entry.args > 0 then
      decho("\n\n  " .. dim("arguments"))
      for _, pair in ipairs(entry.args) do
         decho(string.format("\n    %s%-16s%s%s",
            theme.dc("balance"), pair[1], theme.dc("textDim"), pair[2]))
      end
   end

   if entry.examples and #entry.examples > 0 then
      decho("\n\n  " .. dim("examples"))
      for _, example in ipairs(entry.examples) do
         decho("\n    " .. theme.dc("defence") .. example)
      end
   end

   if entry.settings and #entry.settings > 0 then
      decho("\n\n  " .. dim("settings"))
      for _, key in ipairs(entry.settings) do
         local spec = M.setting(key)
         local current = emunah.config.get(key)
         if current == nil then current = "(unset)" end
         if type(current) == "table" then current = "(table)" end
         decho(string.format("\n    %s%-28s%s%-14s%s",
            theme.dc("balance"), key,
            theme.dc("text"), tostring(current),
            faint(spec and ("default " .. tostring(spec.default)) or "undocumented")))
      end
   end

   if entry.see and #entry.see > 0 then
      decho("\n\n  " .. dim("see also"))
      for _, other in ipairs(entry.see) do
         decho("\n    ")
         jump(theme.dc("balance") .. other, other, "Show " .. other)
      end
   end
end

--- Several matches for one query: list them rather than guessing.
function M.renderMatches(rows, heading)
   title(heading, string.format("%d matches", #rows))
   for _, row in ipairs(rows) do listLine(row.entry) end
end

--- The settings reference.
--- @param filter string|nil a topic id, or a key (or key prefix)
function M.renderSettings(filter)
   filter = filter and tostring(filter):lower() or nil

   local topic = filter and M.topicById(filter)
   local shown = {}
   for _, spec in ipairs(M.settings) do
      local match = true
      if topic then
         match = (spec.topic == topic.id)
      elseif filter then
         match = spec.key:lower():find(filter, 1, true) == 1
      end
      if match then shown[#shown + 1] = spec end
   end

   title("Settings" .. (filter and (" -- " .. filter) or ""),
      string.format("%d keys", #shown))

   if #shown == 0 then
      decho("\n  " .. theme.dc("warning") .. "Nothing matches " .. tostring(filter) .. ".")
      return
   end

   decho("\n  " .. faint("* = differs from the shipped default   + = not in the defaults file"))
   decho("\n")

   for _, spec in ipairs(shown) do
      local current = emunah.config.get(spec.key)
      local shownValue
      if current == nil then
         shownValue = "(unset)"
      elseif type(current) == "table" then
         shownValue = "(table)"
      else
         shownValue = tostring(current)
      end

      local changed = (current ~= nil and tostring(current) ~= tostring(spec.default))
      local marks = (changed and "*" or " ") .. (spec.shipped and " " or "+")

      decho(string.format("\n  %s%s %s%-30s%s%-16s%s",
         theme.dc("warning"), marks,
         theme.dc("balance"), spec.key,
         changed and theme.dc("textBright") or theme.dc("text"), shownValue,
         faint(tostring(spec.default) .. (spec.unit and (" " .. spec.unit) or ""))))

      if spec.detail and filter then
         paragraph(spec.detail, "        ", theme.dc("textDim"))
      end
   end

   if not filter then
      decho("\n")
      decho("\n  " .. dim("Pass a topic or a key for the explanations: "))
      jump(theme.dc("balance") .. "emhelp settings curing", "settings curing",
         "Settings for curing, with explanations")
   end
   decho("\n  " .. faint("Change one with `emset set <key> <value>`."))
end

--- The key bindings.
function M.renderKeys()
   local bindings = M.keys()
   title("Key bindings", "emset keys on|off|rebuild")

   local numpad = bindings.numpad
   if next(numpad) == nil then
      decho("\n  " .. theme.dc("warning") .. "The keys module is not loaded.")
      return
   end

   paragraph("The numpad, bound twice -- once for Num Lock on and once for off -- because "
      .. "which of the two a keyboard sends is not something we get to choose.",
      "  ", theme.dc("textDim"))

   -- Drawn as the pad itself. A list of "7 = northwest" is a lookup table; the shape is the
   -- thing that is actually memorable.
   local GRID = {
      { "7", "8", "9" },
      { "4", "5", "6" },
      { "1", "2", "3" },
      { "0", ".", "" },
      { "+", "-", "" },
   }
   decho("\n")
   for _, line in ipairs(GRID) do
      decho("\n    ")
      for _, key in ipairs(line) do
         if key ~= "" then
            local action = numpad[key] or "-"
            decho(string.format("%s%-3s%s%-10s", theme.dc("balance"), key,
               theme.dc("text"), tostring(action)))
         end
      end
   end

   local actions = bindings.actions
   if next(actions) ~= nil then
      decho("\n\n  " .. dim("function keys"))
      local names = {}
      for name in pairs(actions) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do
         local action = actions[name]
         decho(string.format("\n    %s%-12s%s%s",
            theme.dc("balance"), name, theme.dc("text"),
            type(action) == "table" and (action.describe or action.command or "?")
               or tostring(action)))
      end
   end
end

--- Everything, in one page.
function M.renderAll()
   for _, topic in ipairs(M.topics) do
      M.renderTopic(topic)
      decho("\n")
   end
end

--- The bare `emunah` list: whatever is flagged `quick`.
function M.renderQuick()
   title("Emunah " .. (emunah._version or "?"), "emhelp for everything")
   for _, row in ipairs(M.entries()) do
      if row.entry.quick then listLine(row.entry) end
   end
   decho("\n  " .. faint("`emunah` or `emset` -- same thing. "))
   jump(theme.dc("balance") .. "emhelp", "", "The full index")
end

-- ---------------------------------------------------------------------------
-- entry point
-- ---------------------------------------------------------------------------

--- `emhelp <args>`. The one function commands.lua calls.
function M.render(args)
   args = emunah.util.trim(args or "")

   if args == "" then return M.renderIndex() end

   local verb, rest = args:match("^(%S+)%s*(.*)$")
   verb = verb:lower()
   rest = emunah.util.trim(rest)

   if verb == "search" then
      if rest == "" then
         emunah.log.warn("Usage: emhelp search <word>")
         return
      end
      local rows = M.search(rest)
      if #rows == 0 then
         emunah.log.warn("Nothing in the help mentions %q.", rest)
         return
      end
      return M.renderMatches(rows, "Matching \"" .. rest .. "\"")
   end

   if verb == "settings" or verb == "setting" or verb == "set" then
      return M.renderSettings(rest ~= "" and rest or nil)
   end

   if verb == "keys" or verb == "keybindings" then return M.renderKeys() end
   if verb == "all" then return M.renderAll() end

   local topic = M.topicById(args)
   if topic then return M.renderTopic(topic) end

   local rows, single = M.find(args)
   if single then return M.renderEntry(single.entry, single.topic) end
   if #rows > 0 then return M.renderMatches(rows, args) end

   -- Nothing matched as a command; fall back to a search before giving up, since "emhelp
   -- gold" is a perfectly reasonable thing to type and is not a command name.
   local found = M.search(args)
   if #found > 0 then return M.renderMatches(found, "Matching \"" .. args .. "\"") end

   emunah.log.warn("No help for %q. Try `emhelp` for the index, or `emhelp search %s`.",
      args, args)
end

return M

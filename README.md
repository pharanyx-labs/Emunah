# Emunah

A client-side automation system for [Achaea](https://www.achaea.com) on
[Mudlet](https://www.mudlet.org). It tracks the game's GMCP state, renders it, decides what
the character can actually do at any moment, and drives curing, hunting and movement from
that state.

The module tree lives on disk as plain Lua and reloads with a single command, so development
happens in a normal editor with no package reimport in the loop.

```
emreload          reload every module from disk
emunah            list commands
emunah status     system and character state
```

## Requirements

- Mudlet 4.10 or later (Lua 5.1)
- An Achaea character
- Optional: the MDK package, for tabbed chat. Without it, chat renders in a single console.

## Installation

**1. Clone the repository outside your Mudlet profile directory.**

```sh
git clone <repository-url> ~/src/Emunah
```

> **Do not place the checkout inside the profile directory under the name `Emunah`, and do
> not symlink it there.** Mudlet's package manager deletes a package's own directory on
> uninstall and reinstall, and it follows symlinks — which would delete the working copy. A
> checkout inside the profile must be named `EmunahSrc`, which the bootstrap also looks for
> and the package manager never touches.

**2. Install `Emunah.xml`** through *Package Manager → Install*.

**3. Point the bootstrap at the checkout.** This is stored per profile and only needs doing
once:

```
lua EMUNAH_ROOT = "/home/you/src/Emunah"; EmunahBootstrap()
```

A successful load reports:

```
[emunah] v0.1.0 loaded -- 42 modules.
```

## Capabilities

| Area | State | Detail |
|---|---|---|
| GMCP tracking | Complete | Vitals, status, afflictions, defences, items, skills, room, channels, rift, target, time |
| Interface | Complete | Vitals strip, affliction and defence panels, tabbed chat, room and target panels, embedded map |
| Capability layer | Complete | `have.skill / item / cure / def / balance` — one gate answering "is this possible right now" |
| Curing engine | Working | Per-vector action queue, blocking-affliction handling, 117-affliction cure table |
| Healing | Working | Four sources across three independent balances, each with its own threshold |
| Rift management | Working | Stock levels maintained automatically in both directions |
| Area walker | Working | Self-driving, no mapper-script dependency |
| Hunting | Working | `emunah hunt` walks an area and clears it |
| Affliction detection | GMCP-driven | Reliable except `loki` and `blackout`, both handled — see below |
| Name database | Working | Who is a person, and whether they are an ally — `whois`, `iff`, import/export |
| PvP | Opt-in only | Targets are never auto-acquired, and an ally can never be targeted |

### Affliction detection

`Char.Afflictions` can be relied on for every affliction, in player combat as well as
against denizens, with exactly two exceptions:

| Exception | Effect | Response |
|---|---|---|
| `blackout` | No affliction updates arrive at all | Stop reconciling against a frozen feed; catch up the moment it lifts |
| `loki` | The list cannot be trusted while it is up | `DIAG` on the next balance — costs 1s of equilibrium |

Triggers still earn their place: they see an affliction the instant its message prints,
ahead of the next `Char.Afflictions` push. But they are a refinement rather than the thing
standing between this and player combat. A plausible-but-wrong pattern is worse than a
missing one — it asserts an affliction the character does not have, and the engine spends a
balance curing it — so the shipped set in `src/emunah/curing/detect/patterns.lua` contains
only patterns confirmed against real output, alongside a capture mode for growing it:

```
emunah learn on     # log candidate lines during combat
emunah learn off
emunah detect       # coverage report
```

See [docs/afflictions.md](docs/afflictions.md) for the table's structure and verification
process.

### PvP

`emunah pvp target <name>` is the only way a target is set. There is no auto-acquisition,
because `Room.Players` is knowingly incomplete — concealed opponents produce no entry at
all — and acting on an incorrect read is worse than not engaging.
`src/emunah/curing/detect/opponent.lua` tracks an opponent's afflictions from third-person
patterns, grown the same way.

## Commands

| Command | Purpose |
|---|---|
| `emunah` | Command list |
| `emunah status` | System and character state |
| `emunah cure on\|off` (or `ec`) | Toggle the curing engine |
| `emunah affs` | Tracked afflictions and their cure vectors |
| `emunah defs on\|off\|add <d>\|remove <d>\|list` | Defence keep-up |
| `emunah have [thing]` | Capability report, or a single skill/item check |
| `emunah gmcp [refresh]` | Tracked GMCP state |
| `emunah learn on\|off` | Affliction message capture |
| `emunah walk start\|stop\|pause\|auto on\|off\|delay <s>\|avoid <id>` | Area walker |
| `emunah keys [on\|off]` | Numpad movement bindings |
| `emunah mobs here\|target\|done\|add\|skip\|forget\|areas` | Per-area denizen list |
| `emunah hunt [off]` | Walk an area and clear it |
| `emunah loot [on\|off\|now]` | Collect gold from corpses |
| `emunah bash on\|off\|attack <cmd>\|balance\|health <n>` | Hunting loop only |
| `emunah pvp on\|off\|target <name>\|target off` | PvP loop |
| `emunah prio <aff> <vector> <n>` | Override a cure priority |
| `emunah set [key] [value]` | Read or write a setting |
| `emunah ui [rebuild\|reset\|show]` | Toggle, rebuild or reset the interface |
| `emunah ui map [height <n>\|on\|off\|centre\|raw]` | Map status, size and control |
| `emunah ndb set\|note\|hostile\|here\|export` | The name database, or a roster |
| `emunah whois <person>` | Everything known about one person |
| `emunah iff <person> ally\|enemy\|auto` | Declare a relationship; beats derivation |
| `emunah chat [rebuild]` | Chat capture vs rendering — which half is working |
| `emunah debug [gmcp\|handlers\|timers\|queue]` | Internals and tracing |
| `emreload` | Reload all modules from disk |

### Denizen kill lists

A denizen kind seen for the first time in an area is recorded but not automatically added
to the kill list. It is echoed as a clickable line; one click authorises killing that kind
and saves the decision to `emunah-denizens.lua`, which persists across reloads. Denizens in
the room panel are clickable toggles, and `ih` output is relinked the same way.

`emunah mobs skip <name>` and `emunah mobs kill <name>` cover scripted or bulk changes.

## Configuration

Settings persist per Mudlet profile in `emunah-config.lua`, and are read or written with
`emunah set`:

```
emunah set                             # everything currently stored
emunah set curing.healthThreshold      # one value
emunah set curing.healthThreshold 75   # write it
```

Healing thresholds are the settings most worth tuning. Four sources draw on three
independent balances, so they overlap rather than compete:

| Setting | Default | Resource |
|---|---|---|
| `curing.manaThreshold` | 85 | Sip balance (shared with health; health takes priority) |
| `curing.healthThreshold` | 80 | Sip balance |
| `curing.iridThreshold` | 68 | Moss balance |
| `curing.handsThreshold` | 50 | Equilibrium |

The configuration file carries a schema version. When a shipped default is found to be
wrong, a migration corrects the stored value on load rather than leaving it to outlive the
fix.

## Architecture

```
src/emunah.lua              bootstrap loader (manifest + reload)
src/emunah/
  core/     util log event config timers queue
  gmcp/     init vitals status afflictions defences items skills room comm ire
  have/     capabilities              -- the "is this possible" gate
  curing/   afflist curelist engine defkeepup detect/ (init, patterns, opponent)
  ui/       theme layout vitals affpanel chat roompanel map
  walker.lua                          -- area walker
  keys.lua                            -- numpad movement bindings
  denizens.lua                        -- per-area kill list, targets by replica number
  ih.lua                              -- linkifies `ih` output
  bashing.lua                         -- walk, target, attack, advance
  namedb.lua                          -- who is a person, and what are they
  pvp.lua                             -- PvP loop
  loot.lua                            -- collect gold by replica number
  class/    adapter priest            -- class interface + auto-detection
  commands.lua
test/       mock_mudlet.lua run.lua   -- 635 behavioural tests
package/    .mpackage build project
tools/      build-xml.py syntax_check.py run_tests.py
```

Three ideas carry most of the design:

**One gate for every command.** `core/act.lua` is the single place that knows when the game
will refuse an action — stunned, prone, no balance, rate-limited. Call sites declare what a
command *costs*, never when it is allowed.

**One slot per resource.** Achaea has several independent balances, so `core/queue.lua` is
not a single FIFO but one slot per vector. Eating a herb, applying a salve and drinking an
elixir can all be in flight simultaneously; two herbs cannot.

**Sent is not executed.** The game reports a balance as available until it actually runs a
command, so state alone cannot prevent a duplicate send. Every action arms a short guard on
dispatch, replaced by the exact cooldown the moment the game announces it.

Notes on the game's own mechanics — verified costs, message wording, GMCP payload shapes —
live in [docs/game/](docs/game/).

## Development

Edit any file under `src/`, then `emreload` in Mudlet. No reimport is needed.

The test suite runs the real modules against a Mudlet mock, with no client involved:

```sh
lua test/run.lua
python3 tools/run_tests.py .   # if no Lua interpreter is installed
```

Build the distributable package:

```sh
python3 tools/build-xml.py     # Emunah.xml, no toolchain required
cd package && muddle           # .mpackage; requires the muddler build tool and a JVM
```

### Testing approach

Every behavioural fix carries a regression test that would have caught the original report.
The mock is deliberately strict: each mocked Geyser class exposes only the methods the real
one has, constructor fields are validated against the legal set, and the trigger and alias
matchers implement the regex subset Mudlet actually uses rather than Lua patterns. Two
shipped bugs — a method that does not exist, and a constructor field Geyser silently ignores
— reached players because an earlier, permissive mock accepted anything.

### Implementation notes

Five failure modes specific to this environment, each avoided deliberately and pinned by a
test:

- **Handler leaks on reload.** Event handlers registered at module scope survive a reload,
  so each reload stacks a new generation on the previous one and every GMCP message is
  processed repeatedly. `core/event.lua` tracks handler ids on a registry that outlives the
  reload and tears down the previous generation first.
- **Unconditional `pcall` assignment.** Assigning the result of `pcall(require, name)`
  regardless of success installs the error string as the module, and every later call fails
  far from the real fault. A failed load aborts and rolls back.
- **Update handlers copying the wrong record.** Rebuilding an inventory entry from the
  existing record rather than the incoming one means updates never land.
- **Removing an absent element.** `table.remove(t, table.index_of(t, item))` drops the last
  element when the item is absent, silently corrupting a room list.
- **A reload that cannot reload the loader.** A load function closing over its own module
  manifest can never pick up a newly added module. `emunahReload()` re-executes the loader
  file itself, rebuilding manifest, loader and namespace together.

One Achaea-specific trap is worth stating outright: `Char.Vitals.bal` and `.eq` arrive as
the **strings** `"1"` and `"0"`. In Lua `"0"` is truthy, so `if gmcp.Char.Vitals.bal then`
evaluates true when the character has no balance. All GMCP booleans route through
`util.bool()`.

## Documentation

- [docs/game/](docs/game/) — verified Achaea mechanics, GMCP payloads and message wording
- [docs/afflictions.md](docs/afflictions.md) — the cure table's structure and verification
- [docs/roadmap.md](docs/roadmap.md) — planned work

## Licence

MIT — see [LICENSE](LICENSE).

---

Emunah is an unofficial third-party script. It is not affiliated with or endorsed by Iron
Realms Entertainment. Achaea, Dreams of Divine Lands is their trademark.

# Emunah

A client-side automation system for [Achaea](https://www.achaea.com) on
[Mudlet](https://www.mudlet.org). It tracks the game's GMCP state, renders it, decides what
the character can actually do at any moment, and drives curing, hunting and movement from
that state.

The module tree lives on disk as plain Lua and reloads with a single command, so development
happens in a normal editor with no package reimport in the loop.

```
emreload          update from GitHub's main, then reload every module from disk
emunah            list commands
emset status     system and character state
```

## Requirements

- Mudlet 4.10 or later (Lua 5.1)
- An Achaea character
- Optional: the MDK package, for tabbed chat. Without it, chat renders in a single console.

## Installation

**1. Clone the repository outside your Mudlet profile directory.**

```sh
git clone https://github.com/pharanyx-labs/Emunah.git ~/src/Emunah
```

> **Do not place the checkout inside the profile directory under the name `Emunah`, and do
> not symlink it there.** Mudlet's package manager deletes a package's own directory on
> uninstall and reinstall, and it follows symlinks — which would delete the working copy. A
> checkout inside the profile must be named `EmunahSrc`, which the bootstrap also looks for
> and the package manager never touches.

**2. Install `Emunah.xml`** through *Package Manager → Install*.

**2b. Optional: install `EmunahTriggers.xml`** the same way. It is a trigger-only package
of about 660 of the reference system's lines: affliction gained and cured, states (stun, prone, sleep,
unconscious), the reference system's prompt trigger (a backup for `Char.Vitals`), and the reference system's illusion
catchers. Each calls `emunah.curing.detect.text*` and does nothing if Emunah is not loaded.
Anti-illusion follows the reference system:
- nothing it reports counts until the prompt;
- one illusion discards the whole block;
- a cure line needs its cure in flight;
- an affliction is dropped unless the server confirms it within ~2 seconds.

Emunah's own lines get svof's per-line checks whether or not the package is installed: a
refusal (`You are paralysed and cannot move.`) counts only after a command it could be
answering, a herb balance back within 1.1s of eating is ignored, and the quit prayer counts
only after you typed QUIT. Anything ignored is marked `(i)` on its line.
Regenerate it with `python3 tools/build-trigger-package.py <reference checkout>`; don't edit it by
hand.

**3. Point the bootstrap at the checkout.** This is stored per profile and only needs doing
once:

```
lua EMUNAH_ROOT = "/home/you/src/Emunah"; EmunahBootstrap()
```

A successful load reports:

```
[emunah] v0.1.0 loaded -- 60 modules.
```

## Capabilities

| Area | State | Detail |
|---|---|---|
| GMCP tracking | Complete | Vitals, status, afflictions, defences, items, skills, room, channels, rift, target, time |
| Interface | Complete | Vitals strip, affliction and defence panels, tabbed chat, room and target panels, embedded map |
| Capability layer | Complete | `have.skill / item / cure / def / balance` — one gate answering "is this possible right now" |
| Curing engine | Working | Per-vector action queue, blocking-affliction handling, 131-affliction cure table |
| Healing | Working | Four sources across three independent balances, each with its own threshold |
| Rift management | Working | Stock levels maintained automatically in both directions |
| Area walker | Working | Self-driving, no mapper-script dependency |
| Hunting | Working | `emset hunt` walks an area and clears it |
| Affliction detection | GMCP-driven | Reliable except `loki` and `blackout`, both handled — see below |
| Name database | Working | Real data from `api.achaea.com` and HONOURS, names mined from CW/CLWHO/QW, in-scroll highlighting |
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
only patterns confirmed against real output. The optional `EmunahTriggers.xml` package adds
the reference system's lines on top, behind the reference system's anti-illusion (see Installation).

See [docs/afflictions.md](docs/afflictions.md) for the table's structure and verification
process.

### PvP

`emset pvp target <name>` is the only way a target is set. There is no auto-acquisition,
because `Room.Players` is knowingly incomplete — concealed opponents produce no entry at
all — and acting on an incorrect read is worse than not engaging.
`src/emunah/curing/detect/opponent.lua` tracks an opponent's afflictions from third-person
patterns, grown the same way.

## Commands

There is one prefix, `emset`, and one help command, `emhelp`:

```
emhelp                        the modules, and whether each is on
emhelp curing                 one module: what it does, its commands, and its settings
emset                         status
emset curing on               a command
emset curing.method minerals  a setting
```

`emhelp <module>` is the reference: it says what the module does, lists its commands, and
lists every setting with its current value. Click a setting to change it, as with the reference system's
`vconfig`. It is generated from `src/emunah/help.lua`, which the test suite checks against the
code, so a command or setting added without being documented fails `lua test/run.lua`.

| Module | Commands |
|---|---|
| system | `emset`, `emset <setting> [value]`, `emset reload`, `emset debug [gmcp\|queue\|timers\|handlers]`, `emreload` |
| curing | `emset curing [on\|off]`, `emset pause`, `emset prio <affliction> <balance> <rank>`, `sleep` |
| defences | `emset defs` (the grid), `emset defs on\|off\|add\|remove\|mode` |
| pipes | `emset pipes [on\|off\|now]` |
| manna | `emset manna` |
| hunting | `emset hunt [off]`, `emset bash [on\|off\|attack <command>]`, `emset walk [start\|stop]` |
| pvp | `emset pvp [on\|off\|target <name>\|target off]` |
| loot | `emset loot [on\|off\|now]`, `buy [qty] <number>` |
| antitheft | `emset antitheft [on\|off\|now]` |
| people | `emset whois <person>`, `emset iff <person> ally\|enemy\|auto` |
| interface | `emset ui [rebuild]`, `emset ui map on\|off` |

`emreload` still works if the command module itself fails to load. `sleep` is the game's
SLEEP, marked as yours so Emunah does not wake you out of it. `buy 50 476321` buys by the
number `WARES` showed, paying from the pack.

Typing `QUIT` or `QQ` means the client is closing: Emunah stores the pack in the rift with
`INR ALL`, then stops sending anything at all. Reconnecting, `emreload` or `emset pause`
starts it again.

### Denizen kill lists

A denizen kind seen for the first time in an area is recorded but not automatically added
to the kill list. It is echoed as a clickable line; one click authorises killing that kind
and saves the decision to `emunah-denizens.lua`, which persists across reloads. Denizens in
the room panel are clickable toggles, and `ih` output is relinked the same way.

## Configuration

Settings persist per Mudlet profile in `emunah-config.lua`. `emhelp <module>` lists them with
their current values; `emset <setting> [value]` reads or writes one:

```
emset curing.healthThreshold      # read it
emset curing.healthThreshold 75   # write it
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
  curing/   afflist curelist deflist engine defkeepup detect/ (init, patterns, opponent, diag)
  ui/       theme gag layout vitals affpanel chat roompanel map
  walker.lua                          -- area walker
  keys.lua                            -- numpad movement bindings
  denizens.lua                        -- per-area kill list, targets by replica number
  ih.lua                              -- linkifies `ih` output
  elist.lua                           -- redraws ELIST as a table by kind
  shield.lua                          -- WIELDED at login; chyron notice if no shield
  bashing.lua                         -- walk, target, attack, advance
  namedb.lua                          -- who is a person, and what are they
  namedb/api.lua                      -- api.achaea.com: real data, not inference
  namedb/capture.lua                  -- names mined from CW, CLWHO, QW, HONOURS, angel
  pvp.lua                             -- PvP loop
  loot.lua                            -- collect gold by replica number
  class/    adapter priest            -- class interface + auto-detection
  commands.lua
test/       mock_mudlet.lua run.lua   -- 1729 behavioural tests
            bench.lua profile.lua     -- per-prompt cost, and where it goes
package/    .mpackage build project
tools/      build-xml.py syntax_check.py run_tests.py
```

A full tick under an eight-affliction lock costs **79.0 µs**, down from 124.1 µs, and the
queries it leans on hardest allocate nothing at all — see
[docs/performance.md](docs/performance.md) for the measurements. The design decisions behind
the layout above, and the failure modes each one closed off, are in
[docs/design.md](docs/design.md). Notes on the game's own mechanics — verified costs, message
wording, GMCP payload shapes — live in [docs/game/](docs/game/).

## Development

Edit any file under `src/`, then `emreload` in Mudlet. No reimport is needed.

`emreload` first brings the checkout up to date with `origin main` (fast-forward only), so
a merged fix is one `emreload` away. It leaves a checkout alone when it is on another
branch or has local edits in the way, and says so. `emset system.update false` turns the
pull off for working on a local checkout.

The test suite runs the real modules against a Mudlet mock, with no client involved:

```sh
lua test/run.lua
python3 tools/run_tests.py .   # if no Lua interpreter is installed
```

The per-prompt cost is measurable without the client too. `bench.lua` reports wall time and
bytes allocated per call; `profile.lua` is a sampling profiler that names the hottest lines:

```sh
lua test/bench.lua      # engine.tick() and the queries under it
lua test/profile.lua    # where the time actually goes
```

Build the distributable package:

```sh
python3 tools/build-xml.py     # Emunah.xml, no toolchain required
cd package && muddle           # .mpackage; requires the muddler build tool and a JVM
```

Every behavioural fix carries a regression test that would have caught the original report.
See [docs/design.md](docs/design.md) for the testing approach, the five environment-specific
failure modes each fixed and pinned by a test, and the design decisions behind the module
layout above.

## Documentation

- [docs/design.md](docs/design.md) — why the code is shaped the way it is
- [docs/game/](docs/game/) — verified Achaea mechanics, GMCP payloads and message wording
- [docs/afflictions.md](docs/afflictions.md) — the cure table's structure and verification
- [docs/performance.md](docs/performance.md) — the hot paths, what they cost, and how to measure
- [docs/roadmap.md](docs/roadmap.md) — planned work
- [CHANGELOG.md](CHANGELOG.md) — substantive corrections to shipped data and behaviour
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to verify a change before it ships

## License

MIT — see [LICENSE](LICENSE).

---

Emunah is an unofficial third-party script. It is not affiliated with or endorsed by Iron
Realms Entertainment. Achaea, Dreams of Divine Lands is their trademark.

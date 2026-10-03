# Performance

Achaea combat is decided on round trips. A cure that resolves after the prompt it was
needed on is a cure that did not happen, and Mudlet runs every installed package in a
single Lua state on the UI thread — so time spent here is time the whole client is not
drawing, not reading input, and not sending.

This document records what the hot paths are, what was wrong with them, and how to measure
whether a change made things better. It is not a style guide. Everything below was measured.

## The three paths that matter

| Path | Fires on | Cost |
|---|---|---|
| Trigger matching | Every line of game output | Mudlet C++ PCRE — free to us |
| Trigger **callbacks** | Every line whose pattern matched | All of it ours |
| `engine.tick()` | Every prompt (`Char.Vitals`) | All of it ours |
| UI repaints | Every prompt, and every item/affliction/defence event | All of it ours, and Qt's |

The second and fourth rows are new. The previous version of this document listed only two
paths and asserted that the per-line one was already optimal. That was wrong, and the way it
was wrong is worth keeping:

> **The per-line path is already optimal and should stay that way.** … There is no Lua
> handler on `sysDataReceived` and there must not be one.

Literally true, and it missed the point. **A `tempRegexTrigger` whose pattern matches every
line is a per-line Lua handler with extra steps.** There were five of them.

## Time to send: the 2026-10-03 pass

Everything below this section measures what a function costs. This pass measured what a
fight is decided on, **the gap between the game allowing a command and Emunah sending it**,
with `test/latency.lua`. It found that the expensive delays were not CPU at all.

### Logic: a command held back by the system's own rules

Simulated seconds against a scripted server (RTT 0.1s) that returns a balance at a chosen
moment, announces it with the game's line, and refuses anything sent before then.

| Scenario | Before | After |
|---|---|---|
| salve, game faster than the 1.8s estimate | 600 ms late | **0 ms** |
| salve, game slower than the estimate | not sent within 6 s | **0 ms** |
| focus, game faster than the 4.5s estimate | 1510 ms late | **0 ms** |
| focus, game slower than the estimate | 4100 ms late | **0 ms** |
| voyria at 50% health | cure never sent in 20 s | **sent at once, beside the health sip** |
| herb (already announced, control) | 0 ms | 0 ms |

What caused each:

1. **Salve, focus and tree had no balance-return trigger.** They ran on their fallback
   estimate alone, which is wrong in both directions. svof's verbatim lines are now matched
   (`docs/game/balance.md`).
2. **A refused cure kept its same-affliction guard** (`engine.CURE_GUARD`, 1.5 s) and its
   queue slot until timeout, although the refusal is the game answering it. A refusal now
   frees both (`refused()` in `detect/patterns.lua`).
3. **A confirm timeout freed its vector without ticking.** Neither did `writhe.busy`, the
   stun/sleep/unconscious/arm guards, or the STAND and WAKE in-flight guards. Each now
   acts the moment it lapses (`engine.TICK_ON_EXPIRY`, `queue.timeout`, detect's
   `RETRY_ON_EXPIRY`).
4. **Affliction-healing elixirs shared the health sip's slot.** svof gives them their own
   balance (`purgative`). Healing at rank 0 starved a voyria cure for as long as health was
   low, and every drink put the sip balance out until a line that a purgative never prints.
5. **Lines after `Char.Vitals` waited for the next prompt.** The heartbeat runs on
   `Char.Vitals`. A balance announced after it in the same block was committed at the prompt
   with no tick behind it. The prompt now ticks again when lines followed `Char.Vitals`,
   and costs nothing when none did. Whether Achaea orders a block that way is not established.

### Processing: work done inside the packet, ahead of `send()`

Mudlet handles a packet start to finish on one thread before the socket write is flushed
and before anything is drawn, so every handler that runs ahead of `send()` is latency.
Measured as real Lua time with the mock's own trigger matching subtracted, plus **Qt draw
calls made before the send**, which are counted because the mock can't time them.

| Packet | Before | After |
|---|---|---|
| affliction lands (Add, Add, Vitals, prompt) | 158 µs, **10 draws** before send | **85 µs, 0 draws** |
| herb balance announced, then `Char.Vitals` | 96 µs, 5 draws | **52 µs, 0 draws** |
| herb balance announced after `Char.Vitals` | not sent this packet | **117 µs, 0 draws** |
| Draws per affliction packet | 10 | 8 (two affliction events now paint once) |
| Total Lua per packet | 83–187 µs | within ±6 µs of before: the work moved, it didn't disappear |

| `bench.lua` | Before | After |
|---|---|---|
| `engine.tick()` | 79.0 µs, 2056 B | **67.5 µs, 2000 B** |
| `engine.has()` | 0.17 µs | **0.10 µs** |

What changed:

- **Panels paint after the packet** (`theme.later()`): one zero-delay timer, coalesced per
  panel. The vitals strip used to paint on `emunah.vitals`, which runs before the tick (and
  the UI loads before the engine, so it ran first). The affliction panel painted inside
  `Char.Afflictions.Add`.
- **The engine sends each vector's cure as soon as it resolves it** (`queue.flushVector`).
  This was a wasted balance rather than a timing issue: the same-affliction guard is armed on
  send, so two vectors could choose one affliction in one tick. `apply epidermal` and `focus`
  both went out for one anorexia. svof forbids that (`doingaction`).
- **Restocking runs after the cures**, not before. It was a fifth of the tick and nothing in
  the cure loop reads it.
- **Debug output follows the send** (`act.send`, the engine loop). With `emset debug` on,
  it was a console print ahead of every command.
- `afflist.priority()` re-read the `priorities` setting 56 times a tick. It is now read once,
  per tick, with nothing cached across ticks. Rank tables are looked up once per affliction.
- `util.now()` dropped a `pcall` and a `tonumber`. `act.blocked()` stopped allocating `{}`.
  Name lookups use a memoised lowercase (`util.lower`).

The mock now dispatches events in registration order, as Mudlet does. `pairs()` order had
hidden which handler ran first.

## What it costs now

Measured with `test/bench.lua` under a realistic lock: eight afflictions tracked across
every vector, herbs in hand, health and mana below all four healing thresholds.

| | Before | After |
|---|---|---|
| `engine.tick()` | 124.1 µs | **79.0 µs** |
| `afflist.priority(aff, vector)` | 0.58 µs | **0.28 µs** |
| `afflist.curesVia(aff, vector)` | 0.22 µs | **0.09 µs** |
| `have.cure(option)` | 1.60 µs | **0.87 µs** |
| Chyron scroll step (12.5 Hz) | 47.6 µs, 4171 B | **1.7 µs, 424 B** |
| Highlighter callbacks per line | 88% of lines | **12% of lines** |

The line and chyron rows are the ones that were invisible before, and between them they are
worth more than the tick.

**A note on the byte column.** Earlier revisions of this document quoted figures like "292
bytes per tick". Those were wrong — not by a little. `bench.lua` measured
`collectgarbage("count")` either side of the loop **with the collector running**, so the
delta was "allocated minus whatever happened to be collected", which varied between 194 and
732 bytes per call across consecutive runs of identical code. The collector is now stopped
for the measured loop, the numbers are repeatable to the byte, and the honest figure for a
tick is **2037 bytes**, not 292. Do not compare the new byte column against the old one.

## What was wrong

Ordered by what it was actually costing.

### 1. The name highlighter ran on nearly every line

`ui/names.lua` registered `[A-Z][a-z]` — "contains a capitalised word" — on the reasoning
that it is the cheapest pre-filter Mudlet can apply, and that a hash lookup per word is
nothing. Both halves are true and the conclusion was still wrong, because **the pre-filter
did not filter**: in Achaea essentially every line of room description, combat text and
channel output contains a capitalised word. Measured over eight representative lines, it
matched **88% of them**, and each match ran `pcall(getCurrentLine)` plus `findNames()`'s
`%a+` walk — 21 µs of work per line at a populated roster.

The trigger is now built from the roster itself: one alternation regex, `(?:Alice|Bob|…)`,
rebuilt when `namedb.generation` changes. Still one pattern for Mudlet to match in C++, and
the callback now fires on **12% of lines** — which is the lines that actually name somebody.

No word boundaries, deliberately: the trigger is only a pre-filter, `findNames()` is what
decides what gets styled, and a substring hit costs one wasted callback rather than a wrong
highlight. Getting `\b` semantics to agree between PCRE and the test mock's Lua-pattern
translation would have been a real problem for no gain.

### 2. The chyron allocated 1875 strings a second

`ui/chyron.lua` re-rendered at 12.5 Hz for as long as any message was up — independent of
prompts, and invisible to every benchmark. Each step rebuilt the reel, ran a `gsub` copy of
the whole string to measure it, built `doubled` from four concatenations, and then walked it
calling `doubled:sub(index, index)` **per visible character**: ~140 single-byte string
allocations per step, 12.5 times a second.

None of that depends on the scroll position. The reel is now compiled once per message
change into a byte-offset index and a per-glyph colour, and a step is one `sub()` and one
concatenation. **47.6 µs → 1.7 µs.**

Equivalence was proven rather than assumed: both implementations were run over every scroll
position of a full period for three message sets, and all 532 frames matched.

### 3. Re-normalising names that were already normalised

`engine.add()` lowercases before it stores, so every key in `engine.tracked` is already
lowercase — and then `afflist.get/known/priority/isState/isWrithe/curesVia` and
`deflist.deliberate` each ran `tostring(name or ""):lower()` on it again. That is ~164 calls
per prompt at 0.149 µs, about **24 µs, a fifth of the tick**, spent turning `"paralysis"`
into `"paralysis"`.

Every one of those now tries the bare key first and normalises only on a miss. No second set
of `raw*` entry points to keep in step, and nothing to invalidate — the tables they read are
written at load and never mutated.

This is the same shape as the inventory bug in the previous pass: normalising on read what
was already normalised on write.

### 4. Asking vector-independent questions once per vector

`engine.resolve()` ran for each of six vectors and walked the whole tracked list every time,
asking `deliberate()`, `known()` and `isState()` about the same eight afflictions six times
over — plus a second full pass per idle vector for the server-cure fallback. None of those
three questions depends on the vector.

They are now asked once per tick, in `classify()`, which sorts the tracked list into
"curable" and "afflist has never heard of it". The vector loop reads the result. 53
`deliberate()` calls per prompt became 8.

### 5. Panels repainting when nothing had changed, one row at a time

No panel used a dirty flag, and each emitted **one `decho` per row** — thirty-odd separate
Qt rich-text parses to draw one defence grid. `ui/roompanel.lua` rebuilt completely on every
`Char.Items.Add`, so a restock pulling five herbs into inventory repainted the room five
times. `ui/vitals.lua` called `setStyleSheet` for both balance lights on every prompt
regardless of whether either had changed, and redrew the **entire strip** on every cure timer
lapsing.

Now:

- each panel builds its whole body and issues one draw call (`theme.paint()`);
- a body byte-identical to what is displayed is not drawn at all;
- the balance lights are restyled only when they change, from precomputed stylesheets;
- `emunah.timer.expired` refreshes the vector lights and nothing else.

**Repaints were not deferred to a timer.** Coalescing onto the next tick would let a panel sit
stale whenever events arrive without a prompt behind them, and would make every assertion
about panel contents depend on advancing a clock. Comparing the rendered result gets the same
saving with neither problem.

### 6. Smaller things, each real

- `theme.dc()` parsed a hex string and formatted a new one **on every call** — 0.94 µs, and
  `ui/roompanel.lua` reaches it fourteen times per repaint. Memoised; the palette is a
  constant.
- `ire.riftFind()` fell back to a linear scan of the whole rift whenever the query was a
  `desc` rather than a key — which is the *common* case ("irid" for an entry keyed "irid
  moss"), and `have.inRift()` is called fifteen times per prompt. Now an alias index, rebuilt
  at the same sites that write the rift.
- `have.blockedBy()` walked a nested table looking for one vector, eleven times per prompt
  plus five per repaint. Now a reverse index built once.
- `namedb/capture.lua`'s line buffer did `table.remove(buffer, 1)` — a sixteen-element
  memmove **per line of game output, forever**. Now a ring with a write cursor.
- `gmcp/vitals.lua` allocated two tables and ~15 strings parsing `charstats` on every prompt,
  and a fresh six-key snapshot table besides. Both filled in place now, with a sweep so a
  stat the class no longer reports cannot linger.
- `items.attrib()` allocated a fourteen-key table and ran fourteen `string.find`s per item
  per repaint. Cached on the attrib string itself — Achaea uses a handful of them.
- `util.trim()` chained two `gsub`s, building two strings to return one. One `match` now.
- `bashing.lua` registered three separate `emunah.tick` handlers. One.

### Three per-line triggers left alone, on purpose

`namedb/capture.lua` and `curing/detect/diag.lua` register three more bare-`^` triggers.
Each early-outs on a single table lookup, and the registration ORDER of the capture triggers
is load-bearing — it is what makes the accounting pass judge the line the listing patterns
have already had their chance at (see the comment above them). Registering them on demand
would save a Lua dispatch and risk that ordering. Not worth it; recorded here so the next
person does not have to re-derive it.

## Measuring

```sh
lua5.1 test/latency.lua [iterations] # time from the game allowing a command to sending it
lua5.1 test/bench.lua [iterations]   # wall time and bytes per call
lua5.1 test/profile.lua [iterations] # sampling profiler, hottest lines
lua5.1 test/run.lua                  # includes the draw-call budget assertions
```

Mudlet runs Lua 5.1. Measure with `lua5.1`; the default `lua` on many systems is 5.4, which
has a different allocator and VM.

Four traps, all of which produced confidently wrong numbers before they were noticed:

**`os.clock` is stubbed.** `mock.install()` replaces it with the manually-advanced test
clock so cooldown maths is deterministic. Timing against it measures the fake clock — the
first version of `bench.lua` reported a flat "250000 µs/call" because it stepped the clock
0.25 s per iteration. Use `mock.realClock`.

**The profiler's own timings are meaningless.** `debug.sethook` at a 1000-instruction
interval dominates the wall clock. Its *relative* sample counts are what to read.

**The collector must be stopped to measure allocation.** See the note under "What it costs
now". `bench()` does this; anything measuring bytes by hand must too.

**Per-line and UI costs cannot be timed through the mock, only counted.** `mock.line()`
matches with `string.find` against a translated pattern, which is nothing like PCRE's cost,
and the Geyser stub makes a `decho` a string assignment. So both are measured as **counts**:
how many callbacks a line provokes, how many draw calls a repaint issues. The count is what
transfers to Mudlet; the time is not. `mock.countDraws()` is the entry point.

There is no clean committed baseline to `git stash` against — a large part of the system is
still uncommitted, so reverting only the tracked files produces a mix that does not run.
Before/after here means running the same `bench.lua` against the same checkout before and
after a change.

## Rules for changes

- **Nothing draws before the cure is sent.** A panel asks `theme.later()` to paint it.
  `test/run.lua` asserts zero draws ahead of the send.
- **Anything that frees a gate must tick.** A balance line, a timer lapsing, a confirm
  timing out or a refusal is the moment a command becomes possible. If nothing ticks, it
  waits for an unrelated prompt, and when idle none arrives.
- **Every balance that announces its return is matched.** A fallback estimate is only a
  net for a missed line.
- **Log after the send, never before it.**

- **A trigger pattern that matches most lines is a per-line Lua handler.** Before adding a
  `tempRegexTrigger`, ask what fraction of real output it matches. If the answer is "most",
  it needs to be narrowed or driven from data, not accepted because matching is cheap.
- **Nothing per-line in Lua that a pattern could have excluded.**
- **Cache against a generation, not a timestamp.** A time-based cache in a curing system is
  a stale-state bug waiting for a fight to expose it. Bump a counter at the mutation site.
- **Every memo needs an invalidation test**, written to prime the cache first.
- **Prefer a shared read-only constant to a fresh empty table**, and never hand one to
  something that mutates.
- **A panel draws once, or not at all.** One `decho` per repaint, and no repaint when the
  rendered body is unchanged. `test/run.lua` asserts both.
- **Declare a memo's `local` above every function that touches it.** A cache declared below
  its own invalidator leaves that invalidator clearing a nil global — silently.
- **Measure before and after, and check the metric is real.** Three of the four traps above
  were found by a number that looked plausible.

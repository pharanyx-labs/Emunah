# The affliction table

`src/emunah/curing/afflist.lua` maps 117 afflictions to the cures that remove them, the
vector each cure runs on, and the priority of each within that vector. `curing/engine.lua`
resolves one cure per vector per tick from this data alone.

A cure table is only as trustworthy as its verification, so this document covers the
structure, how entries are checked, how to extend it, and what remains unresolved.

## Structure

```lua
paralysis = {
   cures = { { vector = "herb", item = "bloodroot", alt = "magnesium" } },
   priority = { herb = 6 },
},

mangledleftleg = {
   cures = { { vector = "salve", item = "restoration", alt = "reconstructive",
               location = "legs" } },
   priority = { salve = 14 },
},

anorexia = {
   cures = { { vector = "salve", item = "epidermal", alt = "sensory", location = "body" },
             { vector = "focus" } },
   priority = { salve = 1, focus = 2 },
},
```

| Field | Meaning |
|---|---|
| `vector` | The balance the cure runs on: `herb`, `salve`, `smoke`, `elixir`, `focus`, `moss`, `tree` |
| `item` | The herb, salve or elixir consumed |
| `alt` | The Alchemist equivalent, used when `curing.method` is `minerals` |
| `location` | The body part for `APPLY` |
| `priority` | Rank within each vector. **Rank 1 is most urgent.** Integers; gaps are fine |

Cures are listed in preference order, so an affliction curable two ways takes the first
option whose vector and item are actually available.

## Priorities are per-vector, not global

This is the part most often got wrong, and the reason the table looks unusual.

There is no single ordering of afflictions by urgency, because the vectors run in parallel.
The most urgent thing to *eat* and the most urgent thing to *apply* are unrelated questions.
Collapsing them into one list means a high-priority salve cure occupies the tick while a
herb cure that could have gone out simultaneously, for free, waits — and Achaea combat is
won largely on that throughput.

`engine.tick()` therefore resolves one cure per vector per tick, each against its own
ranking.

## Blocking afflictions

Three afflictions shut a whole vector:

```lua
M.blocks = {
   anorexia  = { "herb", "moss" },   -- cannot eat
   slickness = { "salve" },          -- cannot apply
   asthma    = { "smoke" },          -- cannot smoke
}
```

Each is cured by a vector that another one blocks:

- **anorexia** → apply epidermal, or `FOCUS`
- **slickness** → smoke valerian, or eat bloodroot
- **asthma** → eat kelp

With all three active, every item vector is shut and `FOCUS` is the only way out. That is
why `focus` ranks anorexia second in its own list, and why `have.blockedBy()` is consulted
before any cure is queued — without it the engine sends `eat kelp` while anorexic,
indefinitely.

Stated plainly because it is counter-intuitive and it is the single most common mistake in
a hand-written cure table: **anorexia is cured by applying a salve, not by eating
anything.**

Anorexia blocks two vectors because eating is two balances — herbs and irid moss recover
independently. It does not block `OUTR`, so pulling moss from the rift continues while
anorexic.

## Extending the table

**Adding an affliction.** Add an entry with its cure and a rank within that vector's list.

**Changing a priority without editing the table.** `emunah prio <affliction> <vector> <n>`
is stored in the profile config and applied by `afflist.priority()` ahead of the built-in
value.

**Adding detection patterns.** See `src/emunah/curing/detect/patterns.lua`. Grow the corpus
from `emunah learn on` output rather than from memory, and anchor every pattern with `^` and
`$` — an unanchored pattern matches the same words quoted back in a tell.

The rule throughout: **a plausible-but-wrong entry is worse than a missing one.** A gap is
visible and inert. A wrong mapping is invisible and the engine acts on it, spending a
balance at the moment it was needed. Where a fact is not confirmed, it is recorded as open
below rather than guessed.

## Verification

Entries are checked against three kinds of source, in descending order of authority:

1. **In-game observation** — GMCP payloads and game output captured during play. Settles
   anything the other two cannot.
2. **Achaea's published help** — the affliction/cure table at
   `game-help/?what=afflictions-and-what-cures-them` and the curatives glossary at
   `game-help/?what=curatives-and-what-they-cure-or-cause.`, plus *A Lesson in Herbs*.
   Authoritative on cure mappings, silent on priority ordering.
3. **Independent implementations** — corroboration only, and only for facts about the game
   rather than tactical judgement. Two implementations agreeing on a GMCP affliction name is
   evidence; their choice of what to cure first is not.

Around 75 of the table's entries match the published help exactly on both vector and item,
including all four tempered-humour states, the four limb-severity families, and the
epidermal cluster. Several confirmed name variants are recorded where Achaea's display name
differs from its GMCP name: `inlove` is "Lover's Effect", `waterbubble` is "Drowning",
`weakness` is "Weariness".

### Stack counts in GMCP names

Some afflictions report with a live count embedded in the name string —
`"temperedsanguine (2)"` rather than `"temperedsanguine"`. `gmcp/afflictions.lua` strips the
suffix before the name is used as a lookup key and keeps the count available through
`gmcp.afflictions.stacks(name)`. Without that, every stacking affliction is untrackable
under any spelling, because no table key ever matches.

## Open questions

None of these block normal use; the engine has fought on this table extensively. They are
the concrete items to settle before relying on the data more heavily in PvP.

**1. Five entries may be defences rather than afflictions.** `frost`, `levitation`, `mass`,
`speed` and `venom` are each listed as cured by drinking or applying an item of the same
name. The curatives glossary describes all five items as proactive buffs — "Speed: increases
ability to dodge physical attacks", "Mass: prevents unwilling movement" — rather than
reactive cures. The control case is `voyria`, which the glossary *does* confirm as a cure
("Immunity: cures voyria venom"), and which reads differently from the other five.
`curing/defkeepup.lua` independently lists four of the five as defences to keep up, so the
same codebase already models them as buffs elsewhere. Resolving this needs an in-game check
of what `Char.Afflictions` actually reports.

**2. A same-cure cluster of three.** `caloric`, `frozen` and `shivering` are cured
identically (`apply caloric to body`) and all plausibly map to the published "Freezing"
entry. Whether Achaea has three distinct cold-severity names is unconfirmed.

**3. Four entries have an empty priority table.** `crackedribs`, `skullfractures`,
`torntendons` and `wristfractures` are cured via salve `health` rather than
`mending`/`restoration`. An empty `priority` means `afflist.priority()` returns `nil` for
every vector, so the engine's ranked resolution can never select them. If that is
intentional — swept up by the emergency healing branch instead — it needs stating; if not,
they are silently uncurable.

**4. `unknowncrippledarm` and `unknowncrippledlimb` share `location = "arms"`.** The second
name suggests a location-agnostic fallback rather than a copy of the first.

**5. The five `*disrupt` afflictions** (`airdisrupt`, `earthdisrupt`, `firedisrupt`,
`spiritdisrupt`, `waterdisrupt`) do not appear in the published help. Likely class-specific
content the general pages do not cover — unverifiable from that source rather than known
wrong.

**6. `fear` resolves through the `focus` vector**, but the published page names the action
"Compose". Possibly terminology only, since the `focus` vector issues `FOCUS` elsewhere.

**7. Afflictions observed without cure data.** `horror`, `pyre`, `crescendo` and three
`unweaving*` effects have been seen named but have no confirmed cure, so they are absent
from the table rather than guessed into it.

## Change history

Substantive corrections to the data, most recent first.

**Stack-count handling.** Afflictions reporting as `"name (N)"` were untrackable under any
spelling. `splitStack()` in `gmcp/afflictions.lua` now strips the suffix before lookup and
retains the count.

**Humour states renamed.** `cholerichumour`, `melancholichumour`, `phlegmatichumour` and
`sanguinehumour` became `temperedcholeric`, `temperedmelancholic`, `temperedphlegmatic` and
`temperedsanguine`. The cure data was unchanged; the old keys did not match the names GMCP
reports.

**`blind` and `deaf` removed; `blindaff` and `deafaff` renamed to `blindness` and
`deafness`.** The removed entries cured blindness and deafness by eating bayberry and
hawthorn — but the curatives glossary states those herbs *cause* both conditions. The old
entries would have had the engine spend a herb balance making the affliction worse. Three
independent sources agree the real names are `blindness` and `deafness`, cured by applying
epidermal, which is what the renamed entries already did. Note that `defkeepup.lua` models a
same-named `blind`/`deaf` pair as defensive *skills* — an unrelated table.

**Eight herb-vector afflictions added.** Corroborated against an independent affliction
dictionary keyed directly on `Char.Afflictions.Add.name`. No priority data existed for any
of them, so each was appended after the existing ranked herb list rather than guessed into
the middle of it. Re-rank them once one has actually needed curing in a fight.

**Opponent detection seeded.** `curing/detect/opponent_patterns.lua` gained 14 third-person
symptom patterns and 2 cure confirmations. Filtered to passive, unambiguous symptom text
only — inferring an affliction from an attacker's move is a materially more speculative
technique and is deliberately not used.

**Parry-defence accumulation fixed.** GMCP sends no `Remove` for an existing
`"parrying (weapon)"` entry when a new one is granted, so defence state accumulated stale
parry entries indefinitely. `gmcp/defences.lua` clears them on add.

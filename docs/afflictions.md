# The affliction table

`src/emunah/curing/afflist.lua` maps 131 afflictions to the cures that remove them, the
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

**Changing a priority without editing the table.** `emset prio <affliction> <vector> <n>`
is stored in the profile config and applied by `afflist.priority()` ahead of the built-in
value.

**Adding detection patterns.** See `src/emunah/curing/detect/patterns.lua`. Grow the corpus
from learn-mode output (`lua emunah.curing.detect.startLearning()`) rather than from memory, and anchor every pattern with `^` and
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

**1. Five entries may be defences rather than afflictions.** *Answered by svof: its `gamename` table lists `mass` → `density`, `levitation` → `levitating`, `venom` → `poisonresist` as defences.* `frost`, `levitation`, `mass`,
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

**3. `unknowncrippledarm` and `unknowncrippledlimb` share `location = "arms"`.** The second
name suggests a location-agnostic fallback rather than a copy of the first.

**4. The five `*disrupt` afflictions** (`airdisrupt`, `earthdisrupt`, `firedisrupt`,
`spiritdisrupt`, `waterdisrupt`) do not appear in the published help. Likely class-specific
content the general pages do not cover — unverifiable from that source rather than known
wrong.

**5. (Resolved: fear now COMPOSEs first, per HELP and svof.)** `fear` resolved through the `focus` vector, but the published page names the action
"Compose", and `COMPOSE` is a real command with its own help file (`docs/game/help/compose.txt`:
"At times, you may find yourself in a state of panic ... If this happens to you, COMPOSE.").
So this is probably a different command, not a difference in wording. Unverified whether FOCUS also works.

**6. Afflictions observed without cure data.** `horror`, `pyre` and three `unweaving*`
effects have been seen named but have no confirmed cure, so they are absent from the table
rather than guessed into it. `crescendo` was in this list until 2026-08-03 -- see the change
history below.

**7. (Resolved: goldenseal restored, per HELP and svof.)** `stupidity`'s herb cure (`goldenseal`) did not work. Unlike the ~75 entries checked
against the published help, this one had no recorded provenance at all, and confirmed live
20:57:29-20:58:04 (no opponent present): the engine pulled goldenseal from the rift and ate
it every ~5 seconds for at least five cycles, and `stupidity` was still tracked after every
one. The herb option is removed; `focus` is left in place, untested by that transcript.
`AFFLICTION SHOW STUPIDITY` (the game's own reference command, confirmed to exist the same
session -- see `affpop` in `curing/detect/init.lua`) would settle both what actually cures
it and whether `focus` is right either. Note that the published table
(`docs/game/help/afflictions.txt`) *does* list `Stupidity: Eat Goldenseal / Plumbum`. The
failed eats may have landed inside herb balance (`The plant has no effect.`, see
`docs/game/balance.md`), or had the balance spent by Achaea's server-side curing
(`docs/game/curing.md`), rather than being the wrong cure.

## Change history

Substantive corrections to the data, most recent first.

**svof's per-cure conditions.** `CONDITIONS` carries the extra clauses of svof's
`isadvisable` for each cure (madness, hypochondria, focus-in-flight, limb order, and the
pairs listed in `docs/game/curing.md`). Fear lost its focus option: svof's is switched off.

**Brought in line with svof, which outranks this table on curing (user's ruling).** Fear
COMPOSEs before focusing; stupidity eats goldenseal again (rank 7); `disrupted`
CONCENTRATEs unless confused. `ALIASES` adds the server's names from svof's `gamename`
table (`lovers`, `weariness`, `pacified`, `airpocket`, `burning`, `whisperingmadness`,
`blind`, `deaf`), and `transfixation` joins the writhes. A cross-check of every cure svof
and this table share, with svof's names translated, found no other difference.

**Vector blockers brought in line with svof.** `afflist.blocks` gained `anorexia` →
`elixir`, `mucous` → `smoke`, `inquisition` → `focus`, and a `tree` block for paralysis,
each entanglement and either numb arm. The source is svof's per-balance gates
(`raw-svo.skeleton.lua`: `check_sip`, `check_smoke`, `check_focus`) and `touchtree`'s
`isadvisable` (`raw-svo.dict.lua`), which the user named as the reference. `M.wearsOff`
records the blockers that end on their own, so the "every lock has a key" test can
tell them from a real lock with no escape. The queue now re-checks these when it sends,
not only when it chooses; the full table is in `docs/game/curing.md`.

**`nausea` and `crescendo` added.** Confirmed live 2026-08-03 15:52:00-15:52:17 against a
bard in the arena: Char.Afflictions.Add carried `cure="EAT GINSENG"` for nausea and
`cure="EAT ASH"` for crescendo (the latter closing open question #6 above). Before this,
`crescendo` was untracked by design (open question #6) and `nausea` was simply never seen;
both showed up in the log only as "Tracking unknown affliction ... (no cure defined)". The
server-suggestion fallback in `curing/engine.lua` covered crescendo well enough in the same
fight, but nausea shares the herb vector with paralysis and addiction, both of which were
also up, and that fallback only runs when a vector has nothing else queued for it -- so
nausea went uncured for the rest of the bout with no entry in the table to give it a turn.

**DIAG's removal no longer waits for a fully-understood block.** `curing/detect/diag.lua`
used to skip clearing anything from `M.tracked` if even one line in a DIAG reply named an
affliction not in this table -- conservative on purpose, so a partial reading never cured
less than before. In practice the game reports far more afflictions than this table knows,
so one unmapped word in an otherwise-normal DIAG silently disabled every removal for that
reading. Confirmed live 20:57:29-20:58:04: `stupidity` sat in `M.tracked` and was re-cured
every ~5 seconds (goldenseal pulled from the rift, then `focus`) with no opponent present
for the whole stretch, because nothing ever got the chance to clear it. DIAG spends a whole
equilibrium specifically to re-establish ground truth; removal now runs unconditionally
(the `loki` exception and the bare-state-confirms-deliberate exception are unchanged).

**Four afflictions were uncurable.** `crackedribs`, `skullfractures`, `torntendons` and
`wristfractures` shipped with an empty `priority` table. `afflist.priority()` returns `nil`
for every vector in that state, and `engine.resolve()` only considers ranked afflictions —
so the game reported them, the engine tracked them, the panel displayed them, and no cure
was ever sent. All four are `apply health` damage from ordinary hunting, so the symptom was
a single injury that never healed while everything else cured normally. Ranked after the
existing salve list (42–45) rather than guessed into the middle of it. The test suite now
asserts that every affliction with a cure has a priority the engine can select it by, so no
entry can be left unrankable again.

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

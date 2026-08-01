# Roadmap

Emunah's GMCP tracking, curing engine and hunting loop are complete and covered by tests.
Two structural gaps separate the current state from a system that holds up in player
combat, and both are addressed below.

## Current state

| Area | Status |
|---|---|
| GMCP tracking, interface, capability layer | Complete |
| Curing engine, healing, rift management | Complete for PvE |
| Area walker, hunting loop, loot | Complete |
| Affliction detection | GMCP-driven; the trigger corpus is a seed |
| Class offence | Priest only, single attack, no affliction sequencing |
| PvP | Opt-in targeting and opponent tracking; no offensive sequencing |

### Gap 1: two afflictions GMCP cannot report

**This gap is much smaller than it was assumed to be.** `Char.Afflictions` can be relied on
for every affliction in player combat except `loki` and `blackout`, and both are now
handled: blackout suspends reconciliation until it lifts, loki triggers `DIAG` on the next
balance.

That moves the trigger corpus from load-bearing to a refinement. Triggers still see an
affliction the instant its message prints, ahead of the next GMCP push, which is worth
having in a fight decided on fractions of a second — but the engine no longer depends on
them to know what is wrong.

The remaining work is `DIAG` output parsing, so the engine can reconcile its own state
against the ground truth rather than only putting it on screen. That needs one verbatim
sample of the output.

The workflow is `emunah learn on` → fight or spar → `emunah learn off` → add what was
actually observed. Priority order:

1. Onset detection for the blocking afflictions: anorexia, asthma, slickness, paralysis.
2. Cure-side confirmation for the writhe-class binds in `afflist.writhes`.
3. Common lock-setup afflictions, named from the help checklist, worded from transcripts.
4. The long tail, opportunistically and driven by what curing actually needs.

### Gap 2: offence is single-attack

`class/priest.lua` issues one attack command and implements `handleShield` as an explicit
refusal rather than a guess. There is no affliction sequencing, and only one class exists.

## Planned

**Offensive sequencing for Priest.** A lock-sequencing table shaped like the existing
`{cures, priority}` convention in `afflist.lua`, gated on opponent affliction state from
`curing/detect/opponent.lua`. Blocked on Gap 1: sequencing against an opponent model that
cannot see afflictions is guesswork.

The class's kill route is `absolve`, which is binary on the target's mana being below 50%
— exactly 50% fails. The usual sequence is break a leg, prone, drive mana down, absolve.
Whether the threshold is actually met is a calculation worth computing rather than
assuming, which is the part of the work with any real value in it.

**A second class.** Monk, chosen because it needs no adapter changes —
`adapter.SKILLSET_TO_CLASS` already maps its skillsets — and because a second implementation
is the only way to confirm the sequencing logic is not accidentally Priest-specific. A
contributor-facing guide to adding a class follows the second one, not the first.

**Shield handling.** `handleShield` stays unimplemented until a shield-break mechanic is
confirmed in play. The bashing loop treats the refusal as "cannot handle this" and stops,
which is the correct behaviour for an unknown.

**Tattoo keep-up.** `boar` and `moss` are passive defences raised by `touch`, stripped only
by a specific action, by death, or by leaving the realms. The machinery is in place —
`emunah defs add <name> <command>` supplies the command, and the attempt budget stops a
wrong name from spending a balance every few seconds — but the names as `Char.Defences`
reports them have not been observed, and guessing one means the defence silently never goes
up.

**`CON`-based difficulty.** Penitence currently fires on `killIn()`, an estimate that needs
one landed hit before it says anything. `CON` reports sentience and a power rank directly,
at the point a denizen is first recorded rather than mid-fight, which is better information
for the same decision. Needs the `CON` output format.

**Open data questions.** Six items in
[docs/afflictions.md](afflictions.md#open-questions) need in-game confirmation, most
significantly whether five entries are defences mismodelled as afflictions.

## Working principles

These are why the roadmap has fewer items than it might.

**A wrong assertion is worse than a gap.** A missing pattern is inert. A wrong one asserts
an affliction the character does not have, and the engine spends a balance curing it. Where
the exact game text or mechanic is unknown, the feature waits rather than shipping on a
guess.

**Evidence over reasoning.** Mechanics are established from timestamped transcripts and
GMCP traces, not from what the game plausibly ought to do. Verified findings and the
evidence behind them live in [docs/game/](game/).

**Every behavioural fix carries a regression test** that would have caught the original
report, and the suite must be green before anything is committed.

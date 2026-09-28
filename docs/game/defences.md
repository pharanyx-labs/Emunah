# Defences

Verified from play unless marked otherwise. Each entry says what established it.

## Tattoos and passive defences

```
touch moss
Your moss tattoo tingles slightly.
Balance used: 4.0s.
```

- **Touching a tattoo costs balance whether or not the defence is already up.** Confirmed by
  another player testing it deliberately: "just tried it and was put 3.7 seconds off balance"
  — with a trait that lowers off-balance times, so the base is higher. Never touch a defence
  `Char.Defences` already reports; the cost is paid for nothing.
- `moss` and `boar` are **passive** defences. They are stripped by a specific action, by
  death, or by leaving the realms — not by time. One touch is enough.
- Both appear in `Char.Defences`, so GMCP is a reliable source for whether they are up.

| Command | Costs | Notes |
|---|---|---|
| `touch moss` | balance 4.0s | Staunches wounds. Observed 13:29:16.74 |
| `touch cloak` | equilibrium 1.00s | "You caress the tattoo and immediately you feel a cloak of protection surround you." Observed 16:07:10.56 (2026-09-28). Touched again while up: "You are already protected by the cloak tattoo." with **no cost line**, and the prompt still read `ex` (16:07:16.82). DEF line: "You are surrounded by a cloak of protection." |
| `def` | equilibrium 0.50s | Observed 13:29:20.97. Not free — do not poll it |
| `def brief` | — | Brief names, close to the GMCP defence names |
| `perform inspiration` | equilibrium 3.50s, **and requires balance and standing** | Priest. Lasts around ten minutes (13:35:33.62 to 13:45:28.50), ending with "You slump slightly as the divinely-inspired strength leaves your body." See [`PERFORM INSPIRATION`](#perform-inspiration) below. |

## FOCUS

Clears mental afflictions. **Costs neither balance nor equilibrium** — only its own mental
balance, which is why it still works in a lock that has taken everything else.

Its balance is not reported over GMCP. Like herb, salve and sip balance it is tracked from
the game's own messages, and it is a predictable length. The rejection is confirmed:
`You have not yet regained your mental balance.`

| Rule | Reason |
|---|---|
| **`impatience` blocks focusing** | Cured by eating goldenseal, so the escape is the herb vector |
| **Do not focus while `guilt` is up** | It costs more than the affliction it clears |
| **Unless `anorexia` is also up** | Guilt's cure is a herb and anorexia shuts the herb vector, so refusing to focus means refusing to act at all |
| **`anorexia` outranks every mental affliction on focus** | "You want it away urgently even at the cost of maybe getting another mental" |

### Why the ordering matters against a Priest

Every mental affliction left up is **2% more sapping potential** for an enemy Priest, and
their kill route is a mana kill (see [Priest: absolve](priest-abilities.md#priest-absolve)).
So mental afflictions are a slow loss that compounds, while anorexia is a shut vector — and
the vector it shuts is where most cures live.

Given the choice between the two: *"choose between veering closer to being sapped of a lot
of mana, or being locked. Choose former."* Clear the lock, accept the sapping.

## TOUCH TREE

The Tree of Life tattoo. **Costs no balance and no equilibrium** — only its own tree
balance, which is why it still works when everything else has been taken.

**Which afflictions it clears is not established**, so no entry in `afflist.lua` names
`tree` as a cure vector. `engine.queueTree()` therefore does not claim a mapping: it fires
on the *state* the tattoo exists for — something is afflicting us and every cure we know for
it has been refused for `TREE_DWELL` seconds. Requires the tattoo to be inked, which shows
in `Char.Defences`.

The 15s recovery in `curelist.lua` is an estimate, not an observed figure.

## Where GMCP stops being authoritative

**`Char.Afflictions` can be relied on for every affliction in PvP, with exactly two
exceptions: `loki` and `blackout`.** This is the opposite of the assumption the system was
built under, and it matters — the trigger corpus is a refinement, not the thing standing
between this and player combat.

| Affliction | What it breaks | Response |
|---|---|---|
| **blackout** | Afflictions applied during it produce **no `Char.Afflictions` updates at all** | Do not reconcile while it is up; catch up the moment it lifts. `CONCENTRATE` once, 3s in (`curing.md`) |
| **loki** | The affliction list cannot be trusted while it is up | `DIAG` on the next balance |
| **recklessness** | `Char.Vitals` reports `hp` and `mp` at **maximum** regardless of the truth | Treat the vitals feed as unusable; heal from every source |

Recklessness falsifies *vitals*, not the affliction list, which is why it is a separate
mechanism from the two above.

### DIAG

The ground truth for what is actually afflicting you, and the answer to `loki`.

| | |
|---|---|
| Requires | **balance AND equilibrium** |
| Consumes | **1s of equilibrium** — it does not consume balance |

The require-versus-consume split is the same shape as `smite`: it needs balance present to
go out and does not spend it.

**The output format has not been recorded here**, so nothing parses it yet — sending `DIAG`
puts the truth on screen for the player, but the engine cannot yet reconcile its own tracked
state against it. Paste the output of one and that closes.

See [`DIAG` output](#diag-output) below for the format once it was captured.

## `BLIND` and `DEAF` are defences, and they need `MINDSEYE`

Blinding and deafening yourself is deliberate — protection against attacks that need you to
see or hear. **Without `mindseye` up you then genuinely cannot see or hear anything**, so
raising either without it is not a partial success; it is actively harmful. `deflist` marks
both `requires = "mindseye"`, and keep-up holds the raise rather than sending it. Holding
costs no attempt from the budget: the prerequisite coming up is the ordinary way it
resolves.

**The game reports the resulting state as an affliction as well**, which is a trap. Watched
at 13:55:02:

```
[emunah] Cannot cure blindness: epidermal is in the rift, not in hand.
```

…while `DEF` listed `You are blind.` among twelve defences at 13:47:44, and `DIAG` reported
a bare `blind.` at 13:55:02. Only the salve being out of reach stopped the curing engine
stripping a defence that had been put up on purpose — and it would have kept stripping it
for as long as keep-up kept restoring it.

`deflist.DELIBERATE` maps the affliction to the defence that means it was wanted
(`blindness` → `blind`, `deafness` → `deaf`), and the cure loop skips any affliction whose
paired defence is currently in `Char.Defences`. Gated on the defence being *reported*, so it
lapses the instant the defence does: a real blinding with no `blind` defence up cures
normally.

## A defence's name is not always what grants it

`Char.Defences` names a defence after **what it does**, not after the thing that granted it.
Confirmed payload:

```lua
Char.Defences.Add = {
  name = "poisonresist",
  desc = "Granted by the venom elixir or toxin tonic, this allows you some resistance to
          poison damage." }
```

So the elixir is `venom` and the defence is `poisonresist`. Configured under the elixir's
name it can never match, and keep-up raises it forever. Watched at 13:47:33 — `drink venom`
worked first time ("your resistance to damage by poison increases", and `DEF` listed it),
then two more sips each answered `The elixir flows down your throat without effect.` before
the attempt budget stopped it. Three elixirs and three balances for a defence that had been
up since the first.

Handled three ways, because each catches a different moment:

- `deflist.M.ALIASES` maps `venom` → `poisonresist`, so typing the obvious thing works.
  Config migration 4 renames a saved entry.
- `The elixir flows down your throat without effect.` abandons that defence immediately —
  the game has said plainly there was nothing to do, so retrying is delay, not protection.
- The budget warning lists the names `Char.Defences` is reporting
  that nothing claims. The right answer is almost always in there.

**`speed` has not been checked** against a live `Char.Defences` — the family does not always
agree, as `poisonresist`, `levitating`, `temperance` and the `immunity` duplicate below all
show.

**Same bug, `blind`/`blindness`.** `blind` is the verb that raises the defence (`eat
bayberry`), and it is also what DIAG's bare-state line calls it. Neither is what
`Char.Defences` calls it: the defence itself reports as `blindness` — the same word
`Char.Afflictions` uses for the resulting affliction, so one string now names both channels.
Confirmed live: with `blind` on keep-up, `eat bayberry` answered `The bayberry has no
effect. You are already blind.` three times without the defence ever registering, then:

```
[emunah] Raised blind 3 times and it never appeared in Char.Defences -- stopping.
[emunah]   Char.Defences is reporting these, which nothing here claims: blindness, ...
```

— while genuinely blind the whole session. Handled the same three ways as venom/poisonresist
above: `deflist.M.ALIASES` maps `blind` → `blindness` (config migration 5 renames a saved
entry), and `deflist.M.commands` is keyed on `blindness`. The one wrinkle poisonresist did
not have: DIAG's bare-state vocabulary still says `blind`, and does not agree with either
GMCP channel — see `deflist.M.DIAG_STATES`, kept deliberately separate from
`deflist.M.DELIBERATE` so fixing the GMCP name did not silently break DIAG's own reading.

**`deaf`/`deafness` confirmed the same session.** `Char.Defences` reports it as `deafness`
too:

```
[emunah] Raised deaf 3 times and it never appeared in Char.Defences -- stopping.
[emunah]   Char.Defences is reporting these, which nothing here claims: boartattoo,
            deafness, mosstattoo, preachblessing, resistance
```

Same fix, same shape: `deflist.M.commands` keyed on `deafness`, `M.ALIASES` maps `deaf` →
`deafness`, config migration 6 renames a saved entry. `eat hawthorn`'s own confirmation is a
trigger line — `The aural world fades to silence.` — not a `Char.Defences` update, and it can
print well before `Char.Defences` catches up, the same lag `M.deliberate()` already accounts
for on the affliction side (see above).

**`levitation`/`levitating` confirmed next.** Same shape again: `levitation` is the elixir,
`levitating` is what `Char.Defences` calls the defence. Watched at 18:20:50-18:21:03 — three
sips each answered `The elixir flows down your throat without effect.` while `DEF` listed
`You are walking on a small cushion of air.` the whole time, and the attempt budget's own
diagnostic named `levitating` outright:

```
[emunah] Not raising levitation again: the sip had no effect, so it is already up under a
         different Char.Defences name
[emunah]   Char.Defences is reporting these, which nothing here claims: ..., levitating, ...
```

Same three fixes: `deflist.M.commands` keyed on `levitating`, `M.ALIASES` maps `levitation` →
`levitating`, config migration 7 renames a saved entry.

**`immunity` is not a defence of its own — it is `poisonresist` again.** Not a naming
mismatch this time but a duplicate: drinking `immunity` produces the exact `DEF` line
`Your resistance to damage by poison has been increased.`, word for word the same text
`poisonresist` already shows. Watched at 18:28:28-18:28:48 — sipping it while poisonresist
was already up did not just waste the sip, it answered:

```
The elixir flows down your throat without effect.
As the antivenom ravages your system, you feel very unwell.
You are confused as to the effects of the venom.
```

— an actual affliction from the redundant dose, not a silent no-op like the others above.
`deflist.M.ALIASES` maps `immunity` → `poisonresist` the same as `venom`, so keep-up
recognises the defence as up under either name and never sends `drink immunity` once
`poisonresist` is already there; config migration 8 renames a saved entry.

**`frost`/`temperance` confirmed next.** Same shape as `levitation`/`levitating`: `frost` is
the elixir, `temperance` is what `Char.Defences` calls the defence. Watched at
18:39:57.43-18:39:57.62 — a sip answered `The elixir flows down your throat without effect.`
and the attempt budget's own diagnostic named `temperance` outright:

```
[emunah] Not raising frost again: the sip had no effect, so it is already up under a
         different Char.Defences name
[emunah]   Char.Defences is reporting these, which nothing here claims: ..., temperance, ...
```

Same three fixes: `deflist.M.commands` keyed on `temperance`, `M.ALIASES` maps `frost` →
`temperance`, config migration 9 renames a saved entry. `speed` remains unchecked — see the
note above.

### Unverified defence raise commands

`deflist.M.IMPORTED` holds 16 defences whose raise commands have **not been watched working
here**. They are kept in their own table, lose to anything in `M.commands`, and are labelled
`[unverified]` in the `emset defs` grid — the difference between "we have seen this work" and
"we believe this works" has to survive contact with the code rather than living in someone's
memory.

Scoped to what every character can use plus Devotion and Spirituality.

Two things they are deliberately conservative about:

- **the vector** — recorded only as "believed to spend physical balance" or not. Where that
  was ambiguous, the balance-requiring reading was taken: waiting costs a delay, guessing
  wrong costs a refusal and one of only three attempts.
- **standing** — none is known to work while prone, so all of them require it.

The **names** have not been checked against a live `Char.Defences` either, and that is the
likeliest thing to be wrong. When one is, the defence never appears, the attempt budget
stops after three tries and says so, and `emset defs add <name> <command>` corrects it.
That is the intended way to find out, and it is why none is enabled by default.

**Known conflict, left alone:** `nightsight on` versus Emunah's own `nightsight`. Neither
has been observed here, and `M.commands` wins, so the existing entry stands until someone
watches one of them work.

#### Two corrections this needed

**Invisible defences cannot be kept up.** Some defences never appear in `DEF` output, and
so never in `Char.Defences`. Keep-up
rests entirely on "not in the list means not up", so such a defence is raised, unseen,
raised again, and retired after three tries. Observed 13:24:45.03 — `perform bliss` worked
("You pour blessings of bliss over yourself…"), the next two came back "That person is
already experiencing bliss.", then:

```
[emunah] Raised bliss 3 times and it never appeared in Char.Defences -- stopping.
```

Three raises at 6.50s of equilibrium each, for a defence that was up the whole time.
`bliss` and `satiation` were removed for this reason. **Check `invisibledef` and the
presence of a `def` line before importing any more.**

**`bliss` is back, deliberately, as a one-shot rather than plain removal.** Its own DEF
readout still never names it — confirmed again 22 minutes into the buff, in a separate
session — so the invisibility is real and permanent, not a fluke of timing. `deflist.lua`
keys it `unconfirmable = true`: `defup` marks it satisfied the moment the command is *sent*,
not when `Char.Defences` agrees, because that agreement is never coming. `keepup` mode is
still reachable through the ordinary toggle but is a poor fit — nothing gates its re-raise on
`satisfied`, so it retries every tick until the normal 3-attempt budget stops it, same as
before this fix, just bounded rather than silent. `satiation` has not been given the same
treatment and stays out.

**Bliss is now tracked from its own lines, like svof (2026-09-28).** Its up state used to
be "satisfied on send", held only in memory, so every `emreload` forgot it and sent
`perform bliss` again. svof marks bliss `invisibledef` and reads it from these lines
**[svof]**, which Emunah now does too (`deflist.SYNTHETIC.bliss`). The state is kept across
reloads and cleared on death or disconnect.

```
You pour blessings of bliss over yourself, granting visions of the majesty of the divine.
The divine choir lingers on in your mind, and your spirit soars.
That person is already experiencing bliss.
<name> pours blessings over you, and divine choirs begin to sing joyously at the edge of your hearing.
```

**Bliss's defences settle it on every DEFENCES listing (2026-09-28).** Bliss grants
toughness, resistance and constitution (stated by the user), and those do appear in DEFENCES.
Their lines, from the user's own listing with bliss up:

```
You are using your superior constitution to prevent nausea.
You are resisting magical damage.
Your skin is toughened.
```

`deflist.blissFromListing`: all three present means bliss is up; any one missing means it is
down, and keep-up casts it. After a reload keep-up holds until the listing is read, so
`perform bliss` goes out only when a defence is actually missing.

Bliss's own wear-off line, captured 15:15:26.52 on 2026-09-28, clears it at once:

```
The heavenly visions fade as the bliss leaves you.
```

### `DEFENCES` output, and the check after a reload

The listing is bracketed by these two lines **[svof]**:

```
You have the following defences:
<one line per defence>
You are protected by N defences.
```

No line names its defence. `deflist.DEF_LINES` maps each one to the server's name: 199 lines,
generated from svof's `defs_data`, with invisible defences left out. After `emreload`,
keep-up sends `DEFENCES` and raises nothing until the listing has been read, or for 10s at
most. A reload rebuilds the defence list from the last full `Char.Defences.List`, which
misses every change since. The listing is applied the way svof's `process_defs` does:
- a known line that's missing means that defence is down;
- a listed line means it's up;
- a defence whose line isn't known is left as it was.

**"Costs a balance" ≠ the balance vector.** Achaea has several balances, and knowing a
command spends one does not say which. `perform bliss` was recorded as costing balance and
announced `Equilibrium used: 6.50s.` here. An unverified balance-costing defence therefore
requires **both** until one is actually observed — conservative in the only direction that is cheap, since waiting
costs a delay while guessing wrong costs a refusal and one of three attempts.

## `DIAG` output

```
You are:
blind.
afflicted by thin blood.
Equilibrium used: 1.00s.
```

Costs `Equilibrium used: 1.00s.` The engine sends it whenever loki is up, because
`Char.Afflictions` cannot be trusted then — and **nothing parsed the reply** until
`curing/detect/diag.lua`. The cost was being paid and the question left unanswered.

**Two forms, and only one is an affliction:**

| Form | Read as |
|---|---|
| `afflicted by <name>.` | an affliction |
| `<name>.` | a bare state — reported, never cured |

In the sample the bare entry is `blind`, which the character was holding **deliberately as a
defence** (`DEF` listed it among twelve at 13:47:44). Curing a bare line would have stripped
a defence put up on purpose. Whether the two forms are reliably state-vs-affliction rests on
one sample, so the conservative reading is used — it is the one that cannot do damage if it
turns out to be wrong.

The block ends at the cost line: entries are lowercase and `Equilibrium used:` is not.

**Adding is safe, removing needs the whole block.** An affliction DIAG names that we are not
tracking is exactly the discovery the command was sent for. But an unrecognised line means
absence cannot be told from failure-to-parse, so nothing is cleared on a partial reading —
failing that way would cure *less* than before. `loki` is never cleared by absence either;
it is the illusion, not something the game will admit to.

**Names may contain spaces** — `thin blood`, which has no entry in the affliction table
under any spelling. It cannot be cured however plainly the game reports it, so it is logged
loudly rather than passed over.

## Forcing a prompt

A blank line (`send("")`) makes Achaea emit a fresh prompt, and with it `Char.Vitals` — the
tick everything in Emunah hangs off. Used when a decision changes between game events, so
it is acted on immediately rather than whenever the game next says something: toggling a
defence in `emset defs` does this.

## `PERFORM INSPIRATION`

Reported by user, and the reason the keep-up entry carries `needs`: it cannot be done
**without both balance and equilibrium, and not while prone**. The vector alone only
expresses the equilibrium half.

Raising it, 12:41:19.75 — note the prompt goes `exb` → `xb`, so equilibrium is what it
*spends*:

```
You bow your head and, praying to the gods for inspiration, you are soon rewarded as your
body is suffused with strength.
Equilibrium used: 3.50s.
```

Losing it:

```
You slump slightly as the divinely-inspired strength leaves your body.
```

GMCP carries both ends, so no trigger is needed for either — `Char.Defences` is complete
(see `curing/defkeepup.lua`):

```lua
Char.Defences.Add    = { desc = "Divine inspiration increases your strength.",
                         name = "inspiration" }
Char.Defences.Remove = { "inspiration" }
```

Nothing strips it; it simply lapses after about ten minutes. That is exactly the shape
keep-up exists for, so it is in `defkeepup.M.commands` and needs only
`emset defs add inspiration`.

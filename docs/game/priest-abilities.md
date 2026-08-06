# Priest abilities

Verified from play unless marked otherwise. Each entry says what established it.

## Abilities

`CLOT` is the Survival ability **`clotting`**, not a universal command. Without the lesson:
`Clot is not a valid command. Did you perhaps mean CT, CLOSE, or QL?`

**The character has since trained it** *(stated by the user)*, so the strict gate that fact
justified is gone — `curing/detect/patterns.lua` uses the ordinary permissive `have.skill()`
now, with `have.denySkill()` as the backstop. The general rule still holds and is worth
keeping in mind for the next ability: gate on positive confirmation from the skill index
when there is real evidence an ability is *absent*; permissive is right otherwise.

`CLOT` **requires and consumes no balance and no equilibrium** — it can be sent freely. It
costs **a little mana** *(both stated by the user; the mana figure has not been measured, so
nothing gates on it)*.

Its reply when there is nothing to clot:

```
You do not bleed, my friend.
```

Not a balance rejection and not a failure — just the command answered. Worth handling only
to free the queue slot, since it says nothing about whether bleeding will resume.

## Abilities in use

| Command | Costs | Notes |
|---|---|---|
| `smite <id>` | spends balance 2.9-3.2s; **requires** equilibrium | Priest attack (old default). Balance is announced (`Balance used: 2.9s.`) and equilibrium is **not consumed** -- the prompt reads `e-` straight after (12:41:14.49). It only needs equilibrium to be present, so the requirement is invisible until you lack it. |
| `angel sear <id>` | spends equilibrium 2.50s; **requires** balance too | Priest attack (shipped default since 2026-08-04) -- see [Angel Sear](#angel-sear) below. The mirror image of `smite`: same "requires both, spends one" shape, opposite resource spent. |
| `perform rite of desolation on <id>` | 36 rage; 23.00s cooldown, **not** balance or equilibrium | Priest (Attainment/Battlerage) amplifier, denizens only -- see [Rite of Desolation](#rite-of-desolation) below. Sent as a pre-attack step whenever ready, independent of the attack's own balance/equilibrium state. |
| `perform hands` | equilibrium, 3s | Priest self-heal, ~20% of the bar. Announced with `Equilibrium used: 3.00s.` Independent of sip balance, so it stacks with `drink health` -- but NOT with attacking, which needs equilibrium too. |
| `drink health` | sip balance | Announced back with `You may drink another health or mana elixir.` |
| `clot` | a little mana | Requires the Survival ability `clotting`, now trained. No balance and no equilibrium, either required or consumed — it can be sent freely. Answers `You do not bleed, my friend.` when there is nothing to clot. Mana is the only price, so it is gated on bleeding **more than 30** (`curing.clotThreshold`). |
| `get <id>` | balance and equilibrium | Competes directly with attacking, which is awkward: gold appears from a kill that just spent both. |
| `perform rite of sustenance` | equilibrium 3.00s | Places a bowl on the ground and fills it with manna. Announced with `Equilibrium used: 3.00s.` — prompt went `ex-` → `x-`, so balance was not consumed. Whether it *requires* balance is not established (the prompt read `ex-` beforehand). Any devotion cost is unknown; the prompt does not carry it. |
| `get bowl` / `drink bowl` | see notes | `GET` costs balance and equilibrium as above. What `DRINK BOWL` costs has **not** been observed — it is not an elixir, so sip balance may not apply at all. |
| `perform penitence <id>` | equilibrium ~1s, 300 devotion, 100 mana | Priest (Devotion). Against denizens the devotion cost is *reduced* and the equilibrium cost *increased* by unstated amounts. Brands the target to take **10% more damage from SPIRITUALITY SMITE**. |
| `stand` | balance | Getting up is not free. A knockdown lands right after your own attack, so balance is exactly what you lack when you need it. |
| `wake` | — | Neither requires nor consumes balance or equilibrium. The only command that works while `sleeping`. "Will *attempt* to wake you", so treat it as repeatable rather than guaranteed. |
| movement (`n`, `s`, ...) | **balance AND equilibrium** | Confirmed by the player: you cannot change rooms without both. This is why the walker sits out the full recovery after every kill (`Held "s" -- no balance` at 12:40:56) -- the pause is the game's rule, not a bug in the walker. Do not "optimise" it away. |
| `outr` / `inr` | free | Neither costs a balance. Confirmed 0.23s turnaround. |

### Angel Sear

Replaced `smite` as the shipped Priest attack, 2026-08-04. Verbatim `HELP SEAR`:

```
Sear (Spirituality)                           Known: Yes
-------------------------------------------------------------------------------
Syntax:            ANGEL SEAR <target>
                   ANGEL SEAR ICEWALL <direction>
Works on/against:  Adventurers and room
Cooldown:          2.50 seconds of equilibrium
Resource:          10 Angel power and 100 mana
Details:
With this ability, you may command your guardian angel to sear an
opponent with intense heat, causing them to burst into flames. If the
target is a denizen, this will not consume any of your angel's power.
```

Two facts drive `class/priest.lua`:

- **The cooldown is stated as equilibrium, not balance** — the opposite of `smite`, which
  spends balance and merely requires equilibrium. Confirmed against balance too *(stated by
  the user, 2026-08-04)*: Sear needs BOTH present, exactly like `smite` did, but only
  consumes the one HELP names. `bashing.balance` stays `"both"`; the new `bashing.consumes`
  setting is what tells `M.attack()` which single resource to guard and mark spent.
- **Against a denizen it does not touch Angel power at all** — HELP says so directly ("If
  the target is a denizen, this will not consume any of your angel's power"). Bashing only
  ever targets denizens, so nothing here gates on Angel power; it would only matter for a
  PvP use of the same attack command, which is not what `bashing.attack` is for.

Mana (100) is not gated on either, matching how `smite` never gated on devotion/mana for the
attack itself — only `perform penitence` checks its own floors.

### Rite of Desolation

A Battlerage amplifier, added alongside the Sear switch. Verbatim `HELP DESOLATION`:

```
Desolation (Attainment)                       Known: Yes
-------------------------------------------------------------------------------
Syntax:            PERFORM RITE OF DESOLATION ON <target>
Works on/against:  Denizens
Cooldown:          23.00 seconds
Resource:          36 rage
Details:
This rite will torture the unfaithful, causing their very bones to ache. The pain will last
for several seconds, doing damage to your target for the duration.
```

The cooldown is stated as a flat **23.00 seconds** — no "of balance" or "of equilibrium"
qualifier, unlike every other ability in this file. Read literally: it competes with nothing
else bashing does, so `class/priest.lua` gates it on its own timer (`bashing.desolation`)
rather than `attack.balance` or `cure.equilibrium`.

**The cooldown IS confirmed by the game, just not with an `"X used:"` cost line.** Confirmed
live 2026-08-04: the moment the 23s cooldown actually elapses, Achaea prints one of two lines,
unprompted:

```
You can use Desolation again.
Your Desolation ability could be used again but you lack the necessary Rage.
```

Both mean the cooldown is over; the second adds that rage specifically is the remaining
blocker. `installTriggers()` in `class/priest.lua` clears the `bashing.desolation` guard on
either line, so the flat 23.00s is only a pessimistic starting guess, the same shape as
`inflightGuard()` elsewhere — the real announcement can clear it early (or, if the true
cooldown ever turns out to differ from 23.00s, correct for that too) without risking a
double-send: `shouldDesolation()` still requires the 36-rage floor separately before anything
is actually sent.

There is also a broader, ability-agnostic message — observed but not currently acted on,
since Desolation is the only trained Battlerage ability:

```
You can use another Battlerage ability again. Available abilities: Torment
You can use another Battlerage ability again, but none of your abilities are currently available.
```

`Torment` is named as available but has not been investigated; nothing here sends it. Worth
revisiting if a second Battlerage ability is ever added for this character.

Observed damage types, from the same session: Desolation's own hit and its damage-over-time
tick both read `Damage dealt: N (unblockable)`; Angel Sear's read `Damage dealt: N (fire)`
alongside its `Equilibrium used: 2.50s.` — matching HELP SEAR exactly.

Rage itself is reported the same generic way as Devotion, confirmed live via
`lua display(gmcp.Char.Vitals)` at `06:38:36.52` (2026-08-04):

```
charstats = { "Bleed: 0", "Rage: 0", "Angelpower: 1500", "Devotion: 98%", "conviction: 0",
"prayer_length: 0", "Prayer: Yes" },
```

The exact key is `Rage` (capitalised, plain integer — not a percentage like `Devotion`), and
`Angelpower` is confirmed the same way, supporting the Angel Sear notes above. `conviction`
and `prayer_length` are lower-case in the game's own output; nothing here reads them yet.

Sent as a pre-attack step, the same slot Penitence occupies, but for a different reason:
Penitence competes with the attack for equilibrium, so it is only worth it when the fight is
long enough to repay the lost swing. Desolation costs neither balance nor equilibrium, so
there is nothing to repay — it only waits on its own cooldown and rage, gated additionally on
`denizens.isDenizen()` since HELP restricts it to denizens.

## Devotion

Priest's class resource, reported by `charstats` as a **percentage only** -- so an ability
costing "300 devotion" cannot be checked for affordability directly. Anything gating on it
uses a cautious percentage floor rather than a calculation, and says so.

Running out mid-hunt is expensive: `perform hands` and `perform penitence` both draw on it,
as does the class resource floor in `watch.lua`.

## Zeal (PvP affliction verses)

A third Priest skillset, alongside Devotion and Spirituality (see `class/priest.lua`'s
`M.SKILLSETS`). `AB ZEAL`, pasted by the user 2026-08-05, lists the abilities; at the time of
capture, known abilities ran from `Anoint` through `Unflinching`, with `Ash`, `Penance`,
`Reflection`, `Rebuke`, `Burn`, `Light`, `Wrath`, `Purge`, `Rejection`, `Oration`, `Salvation`,
`Benediction`, `Glory`, `Revelations` still unlearned ("Next ability available in 40
lessons"). **`Rebuke` -- the wiki-described "lock" finisher -- is not trained.** Do not build
a full stack-and-lock combo against that assumption; only Guilt and Condemnation are
confirmed usable.

### Anoint (prerequisite, blocks everything)

Every Zeal verse requires a one-time ritual first. Confirmed live 2026-08-05: both
`recite guilt <target>` and `recite condemnation <target>` were refused, verbatim:

```
You have not anointed yourself with holy ash; see AB ZEAL ANOINT for the path you must walk.
```

`AB ZEAL ANOINT`:

```
Anoint (Zeal)                                 Known: Yes
-------------------------------------------------------------------------------
Syntax:            ANOINT ASH
Details:
A wielder of the holy verses must first gain the ability to imbue their
words with a remnant of Phoenix Song. Travel to Anost in the excised
Ruins of the Dawnspear and ANOINT your brow with the holy ash that can
be found there.
```

Not in `emunah`'s map (no room data for Anost/Dawnspear), and "excised" suggests a specially
instanced area rather than a normally walkable one. This is a real precondition, not a
balance cost: neither refused cast produced "You may speak another holy verse." (see below),
confirming nothing was spent.

### Guilt and Condemnation

`AB GUILT`:

```
Guilt (Zeal)                                  Known: Yes
-------------------------------------------------------------------------------
Syntax:            RECITE GUILT <target>
Cooldown:          1.60 seconds of prayer balance
Details:
This verse reminds a foe of their life's failings, forcing them to
confront them. Attempts to focus their mind shall only serve to worsen
their situation(*).

* Focus still cures an affliction, but it also gives a new mental
affliction in the cured one's place.
```

`AB CONDEMNATION`:

```
Condemnation (Zeal)                           Known: Yes
-------------------------------------------------------------------------------
Syntax:            RECITE CONDEMNATION <target>
Works on/against:  Adventurers
Cooldown:          1.60 seconds of prayer balance
Details:
Condemn your foe with this holy verse, striking them down with the
justice affliction.
```

Condemnation's affliction is stated outright (`justice`). Guilt's HELP text never names one,
but two independent pieces of evidence from the same live cast (2026-08-05) agree: the target
immediately ate a lobelia seed, and `curing/afflist.lua` already has a `guilt` entry (added
earlier, from an unrelated cross-check) whose only cure is `{ herb, lobelia }` -- so this is
not circular. `justice` is cured by `bellwort`, matching what the second test target ate.

**PRAYER BALANCE IS ITS OWN RESOURCE**, separate from both attack balance and equilibrium.
Confirmed live: `recite guilt` and `recite condemnation` both went out and were accepted while
Angel Sear's equilibrium was still on cooldown from an earlier attack -- no rejection either
time. A Priest with Zeal trained can attack (balance/equilibrium) AND recite (prayer balance)
on the same tick; neither competes with the other for anything.

**NOT a "Balance used: N.NNs." announcement**, unlike smite/Angel Sear/Penitence. Confirmed
live: neither cast produced that line. The only confirmation, for both verses, is:

```
You may speak another holy verse.
```

The same shape as the herb/elixir readiness lines (`You may eat another plant or mineral.`)
rather than the attack-cost lines. `class/priest.lua` arms a pessimistic 1.60s guess on send
(`M.RECITE_BALANCE_GUESS`, from HELP) and clears it the instant this line arrives.

**Onset is not detected.** Neither cast produced a message, to the caster, confirming the
affliction actually landed rather than being resisted or shielded -- only that the verse was
successfully spoken. `curing/detect/opponent_patterns.lua` has the one CURE message this test
happened to show (guilt's -- "`<Name> straightens, as if some great burden had been lifted
from <possessive> shoulders.`"), but no gain/onset pattern for either `guilt` or `justice` yet.
Do not add one without seeing the real onset text first.

Confirmed twice now, independently, 2026-08-05: a second live test (post-Anoint, against a
different willing target) showed the identical shape -- `recite guilt`/`recite condemnation`
each went straight from the send-confirmation to the target eating their cure herb (`argentum`
for guilt, `cuprum` for justice -- both the ALT herb afflist.lua already lists, a second match
independent of the first test's primary-herb match), with nothing in between. Treat this as
reasonably solid evidence these two verses do not announce landing to the caster at all, not
just as-yet-uncaptured text. **Do not infer landing from the target eating their cure herb.**
`opponent_patterns.lua`'s own header rules this out explicitly: "never a move-recognition or
probabilistic inference... inferring 'this move probably caused that affliction' is a
fundamentally different and much harder technique that this file deliberately does not
attempt." A real opponent eating that herb is not proof of cause.

### Prayer (verse chaining)

`AB PRAYER`:

```
Prayer (Zeal)                                 Known: Yes
-------------------------------------------------------------------------------
Syntax:            VERSES
Details:
You may now chain holy verses together. Each verse you recite(*)
somewhat quickly after a prior one will form a prayer; a prayer of two
or more verses that you allow to finish without reciting further will
grant you conviction. Conviction is used to enact some of the more
powerful holy verses.

Additionally, certain verses can only be utilised once per prayer, and
others may require a prayer of a certain length before they can be
recited.

* Verses that specifically target yourself do not increase your prayer's
length. Prayers that target others or that are somewhat indiscriminate do.
```

This is what the `conviction` and `prayer_length` charstats (see the raw `Char.Vitals` dump
under Rite of Desolation above -- `"conviction: 0", "prayer_length: 0", "Prayer: Yes"`, noted
there as unread by anything) actually track. Both are already on GMCP directly, lower-case,
no text-parsing needed if something is ever built to read them. Confirmed live: reciting a
single verse and letting the prayer lapse without following up produces

```
Your prayer draws to an unsatisfying conclusion.
```

-- i.e. fewer than two verses in the chain grants no conviction. Nothing in `class/priest.lua`
currently consumes conviction: the verses that would (past Unflinching) are not trained. Not
implemented against a guessed timeout for how long a prayer stays open between verses --
confirmed real but not measured precisely.

### There is no Recite ability

`AB ZEAL`'s ability list has no entry named "Recite" -- the verb belongs to each individual
verse (`Guilt`, `Condemnation`, etc.), not to a separate skill. A wiki source suggested
`RECITE <verse> <target>` as the general syntax; that turned out to be correct as a command
shape, but do not assume a wiki-sourced ability name maps to a real trained ability without
checking `AB ZEAL`/`AB <name>` first -- the list of what is actually known only ever comes
from the game.

## Limb breaks (broken / damaged / mangled)

Not HELP-verified -- from an informant (Anzerloi) live in-game, 2026-08-05, cross-checked
against two independent pieces of real transcript evidence (see below). Treat as reliable but
not to the same standard as a HELP capture.

**Three accumulating tiers, arms and legs, both sides:**

```
brokenleftarm   (tier 1) -- cured by mending
damagedleftarm  (tier 2) -- cured by restoration
mangledleftarm  (tier 3) -- cured by restoration
```

(and the equivalent `*rightarm`/`*leftleg`/`*rightleg` names). **Accumulative, not
replacing**: "if you have damagedleftarm, you definitely have brokenleftarm" -- a higher tier
sits on top of the lower ones rather than superseding them. Tier 2/3 "generally only happen
from limb damage events, namely equalling or exceeding 100% accumulated damage to that limb
before its reset."

**Head and torso are different**: no tier-1 "broken" state at all ("you only break them with
prep damage"), only two levels, both cured by restoration:

```
damagedhead / damagedtorso  (tier 1 of 2)
mangledhead / mangledtorso  (tier 2 of 2, final)
```

`mangledtorso` is NOT independently confirmed -- inferred by symmetry with head's own
two-level chain, same informant, same session. Everything else in this section (including
`damagedhead`/`mangledhead` by name) was stated directly.

**The cure command is generic, not per-side**: `APPLY <salve> TO ARMS` / `...TO LEGS` (not
"to left arm"), and the game itself decides which side to treat -- "it prioritizes left on a
tier basis." Head and torso take their own location instead: `APPLY RESTORATION TO HEAD` /
`...TO TORSO`. `mending` only ever treats a tier-1 break; a tier-2+ break needs restoration
regardless of location.

**The tattoo-block check only cares about a binary, not the tier**: "which arms you have
functional is immaterial to anything, really, the only checks are whether you are 'armless'
or not, meaning both out or you're good" -- one arm broken to the worst possible tier still
lets you smite, touch tattoos, raise a shield, anything; only BOTH arms broken at once blocks
anything. This matches (and now explains) `curing/afflist.lua`'s `M.armAfflictions` design,
already built around exactly that both-sides-at-once check before this conversation happened.

**Independent corroboration, not just testimony**: `damagedhead` and `damagedleftleg` both
appear as literal, real Achaea text in an unrelated live transcript from earlier the same
session (a Jester's status line: `(damagedleftleg) (damagedhead)`) -- a different character,
a different class, an unrelated fight, and still the exact same wording. `mangledhead` was
separately confirmed directly, name and all: *"there are damagedhead and mangledhead
afflictions the curing system acknowledges, that's how they should show on gmcp events as
well."*

**A pre-existing, unrelated bug this surfaced**: `curing/detect/diag.lua`'s `resolve()`
squashed DIAG's whitespace before matching against `afflist`, but never stripped a leading
indefinite article -- so `"afflicted by a crippled left arm."` squashed to
`"acrippledleftarm"`, which matched nothing, even though `crippledleftarm` already existed
in afflist with a real cure. Fixed to try the article-stripped form too. Separately,
`crippledleftarm`/`crippledrightarm`/`crippledleftleg`/`crippledrightleg` had `mending`/
`renewal` as their cure; confirmed live by the user (a different, more direct confirmation
than the informant testimony above) that `restoration`/`reconstructive` is correct instead --
matching what `mangledleftarm` etc. (the next tier up on whatever scale `crippled` belongs to)
already used. Whether `crippled`/`mutilated` (already in afflist, predating this
conversation) are real Achaea tier names distinct from broken/damaged/mangled, or an older/
alternate description of the same states, was not resolved and is not assumed either way --
both sets are kept, and the DIAG fix means whichever wording actually arrives now resolves
correctly.

## Priest: absolve

The class's kill mechanic, for reference — not implemented.

Absolve is a **mana kill** and is binary: it either kills or fails, on the target's mana
being **below 50%**. Exactly 50% fails. The common route is to break a leg, prone the
target, drive mana down (an angel's sap does the mana damage), then absolve. Whether the
threshold is actually met is a calculation most players assume rather than compute.

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
| `recite <verse> <target>` | prayer balance 1.60-3.00s; **requires** balance and equilibrium, spends neither | Every recite sent with either down came back `You must regain balance first.` or `You must regain equilibrium first.`, and the smite straight after a guilt went through (2026-10-23 09:58, see [A spar against Erishka](#a-spar-against-erishka-2026-10-23-0958)). On a shared prompt the verse goes before whatever spends one of them. |
| `metabolise <affliction>` | spends equilibrium 3.00s; **requires** balance too | AB METABOLISE names only equilibrium, but `smite ...|metabolise impatience` came back `You must regain balance first.` (2026-10-23 09:58:24.89). |
| `perform rite of desolation on <id>` | 36 rage; 23.00s cooldown, **not** balance or equilibrium | Priest (Attainment/Battlerage) amplifier, denizens only -- see [Rite of Desolation](#rite-of-desolation) below. Sent as a pre-attack step whenever ready, independent of the attack's own balance/equilibrium state. |
| `perform hands` | equilibrium, 3s | Priest self-heal, ~20% of the bar. Announced with `Equilibrium used: 3.00s.` Independent of sip balance, so it stacks with `drink health` -- but NOT with attacking, which needs equilibrium too. |
| `drink health` | sip balance | Announced back with `You may drink another health or mana elixir.` |
| `clot` | a little mana | Requires the Survival ability `clotting`, now trained. No balance and no equilibrium, either required or consumed — it can be sent freely. Answers `You do not bleed, my friend.` when there is nothing to clot. Mana is the only price, so it is gated on bleeding **more than 30** (`curing.clotThreshold`). |
| `get gold`, `get <id>` | balance and equilibrium | Competes directly with attacking, which is awkward: gold appears from a kill that just spent both. |
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

### Angel Sear and Angel Push on an adventurer (2026-10-24)

Captured by the user against Anzerloi, verbatim:

```
13:54:49.18  angel sear anzerloi
             Your guardian angel's eyes glow like embers as Anzerloi is seared and bursts into flame.
             Equilibrium used: 2.50s.
13:54:55.32  Anzerloi takes some salve from a vial and rubs it on his body.
13:55:14.98  angel push anzerloi
             You beseech your guardian to strike down Anzerloi.
             A guardian angel extends a hand in the direction of Anzerloi, and he is suddenly sent sprawling to
             the ground by an invisible force.
             Equilibrium used: 2.10s.
13:55:22.57  Anzerloi stands up.
```

The sear's line confirms ablaze, the push's confirms prone, and "stands up" cures it
(`curing/detect/opponent_patterns.lua`). He salved his body six seconds after the sear: a
mending salve there cures ablaze, so a salve on a named location takes off the one tracked
affliction a salve there cures, when there is only one (`opponent.salved`). Push's
equilibrium is 2.10s here against HELP's 2.20s. `hunt heresy` at 13:54:19.00 printed "Rage
fills you as the thought of heresy inspires you to greater efforts." and "Equilibrium used:
4.00s.", mana 95% to 85%.

### Angel Strip

`ANGEL STRIP <target>`: equilibrium 1.80s, 10 Angel power and 100 mana; adventurers and
denizens; "will always strip magical shields first" (`help/ab-spirituality-strip.txt`).
Hunting only at first (the user, 2026-10-15). **Since 2026-10-23 it also strips a PvP
target's shield**, and only that: the user lifted the ruling for this one use after
Anzerloi's spar logs showed him stripping Maelgor's shield twice (`pvp-locks.md`,
*Anzerloi's route*). PvP's strip is its own move (`class/priest_pvp.lua`).

Anzerloi, 14:35:03–14:35:52 **[player]**: it **requires balance**, and it has to come
**before** the attack, because it spends equilibrium and smite cannot go without it. The
same holds for Angel Sear, which needs both too. So a strip takes the attack's turn. When
to use it, against a shielded mob: "If no rage, and no heresy defense, do that instead of
smite." Rage is **Battlerage** rage (the user). Heresy is **your** defence (`hunt heresy`,
deflist `heresy`): "If you have heresy def, just smite. You'll do half damage, in fire
type, and remove shield" (14:36:19–14:36:36). Which Battlerage ability the rage case means,
and the line that shows a mob is shielded, are not yet captured.

A mob raising a shield, and a heresy smite burning it away, verbatim (Anzerloi hunting,
2026-10-15 14:47:24–14:47:26):

```
A nearly invisible magical shield forms around a crazed prison guard.
Igniting in holy flame, Anzerloi's mace burns away the magical shield surrounding a crazed prison
guard.
Anzerloi utters a prayer and smites a crazed prison guard with an Auroran Mace.
```

The same capture gives the leader lines support mode follows (`bashing.SUPPORT_ATTACKS`):
`<Name> utters a prayer and smites <mob> with <weapon>.`, `Praying to the Gods, <Name> lays a
desolating rite on <mob>'s body ...`, and Penitence's `<Name> calls down holy fire upon <mob>,
condemning ...`; and the kill, `A crazed prison guard has been slain by Anzerloi.`

`perform purity` as the balance move instead of smite, when "they raise shield and their
health is low enough" (Anzerloi, 14:36:57). **Hunting only** (the user). HELP not captured.

## From the ability dump (2026-10-15)

`help/abilities-2026-10-15.txt` holds every ability's text from GMCP (`emset skills dump`).
What is trained changes, so code checks `have.skill()` at runtime; this section records what
the abilities *do*.

**Nothing reveals a target's afflictions.** `DIAGNOSE` is self only; `ANGEL MINDREAD` reads
tells. The offence's confirmed sources stay landing lines, symptom lines, `contemplate`
(mana) and `ASSESS <target>` (health: 2.50s equilibrium, 50 mana, Survival).

PvP, Spirituality and Devotion:

| Command | Costs | Does |
|---|---|---|
| `smash arms\|legs <target> [chasten <body\|mind\|aff>]` | balance 2.20s | Crushes a limb, "rendering it useless". With chasten, as smite |
| `angel panic <target>` | equilibrium 2.40s | Fear; **slickness instead on a target with hellsight** (CLASSLEADS #178, 2026-10-23) |
| `perform visions <target>` | equilibrium 2.50s, 100 devotion, 50 mana | Dementia; shyness if already demented |
| `perform dazzle <target>` | equilibrium 2.50s, 250 devotion | Stupidity |
| `perform fasting <target>` | equilibrium 2.20s, 10 devotion | Anorexia. The route sends it once the target is slick and holds a mental (`pvp-locks.md`) |
| `judge <target>` | equilibrium 5.00s | Seeks a death sentence; faster against justice. **Not used**: how long it takes, whether anything interrupts it, and every line it prints are uncaptured, so the offence kills with absolve. Capture `judge <target>` in the Arena, with and without justice (condemnation) on them, to build on it |
| `perform rite of piety` | equilibrium 3.80s, 600 devotion | Enemies struggle to leave; a balance penalty when it holds them |

Weaponry `TARGET <body part>`: HEAD, TORSO, RIGHT/LEFT ARM, RIGHT/LEFT LEG, NOTHING. Torso
hits cause internal bleeding, head hits concussion. The smite's own limb words still need a
capture (`head` is the only one seen).

Hunting (Battlerage, denizens only, rage not balance):

| Command | Costs | Does |
|---|---|---|
| `crack <target>` | 17 rage | **Shatters a denizen's shield**: the "rage" case of Anzerloi's shield rule |
| `angel torment <target>` | 14 rage, 16s cooldown | Damage |
| `hammer <target>` | 25 rage, 23s cooldown | More damage against clumsiness or amnesia |

**Heresy** (`hunt heresy`: 4.00s of equilibrium, 400 mana) puts fire on the mace. Against
denizens a smite burns through their magical shield, at half damage and as fire. **Against
adventurers a smite burns away their aura of rebounding**, which is the answer to
smiting into rebounding (13:58:03, above). `recite unflinching <target>` (1.60s prayer)
also conveys heresy, shorter-lived, when you are not already hunting heretics, and the
target's next parry fails. Since CLASSLEADS #178 (2026-10-23), while heresy is active,
finishing a prayer of at least two verses forces an extra ablaze tick on every ablaze enemy
in the room, without resetting the next tick's timer. Anzerloi (19:26:04–19:27:11): crack is the hunting attack "if
got the rage and no heresy"; with heresy, smite. "As for pvp you go on afflict lines and
cure lines."

`perform purity <target>`: **4.00s of equilibrium**, 250 devotion (none against denizens),
bypasses shields and prismatic barriers. HELP says equilibrium; Anzerloi called it a balance
move. HELP wins.

## RITES: what is up in the room

Verbatim, 2026-10-16 08:01:41 (`rites.lua` reads it):

```
You reach out to sense for holy rites:
Rite                Owner                         Seconds left
-------------------------------------------------------------
Well-being          Saemora                       1224
Revitalisation      Saemora                       346
Equilibrium used: 1.00s.
```

Costs 1.00s of equilibrium. Seconds are whole. Still not captured: what an empty room
prints, the line a rite prints when performed, the line when one lapses, and whether
performing a rite that is still up refreshes it or is refused. A Rite of Revitalisation
prints "The Rite of Revitalisation refreshes your body and mind." every 15 seconds
(hidden, `ui/gag.lua`).

### What a fight keeps up: nothing, on its own

Anzerloi, 2026-10-22 17:32–17:36, on what each rite is worth in a fight. Rites are passive,
chance-based helpers, besides arguably piety:

| Rite | When it pays | Why |
|---|---|---|
| demons | the fight | chips mana |
| cleansing | the fight | sometimes puts an enemy off balance as they raise a defence |
| revitalisation | health under pressure | "Not a typical problem for Priests." |
| healing | a partner is in the room | good with an allied group. Alone, angel care instead: mutually exclusive, mobile, faster, and it does not need balance |
| banishment | against an Ashtani | Ashtani use chaos entities |

The other rites rarely see use. Convocation with hellsight is a dead letter: a mass defence
negates it.

**Emunah raises none of them** (the user, 2026-10-23: "change it so i put the rites up
manually"). A fight used to raise this set in its first equilibria (`rites.lua`'s old
`M.PVP`). At 17:31:20–35 that day it spent metabolise's 3.0s, demons' 3.5s and cleansing's
3.6s of equilibrium while the mace, which needs equilibrium present, waited: 15.9s, three
verses, no blow, the prayer lapsing twice. Anzerloi, the same minute: "Rites? They sure
are [slow]. Why I generally don't use them mid-action." A rite you perform is kept up as
any other, and its renewals wait while PvP is on.

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
lessons"). **Superseded 2026-10-15:** the user states the character now has every ability in
Spirituality, Devotion and Zeal. Trained is not the same as specified: only Guilt and
Condemnation have their syntax, cost and replies captured, so they are still the only verses
Emunah sends. Each other one needs its `AB <name>` first.

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

The class's kill. Every attacking mode absolves on a fresh contemplate under half, saps
at once when a fresh reading and one sap (`sapPercent` over the confirmed afflictions) would
take them under half, and reads their mana again straight after that sap
(`class/priest_pvp.lua`, `killSap` and `killRead`). Anzerloi, 2026-10-23 14:38:17-14:38:57:
"You win by having their mana low enough. If that does not present itself on its own (on
your contemplations), you attempt to create conditions to attack their mana with saps."

Absolve is a **mana kill** and is binary: it either kills or fails, on the target's mana
being **below 50%**. Exactly 50% fails. The common route is to break a leg, prone the
target, drive mana down (an angel's sap does the mana damage), then absolve. Whether the
threshold is actually met is a calculation most players assume rather than compute.

Everything below is from Anzerloi in party chat, 2026-10-15 — an informant, not HELP.
Timestamps are the user's prompt clock. **[player]**

### The route (12:30:55, 12:32:10)

- Absolve needs the target **below 50% mana when it lands**.
- Their mana falls on its own as they act, and by your saps.
- Watch their mana with **`contemplate`**. Against **Mind Warden**, contemplate as close to
  the next attack as you can while still leaving time to read the result and queue the
  right attack. (Whose Mind Warden, and what it does, is not stated.)

### What a sap takes (12:33:53–12:37:05)

Each item adds a share of the target's **maximum** mana to one sap:

| On the target | Adds |
|---|---|
| guilt, spiritburn, tenderskin, burning — each | 3.5% |
| each level of a limb break | 3% |
| each mental affliction ("cured by focusing") | 2% |
| prone | 2% |
| any other affliction | 1% |

`sapPercent` reads "mental" as any affliction `afflist` lists a focus cure for, counts a limb
once at its worst tier (the tiers are under *Limb breaks* above), and counts inquisition as
"any other affliction" before its multiplier. Whether a sap does anything with none of
these up is not stated; the base is a parameter that defaults to 0.

### The two saps (12:37:44, 12:39:26)

- **`recite wrath`**, on prayer balance.
- **`angel sap`**, on equilibrium, and needs balance too.
- **Inquisition** adds 50% to an angel sap. It does nothing for `recite wrath`.

### When to sap (12:41 onwards)

Stack enough afflictions that one sap takes them well under 50%, or step them down when
it's worth it ("such as bringing 100% mana down to 60%").

### Momentum routes (12:50:44–12:52:15)

The two main routes are **kelp** and **lobelia** stacks, each a group of afflictions the
target cures from the same herb:

- **lobelia**: guilt, spiritburn, tenderskin (recites); masochism (a rebuke); recklessness
  (a chasten).
- **kelp**: `chasten body`; `perform sloth`, which gives weariness (`weakness` in
  `afflist`, the reference system's `gamename`).

### The prayer (12:45:21–12:49:55)

- Track `prayer_length` and `conviction` from GMCP. They arrive as charstats strings;
  `gmcp/vitals.lua` already parses them to numbers (`priest.prayer()`).
- Before each attack, list which recites and rebukes the current length and conviction
  allow. Example given: Revelations needs a prayer of at least 3 (the conviction figure was
  cut off). **`VERSES`** lists each verse's requirements.
- Some verses are **once per prayer**. Mark one unusable when you recite it, and free them
  all on a **successful rebuke** (any rebuke), or when `prayer_length` drops back to 0 for
  any other reason. Emunah marks on send and frees on the change to 0 (`M.ONCE_PER_PRAYER`
  is empty until `VERSES` says which verses are limited).

### From HELP (2026-10-15, `help/` has each verbatim)

| Command | Costs | Notes |
|---|---|---|
| `angel sap <target>` | equilibrium 2.75s, 5 Angel power | Drain scales with afflictions; HELP ranks them as Anzerloi does. Lands as `Your guardian angel casts a piercing glance at Anzerloi.` then `Equilibrium used: 2.75s.` (13:31:45): **no figure** for the caster, so only the next contemplate measures it |
| `recite wrath <target>` | prayer balance 3.00s | Once per prayer; needs 20% conviction and a prayer of 1 (`VERSES`). Also burns body if the target is ablaze **and** prone |
| `angel absolve <target>` | equilibrium 4.40s, 50 Angel power | Target "must be on less than half of his maximum mana". Success captured, see below; failure not yet |
| `contemplate <target>` | equilibrium 1.00s, 50 mana | `Anzerloi's mana stands at 5337/5405 [98%].` then `Equilibrium used: 1.00s.` (13:31:27); prompt `exckdb` → `xckdb`, balance kept. Read into `priest.mana(name)` |
| `chasten <target> [body\|mind\|<affliction>]` | equilibrium 2.80s, 100 mana | Body pool: paralysis, healthleech, clumsiness, nausea, asthma. Mind: epilepsy, dizziness, confusion, recklessness. A full pool gives addiction (body) or impatience (mind). "Can be performed off balance if following a smite attack" |
| `smite <target> <limb> [chasten <body\|mind\|affliction>]` | balance 2.90s | `help/ab-spirituality-mace.txt`: smite and chasten in one command |
| `perform sloth <target>` | equilibrium 2.20s, 10 devotion | Gives weariness (`weakness`) |
| `recite purge <target>` | prayer balance 1.60s | Damages and sets them **ablaze**: a 3.5% sap affliction, and half of wrath's body condition. VERSES: 5% conviction, once per prayer |
| `recite revelations <target>` | prayer balance 1.60s | Gives **hellsight**. VERSES: 10% conviction, prayer of 3, once per prayer |
| `recite reflection <target>` | prayer balance 2.70s | For ten seconds, some afflictions dealt to you are given back to them. VERSES: 5%, prayer of 2 |
| `recite ash <target>` | prayer balance 1.60s | **Delivers spiritburn.** Fire ticks then drain their mana, and so does moving while on fire |
| `recite burn <target>` | prayer balance 1.60s | "Leaving them tender and pained"; applying a salve drains their mana. HELP does not name the affliction. **Tenderskin**, confirmed by Anzerloi's spars (2026-10-13): `"Burn!" commands Anzerloi, ...` then `You have been afflicted with tenderskin.` (`pvp-locks.md`, *Anzerloi's route*) |
| `recite penance <target>` | prayer balance 1.60s | **Gives paralysis** |
| `recite fragility <target>` | prayer balance 1.60s | Next mace blow does about 30% more limb damage |
| `recite attend <target>` | prayer balance 1.60s | Strips their ear protection (deafness) |
| `recite rejection <target> <direction>` | prayer balance 2.80s | Damage at range, line of sight; bypasses shields and prismatic barriers |
| `recite fire <target\|me>` | prayer balance 3.00s | Fire protection on you or an ally |
| `recite glory`, `recite light`, `recite salvation [prepare]` | prayer balance 3.00s / 3.00s / 3.80s | Self-targeted, for the group: glory's relocation on a raised ally, light heals blessed comrades (about every 25s), salvation a prismatic barrier. AB PRAYER: a verse that targets yourself does not lengthen the prayer |
| `recite <verse> <target> rebuke <sin>` | with the verse | Ends the prayer with a punishment. darkness (prayer 2): paranoia; chaos (3): hallucinations; evil (3): masochism; heresy (4): inquisition, only on a target with guilt **and** spiritburn. Only on a verse that targets an enemy |

`VERSES`: glory (0%, 2), light (0%, 0), purge (5%, 0), reflection (5%, 2), revelations
(10%, 3), salvation (10%, 0), wrath (20%, 1) as conviction and prayer length; all seven
once per prayer. Conviction is a percentage. `class/priest.lua` holds these as
`VERSE_NEEDS`, `ONCE_PER_PRAYER` and `REBUKES`.

Sap, absolve and contemplate all spend **equilibrium**, so they compete with each other
and with `perform hands`. Wrath is on prayer balance but once per prayer and costs 20%
conviction to reach, so the repeatable sap is the angel's. Absolve and sap draw **Angel
power** against players (1500 seen in charstats, 2026-08-04).

**Conflict, unresolved:** HELP WRATH ends "Inquisition increases more than anything else",
the same sentence as HELP SAP. Anzerloi said inquisition boosts angel sap "BUT NOT recite
wrath" (12:39:26). `sapPercent` follows Anzerloi for now; it needs a test against a real
target.

Spiritburn and tenderskin are afflictions, not abilities: `AB` and `HELP` under those names
find nothing (13:07). Ash gives spiritburn (HELP says so); Burn is very likely tenderskin
(above). Still uncaptured, and by their one-line descriptions defensive: Will, Endurance,
Void, Protection, Persevere, Unflinching, Oration, Benediction.

### Absolve landing (13:39:01, in the Arena)

```
angel absolve anzerloi
You nod gravely at your guardian angel, whose wings flare suddenly as an alien and frightening look
of power sweeps across her face. With one hand, she reaches forward, and as her hand touches
Anzerloi's chest, it flares an impossibly bright white and enters his breast. The angel's eyes roll
back in her head in ecstasy as she rips the soul from Anzerloi's body. Anzerloi collapses without a
sound, his body now nothing more than a useless husk.
You have slain Anzerloi.
With the completion of your adventure, you feel your renown grow to new heights! (You gain 150
Renown.)
Defeated, Anzerloi is cast out of the Arena.
**********************************************************
You have been victorious and leave the Arena in triumph!
**********************************************************
```

The kill is announced by the ordinary `You have slain <name>.`, which `pvp.lua` already
reads to clear the target and end the session. The flavour text wraps at the client's width,
so nothing anchors on it. His mana before the cast was not contemplated, so this does not
measure the threshold.

### Rebuke counts its own verse (13:24:48)

Anzerloi: "Rebuke concludes a prayer, and is performed right after the recite, meaning that
on the point of rebuke it will count that recite for its prerequisite length." Example: "if
your prayer length is 1, you can, for instance, recite guilt rebuke darkness. The guilt
before it IS the prayer length 2 achieved, and then it is immediately reset by the rebuke."
So a rebuke needs its stated length **minus one** already in the prayer, and the prayer
ends with it (`priest.prayerAllows`). **[player]**

### A test cast that did not settle tenderskin (13:21:07–13:21:10)

**Settled since** by Anzerloi's spars (2026-10-13): "Return to ash" and "And you shall be
naught but cinders" are Ash, and give spiritburn; "Burn!" is Burn, and gives tenderskin.
Both by the game's own `You have been afflicted with ...` (`pvp-locks.md`, *Anzerloi's
route*). The capture below is kept as it was.

Asked for tenderskin, Anzerloi cast at the user:

```
"Return to ash," decrees Anzerloi, hands outstretched in your direction.
Your skin begins to grow uncomfortably hot.
...
You eat a lobelia seed.
The uncomfortable heat suffusing you fades.
```

"Return to ash" may be Ash's line rather than Burn's. And the reference system files both received lines
under **firedisrupt** (its firedisrupt trigger, and `valid.focus2`'s spirit-disrupt list), which
Emunah's trigger package inherits as a firedisrupt cure. The reference system predates spiritburn and
tenderskin, so Achaea may have reused the text; this transcript cannot tell. The GMCP
`Char.Afflictions.Add` name would: repeat it with `emset debug gmcp`.

### Rebuke heresy, and the conviction a closed prayer gives (2026-10-24 14:09-14:10)

The user against Anzerloi, who did not cure. Two four-verse prayers, each closed on
`rebuke heresy`, verbatim:

```
14:09:25.00  "Know the pain which you have caused," you proselytise to Anzerloi.
14:09:28.62  "Burn!" you command Anzerloi, fire leaping forth to sear him.
14:09:32.80  "Return to ash," you decree, focusing your holy might upon Anzerloi.
14:09:36.25  "And your guilt will be made plain," you proselytise to Anzerloi.
             You decree that Anzerloi will pay for her crimes against Creation.
             As your prayer ends, holy fire outlines your form and you feel your righteous conviction surge to
             yet greater heights.
             Your spirit surges with 20% holy conviction.
14:09:42.82  As your praying falters, your conviction does so in concert.
             Your spirit surges with 10% holy conviction.
14:09:49.28  As your praying falters, your conviction does so in concert.
             Your conviction has entirely left you.
```

and condemnation, burn, guilt, `guilt rebuke heresy` (no spiritburn on him) at 14:10:03-14:10:12,
printing the same decree line and the same 20%.

- **A four-verse prayer closed by a rebuke gives 20%**, the conviction wrath needs. With the
  two-verse prayer's 10% (09:58:49), that is 5% a verse.
- **Heresy's rebuke line does not say whether inquisition landed**: "You decree that <name>
  will pay for her crimes against Creation." came both with spiritburn on him and without
  (the "her" is the game's, for Anzerloi). Inquisition is confirmed only by its effects, as a
  push on a smite's line proning them (`pvp-locks.md`).
- **Conviction falls 10% about every 6.5s** once the prayer is over and no other has begun
  (14:09:36.25, 42.82, 49.28; 14:10:12.69, 19.25). Whether a new prayer holds it, so that
  wrath can still go at that prayer's fourth verse, is not yet captured.
- The first `recite guilt` at 14:09:21.03 landed at 14:09:25.00, after the prayer begun by
  burn had ended at 24.74: lag, not a rule. A verse late by that much ends the chain.

### One sap, measured (2026-10-24 14:10:25-14:10:54)

Straight after the two heresy prayers above, Anzerloi still not curing:

```
14:10:25.75  contemplate anzerloi
             Anzerloi's mana stands at 5339/5428 [98%].
14:10:47.95  angel sap anzerloi
             Your guardian angel casts a piercing glance at Anzerloi.
             Equilibrium used: 2.75s.
14:10:54.12  contemplate anzerloi
             Anzerloi's mana stands at 4012/5428 [73%].
```

**One sap took 1327 of 5428, 24.4%**, and more than that by whatever he regenerated in the
29s between readings. On him, uncured: guilt, tenderskin, spiritburn and justice from the
verses, and inquisition if the first prayer's heresy landed (guilt and spiritburn were both
on him for it). Anzerloi's figures (`priest.sapPercent`) give (3 x 3.5 + 1 + 1) x 1.5 =
18.75%: they undercount here. A doubled inquisition multiplier would fit (25%), but one
reading of an uncertain set is not enough to retune on, and undercounting is the safe
direction: the kill sap goes later than it might, and absolve still waits for a reading.
What it does show: with the lobelia trail and inquisition on them, two saps take a fresh
target from full into absolve's range.

### A sap on a clean target, and argentum eating the trail (2026-10-24 14:15-14:16)

```
14:15:10.90  contemplate anzerloi        Anzerloi's mana stands at 5413/5428 [99%].
14:15:43.92  angel sap anzerloi          Your guardian angel casts a piercing glance at Anzerloi.
14:15:46.91  contemplate anzerloi        Anzerloi's mana stands at 5318/5428 [97%].
14:15:48.11  recite burn anzerloi        (14:16:13.01) Anzerloi eats an argentum flake.
14:16:13.03  recite guilt anzerloi       (14:16:14.97) Anzerloi eats an argentum flake.
                                         Anzerloi straightens, as if some great burden had been lifted from his shoulders.
14:16:15.17  recite ash anzerloi         (14:16:17.06) Anzerloi eats an argentum flake.
14:16:17.14  contemplate anzerloi        Anzerloi's mana stands at 5318/5428 [97%].
14:16:20.01  angel sap anzerloi
14:16:23.12  contemplate anzerloi        Anzerloi's mana stands at 5252/5428 [96%].
             (14:16:22.88: the three-verse prayer lapsed for 15% conviction, 5% a verse)
```

- **A sap on nothing took 95 and 66 of 5428** (1.75%, 1.2%), but his mana was not still:
  "Bear in mind my mana is not static. When you sapped I was below 100%, and also
  regenerating it back. Just use set values" (Anzerloi, 15:19:22-15:19:51), and "sap_value
  should only be above 0 if the target has any actual affs" (15:45:11). So a sap on nothing
  counts as nothing.
- **Spiritburn and tenderskin are cured with no line of their own**: each went with an
  argentum eaten 0.2-0.3s after its verse, and only guilt prints one. So an eat of their
  herb is all there is, which is what `opponent.couldHaveCured` goes on.
- **He ate every two seconds or so, as fast as the verses landed**, so verses alone never
  stack the lobelia trail on him. It holds only when each exchange also gives an affliction
  of another herb, as the mace's kelp chasten does: one herb balance cannot take both.

### Wrath measured, and a new prayer holds conviction (2026-10-24 14:22:54-14:23:24)

Anzerloi not curing. `guilt rebuke heresy` closed burn, guilt, ash, guilt; then burn, guilt,
ash, a contemplate, wrath, a contemplate:

```
14:23:02.47  recite guilt anzerloi rebuke heresy
             You decree that Anzerloi will pay for her crimes against Creation.
             Your spirit surges with 45% holy conviction.
14:23:10.09  contemplate anzerloi    Anzerloi's mana stands at 5266/5428 [97%].
14:23:11.32  recite wrath anzerloi
             "And may the cleansing fires consume you!" you dictate to Anzerloi, holy flame wreathing him in
             cleansing fury.
14:23:14.57  contemplate anzerloi    Anzerloi's mana stands at 4658/5428 [85%].
14:23:17.62  Your spirit surges with 65% holy conviction.
14:23:24.10  As your praying falters ... Your spirit surges with 55% holy conviction.
```

- **A new prayer holds conviction**: no "falters" line came in the second prayer, which began
  at 14:23:04, 1.6s after the rebuke.
- **Wrath does not spend conviction**: 45% before it, 65% once its prayer of four ended, the
  same 20% any four-verse prayer adds. Conviction builds prayer on prayer.
- **Wrath took 608 of 5428, 11.2%**, with tenderskin, guilt and spiritburn on him and
  inquisition if heresy landed. Anzerloi's figures give 3 x 3.5 + 1 = 11.5% for wrath, which
  inquisition does not multiply: they hold for wrath, with no base.
- Wrath's line: "And may the cleansing fires consume you!" ... "holy flame wreathing him in
  cleansing fury."
- The first prayer's 45% (against 20% for the same prayer at 14:09:36) is not explained by
  the capture; leftover conviction from a prayer before it is the likely reason.

### Conviction drains when the prayer lapses (13:48:20)

```
As your praying falters, your conviction does so in concert.
Your conviction has entirely left you.
```

So conviction is not banked: let the chain lapse and it is gone. The timings are measured
from the spar against Erishka below: a prayer ends about five seconds after its last verse,
and the conviction it grants is gone about six and a half seconds after that unless another
prayer has started.

### A spar against Erishka (2026-10-23 09:58)

Maelgor against Erishka, an Auroran Knight, in attack mode (head smites and angel sear).
Logged from Maelgor's side. About ten recites went out in 25 seconds and three landed.

**A verse needs balance and equilibrium, and spends neither.** Each recite that landed went
with both up: guilt at 24.63, unflinching at 38.00, ash at 43.92. Each one sent with either
down was refused:

```
09:58:29.90  perform rite of demons|recite unflinching erishka
             As you enact the rite of demons, your hackles rise.
             Equilibrium used: 3.50s.
             You must regain equilibrium first.
```

The same refusal on balance followed the recites at 25.24, 26.24, 41.12, 44.27 and 45.60,
each sent while a smite's balance was out. The smite at 24.89 went through behind the guilt
at 24.63, so the verse does not spend balance.

**The prayer's window.**

```
09:58:24.63  "Know the pain which you have caused," you proselytise to Erishka.
09:58:29.90  Your prayer draws to an unsatisfying conclusion.
09:58:38.00  "The light shall not be denied," you declare, as you prepare for your clash with Erishka.
09:58:43.92  "And you shall be naught but cinders," you decree, focusing your holy might upon Erishka.
09:58:49.02  As your prayer ends, holy fire outlines your form and you feel your righteous conviction surge to
             yet greater heights.
             Your spirit surges with 10% holy conviction.
09:58:55.54  As your praying falters, your conviction does so in concert.
             Your conviction has entirely left you.
```

A one-verse prayer ended 5.27s after its verse; a two-verse prayer ended 5.10s after its
second, granting 10%. That conviction was gone 6.52s later with no new prayer.

**Unflinching** is `"The light shall not be denied," you declare, as you prepare for your
clash with <target>.` followed by `Rage fills you as the thought of heresy inspires you to
greater efforts.` That rage ended at 10:01:38.42 (`Your rage to destroy heretics
subsides.`), three minutes after the verse.

**Two moves that spend different balances still cannot share a prompt.** `smite erishka
head chasten clumsiness|angel sear erishka` gave `You must regain balance first.` for the
sear straight after the smite's lines, both times (41.12, 44.20). Each needs the balance
the other spends.

**A head smite** did 13.9% to Erishka's head, three times.

### A complete attack (13:48:20–13:49:37)

Anzerloi: "Not gonna get you anywhere without smiting and chastening." "Your attack needs
to be as complete as possible." "Recite/bal/option eq." "Giving me one aff at the same rate
I can cure it isn't going to cut it." **[player]**

Each exchange should use all three: a verse on prayer balance, `smite <limb> chasten
<aff>` on balance, and an equilibrium action when one is worth it. One affliction per
exchange is cured as fast as it lands; stacking afflictions that share a herb is what
outpaces the cure.

### Smite with chasten, into rebounding (13:58:03–13:58:21)

```
smite anzerloi head chasten asthma
You utter a prayer and smite Anzerloi's head with a spiritual mace.
The attack rebounds back onto you!
As your blow lands with a crunch, you perceive that you have dealt 13.9% damage to yourself's head.
Health lost: 404 (physical blunt).
Balance used: 2.5s.
You direct a dark bolt of energy through your mace towards Anzerloi. The curse of asthma is brought
down on to your victim.
H:86% M:92% E:99% W:100%  eckdb
Anzerloi eats an aurum flake.
Health lost: 38 (raw).
You bleed 38 health.
You have recovered balance on all limbs.
```

- **`head` is a limb word** the smite takes. The leg words are not yet seen.
- **The attached chasten costs no equilibrium.** Balance only: `Balance used: 2.5s.`, and
  the prompt went `exckdb` → `eckdb` (equilibrium kept). 2.5s, not HELP's 2.90.
- **Rebounding turns the smite back on you:** 13.9% to your own head, 404 health, then
  bleeding. **The chasten still landed.** Smiting into rebounding is a heavy self-hit, so
  the offence must know when the target has it. It dropping is visible: `Anzerloi's aura of
  weapons rebounding disappears.` (13:58:12, just before his own verse). How a Priest strips
  it is not known.
- **Chasten announces what landed**, naming the affliction: `The curse of asthma is brought
  down on to your victim.` Emunah tracks it on the target (`class/priest.lua`).
- **Their cures are visible:** `Anzerloi eats an aurum flake.` (asthma's kelp alternative,
  0.1s later), `Anzerloi takes a long drag off his pipe.`

His verses at the user, as the target sees them, for the record:

```
"Know the pain which you have caused," Anzerloi proselytises, finger pointed directly at you.
A terrible guilt descends upon you.
"And your guilt will be made plain," Anzerloi proselytises, finger pointed directly at you.
A terrible guilt descends upon you.
You suddenly feel alone; betrayed, and much more as a terrible panic seizes you.
As his prayer draws to a close, holy fire outlines Anzerloi.
```

The second guilt carried a rebuke: paranoia ("terrible panic", cured by ash: `Aaaahhh. No
one is out to get you after all.`), and the prayer closed with it. Emunah cured the guilt
in 0.3s and the paranoia in 0.6s.

### Still needed before any of this sends

- ~~Confirmation that Burn gives tenderskin~~: settled by the spars of 2026-10-13, along
  with Ash's spiritburn, sloth's weariness, and wrath and absolve landing (the target's
  end; `pvp-locks.md`, *Anzerloi's route*).
- Live lines, from the caster's end: absolve and sap failing; the smite's leg words
  (`left leg` / `right leg` are sent on HELP TARGET's word).
- How a Priest takes down rebounding, and the line when a target raises it.
- Whether a sap has a base amount; whether inquisition boosts wrath; whether a verse spends
  conviction.

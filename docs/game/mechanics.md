# Game mechanics

Verified from play unless marked otherwise. Each entry says what established it.

## Balance

**A sent command is not an executed one.** Achaea runs a command some time after it
arrives. Until it does, `Char.Vitals` keeps reporting the balance that command is about to
spend as *available* — truthfully. Anything gating on the raw flag will double-send.

> Two smites went out at `00:17:22.40` and `00:17:23.06`, both while the prompt read
> `ex-`. The second was rejected once the first resolved.

**Achaea states the exact cost when it takes balance:**

```
Balance used: 3.2s.
```

Verified for Priest `smite`. Arm timers off this rather than estimating. The
pre-confirmation window is one network round trip — `getNetworkLatency()` measures it.

**Movement costs both balance and equilibrium** *(stated by the user)*. It is therefore
directly rivalrous with attacking: a step straight after a kill waits out the full balance
recovery, and that pause is the game's rule rather than something to tune away.

Supporting evidence for the balance half:

> `06:50:13.31` prompt `e-` (equilibrium, no balance) → `e` sent →
> `06:50:16.26` `You must regain balance first.` →
> `06:50:16.49` `You have recovered balance on all limbs.`, prompt `ex-`

The IRE mapper agrees, deferring speedwalks with `(when we get balance back / aren't
hindered)`. So movement and attacks compete for the same resource: a step taken straight
after an attack is refused, and an attack fired mid-speedwalk races the next step.

**Herb balance is its own balance**, separate from attack balance. *(Stated by the user;
not independently confirmed from a transcript — no herb was eaten in any capture.)* Salve,
smoke, focus and elixir each have their own too, evidenced by each having a distinct
rejection message.

## Rejections

Exact wording — these are trigger patterns, so they matter verbatim.

| Message | Means |
|---|---|
| `You must regain balance first.` | No balance. Also what a herb eaten too soon gets. |
| `You have not yet regained balance for applying salves.` | Salve balance |
| `You may not drink another elixir yet.` | Elixir/sip balance |
| `You have not yet recovered balance for smoking.` | Smoke balance |
| `You have not yet regained your mental balance.` | Focus balance |
| `You must be standing first.` | Prone |
| `You are too stunned to be able to do anything.` | Stunned |
| `Now now, don't be so hasty!` | **Rate limited** — commands sent too fast |
| `Clot is not a valid command.` | No `clotting` lesson (Survival) |
| `What do you want to eat?` | The herb named is not in inventory — **being in the rift is not enough**, and a cure must check what is in hand rather than total supply. Nothing was eaten and no herb balance was spent. Observed at 18:26:51.05, right after a death dropped everything. |
| `What is it that you wish to drink?` | **Not a balance rejection.** No vial we are carrying holds that fluid, so the noun in `drink <fluid>` did not resolve. Nothing was drunk and no sip balance was spent. Observed at 11:10:14.06 on `drink mana`, with fourteen vials held and 2000 sips of mana sitting in the rift. |

## Irid moss

Its own balance — not herb balance, not sip balance. Confirmed live at 11:28:

```
outr irid
You remove 1 irid, bringing the total in the rift to 498.
eat irid
You eat some irid moss.
You feel your health and mana replenished.        (mana 80% -> 88%)
You may eat another bit of irid moss or potash.   (~2.75s later)
```

- Restores **health and mana together**.
- Must be pulled from the rift before it can be eaten.
- `OUTR` works while anorexic; `EAT` does not — anorexia blocks eating, and irid moss is
  eaten. Neither works while stunned or dead.
- The recovery announcement names potash as well, so the two presumably share the balance.
  Untested — nothing uses potash yet.

## Moving things in and out of the rift

Both directions confirm with the same sentence, and the item can be two words:

```
outr 3 irid
You remove 3 irid, bringing the total in the rift to 490.
inr all
You store 9 ash, bringing the total in the rift to 100.
You store 10 green ink, bringing the total in the rift to 10.
```

Measured turnaround for `OUTR`: **0.23s** (sent 11:48:26.14, confirmed 11:48:26.37). Neither
costs a balance.

## Vials and the rift

Held vials do not refill themselves, and the rift is not a vial: 2000 sips of mana in the
rift is not something `drink mana` can reach. From `HELP RIFT`, verbatim:

    FILL <vial> WITH <fluid> FROM RIFT
       Fill a vial with fluid from your rift.

Not yet established, so do not build on it without asking: whether the target vial has to be
empty first, what a successful fill prints, and what it prints when the rift is out of that
fluid. Nothing automates filling for that reason.

## Incapacitation

**Stunned blocks every command.** Not just attacks — everything, including `STAND`.

Onset (the tail varies by denizen and attack, so anchor only the head):

```
You are momentarily stunned as the massive bulk of a guard pig smashes into you.
```

Clears with `You are no longer stunned.`

**Attacking needs equilibrium as well as balance.** Confirmed live: after `perform hands`
took equilibrium, the prompt read `x-` (balance, no equilibrium) and three smites in a row
came back `You must regain equilibrium first.` So the heal and the attack compete, and a
system that models smite as balance-only throws away every attack during that window.

**`You are not fallen or kneeling.`** is the reply to `STAND` when already upright -- not
"You are already standing.", which has never been observed.

**STAND costs balance.** Confirmed live: knocked down at `08:12:57.54` with the prompt
reading `e-`, the stand went out immediately and came back `You must regain balance first.`
A single refused attempt left the character flat for twelve seconds.

**Prone blocks only what needs you upright.** Attacks and `GET` do; eating a herb and
drinking an elixir do not. Detected from `You must be standing first.`, cleared by
`You stand up.` or `You are already standing.`

Knockdown onset messages are per attack per denizen. Observed so far:

```
Springing forward, a wildcat soldier launches forward into you, sending you sprawling.
```

One hit can cause both stun and knockdown. Stun clears first, and only the next action
reveals you are still down.

> Guard pig charge, `00:17:19.00` → stun. `00:17:21.98` → `You are no longer stunned.`
> `00:17:22.18` → `You must be standing first.`

## Aggressive denizens do not stop when you do

Confirmed live: a safety stop fired mid-fight and the goat carried on ramming for ~270 a
time -- `08:43:02`, `43:08`, `43:14`, `43:21` -- while the character stood there tanking and
drinking, neither fighting nor leaving. Disengaging is not an escape from something that is
already attacking you.

So the damage-rate check is advisory in combat and only the critical health floor applies;
out of combat it stands, because a drain nothing is fighting back against -- bleeding, a
room effect -- is exactly the case where stopping IS the remedy.

Also observed on that goat's kick: `Balance used: 0.5s.` on ITS attack, i.e. some denizen
attacks cost the victim balance. Not yet acted on.

## Rate limiting

Achaea throttles fast command streams with `Now now, don't be so hasty!`. Steps roughly one
round trip apart (~300ms) triggered it. Anything driving movement itself must pace it.

## Abilities

`CLOT` is the Survival ability **`clotting`**, not a universal command. Without the lesson:
`Clot is not a valid command. Did you perhaps mean CT, CLOSE, or QL?`

Gate on positive confirmation from the skill index — the permissive "assume yes while the
index loads" default is wrong for abilities known to be absent.

## Abilities in use

| Command | Costs | Notes |
|---|---|---|
| `smite <id>` | spends balance 2.9-3.2s; **requires** equilibrium | Priest attack. Balance is announced (`Balance used: 2.9s.`) and equilibrium is **not consumed** -- the prompt reads `e-` straight after (12:41:14.49). It only needs equilibrium to be present, so the requirement is invisible until you lack it. |
| `perform hands` | equilibrium, 3s | Priest self-heal, ~20% of the bar. Announced with `Equilibrium used: 3.00s.` Independent of sip balance, so it stacks with `drink health` -- but NOT with attacking, which needs equilibrium too. |
| `drink health` | sip balance | Announced back with `You may drink another health or mana elixir.` |
| `clot` | — | Requires the Survival ability `clotting`. |
| `get <id>` | balance and equilibrium | Competes directly with attacking, which is awkward: gold appears from a kill that just spent both. |
| `perform penitence <id>` | equilibrium ~1s, 300 devotion, 100 mana | Priest (Devotion). Against denizens the devotion cost is *reduced* and the equilibrium cost *increased* by unstated amounts. Brands the target to take **10% more damage from SPIRITUALITY SMITE**. |
| `stand` | balance | Getting up is not free. A knockdown lands right after your own attack, so balance is exactly what you lack when you need it. |
| movement (`n`, `s`, ...) | **balance AND equilibrium** | Confirmed by the player: you cannot change rooms without both. This is why the walker sits out the full recovery after every kill (`Held "s" -- no balance` at 12:40:56) -- the pause is the game's rule, not a bug in the walker. Do not "optimise" it away. |
| `outr` / `inr` | free | Neither costs a balance. Confirmed 0.23s turnaround. |

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
| `def` | equilibrium 0.50s | Observed 13:29:20.97. Not free — do not poll it |
| `def brief` | — | Brief names, close to the GMCP defence names |
| `perform inspiration` | equilibrium 3.50s | Priest. Lasts around ten minutes (13:35:33.62 to 13:45:28.50), ending with "You slump slightly as the divinely-inspired strength leaves your body." |

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
their kill route is a mana kill (see absolve, below). So mental afflictions are a slow loss
that compounds, while anorexia is a shut vector — and the vector it shuts is where most
cures live.

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
| **blackout** | Afflictions applied during it produce **no `Char.Afflictions` updates at all** | Do not reconcile while it is up; catch up the moment it lifts |
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

## Paralysis blocks almost everything

Three verbatim refusals, all observed in one arena bout:

```
Your state of paralysis prevents you from doing that.          (drink health)
You are paralysed and cannot do that.                          (drink health)
Frustratingly, your body won't respond to your call to action.  (perform hands)
```

**Eating still works**, which it must — bloodroot is what cures paralysis. `core/queue.lua`
therefore flushes only the eating vectors while it is up, plus `tree`: whether a tattoo can
be touched while paralysed is unverified, and withholding the last resort from a character
that is already stuck is the worse error.

## Eating inside the herb balance

`The plant has no effect.` is what Achaea says when a herb is eaten **while still off herb
balance**. The herb is consumed and nothing is cured.

It is not a statement about the cure being wrong, which is the natural reading and the
expensive one — an attempt to act on that reading disabled `eat bloodroot` for paralysis and
`eat lobelia` for guilt mid-fight.

Curing an affliction and regaining the balance are separate events: eating bloodroot cures
paralysis **instantly** and still costs the full herb balance. Anything that infers the
balance from a cure landing will send the next eat inside it.

The balance is announced — `You may eat another plant or mineral.` — so it never needs
inferring.

## Commands that fail for free

Not every rejection costs something, and knowing which is which decides whether a check is
worth doing before sending.

- **Penitence on a target that already has it** fails and costs no balance or equilibrium.
  Re-branding is wasteful but not expensive, so the guard against it can be cheap.
- **Touching an active tattoo** costs the full balance. The guard has to be reliable.

## Priest: absolve

The class's kill mechanic, for reference — not implemented.

Absolve is a **mana kill** and is binary: it either kills or fails, on the target's mana
being **below 50%**. Exactly 50% fails. The common route is to break a leg, prone the
target, drive mana down (an angel's sap does the mana damage), then absolve. Whether the
threshold is actually met is a calculation most players assume rather than compute.

## Devotion

Priest's class resource, reported by `charstats` as a **percentage only** -- so an ability
costing "300 devotion" cannot be checked for affordability directly. Anything gating on it
uses a cautious percentage floor rather than a calculation, and says so.

Running out mid-hunt is expensive: `perform hands` and `perform penitence` both draw on it,
as does the class resource floor in `watch.lua`.

## Prompt

`CONFIG PROMPT CUSTOM` builds a custom prompt. Tokens verified from `HELP` (see
`help/config-prompt.txt` when captured): `*%h *%m *%e *%w` percentages, `*b` balances,
`*d` defences, `*t` target name, `*s` server time (GMT, `HH:MM:SS.hh`), `#r`/`#R` etc for
colour. Percentage tokens do **not** append `%` — add it literally.

`*t` reflects whatever `SETTARGET` holds, so it shows a replica number for denizens and a
name for players without any special-casing.

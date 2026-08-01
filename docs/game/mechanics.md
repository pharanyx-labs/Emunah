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

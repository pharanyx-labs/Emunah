# Balance and rejections

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
| `You must regain balance first.` | No balance. **Generic** — see below. Also what a herb eaten too soon gets. |
| `You have not yet regained balance for applying salves.` | Salve balance |
| `You may not drink another elixir yet.` | Elixir/sip balance |
| `You have not yet recovered balance for smoking.` | Smoke balance |
| `You have not yet regained your mental balance.` | Focus balance |
| `You must be standing first.` | Prone |
| `You are too stunned to be able to do anything.` | Stunned |
| `You are asleep and can do nothing. WAKE will attempt to wake you.` | Asleep. The game names the one command that works. Observed three times at 06:03:03–06:03:13, each answering a `STAND` |
| `Now now, don't be so hasty!` | **Rate limited** — commands sent too fast |
| `Clot is not a valid command.` | No `clotting` lesson (Survival). Since trained — kept as the backstop for the reverse mistake |
| `You do not bleed, my friend.` | `CLOT` with nothing to clot. **Not a rejection** — nothing was refused and nothing was spent |
| `What do you want to eat?` | The herb named is not in inventory — **being in the rift is not enough**, and a cure must check what is in hand rather than total supply. Nothing was eaten and no herb balance was spent. Observed at 18:26:51.05, right after a death dropped everything. |
| `What is it that you wish to drink?` | **Not a balance rejection.** No vial we are carrying holds that fluid, so the noun in `drink <fluid>` did not resolve. Nothing was drunk and no sip balance was spent. Observed at 11:10:14.06 on `drink mana`, with fourteen vials held and 2000 sips of mana sitting in the rift. |

### `You must regain balance first.` is not owned by any one vector

It answers whichever command wanted the physical balance, so it cannot be attributed to a
fixed vector. Transcript, 12:01:18.64 onward:

```
-> perform hands            (equilibrium vector)
-> eat irid                 (moss vector)
12:01:19.03  You must regain balance first.
12:01:19.04  You eat some irid moss.          <- the eat WORKED
```

Two commands, two replies, in order: the refusal belongs to `perform hands`. It was being
read as a herb refusal, which re-armed the herb recovery timer for a herb balance that was
perfectly fine. Again at 12:01:24.47 and 12:01:28.17 with no eat in flight at all — the
previous one had resolved five seconds earlier.

What the message always states is that **balance** is gone; that much is recorded
unconditionally. The herb reading is applied only when a herb or moss action is actually in
flight.

## `PERFORM HANDS` needs balance as well as equilibrium

It *costs* equilibrium — `Equilibrium used: 3.00s.` — but it is **refused when balance is
down**. Five for five in one fight:

| Time | Prompt | Result |
|---|---|---|
| 12:01:18.64 | `e-` | `You must regain balance first.` |
| 12:01:22.98 | `e-` | `You must regain balance first.` |
| 12:01:27.70 | `e-` | `You must regain balance first.` |
| 12:01:30.94 | `ex-` | `You lay your hands on yourself.` |
| 12:01:34.31 | `ex-` | `You lay your hands on yourself.` |

(`e` is equilibrium, `x` is balance — confirmed at 12:01:08.67, where `You have recovered
balance on all limbs.` turned `e-` into `ex-`.)

This matters more than it looks: smite holds balance for 2.8s of every attack cycle, so
during a fight the character is off balance most of the time and nearly every hands attempt
was being refused — while healing at 23% health.

### Its success line is `You lay your hands on yourself.`

Followed by `A feeling of divine warmth and joy spreads through you.` Nothing was matching
either, so the equilibrium vector was never confirmed and every hands — including the ones
that plainly worked — timed out:

```
12:01:31.34  You lay your hands on yourself.
12:01:31.83  No confirmation for [equilibrium] perform hands -- re-arming.
```

**Keep-up's item-based raises hit this too, not just curing.** `have.cure()` already checks
possession before sending a cure (this is what the `What do you want to eat?` row above is
about) — `defkeepup.tick()` did not, for defences raised by eating or smoking an herb
(`blindness`/bayberry, `deathsight`/skullcap, and others resolved through
`afflist.defenceCures`). Watched at login, 17:03:45–48: `eat skullcap` answered `What do you
want to eat?` three times in under three seconds, exhausting the attempt budget and retiring
`deathsight` for the rest of the session, while the rift still held 96 skullcap and
restocking pulled one into hand only seconds later — the raise simply ran before restocking
got a turn. Fixed by having `deflist.M.resolve()` also return the item a raise needs, and
`defkeepup.tick()` holding (not spending an attempt) until `have.item()` — or, for the smoke
vector, `have.pipe()` — confirms it is actually in hand.

## Rate limiting

Achaea throttles fast command streams with `Now now, don't be so hasty!`. Steps roughly one
round trip apart (~300ms) triggered it. Anything driving movement itself must pace it.

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

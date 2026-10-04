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

**Salve, focus and tree announce their return too** [svof], verbatim from svof's `svo got
salve balance`, `svo got focus balance` and `svo got tree balance` triggers:

```
You may apply another salve to yourself.
Your mind is able to focus once again.
You may utilise the tree tattoo again.
```

Nothing matched these until 2026-10-03, so all three ran on their fallback estimate alone.
`test/latency.lua` scripts a server that returns the balance at a chosen moment. With the
estimate longer than the balance, a salve went out 0.6s late and a focus 1.5s late. With it
shorter, the early send was refused and the refusal re-armed the whole estimate: a focus 4.1s
late, and a salve that had not gone at all 6s later. With the lines, 0ms in every case.

**The affliction-healing elixirs have their own balance** [svof]: immunity, frost, venom,
speed and levitation run on `bals.purgative`, which svof gates (`check_purgative`)
independently of the health/mana sip (`check_sip`). HELP curing-balances lists four balances
and does not mention these elixirs at all. Its return, from svof's `svo got purgative
balance`:

```
You may drink another affliction-healing elixir.
Your system is able to absorb antidotes once again.
```

**[open]** Whether a purgative drunk off its balance draws `You may not drink another elixir
yet.` (the sip's rejection) or a line of its own is not established. Emunah applies that line
to a purgative only when a purgative is the one drink in flight.

**Smoke balance announces its return:** `Your lungs have recovered enough to smoke another
mineral or plant.` Seen at 14:18:47.21 and 14:18:52.50 (2026-09-28), 1.5–1.7s after each
smoke. SMOKE is a "puff cure": per Anzerloi (2026-09-28), "you can do it if on puff balance
and not asthmatic". It doesn't wait on elixir, herb, balance or equilibrium.

## Rejections

Exact wording — these are trigger patterns, so they matter verbatim.

| Message | Means |
|---|---|
| `You must regain balance first.` | No balance. **Generic** — see below. Also what a herb eaten too soon gets. |
| `You have not yet regained balance for applying salves.` | Salve balance |
| `You may not drink another elixir yet.` | Elixir/sip balance. Possibly the purgative's too — see above |
| `You have not yet recovered balance for smoking.` | Smoke balance |
| `You have not yet regained your mental balance.` | Focus balance |
| `You must be standing first.` | Prone |
| `You are too stunned to be able to do anything.` | Stunned |
| `You are asleep and can do nothing. WAKE will attempt to wake you.` | Asleep. The game names the one command that works. Observed three times at 06:03:03–06:03:13, each answering a `STAND` |
| `Now now, don't be so hasty!` | **Rate limited** — commands sent too fast |
| `Clot is not a valid command.` | No `clotting` lesson (Survival). Since trained — kept as the backstop for the reverse mistake |
| `You do not bleed, my friend.` | `CLOT` with nothing to clot. **Not a rejection** — nothing was refused and nothing was spent |
| `You already possess equilibrium.` | `CONCENTRATE` with equilibrium not disrupted (play, 2026-09-28; [svof] `cure disrupt`). **Not a rejection**: it frees the `special` slot and drops any tracked `disrupted` |
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
therefore flushes only the eating vectors (plus `free` and `writhe`) while it is up.

**`TOUCH TREE` is refused while paralysed.** Confirmed live 2026-08-03 `16:14:25.08`:
`touch tree` sent while paralysed came back `Frustratingly, your body won't respond to your
call to action.` So `tree` is not among the vectors allowed through (`queue.WHILE_PARALYSED`).

## Riding: what costs what

From one `emset debug gmcp` trace (the user, 2026-10-04, 10:09:37–10:10:28), with the
horse `horse368644`. The character's Riding skill tops out at VAULT (`AB RIDING`).

| Command | Reply | Cost |
| --- | --- | --- |
| `vault horse368644` | `You easily vault onto the back of a heavy horse.` | `Balance used: 1.0s.` (prompt lost `x`) |
| `dismount` | `You step down off of a heavy horse.` | none seen |
| `order horse368644 follow me` | `Your order is obeyed.` / `A heavy horse obediently falls into line behind you.` | none: no balance line, prompt flags unchanged |
| `lose horse` | `You move about quickly and lose a heavy horse.` | `Balance used: 0.5s.` |
| `mounts` | `Your loyal mounts are:` … | `Equilibrium used: 4.00s.` (09:47:01). Never sent automatically |

The user names the follow command as `order 368644 follow me` (bare number); that is what
`riding.lua` sends.

**The order costs nothing but needs balance and equilibrium both** (2026-10-04 login):
refused `You must regain equilibrium first.` at 11:36:47.81 (balance up, mindseye's
equilibrium spent) and `You must regain balance first.` at 11:36:50.90 (equilibrium up, the
vault's balance spent). Since it is pointless once riding, it is not sent while our own
vault is queued or in flight.

**A sent balance action holds everything that needs balance until it is answered.** At
11:36:50.33 `perform bliss` and the order went out behind `vault horse368644` and both were
refused for balance. `vitals.spend("bal")` had marked it spent, and nothing but a
`Char.Vitals` carrying `bal` writes it back, so one sent before the server ran the vault did
(inferred: no GMCP trace of that moment). `act.blocked` now treats an unanswered action on
the `balance` slot as balance spent, and the same for `equilibrium`.

**Riding is not in GMCP.** The vault produced only `Char.Vitals`, no `Char.Defences.Add`.
The state comes from the lines above, svof's (`defs_data.riding` on/off lines, its
`lost_riding` and "riding already on" triggers) **[svof]**, and the `DEFENCES` listing line
`You are riding (.+).` **[svof defr]**.

**Falling asleep throws you off** (2026-10-04, 10:33:32.81): `You close your eyes, curl up in
a ball, and fall asleep.` then `You lose purchase on a heavy horse.` — svof's offr line, so
riding goes false and the follow order goes out once awake (10:38:22.70, obeyed).

**The mount is in the room's `Char.Items` list whether ridden or following** — listed in the
room walked into on horseback (10:09:48) and while following (10:10:12), and missing once lost
(10:10:28). Its replica number never changes (the user).

**Asking is free** (the user, 2026-10-04, 10:21:15–10:21:35, while riding): no balance line,
prompt flags `exckdb` throughout.

| Command, while riding | Reply |
| --- | --- |
| `vault horse368644` | `You must dismount before you can mount anything else.` |
| `order 368644 follow me` | `A heavy horse is already following you.` |

So while the riding state is unknown, Emunah vaults: a refusal costs nothing and says we are
riding, and otherwise the vault is the one keep-up wanted. The refusal puts back the balance
`vitals.spend("bal")` marked spent, since `Char.Vitals` will not resend an unchanged `bal`.

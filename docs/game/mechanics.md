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
| `You must regain balance first.` | No balance. **Generic** — see below. Also what a herb eaten too soon gets. |
| `You have not yet regained balance for applying salves.` | Salve balance |
| `You may not drink another elixir yet.` | Elixir/sip balance |
| `You have not yet recovered balance for smoking.` | Smoke balance |
| `You have not yet regained your mental balance.` | Focus balance |
| `You must be standing first.` | Prone |
| `You are too stunned to be able to do anything.` | Stunned |
| `You are asleep and can do nothing. WAKE will attempt to wake you.` | Asleep. The game names the one command that works. Observed three times at 06:03:03–06:03:13, each answering a `STAND` |

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
| `Now now, don't be so hasty!` | **Rate limited** — commands sent too fast |
| `Clot is not a valid command.` | No `clotting` lesson (Survival). Since trained — kept as the backstop for the reverse mistake |
| `You do not bleed, my friend.` | `CLOT` with nothing to clot. **Not a rejection** — nothing was refused and nothing was spent |
| `What do you want to eat?` | The herb named is not in inventory — **being in the rift is not enough**, and a cure must check what is in hand rather than total supply. Nothing was eaten and no herb balance was spent. Observed at 18:26:51.05, right after a death dropped everything. |
| `What is it that you wish to drink?` | **Not a balance rejection.** No vial we are carrying holds that fluid, so the noun in `drink <fluid>` did not resolve. Nothing was drunk and no sip balance was spent. Observed at 11:10:14.06 on `drink mana`, with fourteen vials held and 2000 sips of mana sitting in the rift. |

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

## Containers

Gold is stowed with `PUT <item> IN <container>` and the container is worn with
`WEAR <container>`, both by replica number *(command forms stated by the user)*:

```
put gold in backpack452292
wear backpack452292
```

**What `PUT` costs has not been established.** `loot.stowGold()` therefore declares no
requirement and relies on being retried when a balance returns, with an attempt budget to
stop that becoming a loop. Confirm the cost and the requirement can be declared properly.

**Also unverified: whether gold placed in a container leaves the `inv` location.** The model
is that it does — `Char.Items` tracks container contents under `repNNN` as a separate
location (see `gmcp/items.lua`) — and `M.STOW_ATTEMPTS` is what bounds the damage if that is
wrong. A `Char.Items` trace of one `put` closes both questions.

Observed verbatim, and the trigger that re-wears the pack:

```
You remove a canvas backpack.
```

## Shops

From `HELP SHOPS` (verbatim in `help/shops.txt`):

    BUY [<howmany>] <item> [CODE accesscode]

"Use the full name, with number, to be sure you're buying the right thing! ... Never use
two words." -- so `buy tun115258` is correct and `buy 115258` or `buy vial` is not. Quantity
is a leading number: `buy 7 pike61672`.

Prices are gold (gp), credits (cr) or Mayan Crowns (mc). "Groupable items can be sold in
bulk", shown as `gp ea` in `WARES` -- `shop.lua` treats that suffix as the signal that a
quantity purchase is meaningful, not the item's name (inks happen to be the observed
example, but nothing about the mechanic is ink-specific).

**Stated by the user, not yet in a HELP file or transcript:**

- Tuns (`tun<repnum>`, all "(refill only)" in `WARES`) are an exception to plain `BUY`.
  The correct command is `FILL RIFT WITH <tun repnum>`, one at a time -- multiples are not
  possible. This is a different command from the vial-filling one below (that one fills a
  *vial* from the rift; this one fills the *rift itself* from a shop).
- Retrieving gold to pay with must name the container by replica number, the same rule as
  `PUT`/`WEAR` above: `get <n> gold from backpack452292`, not `get gold from pack`.

**Not established, and `shop.lua` deliberately does not guess:**

- What `BUY` costs (balance/equilibrium), or what it prints on success or refusal. No
  trigger in `shop.lua` waits for a confirmation string for this reason -- the purchase is
  fired once, immediately after the `GET`, and verified after the fact by comparing
  `Char.Status.gold` before and after rather than by pattern-matching a guessed message.
- Whether `get <n> gold from <container>` costs anything beyond the ordinary GET cost
  already confirmed for picking gold up off the ground (`loot.take()`: balance,
  equilibrium, standing). `shop.lua` declares the same requirement on the assumption it is
  the same verb; unconfirmed against a container specifically.
- How `cr`/`mc` purchases work. `shop.lua` parses and displays them but does not attempt to
  buy them -- only `gp`-priced items are automated.

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

### Sleep

**The `Char.Afflictions` name is `sleeping`, not `asleep`.** Verbatim from the capture:

```
[gmcp] << Char.Afflictions.Add {cure="" desc="While asleep, you can do little but dream,
                                and wake up." name="sleeping"}
```

The `cure` field is **empty**, so `engine.serverCure()` cannot help — the response has to be
known here. `Char.Afflictions.Remove` carries it as a bare name in an array, like everything
else.

- **Blocks every command**, like stun rather than like prone. The one exception is `WAKE`,
  which the rejection itself names.
- **`WAKE` neither requires nor consumes balance or equilibrium** *(stated by the user)*.
  Being asleep is a special state rather than a balance.
- **Duration is variable**, sometimes up to ~10s.
- **`prone` is applied at the same time.** This is the important one for anything automated:
  the knockdown response fires while asleep and every `STAND` is thrown away.

> `06:02:59.94` `sleep` → `Char.Afflictions.Add sleeping` → `Char.Afflictions.Add prone` →
> `06:03:03.06` `You close your eyes, curl up in a ball, and fall asleep.`
> `STAND` at `06:03:03.27`, `06:03:12.85`, `06:03:13.06` → each `You are asleep and can do
> nothing. WAKE will attempt to wake you.`
> `06:03:15.10` `You open your eyes and stretch languidly, feeling deliciously well-rested.`
> (`Char.Afflictions.Remove` for `sleeping`, then for `prone`) →
> `06:03:15.31` `You stand up.`

Sleep is therefore driven from GMCP, not from text. **Two messages are still unknown** and
must not be guessed: what an *opponent's* sleep prints on onset, and what a successful `WAKE`
prints. The wake line above is specifically the rested one at the end of a full sleep.

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

## Pipes

`PIPELIST` is the complete state of every pipe, and the only reliable source for it:

```
Status  Pipe         Contents                       Puffs Months
-------------------------------------------------------------------------------
lit     pipe367581   a skullcap flower              10    250
out     pipe408402   slippery elm                   10    250
out     pipe422328   a valerian leaf                10    250
-------------------------------------------------------------------------------
```

**Inventory cannot answer this.** All three of those are called `a white stone pipe` — the
herb appears nowhere in the description. `have.pipe()` matched a herb name against the
inventory name and therefore never matched any pipe, falling through to its permissive
"allow it and warn" branch every time.

`PIPELIST` appears to cost nothing: six went out between `07:17:49` and `07:18:22` with the
prompt reading `ex-` throughout and no `Equilibrium used:` line, which Achaea does print for
anything taking equilibrium (`DEF` costs 0.50s and says so).

### Commands, and which id form each takes

Both forms are verified, each in its own command. **Neither has been observed working in the
other's slot**, so neither is assumed to.

| Command | Id form | Reply |
|---|---|---|
| `light pipe367581` | `pipeNNNNN` | `You use a soot-blackened tinderbox to make fire.` then **`You carefully light your treasured pipe until it is smoking nicely.`** |
| `light pipes` | — | Lights every pipe with contents. Answers `You light a white stone pipe.` — a **different** wording from the one above |
| `put skullcap in 367581` | bare `NNNNN` | `You fill your pipe with a skullcap flower.` |
| `smoke pipe367581` | `pipeNNNNN` | `You take a long drag of skullcap off your pipe.` |
| `smoke elm` | — | Works too: **`SMOKE` takes the herb** and resolves it to the pipe holding it. This is what every smoke cure in `curelist.lua` builds |

**The two LIGHT wordings are the trap.** Matching only `You light a white stone pipe.` means a
successful `light pipeNNNNN` confirms nothing, so the same pipe gets lit again a moment later:
observed at `07:34:16` and `07:34:21`, the second answered `That pipe is already lit`.

Other replies, all observed:

| Message | Means |
|---|---|
| `That pipe is already lit and burning nicely.` | `LIGHT` on a lit pipe |
| `There is nothing in the pipe to light.` | `LIGHT` on an empty pipe — our puff count was stale |
| `That pipe isn't lit.` | `SMOKE <herb>` when the pipe holding it has gone out |
| `Your pipe, containing a skullcap flower, has gone cold and dark.` | It went out. Names the **contents**, not the pipe |
| `Your lungs have recovered enough to smoke another mineral or plant.` | Smoke balance back |

### PIPELIST output must not be gagged

Deleting a line while Mudlet is still working through the lines that arrived in the same
packet shifts the buffer under it, and the rows after the deleted one never reach the trigger.
Reported in play as *"it's also only lighting the skullcap pipe"* — the first row. Only pipe
one was ever recorded, so only pipe one was ever lit.

### Every state change has its own message, so `PIPELIST` is a backstop

Polling for what the game already announces was reported in play as spam. Each transition is
observable on its own:

| Transition | Line |
|---|---|
| → lit | `You carefully light your treasured pipe until it is smoking nicely.` / `You light a white stone pipe.` / `That pipe is already lit and burning nicely.` |
| → out | `Your pipe, containing a skullcap flower, has gone cold and dark.` |
| → filled | `You fill your pipe with a skullcap flower.` — loaded but **still cold** |
| → empty | `There is nothing in the pipe to light.` |
| −1 puff | `You take a long drag of skullcap off your pipe.` |

**A freshly filled pipe holds 10 puffs.** Observed once per pipe — skullcap at `07:17:26`, elm
and valerian in the same listing. This is the one number inferred rather than read, so it is
a named constant (`pipes.FULL_PUFFS`) and the backstop poll corrects it if it is ever wrong.

None of the confirmations name the pipe, so they are attributed to whichever pipe the last
command was about — sound only because one pipe command is in flight at a time.

### Keep-up cannot be driven by the tick alone

`Char.Vitals` arrives with a **prompt**, and an idle character produces almost none — the
prompts at `07:34:21.81` and `07:35:42.82` are eighty-one seconds apart, which is exactly how
long the second pipe sat cold. `pipes.lua` runs a short self-scheduling chain timer while
anything still needs doing, the same fix the restocker needed for the same reason.

A pipe burns for minutes, not seconds: lit `07:16:17`, cold `07:19:41`. Smoking takes one
puff (10 → 9) and lighting does not.

### Not yet established

- **What `PIPELIST` prints for an empty pipe.** Every capture has all three holding
  something. `pipes.lua` treats blank contents *or* zero puffs as needing a refill, so it
  works either way, but a row it cannot parse at all would be dropped silently.
- **The message when a pipe runs out of herb**, if there is one.
- **Whether `LIGHT` or `PUT` costs anything.** The prompt read `ex-` throughout, so probably
  not; nothing is declared for either.

## The manna rite

One run, verbatim, at `07:07:08` — the source for `manna.lua`:

```
perform rite of sustenance
You utter a plea to the all-powerful gods to bless you with sustenance, and humbly place
your empty bowl on the ground.
A rain of nourishing manna falls from heaven, filling the bowl to the brim.
Equilibrium used: 3.00s.                                    (prompt ex- -> x-)
You have recovered equilibrium.
get bowl
You pick up an earthenware bowl.
drink bowl
With rapture in your heart, you lift the bowl of manna to your lips and slowly drain it,
savouring every last drop.
You feel utterly replete.
```

The gaps in that transcript (`:08` → `:15` → `:18`) are a player typing, **not** required
delays. The only real constraint is the rite's 3 seconds of equilibrium, which `GET` needs
back — and the game announces it, so nothing has to estimate it.

The line that means the bowl is actually full is the **rain**, not the plea: the plea prints
when the bowl is placed, one step earlier.

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
| `perform inspiration` | equilibrium 3.50s, **and requires balance and standing** | Priest. Lasts around ten minutes (13:35:33.62 to 13:45:28.50), ending with "You slump slightly as the divinely-inspired strength leaves your body." See below. |

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

### `BLIND` and `DEAF` are defences, and they need `MINDSEYE`

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

### A defence's name is not always what grants it

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
- The budget warning and `emunah defs names` list the names `Char.Defences` is reporting
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
`[unverified]` in the `emdefs` grid — the difference between "we have seen this work" and
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
stops after three tries and says so, and `emunah defs add <name> <command>` corrects it.
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

**"Costs a balance" ≠ the balance vector.** Achaea has several balances, and knowing a
command spends one does not say which. `perform bliss` was recorded as costing balance and
announced `Equilibrium used: 6.50s.` here. An unverified balance-costing defence therefore
requires **both** until one is actually observed — conservative in the only direction that is cheap, since waiting
costs a delay while guessing wrong costs a refusal and one of three attempts.

### `DIAG` output

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

### Forcing a prompt

A blank line (`send("")`) makes Achaea emit a fresh prompt, and with it `Char.Vitals` — the
tick everything in Emunah hangs off. Used when a decision changes between game events, so
it is acted on immediately rather than whenever the game next says something: toggling a
defence in `emdefs` does this.

### `PERFORM INSPIRATION`

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
`emunah defs add inspiration`.

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

## Prompt

`CONFIG PROMPT CUSTOM` builds a custom prompt. Tokens verified from `HELP` (see
`help/config-prompt.txt` when captured): `*%h *%m *%e *%w` percentages, `*b` balances,
`*d` defences, `*t` target name, `*s` server time (GMT, `HH:MM:SS.hh`), `#r`/`#R` etc for
colour. Percentage tokens do **not** append `%` — add it literally.

`*t` reflects whatever `SETTARGET` holds, so it shows a replica number for denizens and a
name for players without any special-casing.

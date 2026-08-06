# Sustenance and economy

Rift, containers, shops, pipes and the manna rite. Verified from play unless marked
otherwise. Each entry says what established it.

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

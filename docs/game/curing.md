# Curing: balances, cures, and what repeats cost

How Achaea gates healing, taken from the published HELP files (verbatim copies in `help/`)
and cross-checked against what play has already established in `balance.md`,
`incapacitation.md` and `defences.md`. Each claim is tagged with where it came from:

- **[HELP x]**: stated in `help/x.txt`
- **[play]**: established from a transcript, and the file that records it
- **[open]**: not settled by any source. Ask before building on it.

When HELP and play disagree, play wins, because the website help can lag the live game. Record
the disagreement here and don't quietly pick one.

## The two combat balances

**[HELP equilibrium]** Most abilities use **balance** (physical) or **equilibrium**
(mental), and recovery is "generally from 2 to 5 seconds, depending on the ability".

> In most cases, not having balance prevents you from using an ability that requires
> equilibrium, and vice versa. There are many exceptions to this rule which you must
> discover for yourself.

So the default for an unfamiliar bal/eq ability is **needs both**. That is what
`deflist.lua` already assumes for imported defences (`{ bal = true, eq = true, standing =
true }`). The known exceptions are all [play] facts:

| Action | Spends | Also requires | Source |
|---|---|---|---|
| `perform hands` | equilibrium 3.0s | balance | `balance.md` |
| smite | balance | equilibrium | `incapacitation.md` |
| `perform inspiration` | equilibrium 3.5s | balance, standing | `defences.md` |
| `touch moss` (and other tattoos) | balance ~4s | [open] eq | `defences.md` |
| `def` | equilibrium 0.5s | [open] | `defences.md` |
| `stand` | balance | | `incapacitation.md` |
| movement | balance and equilibrium | | `balance.md` (stated by user) |
| `diag` | equilibrium | balance (declared, not proven) | `engine.queueDiag()` |

**[HELP compose]** When equilibrium is *disrupted* (the example given is being very cold),
it "will not return no matter how long you wait". `CONCENTRATE` restores it, and
**confusion prevents concentrating**. Nothing in Emunah models this state yet: a system
that waits for `eq` to come back will wait forever. See *Gaps* below.

## The curing balances

**[HELP curing-balances]** names four and says what shares each:

| Balance | Shared by | Emunah vector |
|---|---|---|
| Salve | every salve and balm (`APPLY`) | `salve` |
| Herb | eating plants **and minerals** | `herb` |
| Elixir | health/mana elixirs **and** vitality/mentality tonics | `elixir` |
| Moss | irid moss **and potash** | `moss` |

The salve example in that file shows why one slot per balance is right:

> if you have 3 broken limbs, you cannot simply apply mending 3 times in a row to cure all
> 3. You must apply mending to cure one, wait, then apply mending to cure another

Inside the balance, the second application is not refused. It is **ineffective**, meaning it's used
up for nothing. For herbs the game says so: `The plant has no effect.` **[play, balance.md]**

The official list stops at four, but play and the server-side curing help show more
balances of the same kind:

| Balance | Evidence |
|---|---|
| Smoke | distinct rejection `You have not yet recovered balance for smoking.` **[play, balance.md]**; `CURING TREE SCENARIO NOBAL ... SMOKE` **[HELP curingsystem]** |
| Focus | `You have not yet regained your mental balance.` **[play]**; `NOBAL ... FOCUS` **[HELP curingsystem]** |
| Tree | own timer, no bal/eq **[play, defences.md]** |
| Writhe | not a balance: a duration, see below |

**[HELP heal]** / **[HELP combatprinciples]**: health and mana elixirs "both use the same
balance, [so] you must choose which to heal". One elixir slot, and health and mana compete for it.

### Do cures need balance or equilibrium?

**Neither is stated by HELP.** The combat principles file calls these "their own type of
balance", separate from bal/eq, and play agrees for every vector tested:

- Eating works while off balance: `eat irid` succeeded at 12:01:19.04 while `perform hands`
  was refused for balance in the same second **[play, balance.md]**.
- FOCUS and TOUCH TREE cost neither **[play, defences.md]**.
- **[open]** Salve, smoke and sip have not been shown in a transcript to work off balance.
  The code assumes they do. The `emunah debug` output from one fight would settle it.

What *does* block cures is the character's state rather than a balance:

| State | Blocks | Source |
|---|---|---|
| Stunned | everything | [play, incapacitation.md] |
| Asleep | everything except `WAKE` | [play, incapacitation.md] |
| Paralysed | everything except eating (herb, moss). `touch tree` included | [play, balance.md] |
| Prone | only what needs you upright. Eating and drinking still work | [play, incapacitation.md] |
| Both arms broken | `touch tree` | [play, afflist.lua] |
| Anorexia | eating: the `herb` and `moss` vectors, but not `OUTR` | [play, `afflist.blocks`] |
| Slickness / asthma / impatience | salve / smoke / focus | [play, `afflist.blocks`] |

## Cures that must be sent once and then left alone

Two HELP files say plainly that **repeating the command makes it slower**. This is
the opposite of every balance-gated cure, where retrying after a lost confirmation is
harmless.

**[HELP entanglement]**
> It takes time to writhe out from entanglement, and if you WRITHE again while you are
> already writhing, it will take even longer! Just WRITHE once, then wait until you are
> free of that entanglement.
>
> [If entangled more than one way] you will need to WRITHE once, then wait until you are
> free from the first entanglement, then WRITHE again.

**[HELP sleeping]**
> You will find that when you type WAKE, you will begin to struggle your way out of
> sleep, and eventually you will wake up. Typing WAKE repeatedly will only delay this
> process, so just do it once, and wait.

**Emunah currently repeats both.** See *Where the code disagrees with HELP*.

**[open]** The messages for *starting* to writhe or wake, and for a WRITHE or WAKE sent while one is
already in progress, are not recorded anywhere. A correct fix needs those lines. Ask for a
transcript and don't guess them.

## Other cure mechanics from HELP

- **Salves target a body part.** `APPLY <salve> [TO <head|arms|legs|body>]`. Without a part,
  it goes to "a part of your body that requires it, if any" **[HELP heal]**.
- **Mangled limbs need restoration before mending.** State 2 limb damage "cannot be healed
  without first applying a restoration salve", and a restored limb "does not get fixed
  immediately" **[HELP bodypartdamage, target]**. Body part damage has three states:

  | Part | State 1 | State 2 |
  |---|---|---|
  | Head | stupidity | concussion |
  | Body | minor bleeding | serious bleeding |
  | Limbs | limb breaks | mutilated and broken; restoration first |

- **`DRINK <fluid>` drinks from the first vial holding it**, and so does `APPLY <salve>`
  **[HELP heal]**. The noun must match a vial *in inventory* **[play, balance.md]**.
- **Vials hold 200 sips. The rift holds 2000 sips of health/mana and 1000 of most other
  fluids.** `FILL <vial> WITH <fluid> FROM RIFT` **[HELP vials, rift]**.
- **Herbs and minerals in the rift are not in hand.** `OUTR [amount] <item>`, default one
  **[HELP rift]**. Eating needs it in inventory **[play, balance.md]**.
- **Smoking**: `PUT <herb> IN PIPE`, `LIGHT PIPE` (needs a fire source such as a tinderbox),
  `SMOKE PIPE`. "A lit pipe will eventually go out if you don't smoke it now and then"
  **[HELP smoking]**.
- **Bleeding** clots naturally over time, faster with `CLOT` (Survival) or a moss tattoo
  **[HELP bleeding]**. CLOT's costs are in `priest-abilities.md`.
- **Fear**: the cure action is **`COMPOSE`** **[HELP afflictions, compose]**.
- **Insomnia prevents being put to sleep, but "generally the things that put you to sleep
  will remove your insomnia"** **[HELP sleeping]**. Kola/quartz lets you wake at will.

## Server-side curing (`CURING ...`)

**[HELP curingsystem]** Achaea has its own built-in curing system that handles afflictions,
defence upkeep, sipping, moss, focus, tree and clot. It spends the same balances Emunah
spends, and Emunah cannot see its commands, only their effects.

**If it is on while Emunah cures, the two race for every balance.** Emunah sees a balance as
free, sends into it, and gets `The plant has no effect.` or a salve/sip rejection, because
the server spent it first. That is exactly the "acting without the balance" symptom.
Nothing in `src/` checks or mentions `CURING STATUS`.

**[open]** Whether it is on for the user's character, and what its output looks like
(`CURING STATUS`). Ask before writing code that toggles it: `CURING ON|OFF` and its
sub-switches are the only syntax HELP gives.

## Where the code disagrees with HELP

Each is a candidate bug. None is fixed here, because the fix depends on the **[open]** items
above.

| # | Code | HELP | Effect |
|---|---|---|---|
| 1 | `engine.lua` pushes `writhe` every tick while entangled. The only confirmation is the entanglement's removal, so if that takes longer than `curing.confirmWait` (2s) the send times out and it goes out again. `afflist.lua` describes the cure as "repeated WRITHE". | WRITHE once, then wait. Repeating makes it take longer. | Entanglement lasts longer than it should, in the fights where it matters most. |
| 2 | `detect/init.lua` `wakeUp()` resends WAKE every `WAKE_GUARD` (1.0s) while asleep, on the reasoning that "attempt" means it can fail. | WAKE once. "Typing WAKE repeatedly will only delay this process." | Every involuntary sleep lasts longer. |
| 3 | `fear` cured by the `focus` vector. | Fear: `COMPOSE`. | Possibly works anyway. Unverified. `docs/afflictions.md` open question 5. |
| 4 | `stupidity`'s goldenseal cure removed after it "did not work" (20:57:29-20:58:04). | Stupidity: eat goldenseal / plumbum. | The removal may have been a herb-balance collision (see `The plant has no effect.`, or server-side curing) rather than a wrong cure. Re-test before trusting either. |
| 5 | `crippled<limb>` cured with restoration. | Crippled limb: **mending**. Damaged/mangled: restoration. | The user confirmed restoration live (`priest-abilities.md`), so the code is right by the play-beats-HELP rule. The web copy may be stale. Recorded so nobody "fixes" it back from HELP. |
| 6 | Disrupted equilibrium isn't modelled. | Equilibrium won't return without `CONCENTRATE`. Confusion blocks CONCENTRATE. | Any eq-gated action waits forever. |
| 7 | `stinky` has no cure entry. | `SCRUB`, only at a water location. | Harmless: tracked, never cured. |

## Adding to this file

Cite a source for every claim. A new HELP file goes in `help/` first, verbatim. A transcript
fact goes in the topic file it belongs to (`balance.md`, `incapacitation.md` ...) with its
timestamps, and gets summarised here with a pointer.

# Curing: balances, cures, and what repeats cost

How Achaea gates healing, taken from the published HELP files (verbatim copies in `help/`)
and cross-checked against what play has already established in `balance.md`,
`incapacitation.md` and `defences.md`. Each claim is tagged with where it came from:

- **[HELP x]**: stated in `help/x.txt`
- **[play]**: established from a transcript, and the file that records it
- **[svof]**: taken from [svof](https://github.com/svof/svof), the long-standing Mudlet
  curing system for Achaea, which the user has named as the reference for curing
  methodology and balance blockers. The gates are in `raw-svo.skeleton.lua` (`check_herb`,
  `check_salve`, `check_sip`, ...), the per-action rules in `raw-svo.dict.lua`
  (`isadvisable`), and the game's message lines in `svo (install the zip, not me).xml`.
  Its last commit is June 2021, so when it disagrees with a timestamped transcript the
  transcript wins. Say so here when that happens.
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

**No.** svof's curing gates (`check_herb`, `check_salve`, `check_sip`, `check_smoke`,
`check_moss`, `check_focus`) check their own balance and afflictions, never bal or eq
**[svof]**. HELP doesn't say either way. The combat principles file calls these "their own type of
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

## What gates each action: the full table

Every blocker below is enforced in code. Beyond its own balance, each vector is held while
any of these is true. Stun and sleep hold everything (`act.blocked`). `have.vectorBlocked`
is asked when the queue actually *sends*, not only when the cure is chosen, because a
block can land while a cure waits for its balance.

| Action | Held while | Enforced in | Source |
|---|---|---|---|
| eat herb / mineral | anorexia; paralysis does **not** block | `afflist.blocks` | [svof check_herb], [play] |
| eat moss / potash | anorexia | `afflist.blocks` | [svof check_moss] |
| sip elixir | anorexia; paralysis | `afflist.blocks`, `queue.WHILE_PARALYSED` | [svof check_sip]; [play] for paralysis |
| apply salve | slickness; paralysis | `afflist.blocks`, `queue.WHILE_PARALYSED` | [svof check_salve]; [play] for paralysis |
| smoke | asthma, mucous; paralysis | `afflist.blocks`, `queue.WHILE_PARALYSED` | [svof check_smoke] |
| focus | impatience, inquisition, willpower ≤ 75, mana ≤ 35% (svof `manause`, `curing.focusMinMana`); paralysis | `afflist.blocks`, `have.vectorBlocked` | [svof check_focus] |
| touch tree | paralysis, webbed, bound, transfixed, roped, impaled, either arm numb, both arms disabled | `afflist.blocks`, `have.vectorBlocked` | [svof touchtree], [play] |
| writhe | a writhe already under way | `have.balance("writhe")` | [HELP entanglement], [svof] |
| wake | a wake already under way; a sleep you chose | `detect.wakeUp` | [HELP sleeping], [svof] |
| stand | no bal **or no eq**; paralysis; entangled; crippled/mangled/mutilated leg | `detect.standUp`, `act.blocked` | [svof prone], [play] for bal |
| attack, move, get (anything `standing`) | prone; paralysis; entangled; its bal/eq | `act.blocked` | [svof balance_controller], [play] |
| `perform hands`, `diag` (bal/eq vectors) | paralysis; bal and eq | `queue.WHILE_PARALYSED`, `needs` | [play] |

| anything at all | dead; stunned; unconscious; asleep (bar WAKE) | `act.blocked` | user's rule for death; [play] stun/sleep; [svof] unconsciousness |
| anything needing bal or eq | either arm off balance | `act.blocked`, `detect.armBalance` | [svof check_balanceful_acts] |

**Death pauses Emunah completely** (the user's rule). Nothing is sent while `Char.Vitals`
reports 0 health. The queue is emptied, and bashing and the walker stop. On revival curing
resumes by itself. Bashing and walking stay off until restarted by hand.

**Arm balance.** Lost to arm-strike attacks, one arm at a time (svof `Lost arm balance`:
`You ball up one fist and hammerfist` / `You launch a powerful uppercut at` / `You form a
spear hand and stab out towards` / `You unleash a powerful hook towards`). Regained with
`You have recovered balance on your left arm.` / `...right arm.` [svof], or `You have
recovered balance on all limbs.` [play]. A 10s backstop covers a missed recovery line.

**Unconsciousness.** Onset: `Your legs collapse from under you and consciousness leaves you
as you pass out from extreme hunger.` (also prone). Clears with `You regain consciousness
with a start.`, or after 7s (svof's `customwait = 7`). Both lines are from [svof]. Other
onsets are per attacker and its GMCP name is unconfirmed. Add them from a transcript.

**Differences from svof, kept on purpose.** svof does not hold sips, salves or smoking for
paralysis. Emunah does, because play showed each refused while paralysed (`balance.md`,
*Paralysis blocks almost everything*). 
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

Both are now sent once. The game announces the start and the finish, and these lines
come verbatim from svof's trigger set **[svof]**:

| Event | Line |
|---|---|
| writhe started | `You begin to struggle free of your entanglement.` |
| | `You begin trying to wrest your mind free of that which has transfixed it.` |
| | `You begin to writhe furiously to escape the <weapon> that has impaled you.` |
| writhe finished | `You have writhed free of your entanglement by ropes.` / `by tied ropes.` / `by webs.` |
| | `You have writhed free of your state of transfixation.` |
| | `With an heroic effort you manage to writhe yourself free from the weapon that impaled you.` |
| writhe with nothing to escape | `You begin to writhe helplessly, throwing your body off balance.` |
| wake started | `You begin your struggle to escape from the dreamworld.` |
| awake | `You open your eyes and yawn mightily.` / `You already are awake.` / `You are jerked awake by the pain.` |

After a writhe starts, Emunah holds the vector for 6s (svof's `customwait = 6`), or until a
finish line or the entanglement's GMCP removal, so the *next* entanglement gets its own
writhe as HELP says. After a wake starts, nothing is resent until the sleep ends. Before
either start line arrives, an unanswered command is still retried once per round trip,
since it may simply have been lost.

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

**Settled 2026-09-28: it is off.** `CURING STATUS` showed `Enabled: No` with affliction
curing, focus, tree and clot all off, and the user then turned sipping and defence upkeep
off by hand. They asked for Emunah **not** to send `CURING` commands at login. Don't add
that. A balance collision is Emunah's own logic, not the server's.

## Where the code disagrees with HELP

Each is a candidate bug unless marked fixed.

| # | Code | HELP | Effect |
|---|---|---|---|
| 1 | **Fixed**: was: `engine.lua` pushes `writhe` every tick while entangled. The only confirmation is the entanglement's removal, so if that takes longer than `curing.confirmWait` (2s) the send times out and it goes out again. `afflist.lua` describes the cure as "repeated WRITHE". | WRITHE once, then wait. Repeating makes it take longer. | Entanglement lasts longer than it should, in the fights where it matters most. |
| 2 | **Fixed**: was: `detect/init.lua` `wakeUp()` resends WAKE every `WAKE_GUARD` (1.0s) while asleep, on the reasoning that "attempt" means it can fail. | WAKE once. "Typing WAKE repeatedly will only delay this process." | Every involuntary sleep lasts longer. |
| 3 | **Fixed**: `fear` now COMPOSEs first, focus second (svof `dict.fear.misc`). | Fear: `COMPOSE`. | |
| 4 | **Fixed**: goldenseal restored at rank 7 (HELP and svof agree). | Stupidity: eat goldenseal / plumbum. | The 20:57 failure predates the eat-inside-herb-balance fix. |
| 5 | `crippled<limb>` cured with restoration. | Crippled limb: **mending**. | **Not a real disagreement.** svof's internal `crippled` is the server's `broken`, and Emunah cures `broken*` with mending. By svof's `gamename` table, `mangled` is the server's `damaged` and `mutilated` is its `mangled`. |
| 6 | **Fixed**: `disrupted` (svof's gamename) CONCENTRATEs, never while confused. | Equilibrium won't return without `CONCENTRATE`. Confusion blocks it. | |
| 7 | `stinky` has no cure entry. | `SCRUB`, only at a water location. | Harmless: tracked, never cured. |

## Per-cure conditions (svof `isadvisable`)

Beyond whole-vector blockers, svof holds individual cures when they'd be wasted, undone or
done out of order. Emunah keeps these in `afflist.CONDITIONS`, checked by `have.cure()`:

- **Whispering madness** blocks the herb and focus cures of confusion, dementia,
  paranoia, hallucinations, masochism, recklessness, vertigo, loneliness, and the herb
  cure of hypersomnia, impatience, lethargy, nausea and addiction. It also blocks focusing
  stupidity.
- **Hypochondria first:** impatience, lethargy, nausea and addiction are re-applied if
  cured under it.
- **Not while a focus is in flight:** goldenseal for stupidity, dissonance, dizziness,
  shyness, epilepsy and impatience. The focus may already cure it.
- **Limbs worst first:** mangled, then damaged, then broken. Paresthesia comes before
  a break on that limb pair.
- **Pairs:**
  - inquisition blocks valerian for hellsight;
  - hecate blocks elm for madness;
  - stain blocks bloodroot for slickness;
  - mild trauma blocks heartseed and hypothermia;
  - frozen and hypothermia come before shivering;
  - blind comes before scalded.
- **Fear** is COMPOSE only. svof has its focus cure switched off.

## Server names (svof `gamename`)

svof records what the server calls each affliction where its own name differs. Emunah
accepts both (`afflist.ALIASES`): `lovers`, `weariness`, `pacified`, `airpocket`, `burning`,
`whisperingmadness`, `transfixation`, and the affliction `blind`/`deaf`. Note that
`blindness`/`deafness` are the **defences** from bayberry and hawthorn. `weariness` is also
confirmed by a real `Char.Afflictions.Add` payload quoted in the tests.

## Adding to this file

Cite a source for every claim. A new HELP file goes in `help/` first, verbatim. A transcript
fact goes in the topic file it belongs to (`balance.md`, `incapacitation.md` ...) with its
timestamps, and gets summarised here with a pointer.

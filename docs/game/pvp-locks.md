# Locks: afflicting, and following a target's afflictions

Source: **Anzerloi teaching in party, 2026-10-15 20:22:48–20:32:20**, walking the user through his
arena win over Sobriquet (`alchemist.md`), and **Synbios raising his defences** in front of the
user at 20:29:34–20:29:45. Quotes are verbatim from the user's log, with its timestamps. Tags as
in `curing.md`: **[player]** a player's account, **[play]** a line seen in play, **[reference]**,
**[open]**.

## What a lock is

Every cure has a route, and each route can be shut by an affliction (`afflist.blocks`):

| Route | Shut by |
|---|---|
| eating (herb, moss), sipping | anorexia |
| smoking | asthma |
| salving | slickness |
| focus | impatience |
| the tree tattoo | paralysis |

A lock is enough shut routes that the afflictions shutting them cannot be cured. The reference system's
definitions (`cnrl.lockdata`), which Emunah uses on both sides (`watch.LOCK_AFFLICTIONS`):

| Lock | Afflictions |
|---|---|
| soft | slickness, anorexia, asthma |
| venom | soft + paralysis |
| hard | soft + impatience (the reference system also: focus unusable for mana) |
| true | soft + paralysis, impatience, disrupted, confusion |

The lock Anzerloi builds is hard and venom together: slickness, anorexia, asthma, impatience,
paralysis. **[player]** 20:26:06: "Missing anorexia and paralysis for lock." — of a target that
was prone, asthmatic, slick and impatient.

## The lesson, in order

**[player]**, all from party:

- 20:23:36: "That's the moment I had all preps and started kill sequence. There's an important
  curing point to be made here. He was almost clean of affs at that point." 20:23:53: "Actually,
  had 0 affs." — the kill is set up by limb damage, not by afflictions.
- 20:22:48: "The green squares are my representation of prep." 20:23:07: "From left to right -
  leftarm, head, rightarm, then leftleg torso rightleg."
- 20:24:37: "Sunrise and sunset are moves that need limbs prepped, and they break them."
  20:24:44: "Sunrise left broke torso and left leg." 20:24:53: "Also gives asthma and prones."
- 20:25:16: "Sobriquet has time to eat one herb before my next attack hits, eats for paralysis."
  20:25:20: "Keeps asthma."
- 20:25:40: "Then comes sunrise, breaks head and arm, give impatience and slickness." (His
  arena log calls that second break SUNSET: `BHAJAN (dizziness) SUNSET LEFT Sobriquet
  (impatience) (slickness)`, `(damagedleftarm) (damagedhead) (stupidity)`.)
- 20:25:57: "So now he is prone, asthmatic, slick, impatient." 20:26:06: "Missing anorexia and
  paralysis for lock."
- 20:29:02: "If there is any hope of not being locked within 2 seconds, it's to get rid of the
  impatience." The user: "Guessing at it blocking focus?" 20:29:44: "Exactly."
- 20:29:52: "Next attack is doubtlessly anorexia." 20:29:59: "They can't salve, because they're
  slick." 20:30:14: "They can't puff the slickness because they're asthmatic." 20:30:28: "As soon
  as anorexia hits, no hope of eating for asthma to clear that slickness too."
- 20:30:53: "So he COULD eat for asthma there." 20:31:04: "That would cause him to puff and
  immediately salve his leg." 20:31:11: "Because it's broken and he's prone." 20:31:20: "And he
  must get up to do anything at all."
- 20:31:42: "That's also very stupid too, because now he can't salve for 4 seconds because it's
  a restoration salve application." 20:32:00: "Making me still free to jab the anorexia and
  re-give the asthma and slickness, while he's STILL impatient." 20:32:20: "He would've replaced
  the slickness with being off salve balance, understand?"

## What Emunah does with it

**Defending.** `impatience-before-hard-lock` (`curing/situations.lua`, `curing.md`): with
asthma, slickness and impatience together, goldenseal goes ahead of kelp and bloodroot. At
the reference system's ranks it was the other way round, the mistake the lesson describes.
`forming-lock` (`curing/treefunc.lua`) touches the tree on that same prompt. The tattoo
uses none of the herb balance the goldenseal needs, and paralysis, which shuts the touch,
is the hit that completes the lock. `metabolise impatience` (`curing/metabolise.lua`) is
set once during PvP, on equilibrium, so a second player's impatience inside about two
seconds of the first is resisted. The same player can still reapply it. It does not use
herb balance, and it waits while `perform hands` or `DIAG` wants the equilibrium.

**Attacking.** For the PvP target, from the afflictions the tracker has confirmed
(`curing/detect/opponent.lua`):

- `opponent.blockedVectors()`: their routes shut, and by what
- `opponent.lockProgress()`: the locks they are in, and what each other one still needs
- `opponent.lockNeeds()`: what the hard and venom locks still need, once two of those five
  afflictions are on them (a tuning number, so the modes keep their meaning early on)
- a Priest's chasten carries what the lock still needs when its pools have it: paralysis or
  asthma (`class/priest_pvp.lua`)
- `emset pvp` shows their class, the routes they cannot use, the locks, what the lock needs,
  the defences seen, and when they last ate, sipped or salved

## Watching an opponent from outside

**[play]**, Synbios at 20:29:34.40–20:29:45.03 (`opponent_patterns.lua`):

| Line | Read as |
|---|---|
| `Synbios clenches his fists and grits his teeth.` | insomnia: our own is "You clench your fists, grit your teeth, and banish all possibility of sleep." **[reference]** |
| `Synbios eats a kola nut.` | kola; his herb balance used |
| `Synbios eats a hawthorn berry.` | deafness, as keep-up raises it |
| `Synbios eats an arsenic pellet.` | **[open]**: no cure Emunah knows uses arsenic |
| `Synbios touches a cloak tattoo.` / `... a mindseye tattoo.` | cloak, mindseye |
| `Synbios takes a drink from an elegant diamond vial.` | a sip, unknown which |
| `Synbios takes some salve from a vial and rubs it on his skin.` | a salve, unknown which |
| `Synbios applies a quicksilver droplet to himself.` then, 10s later, `A supple metallic shell of quicksilver has formed around Synbios.` | fangbarrier: the same 10s our own shell takes |
| `A frigid stream of cerulean light emanates from a prismatic ring, surrounding Synbios with a frosty aura.` (and heliotrope, argentine, sanguine) | **[open]**: an artefact's auras |
| `With a low rumbling from deep within his belly, Synbios utters a guttural chant. ... a flexible, translucent shell.` | **[open]** |

An eaten herb is read by the rift's own description first, then by any word of the
description that is a curative's name, so an herb Emunah holds none of is still recognised.

## Anzerloi's route

Source: **three spars, Maelgor (Depthswalker) against Anzerloi, 2026-10-13**, logged from
Maelgor's end and pasted by the user on 2026-10-23: #48 (02:49:31–02:50:51), #49
(03:07:04–03:08:32), #50 (03:12:13–03:12:37). Anzerloi is a Priest with the abilities the
user has. Logged from the target's end, so every verse comes with the game naming what it
gave. **[play]** throughout, Maelgor's clock.

### What each exchange is

About every 2 seconds, **one verse, then either a smite carrying a chasten or one
equilibrium move**: sloth, dazzle, angel strip, sap or absolve. There is no exchange in
the three logs with both. A smite needs equilibrium and the angel needs balance
(*Angel Strip* in `priest-abilities.md`).

### The prayers

Each fight opens the same way, two herbs an exchange:

| #50 | Verse | With |
|---|---|---|
| 03:12:15.42 | `"Burn!" commands Anzerloi, fire leaping from him to you in a searing flash.` (tenderskin) | `Raising an imperious hand, Anzerloi condemns you to suffer under the sin of sloth.` (weariness) |
| 03:12:17.21 | Burn | sloth |
| 03:12:19.52 | `"Your crimes shall not go unpunished," Anzerloi recites to you, voice hard with condemnation.` (justice) | sloth |
| 03:12:21.44 | `"And your guilt will be made plain," ...` (guilt), then `Scenes of torture and violence rise to plague you as Anzerloi burns with a fiery incandescence.` (masochism: rebuke evil), then `As his prayer draws to a close, holy fire outlines Anzerloi.` | `Anzerloi utters a prayer and smites you with an Auroran Mace.` `Anzerloi strikes you with a dark bolt of energy directed through his mace.` (recklessness) |

Guilt, masochism and recklessness are all lobelia, landing at once. The second prayer
(#50, 03:12:23–03:12:30): Burn with dazzle (`Anzerloi directs a dazzling ray of divine light
at you.`, stupidity), Burn with sloth, Reflection (`"May you yet feel the pain you so
inflict," ...`) with a smite on the left leg, then Revelations (`"And see that which Evil
reaps!" ...`, hellsight) with rebuke evil and a smite chastening asthma. #48 and #49 open
the same way.

A verse has two wordings: opening a prayer, and carrying one on, which starts "And".
Guilt is `"Know the pain which you have caused," Anzerloi proselytises, finger pointed
directly at you.` or `"And your guilt will be made plain," ...`. Ash is `"Return to ash,"
decrees Anzerloi, ...` or `"And you shall be naught but cinders," ...`. Condemnation is
`"Your crimes shall not go unpunished,"` or `"Your sins condemn you to this fate,"`. Penance
is `"And face your penance!" Anzerloi denounces you, hand raised in warding.`.

**Inquisition** (rebuke heresy): `The weight of your sins weigh heavily as Anzerloi lifts an
imperious finger to point at you, fire surging about him as he does so.` (#49 03:07:39.10,
03:07:58.35). Both times it came on the verse after guilt and ash had both gone out.

### Hellsight and asthma

`An unspeakable, horrific image rises from the bowels of hell to plague you.` comes about
once a second while hellsight is on, often bringing an affliction with it. Hellsight is
smoked away, so asthma keeps it on: Maelgor's own system has a rule for exactly this
("HELLSIGHT + ASTHMA -> clear ASTHMA so Hellsight can be smoked"). In #49 it lasted from
03:07:46.32 to 03:08:14.63, with asthma chastened again at :50 and :56. It brought
confusion, stupidity, dizziness, hallucinations, epilepsy, vertigo, slickness, and sleep
(`You close your eyes, curl up in a ball, and fall asleep.`). When Maelgor shielded
(03:07:58.49), Anzerloi held his attack: "Shielded well, but I pressed hellsight instead."
Maelgor conceded.

### The legs

Past the first prayer the smites go to the legs: `Anzerloi utters a prayer and smites your
right leg with an Auroran Mace.` then `As Anzerloi's blow crunches into you, you perceive
that he has dealt 16.6% damage to your right leg.`. In #49 the right leg was taken to one
hit from breaking (Maelgor's counter `RL:1!`) and the left to five.

### The kill (#50)

- 03:12:34.58: Ash (`"And you shall be naught but cinders,"`), and `Anzerloi's guardian
  angel casts a piercing glance at you.`. The sap took Maelgor from 3067 to 2257 mana,
  18% of his 4466, with about nine afflictions on him.
- 03:12:37.20, Maelgor at 2470 (55%): `"Burn, blight upon Creation!" Anzerloi dictates to
  you, holy fires bursting into being and scouring you to your very soul.` (wrath), then
  absolve on the same tick. Wrath took him under half, and absolve landed.
- The two prayers before it had each closed on a rebuke. That banked the 20% conviction
  wrath needs.

### Shields

`Your shield defence has been stripped by Anzerloi's guardian angel.` (#49 03:07:41.00,
03:07:44.63; #48 02:50:31.07, 1.8s after Maelgor shielded), each alongside a verse. The
verse landed through the shield (Ash at 03:07:41.00, on the same prompt).

### Also seen

- **Third-person cures**, filling a gap below: `Anzerloi touches a tree of life tattoo.`
  and `Anzerloi takes a long drag off his pipe.`
- **His own defences**: his aura of rebounding drops as he attacks (`Anzerloi's aura of
  weapons rebounding disappears.`, just before each verse) and is back about a second
  later. Also `A gentle hum arises from Anzerloi's angel, as it raises a shield to protect
  him.`, `The guardian angel of Anzerloi shimmers and he gives a sigh of relief.` (after
  which an affliction was gone), and `Anzerloi's wounds close up before your eyes.`.
- Reflection returned Maelgor's own afflictions to him: `The aura around Anzerloi lashes
  out at you.` then `You have been afflicted with nausea.` (#49 03:07:35.80).
- `"The light shall not be denied," Anzerloi declares, as he fixes his unblinking gaze
  upon you.` then `A look of outrage fills the face of Anzerloi.` (#48 02:49:49.44) is
  **Unflinching**: our own recite of it printed `"The light shall not be denied," you
  declare, ...` and `Rage fills you as the thought of heresy inspires you to greater
  efforts.` (2026-10-23 09:58:38.00).

### What Emunah does with it

Offence is this route (`class/priest_pvp.lua`, `M.PRAYERS`). The user's rulings,
2026-10-23:

- **The prayer is a fixed cadence**, chosen at each prayer's start from the conviction
  GMCP reports. Under 10 it is the *stack* (burn, burn, condemnation, guilt rebuke evil).
  At 10 or more it alternates *hellsight* (burn, burn, reflection, revelations, guilt rebuke
  evil) and *heresy* (burn, burn, guilt, ash rebuke heresy). At 20 or more it is the *drain*
  (burn, ash, wrath, guilt rebuke evil). None of this assumes a verse landed.
- **The verse first, and it needs both balances.** A verse spends neither, but the game
  refuses it while either is down (the spar against Erishka, 2026-10-23, in
  `priest-abilities.md`). So each exchange waits for both, and the verse goes ahead of the
  mace or the equilibrium move on that prompt. A fight's rite, once a prayer is running,
  only follows a verse, so its equilibrium is back before the prayer lapses.
- **The mace or an equilibrium move each exchange, never both.** Every attacking mode works
  this way: each move needs the balance the other spends. Attack and hinder alternate the
  two; finish and offence send the equilibrium move whenever one is due. In the first prayer
  equilibrium sends sloth or dazzle on every verse except the rebuke's. After that, only on
  a prayer's first verse. During the drain, equilibrium does contemplate, sap and absolve.
  Otherwise the mace goes, and the piece a forming lock still needs always takes the mace's
  turn.
- **The legs evenly.** Each smite goes to whichever leg our blows have hurt least, by the
  figures our own hit lines report (`priest.limbs()`). When the two are level, it goes to
  the other leg from last time.
- **The chasten**: asthma for 20s after Revelations, whenever it is not confirmed on them;
  then, once they are slick, one mental (below); then a lock's missing piece; then, while
  a hellsight prayer builds to Revelations, a kelp affliction and then asthma; then
  clumsiness, healthleech, asthma, paralysis. Recklessness beside guilt rebuke evil is
  gone: "Take that recklessness out" (Anzerloi, 2026-10-23).
- **Hellsight, then slickness, then anorexia.** Since CLASSLEADS #178 (2026-10-23), `angel
  panic` on a target with hellsight gives slickness instead of fear. Anzerloi's procedure,
  taken as he gave it (the user: "assume everything anzerloi says is 100% correct"):
  - "Only give hellsight when asthma is secure with more kelp affs" (16:03:56). Revelations
    goes only with asthma and another kelp affliction confirmed. Guilt rebuke evil takes
    its slot otherwise.
  - "Recite hits first so that's instant slickness on top of the asthma and kelp trail,
    don't rebuke" (16:08:36). Revelations goes without a rebuke, and the angel's panic
    takes the mace's place on that exchange.
  - "On next attack guilt rebuke a mental/perform sloth" (16:08:36). The hellsight prayer's
    fifth verse is guilt rebuke evil (masochism, cured by focus), with sloth.
  - "Minimum 1/2 chance they focus the wrong thing before you chasten another mental in
    them" (16:08:59). Once slick, the chasten gives one mental, epilepsy, dizziness or
    confusion, and no more once one is confirmed ("Still too many mentals", 2026-10-23).
  - "Next attack could be a perform fasting to get anorexia, which they'll have to focus
    because slick. For that to be worth it, need some mentals" (16:07:08–16:07:17).
    `perform fasting` (2.20s of equilibrium, 10 devotion) goes once per Revelations, with
    one other mental confirmed.
  - "If target has hellsight, or you determined your recite to be revelations, angel panic
    becomes a slickness-giving move" (16:16:16). Panic again once their slickness is
    confirmed and then eaten away, while hellsight is held. Their fangbarrier sloughing
    off (`The protective coating covering the skin of X sloughs off.`) confirms the
    slickness (16:09:48). The caster's own line does not change ("You bid your guardian to
    rouse the mind of X into a state of panic.").
  - The victim's line, verbatim (16:15:21.77): `Strange terrifying voices whisper through
    your mind, and your hellish visions grow so vivid that a cold sweat of fear slicks
    your skin.` Panic's fear also drops what is wielded: `You drop a kite shield in your
    terror.`
- **Absolve only on a contemplate under 50%.** Wrath is a second sap, not half of a
  finisher.
- **The kelp trail, and mentals only when they pay** (Anzerloi, 2026-10-23, after the
  17:44 spar, where attack mode paired guilt and ash with recklessness, confusion,
  dizziness and epilepsy, and `chasten mind` three times): "See the problem? Matching
  mentals with eatables. I get rid of them before your next attack." "Gotta only use
  mentals when they can't focus or it can harm them." "That's why I work the kelp trail
  primarily." "Mentals are for when you get a good lobelia trail to hold the guilt. And
  you don't have a more worthy affliction to contribute to the kelp trail." "Between
  another mental and hellsight, I'll go hellsight any day. But you need a little bit of
  kelp to make it worth it." "I like saving asthma for the end." So every mode's chasten
  goes clumsiness, healthleech, asthma; a mental (focus cures it) only with focus shut
  (impatience, inquisition), in the slickness sequence, or with guilt and another lobelia
  affliction held and the kelp trail full (`M.mentalsAllowed`); the mind pool likewise,
  its capstone aside. Attack mode recites Revelations once asthma is secure, with the
  panic and fasting that follow. Then: "Take that recklessness out." "Still too many
  mentals." So no order names a mental; recklessness is never chastened, and `chasten
  mind` only for its capstone, since the game may pick recklessness from the pool; the
  slickness sequence gives one mental and stops (`M.MENTALS`, `M.mentalCount`).
- **F1 is Anzerloi's exploit route** (2026-10-24 13:33-14:44, after a spar where F1 sent
  21 attacks with no contemplate, no sap and no conviction). "You think - what can I
  exploit now? If can't, what can I push based on current circumstance to maybe exploit on
  next attack? ... at the end you default to 'push kelps'." In `class/priest_pvp.lua`:
  - **A reading to start from**: contemplate rides on the first blow, and again every
    `READ_EVERY` (20s), as well as at or under `READ_BELOW`.
  - **The lobelia trail** (`attackPrayer`, `ATTACK_LOBELIA`): burn, guilt, ash. Tenderskin,
    guilt and spiritburn are 3.5% of a sap each and one herb (lobelia/argentum) cures all
    three, one per eat. "That was not a trail that would've netted much sap value" (13:33:05)
    of the old kelp chastens; "It's just a kelp aff."
  - **The fork at the fourth verse** ("At prayer length 4 you have an important fork. You may
    recite for hellsight and/or rebuke for inquisition", 14:37). Wrath first if it and a sap
    would bring absolve in reach; then Revelations when they are asthmatic or have another
    kelp affliction (`hellsightReady`, 14:39); then the other of guilt and spiritburn with
    `rebuke heresy` ("if target has either guilt or spiritburn, you can recite the other and
    rebuke heresy, now they got inquis", 14:38:55: the verse lands before its rebuke); then
    wrath worth a sap. The rebuke closes the prayer (evil when heresy cannot land), which is
    what banks conviction. Revelations without heresy stays open.
  - **Hard set** ("you hard set your attack and don't let anything override it", 14:41:17,
    `attackHardSet`): on Revelations' prompt equilibrium is only absolve, strip or the fork's
    sloth; the mace chastens asthma, else a kelp affliction, with it (14:40:29).
  - **Saps as it goes** (`pressSap`): at any mana when worth `PRESS_SAP` (10%, the whole
    trail), `SAP_WORTH` (5%) at or under 70%.
  - **Fire only on inquisition**: purge on the prayer, `inquisitionSear` on equilibrium, and
    a push riding on the blow (`pushWithBlow`). "If you do it without smite, target
    becomes prone. If you do it with smite, the target needs to have inquisition to be
    proned" (Anzerloi, 2026-10-24 14:04:50). `smite anzerloi|angel push anzerloi` goes on
    one line (14:04:00.92); without inquisition it prints "A guardian angel reaches out to
    push Anzerloi back, but he stands his ground." and no "Equilibrium used:". So the
    answer is evidence: stood their ground clears the inquisition we took the rebuke to
    give, and proned confirms it. Prone is 2% of a sap, and with ablaze wrath burns the
    body too (HELP WRATH).
  - **The tree**: chasten paralysis when they touched it within `TREE_RECENT` (10s).
- **What is on them, as chances** (`opponent.oddsFor`, `priest_pvp.picture`). "Iterate over
  target's existing affs. Preferably in percent probabilities value ... Each of these
  relative to that aff's probability. If 50% I got spiritburn, then + (3.5/0.5)" (Anzerloi,
  2026-10-24 15:20-15:21; times, by the sense of it), and "Afftracking is really the first
  thing you should implement, before any thought of attack protocol" (15:45:44). A landing
  line, or a verse we sent (which prints none: `opponent.suspect`), makes an affliction
  certain. A cure that could have taken any of several shares itself among them by their
  chances: with a total over one, each keeps 1 - 1/total; with one or less, it took them
  all. One argentum on a certain guilt, spiritburn and tenderskin leaves each at two in
  three; a second, one in three. A line naming the cure (guilt's "straightens") takes that
  one off and gives the eat back to the rest. A suspicion never confirmed lapses after
  `SUSPECT_FOR` (12s). The sap is each affliction's value times its chance, and nothing on
  them is nothing taken ("sap_value should only be above 0 if the target has any actual
  affs", 15:45:11). Likely, for the fork, is an even chance or better. The confirmed picture
  (`opponent.list`) is unchanged, and absolve, the locks and the mentals' gate decide on it.
- **The kill wherever it is** (Anzerloi, 2026-10-23 14:38:17-14:39:20): "You win by having
  their mana low enough. If that does not present itself on its own (on your
  contemplations), you attempt to create conditions to attack their mana with saps. Most of
  the fight is setting up conditions that would allow you to create such conditions to
  sap." Every attacking mode, in any prayer: absolve on a fresh reading under half; sap at
  once when the estimate and one sap (`sapWorth`, over what is likely on them) would take
  them to 45% or under (`killSap`, `KILL_SAP_TO`: "if target.MP - sap_value =< 45 then",
  2026-10-24 14:44:33); contemplate again straight after it (`killRead`), since a
  sap shows no figure. A shield is stripped first: "Dazzle and purity bypass shield"
  (14:43:48), so the rest is taken not to.
- **Asthma tells** (14:26:24-14:30:21): "If they're holding breath and you hit with asthma
  (or more importantly, someone else hits them with asthma but you can't tell) they
  exhale." "If they cure asthma while upkeeping breathing and are on balance, they
  immediate start holding breath. So if they have multiple kelp affs, eat kelp and hold
  breath, confirm asthma, other kelp affs untouched." Read from the reference system's
  third-person lines: `X exhales loudly.` gives asthma; `X inhales and begins holding
  his|her breath.` takes it off, and puts back a kelp affliction an eat up to 2s before
  took off by rank (`opponent.breathHeld`). `exhales softly` and `suddenly inhales deeply`
  are not read: what they mean is not known.
- **A shield is stripped** before any mace blow, in every attacking mode. A shield counts as
  up from `<name> touches a shield tattoo.` until our strip goes out.

## Open

- **Restoration salve and its 4s.** "He can't salve for 4 seconds because it's a restoration
  salve application" **[player]**. Emunah waits for the game's "You may apply another salve to
  yourself." either way; the length is not in `balance.md` until HELP or a timestamped
  application shows it.
- **Prep on a shared target.** Emunah counts only the limb damage its own blows report. A
  partner's blows don't show up in that count, and a Bard's prep is his own echo
  (`[21][42][--]`), not a game line.
- **A partner's attacks as we see them**, to know what he has landed and what the lock still
  needs from us.
- The third-person line for focus. The tree and the pipe are under *Anzerloi's route*.
  `Anzerloi draws a steadying breath but falters soon there after.` (four times, where a
  verse would go) may be focus, or a verse failing.
- **What stops a cleave.** A knight's cleave (`<name> raises her longsword over her head
  and begins to swing it in a wide circle`, then `begins to bear down on you with her
  whirling longsword`) killed from full health about ten seconds after the first line
  (2026-10-23 10:00:38-48). Emunah names it as a danger; the counter is not known.
- **From the route** (*Anzerloi's route*):
  - **Smites that break outright.** Sometimes a leg smite gives `brokenrightleg` straight
    away with no figure (six times in #48), and other times 16.6%. What decides which is
    not known, and a break with no figure adds nothing to Emunah's count.
  - **The caster's lines.** Not captured from the caster's end: our smite's leg words and
    its figure for a leg, a rebuke landing, Revelations, our strip, and a shield falling by
    any other means.
  - **When a limb's damage resets** on the target, so the count can follow it.
  - **How long hellsight lasts** without asthma, and whether 20s is the right window.
  - **Panic's slickness from the caster's end.** The caster's line is the same either way
    (16:14:24), so only the target's fangbarrier sloughing off confirms it.
- **Third-party cures we no longer see.** Since CLASSLEADS #178, a third party sees the cure
  of bloodfire, coldfate, conflagration, constricted, degenerate, earworm, enmeshed, guilt,
  hatred, horror, inquisition, kkractlebrand, latched, lovers, mindravaged, mycalium,
  petrified, rebbies, reeling, retribution, shadowmadness, snared, tension, the unweavings
  and whisperingmadness only with the relevant skill. A partner's afflictions from that
  list can no longer be tracked as cured. Guilt and inquisition come from Zeal, which we
  have, so their cures should still show to us; not yet seen in a fight since the change.

## F1 against Anzerloi, 2026-10-24 14:33-14:34: four saps, no trail

F1 ran 1m17s: 29 attacks, 28 verses, four angel saps. His mana read 100% (14:33:25), 98%
(14:33:57, after three saps), 87% (14:34:20), 90% (14:34:36, after the fourth). "Absolutely
no trail." What it showed, and what changed:

- **He cured as fast as we gave.** An argentum within a second of each lobelia verse, an
  aurum for each kelp chasten, magnesium for each paralysis, the tree every ten seconds or
  so, and focus. The lobelia trail never stood, so the saps had little to drain.
- **His sips and potash put the mana back.** He drank from his vial about every eight
  seconds and ate potash several times; at full health a sip can be mana. The estimate
  counted none of it and fell under half, and the kill alert lit while he stood at 98%. Now
  a sip at or over `SIP_MANA_ABOVE` (80%) health counts `SIP_MANA` (14%) back and moss
  `MOSS_MANA` (5%), and potash and irid are recognised as eaten.
- **Inquisition was taken as certain.** `ash rebuke heresy` went at 14:33:43.56 with guilt
  counted likely, though an argentum had gone down at 43.00, and three saps followed on a
  doubled value. Now the rebuke's inquisition is only as likely as guilt and spiritburn both
  being on them. "The weight of his crimes no longer weighs so heavy upon Anzerloi."
  (14:33:48.21) is taken as inquisition coming off (unconfirmed).
- **Hellsight was held for a fixed time.** Revelations landed ("Anzerloi claws at his eyes,
  fingers scrabbling frantically.", 14:34:07.16) and he smoked it away at 14:34:08.80, but the
  mace chastened asthma for eight blows after. The pipe ("takes a long drag off his pipe") is
  now a smoke cure shared among what a pipe takes, and proof asthma was not on them; the
  asthma hold and the slickness panic go on hellsight's odds.

## F1 again, 2026-10-24 14:39:48-14:40:59, on the code above

One sap instead of four. The fork went twice: Revelations with the mace's asthma
(14:40:30), and Revelations with sloth (14:40:43) followed by the panic that gave slickness
("The protective coating covering the skin of Anzerloi sloughs off.", 14:40:47). Rebuke
evil's masochism kept him focusing, seven times, and his mana touched 82%. "It's progress,
but it's also a mess. No method." Fixed from it:

- **Slickness only with asthma likely.** Two aurum went down between the asthma chasten and
  the panic, and he smoked the slickness off at 14:40:50. The panic and the hold went on the
  confirmed list, which still had asthma; they go on its odds now.
- **The mace waits on equilibrium's guard.** After the panic, `smite ... chasten asthma` went
  on the next prompt and came back "You must regain equilibrium first." (14:40:47.11): the
  prompt still showed equilibrium, but the smite needs it and the panic had it.
- **Masochism's symptom**: "Anzerloi smiles as he rams his fist into his jaw."

## Their mana, estimated, and the kill window

"Don't contemplate too much as it'll cost us valuable time. Try and estimate it and only use
contemplate when you feel they are close" (the user, 2026-10-23). `priest_pvp.manaEstimate`:
the last contemplate (full with none), less our saps and wraths since (sapPercent over what
was on them as each went), less `FOCUS_COST` (13%) for each focus seen. Regeneration, moss
and mana sips are not counted, so it errs low. Contemplate rides on a blow only at or under
`READ_BELOW` (60%); `killRead` reads when the estimate is under half (never two inside
`FRESH`) and straight after the kill sap. Attack also reads on its first blow and every
`READ_EVERY` (20s): with no reading the estimate stays "full" against anyone who never
focuses. `killSap` and the saps use the estimate, sized on what is likely on them; absolve
only a real reading. A sap or wrath sent at the moment of a reading is already in it.

The kill window alert (`pvp.updateAlert`, `priest_pvp.killRows`): LOCKED, ABSOLVE (now /
in range / a sap away), JUDGE (about 6s with justice, about 12s while locked: Anzerloi, 18:05,
"I think"). Judge is not sent.

## FOCUS's mana cost, for estimating an opponent's mana

The user's own FOCUS, 2026-10-23 18:08:23.28 to 18:08:26.11: mana 94% to 81% on the prompt
after `focus` (a `drink mana` went on the same line, which had not yet landed). So one
focus took about 13% of the user's maximum mana. The opponent tracker counts each
`A look of extreme focus crosses the face of X.` (`opponent.focusesSince`) for an estimate
of their mana (above).

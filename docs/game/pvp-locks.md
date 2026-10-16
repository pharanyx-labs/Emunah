# Locks: afflicting, and following a target's afflictions

Source: **Anzerloi teaching in party, 2026-10-15 20:22:48–20:32:20**, walking the user through his
arena win over Sobriquet (`alchemist.md`), and **Synbios raising his defences** in front of the
user at 20:29:34–20:29:45. Quotes are verbatim from the user's log, with its timestamps. Tags as
in `curing.md`: **[player]** a player's account, **[play]** a line seen in play, **[svof]**,
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

A lock is enough shut routes that the afflictions shutting them cannot be cured. svof's
definitions (`cnrl.lockdata`), which Emunah uses on both sides (`watch.LOCK_AFFLICTIONS`):

| Lock | Afflictions |
|---|---|
| soft | slickness, anorexia, asthma |
| venom | soft + paralysis |
| hard | soft + impatience (svof also: focus unusable for mana) |
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
svof's ranks it was the other way round, the mistake the lesson describes.

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
| `Synbios clenches his fists and grits his teeth.` | insomnia: our own is "You clench your fists, grit your teeth, and banish all possibility of sleep." **[svof]** |
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

## Open

- **Restoration salve and its 4s.** "He can't salve for 4 seconds because it's a restoration
  salve application" **[player]**. Emunah waits for the game's "You may apply another salve to
  yourself." either way; the length is not in `balance.md` until HELP or a timestamped
  application shows it.
- **Prep on a shared target.** Limb damage is what starts the kill, but Emunah has no limb
  counter for the target, and a Bard's prep is his own echo (`[21][42][--]`), not a game line.
- **A partner's attacks as we see them**, to know what he has landed and what the lock still
  needs from us.
- The third-person lines for the tree, smoking and focus.

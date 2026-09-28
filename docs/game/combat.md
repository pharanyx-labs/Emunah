# Combat: principles that shape the system

What HELP 13 (*The Principles of Battle*) and the character-state files say about how a
fight works, filtered to what automation has to respect. Verbatim sources are in `help/`;
tags follow `curing.md` (**[HELP x]**, **[play]**, **[open]**).

## Chasing balance

**[HELP combatprinciples]**
> Most of the damage and afflicting-dealing abilities in Achaea, as well as some defensive
> and movement ones, will require that you have equilibrium and balance and will, after you
> use the ability, take equilibrium or balance away from you for a certain number of
> seconds.
>
> If you recover equilibrium and balance, and your opponent is in the room with you, there
> is no reason not to immediately use another ability that will use these up, unless you
> wish to flee.

For Emunah this means three things:

1. **Offence and defence compete for bal/eq; curing mostly doesn't.** Attacks, tattoos,
   `stand`, movement and Priest heals all draw on bal/eq. Herbs, salves, elixirs, moss,
   smoke, focus and tree each have their own balance (`curing.md`). A cure should never
   wait on bal/eq unless it's proven to need it, and an attack should never be held back
   for a cure on another vector.
2. **Every cost is announced.** `Balance used: N.NNs.` / `Equilibrium used: N.NNs.`
   **[play, balance.md]**. Arm timers from those lines, not from estimates.
3. **Idle balance is lost damage.** Any hold in `core/act.lua` or `core/queue.lua` must be
   for a reason the game would enforce, or the system is slower than a human.

## Healing balances are a choice, not a queue

**[HELP combatprinciples]**
> you are limited as to how often a health or mana elixir can be drunk with a beneficial
> effect. Since they both use the same "balance", you must choose which to heal while in
> the midst of combat.

The elixir slot pre-empts by priority (`core/queue.lua`), so health and mana are ranked
against each other every tick rather than sent in turn.

## Damage types

**[HELP combatprinciples]** Nine types: cutting, blunt, cold, fire, asphyxiation, electric,
magic, poison, psychic. Avoidance mitigates physical damage **[HELP combatprinciples]** and
"most major forms of damage other than asphyxiation and the universally unblockable type"
**[HELP avoidance]**. Defences against the others come from elixirs and salves; see
`help/defence.txt`:

| Defence | Action | Herb / mineral |
|---|---|---|
| Resist fire | sip | frost |
| Resist poison | sip | venom |
| Resist cold attacks | apply | caloric |
| Dodge physical | sip | speed |
| Weapon rebound | smoke | skullcap / malachite |
| Levitate | sip | levitation |
| Prevent being moved | apply | mass |
| Block serpent bites | apply | sileris / quicksilver |
| Insomnia | eat | cohosh / gypsum |
| Wake at will | eat | kola / quartz |
| Deathsight | eat | skullcap / azurite |
| Third eye | eat | echinacea / dolomite |
| Blindness / deafness | eat | bayberry, hawthorn / arsenic, calamine |
| Water breathing | eat | pear / calcite ("cannot be used pre-emptively") |

**[open]** Which balance a defence *raise* spends isn't stated separately. The assumption
that it's the same balance as the cure with the same verb (eat = herb, sip = elixir) is how
`deflist.lua` works. Treat any contradicting rejection as evidence and record it.

## Body parts

**[HELP bodypartdamage, target]** Six parts: head, torso, left/right arm, left/right leg.
Damage to a part has three states. See the table in `curing.md`. The key rule is that a
state-2 limb needs **restoration before mending**, and restoration "does not get fixed
immediately". A mending sent to a mangled limb is wasted.

A limb being *broken* and a limb being *damaged* are different things, and HELP says so explicitly:
"It should be emphasized that they are _not_ the same thing."

Parrying (Weaponry) blocks body-part attacks with a suitable weapon wielded.

## Denizens vs. adventurers

**[HELP denizencombat]**
- "Most abilities that do something other than just cause damage will not work against
  denizens." Afflicting a denizen is wasted balance, which matters for bashing.
- A denizen "will continue to attack you until either it begins to panic and runs away, or
  until you or it is dead". This matches the play finding that disengaging doesn't stop an
  aggressive denizen **[play, incapacitation.md]**.
- Attacking denizens builds **rage** for battlerage abilities (`HELP BATTLERAGE`, not yet
  captured).
- Critical hits have five tiers: CRITICAL 2x, CRUSHING 4x, OBLITERATING 8x, ANNIHILATINGLY
  POWERFUL 16x, WORLD-SHATTERING 32x. Useful for damage-rate estimates.
- **[HELP curses]** "the only curse that will work on denizens is 'bleed'"; **[HELP venom]**
  "denizens will be immune to most venoms that do things other than cause damage".

## Afflictions come from attacks

**[HELP venom]** lists what each Serpent venom does, which is useful for mapping an
attacker's message to the affliction that follows. The descriptions are prose: curare leaves
the victim "unable to move", delphinium results in "a peacefully sleeping victim", notechis
"induces haemophilia", gecko leaves the body "coated in a very slick slime", slike removes
"all desire for food or drink", and voyria is "the most deadly venom" (its cure is an
immunity sip, per `help/afflictions.txt`). The names of the resulting
afflictions come from `help/afflictions.txt`, not from this prose. Don't map a venom to a
GMCP name without a capture.

Body-part attacks cause stupidity/concussion (head), bleeding (torso) and breaks (limbs).

## Escaping and states

- **Fleeing is just moving** **[HELP fleeing]**, which costs balance and equilibrium
  **[play, balance.md]** and is blocked by entanglement (WRITHE, `curing.md`).
- **Safe rooms** forbid offensive abilities **[HELP saferooms]**. An attack refused there is
  not a balance problem.
- **Death**: mana drains while dead, and at zero you are forced to embrace death. Levels 10
  and below are returned to the Ring of Portals and cured **[HELP death]**. The death
  message isn't captured here. Death-gating is opt-in in `act.lua` for that reason.
- **Asthma** and similar afflictions make you run out of breath while moving **[HELP
  breathing]**.
- **Mana** at zero blocks "most actions or abilities that require mental strength"
  **[HELP mana]**. **Endurance** and **willpower** at zero block "taxing physical" and mental
  actions respectively **[HELP endurance, willpower]**. None of these three is gated in
  `act.lua` yet. **[open]** Which specific commands they block.

## Preparation checklist

**[HELP preparation, combattips]** Armour, a weapon, cures and defences, and tattoos:
shield, hammer (breaks shields), cloak (blocks brazier summons), starburst (resurrects on
death), tentacle, boar (health regen), moon (mana regen). "Always keep as many defences up
as possible, so that you are ready in case you are surprised." That is what
`curing/defkeepup.lua` exists for.

Touching a tattoo costs balance even when the defence is already up **[play, defences.md]**.
Keep-up must check `Char.Defences` first.

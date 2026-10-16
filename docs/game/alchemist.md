# Fighting an Alchemist, and fighting beside a Bard

Source: **Anzerloi's arena log, 2026-10-15** — a Mudlet console extract from *his* profile,
shared by the user. Anzerloi (a Bard today; he has played a Priest too, see `bashing.lua`'s
support lines) beat Sobriquet, a Sublimation Alchemist ("sub alch", as a bystander named him)
with a pet crocodile, E'thernal, in the Oniar Estate arena. There are no timestamps, so
ordering is by line only.

Anzerloi runs his own system, so the log is game text interleaved with that system's echoes.
Lines below are verbatim. Tags:

- **[log]** the game's own line, as it appears in the log
- **[anzerloi]** what his system's echo says the line meant
- **[svof]** svof's trigger or dictionary for the same line (`svof/`)
- **[guess]** an educated reading, the user's instruction for this log; nothing acts on one
- **[open]** not known

## Reading his system's echoes

| Echo | Reading |
|---|---|
| ` [AFF] paralysis` on its own line, *before* a game line | an affliction he gained. It precedes the line that gives it, so it is most likely GMCP Char.Afflictions.Add arriving ahead of the text **[guess]** |
| ` Ate Magnesium [AFF] paralysis` | he ate magnesium for paralysis |
| ` Touched Tree [AFF] asthma`, ` Puffed Realgar [AFF] slickness`, ` Salved Body [AFF] anorexia` | the same, for tree, smoke and salve |
| ` Sobriquet eats aurum` / ` * Sobriquet aurum: (asthma 66%) (sensitivity 66%) (clumsiness 66%)` | his opponent tracker: Sobriquet ate aurum, and each listed affliction is now that likely still on him |
| ` Sobriquet has rebounding` / ` * Sobriquet lost: (REBOUNDING)` | the opponent's defences going up and down |
| `  PAEAN  (paralysis)  HIGHSUN  Sobriquet (clumsiness)` | his own attack: a song and a weapon move, each with the affliction it gives. A name in capitals, `(REBOUNDING)`, `(DEAFNESS)`, is a defence it strips |
| ` * Sobriquet head 21%` and the bar `[21][42][--] - 100[--][21][--]` | limb damage he has dealt: left arm, head, right arm / left leg, torso, right leg |
| `[CUTTING: 477]`, `[POISON: 457]`, `[UNBLOCKABLE: 774]` | damage he took from the line, by type |
| ` Bleeding: 18` | his own bleeding |
| `ENTERED:` / `LEFT:` / `HERE:` / `Alerted:   SE  Sobriquet` | people arriving, leaving, present, and approaching from a direction |

## The Alchemist's lines, against svof and Emunah

| Line [log] | Meaning | Emunah now |
|---|---|---|
| `A diminutive homunculus resembling Sobriquet claws into your flesh with dirty nails. The surrounding flesh begins to swell with fluid.` | svof's "Homunculus mercury (swellskin) bite" **[svof]**; tagged `homunculusmercury` **[anzerloi]**, the server's name in svof's own serverside table | gain + attacker (generated) |
| `Your flesh begins to swell as a diminutive homunculus resembling Sobriquet sinks its teeth into you.` | the same affliction **[anzerloi]**; **not in svof** | **[open]**: needs a second sighting before it gets a trigger |
| `Eating is suddenly less difficult again.` | homunculusmercury ends on the next herb eaten, of any kind **[svof: swellskin]**; seen after plumbum, antimony and magnesium **[log]**. While it lasts it "increases next herb balance" (svof's DIAG note) | cure (generated); `afflist.wearsOff` |
| `A diminutive homunculus resembling Sobriquet turns its head towards you, ... lets out an ear-piercing shriek that disrupts your thoughts.` | takes your focus balance **[svof: homunculus_throat → lostbal_focus]** | focus spent (generated) |
| `A diminutive homunculus resembling Sobriquet stares menacingly at you, its eyes flashing brightly.` | starts every homunculus-and-humour combo in the log **[log]**; svof only uses it as context for a haemophilia line | nothing |
| `Sobriquet glowers at you with a look of repressed disgust before making a slight gesture toward you.` | the humour attack's first line; there are two, one each for the temper and the wrack **[log]** | nothing |
| `You feel a sudden wave of malaise as your sanguine humour is tempered.` | `temperedsanguine`, and choleric, melancholic, phlegmatic alike **[svof, anzerloi]**. Stacks up to 3 in one go **[svof: got_humour]** | by GMCP (`afflist.temperedX`); svof's trigger takes an argument and is not generated |
| `Your sanguine humour drains some.` / `Your sanguine humour drains back to normal levels.` | one level cured, the last one cured. Antimony each time **[log]**, the mineral of ginger **[svof]** | by GMCP |
| `A short convulsion sweeps through your body as Sobriquet wracks your sanguine humour.` | one affliction from that humour's three **[svof: got_humour's table]**: choleric illness/sensitivity/slickness, melancholic anorexia/impatience/stupidity, phlegmatic asthma/clumsiness/disloyalty, sanguine haemophilia/recklessness/paralysis. Every wrack in the log agrees: sanguine → paralysis, phlegmatic+melancholic → asthma+impatience, melancholic+choleric → anorexia+slickness **[anzerloi]** | afflictions by GMCP; the line names the attacker (generated) |
| `... wracks your melancholic and choleric humours.` | a truewrack: two at once **[svof]** | as above |
| `Your blood is wracked by residual energy.` / `Your blood and body are ...` / `Your blood, body, and mind are ...` | damage, unblockable, 514–774 **[log]**. More words as more humours are tempered **[guess]**. **Not in svof** | nothing |
| `Sobriquet sketches out a symbol in the air with his finger in the shape of two overlapping hexagons.` then `Sobriquet sends myriad russet streams towards you, shattering your shield.` | your shield tattoo is gone **[svof: defs, shield off]** | GMCP removes it; keep-up raises it |
| `Sobriquet sketches out a symbol ... in the shape of a bisected circle.` then `Sobriquet surrounds himself with a translucent achromatic aura.` | **[open]** — a defence of his. The next residual-energy hit was 514, down from 774 **[log]** | nothing |
| `The reflective barrier surrounding Sobriquet reflects part of your attack back at you.` / `As your attack falls, Sobriquet's reflective barrier shatters and reflects the attack.` | his `tin` barrier (svof: "You are protected by a reflective barrier."). The first blow comes partly back, the next breaks it and comes back too: 477 each **[log]** | `pvp.reflecting` |
| `You yelp in pain as E'thernal, the black crystalline crocodile bashes you.` / `E'thernal, the black crystalline crocodile wounds you with a glancing cut.` | the pet: 62–95 blunt or cutting damage a hit **[log]** | nothing |

**Reave.** An Alchemist's finisher, faster the more of your humours are tempered: two, 10s;
three, 8s; four, 4s **[svof: sk.warnings]**. Emunah names it on the prompt (`watch.dangers()`),
with svof's other instant-kill states: dismember (bound and impaled), pulp (prone and serious
concussion), golem destroy (melting burn).

**How the combo arrives.** One paragraph held the homunculus's stare, its shriek, two glowers,
a temper, a truewrack and the residual damage **[log]**. svof refuses a shriek that is not
alone on its line; that check would discard the real one, so Emunah does not carry it.

## The Bard's side: what Anzerloi brings

From his own echoes **[anzerloi]**. For planning a fight together; nothing in Emunah acts on
it yet.

| Move | Gives |
|---|---|
| PAEAN | paralysis |
| ODE | asthma |
| ELEGY | lethargy |
| BHAJAN | dizziness |
| PROSODION | strips deafness; with it gone, sensitivity |
| NOMOS | strips rebounding (sent each time Sobriquet had it) |
| HIGHSUN | clumsiness, weariness or generosity; head and arm damage |
| JAB `<limb>` | nausea (torso) or clumsiness (arm), and that limb's damage; envenomed, voyria |
| HEELSNAP `<leg>` | hamstring, sensitivity or healthleech, leg damage |
| FLICK | earworm |
| SUNRISE / SUNSET | breaks prepared limbs: damaged left leg and torso, then left arm and head, with prone, asthma, impatience, slickness, stupidity |
| BEHEAD | the finisher, three in a row |

Also: `recite divinechild`, a saga (`Saga: ELECTRICITY`, `Saga: BLUNT`), `SONATA HEAL`, and a
crescendo that Sobriquet reset by eating ash every time it built up.

**What Sobriquet cured, and with what.** Magnesium (paralysis) on nearly every herb balance;
aurum (asthma, clumsiness, sensitivity, weariness, healthleech); ferrum (nausea, lethargy);
plumbum (dizziness, stupidity); ash (the crescendo); potash; tree; focus; legs salve **[log,
anzerloi]**.

**Complementing him [guess].** Paralysis, clumsiness, nausea and asthma come from both a Bard and
chasten; doubling them only feeds the opponent's magnesium and aurum. A Priest beside him adds
most by giving what he does not: the mental afflictions, sap, and the angel. The planner needs
his attacks *as we see them* to know what he landed, and the only log so far is from his side.

## Open

- Anzerloi's attack lines as a third party sees them: what Emunah would read to know what he
  has landed on a shared target, and to follow his target.
- How he calls a target: channel and wording. `allies.calls` reads it once known.
- The second homunculus bite line, and the achromatic aura.
- Whether `Your blood, body, and mind` names the tempered humours.

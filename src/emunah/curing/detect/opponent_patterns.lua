--- Opponent detection patterns.
---
--- The third-person counterpart to curing/detect/patterns.lua's self-affliction corpus.
--- Same discipline: every pattern here is a passive, third-person SYMPTOM message -- what
--- Achaea shows anyone in the room when an affliction visibly manifests on someone else
--- (a person's face contorting, staggering, swaying) -- never a move-recognition or
--- probabilistic inference from an attacker's own action text. That distinction matters:
--- symptom messages are a fixed, unambiguous fact about the affliction itself, so a pattern
--- here either matches Achaea's exact wording or it does not fire at all. Inferring "this
--- move probably caused that affliction" is a fundamentally different (and much harder)
--- technique that this file deliberately does not attempt.
---
--- PROVENANCE
--- ----------
--- This corpus was cross-checked against a mature third-party Achaea combat system's own
--- affliction-symptom trigger set, narrowed to the passive third-person messages that map
--- onto afflictions already in afflist.lua -- see docs/afflictions.md. Every entry here is
--- Achaea's own fixed game text (necessarily identical across any script reacting to the
--- same event), reimplemented against this module's own gain/cure API; none of the
--- surrounding detection logic, naming, or move-based inference technique from that source
--- is used here.

local opponent = emunah.curing.detect.opponent

-- ---------------------------------------------------------------------------
-- Third-person symptom onset -- the opponent visibly displays the affliction.
-- ---------------------------------------------------------------------------

opponent.add("masochism",   [[^The face of (\w+) contorts in horrified revulsion\.$]])
opponent.add("slickness",   [[^The protective coating covering the skin of (\w+) sloughs off\.$]])
opponent.add("clumsiness",  [[^(\w+) stumbles clumsily as the blow lands\.$]])
opponent.add("dizziness",   [[^(\w+) begins to sway unsteadily\.$]])
opponent.add("hypersomnia", [[^(\w+) suddenly appears tired all of a sudden\.$]])
opponent.add("addiction",   [[^A humbug clutches to the throat of (\w+), its grotesque body undulating\.$]])
opponent.add("stupidity",   [[^(\w+) makes a strangled meowing noise and quickly shuts up, blushing\.$]])
opponent.add("nausea",      [[^(\w+) doubles over, vomiting violently\.$]])
opponent.add("impatience",  [[^(\w+) shuffles \w+ feet in boredom\.$]])
opponent.add("darkshade",   [[^(\w+) stiffens suddenly, (?:his|her) features a masque frozen in agony\.$]])
opponent.add("mycalium",    [[^(\w+) violently quakes and shudders, \w+ eyes rolling in their sockets\.$]])
opponent.add("paralysis",   [[^Horror overcomes (\w+)'s face as \w+ body stiffens into paralysis\.$]])
opponent.add("dementia",    [[^(\w+) stares about \w+ frenziedly, wild-eyed\.$]])
opponent.add("epilepsy",    [[^(\w+) begins to shake uncontrollably\.$]])

-- BREATHING, the asthma tells (Anzerloi, 2026-10-23 14:26:24-14:30:21: "Valuable tells for
-- asthma"). "If they're holding breath and you hit with asthma (or more importantly,
-- someone else hits them with asthma but you can't tell) they exhale." And a held breath
-- means asthma is gone: "You can't do any breathing stuff with asthma" (opponent.breathHeld).
-- The wording is the reference system's third-person breathing lines; "exhales softly" and
-- "suddenly inhales deeply" are left alone until what they mean is known.
opponent.add("asthma",      [[^(\w+) exhales loudly\.$]])

-- Confusion landing: right after "The curse of confusion is brought down on to your victim."
-- at 17:44:40.85 on 2026-10-23, "Anzerloi looks about bemusedly."
opponent.add("confusion",   [[^(\w+) looks about bemusedly\.$]])
-- Our angel's sear and push, 2026-10-24 13:54:49 and 13:55:14, on Anzerloi.
opponent.add("ablaze",      [[^Your guardian angel's eyes glow like embers as (\w+) is seared and bursts into flame\.$]])
opponent.add("prone",       [[^A guardian angel extends a hand in the direction of (\w+), and (?:he|she) is suddenly sent sprawling to the ground by an invisible force\.$]])
-- 7.6s after the push (13:55:22.57).
opponent.addCure("prone",   [[^(\w+) stands up\.$]])
-- A push on a smite's line, into a target without inquisition (2026-10-24 14:04:00.92).
opponent.watchLine([[^A guardian angel reaches out to push (\w+) back, but \w+ stands \w+ ground\.$]],
   opponent.pushResisted)

-- Focus and the tree, both seen in the 17:44 spar. Each cures one affliction; it comes off
-- only when exactly one tracked affliction could be it. Focus also costs their mana.
opponent.watchLine([[^A look of extreme focus crosses the face of (\w+)\.$]], opponent.focused)
opponent.watchLine([[^(\w+) touches a tree of life tattoo\.$]], opponent.treeTouched)
opponent.watchBreath([[^(\w+) inhales and begins holding (?:his|her) breath\.$]])

-- ---------------------------------------------------------------------------
-- Third-person cure confirmation -- specific, unambiguous "they writhed free" messages.
-- Only the two whose wording is certain; a plausible-but-wrong cure pattern here retracts
-- an affliction that's still there, which is exactly the wrong kind of guess.
-- ---------------------------------------------------------------------------

opponent.addCure("roped",      [[^(\w+) has writhed free of \w+ entanglement by tied ropes\.$]])
opponent.addCure("transfixed", [[^(\w+) has writhed free of \w+ state of transfixation\.$]])

-- Confirmed live, 2026-08-05, immediately after `recite guilt <name>`: the target ate a
-- lobelia seed (guilt's own cure herb, see afflist.lua) and this line followed. No onset
-- (landing) message was seen for guilt or justice -- see class/priest.lua's header on the
-- Zeal verses for why no M.add() gain pattern exists for either yet.
opponent.addCure("guilt", [[^(\w+) straightens, as if some great burden had been lifted from \w+ shoulders\.$]])

-- What they eat retracts what it cures, raises what it raises, and spends their herb
-- balance (opponent.lua's cure-lines section).
opponent.watchEats()

-- ---------------------------------------------------------------------------
-- What an opponent is seen using, and the defences seen going up. Verbatim from Synbios
-- raising his defences in front of the user, 2026-10-15 20:29:34.40-20:29:45.03
-- (docs/game/pvp-locks.md). A drink and a salve do not say which, so they only mark the
-- balance used.
-- ---------------------------------------------------------------------------

opponent.watchUse("sip", [[^(\w+) takes a drink from .+ vial\.$]])
opponent.watchUse("salve", [[^(\w+) applies an? \w+ \w+ to (?:himself|herself)\.$]])
-- A salve and where it went, which narrows what it cured (opponent.salved): "rubs it on
-- his legs" (2026-10-24 13:30:32.06, as our blows worked his legs), "on his body" (13:54:55.32,
-- 6s after our sear set him ablaze), and "on (his|her) skin" from Synbios's defences.
for _, location in ipairs({ "legs", "arms", "head", "torso", "body", "skin" }) do
   opponent.watchLine([[^(\w+) takes some salve from a vial and rubs it on \w+ ]] .. location
      .. [[\.$]], function(name) opponent.salved(name, location) end)
end

-- Our own insomnia is "You clench your fists, grit your teeth, and banish all possibility
-- of sleep." [reference]; this is the same act seen from outside.
opponent.watchDefence("insomnia", [[^(\w+) clenches \w+ fists and grits \w+ teeth\.$]])
-- Applied at 20:29:35.02, formed at 20:29:45.03: the same 10s our own sileris shell takes.
opponent.watchDefence("fangbarrier", [[^A supple metallic shell of quicksilver has formed around (\w+)\.$]])
-- Touching cloak and mindseye (20:29:35.02, 20:29:35.77); shield by keep-up's same rule.
opponent.watchTattoos()

return true

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

-- ---------------------------------------------------------------------------
-- Third-person cure confirmation -- specific, unambiguous "they writhed free" messages.
-- Only the two whose wording is certain; a plausible-but-wrong cure pattern here retracts
-- an affliction that's still there, which is exactly the wrong kind of guess.
-- ---------------------------------------------------------------------------

opponent.addCure("roped",      [[^(\w+) has writhed free of \w+ entanglement by tied ropes\.$]])
opponent.addCure("transfixed", [[^(\w+) has writhed free of \w+ state of transfixation\.$]])

return true

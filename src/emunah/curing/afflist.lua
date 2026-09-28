--- The affliction table: what each affliction is, and how to cure it.
---
--- PROVENANCE
--- ----------
--- Cure mappings, herb/mineral alternates and salve application locations are cross-checked
--- against Achaea's own "A Lesson in Herbs". See docs/afflictions.md for how to extend the
--- table and what each entry has been verified against.
---
--- SHAPE
--- -----
---   <affliction> = {
---      cures    = { { vector, item, alt, location }, ... },  -- in preference order
---      priority = { <vector> = <rank> },                     -- 1 is most urgent
---   }
---
--- `item` is the herb/salve/elixir name; `alt` is the Alchemist equivalent, used when
--- `curing.method` is "minerals". `location` is the body part for APPLY.
---
--- PRIORITIES ARE PER-VECTOR
--- -------------------------
--- This is the part that is easy to get wrong. There is no single global ordering of
--- afflictions, because the vectors run in parallel: the most urgent thing to *eat* and
--- the most urgent thing to *apply* are unrelated questions, and answering them with one
--- combined list means a high-priority salve cure blocks a low-priority herb cure that
--- could have happened in the same second for free. Each vector therefore carries its own
--- rank, and curing/engine.lua resolves one cure per vector per tick.

local M = {}

--- Afflictions that prevent a whole vector from working.
---
--- These three are the reason Achaea combat has "locks": each one blocks a vector, and
--- each one is cured by a vector that another blocks.
---
---   anorexia  blocks eating    -> cured by applying epidermal, or FOCUS
---   slickness blocks applying  -> cured by smoking valerian, or eating bloodroot
---   asthma    blocks smoking   -> cured by eating kelp
---
--- With all three up, every item vector is shut and FOCUS is the only way out -- which is
--- exactly why focus ranks anorexia second in its own list. The engine consults this
--- table before choosing a cure, so it will not queue an `eat` while anorexic and then
--- sit there wondering why nothing is happening.
--- An affliction can shut more than one vector: anorexia blocks EATING, and eating is two
--- vectors here because irid moss runs on a balance of its own. It does not block OUTR --
--- pulling moss out of the rift still works while anorexic, which is why the pull and the
--- eat are queued separately.
M.blocks = {
   -- `elixir` too: svof's sip gate (raw-svo.skeleton.lua check_sip) refuses to sip while
   -- anorexic, as does its purgative gate. Anorexia is loss of the desire for food OR
   -- drink (HELP VENOM, slike: "lose all desire for food or drink").
   anorexia  = { "herb", "moss", "elixir" },
   slickness = { "salve" },
   asthma    = { "smoke" },
   -- svof check_smoke refuses on `mucous` as well as asthma. The refusal line it matches
   -- is "Your lungs are too clogged with mucous for you to attempt smoking."
   mucous    = { "smoke" },
   -- svof check_focus refuses on `inquisition` (a Priest affliction: "The words echo ...
   -- in your mind, interrupting your concentration.").
   inquisition = { "focus" },
   -- TOUCH TREE. svof's touchtree isadvisable refuses on paralysis, on any of these
   -- entanglements, and on EITHER arm being numb -- a numb arm cannot reach the tattoo the
   -- way a broken one cannot (both-arms-broken is have.bothArmsBroken(), not a table
   -- entry, because it takes two afflictions together). Paralysis is also enforced by
   -- queue.WHILE_PARALYSED on play evidence (2026-08-03 16:14:25.08); listing it here
   -- as well is what makes the UI's vector light and have.cure() agree with the queue.
   paralysis     = { "tree" },
   webbed        = { "tree" },
   bound         = { "tree" },
   transfixed    = { "tree" },
   transfixation = { "tree" },
   roped         = { "tree" },
   impaled       = { "tree" },
   numbedleftarm  = { "tree" },
   numbedrightarm = { "tree" },
   -- IMPATIENCE SHUTS FOCUS. Reported in play as "focus requires no eq or balance but the
   -- affliction 'impatience' does" -- read as: FOCUS itself costs neither equilibrium nor
   -- balance, and impatience is what stops it. Impatience is cured by eating goldenseal,
   -- so the escape from it is the herb vector, exactly like the three above.
   --
   -- This matters more than an ordinary block. Focus is the vector that clears mental
   -- afflictions, and against a Priest every mental affliction left up is 2% more sapping
   -- potential for them -- so a shut focus vector is not merely slower curing, it is the
   -- opponent's kill condition getting closer while it stays shut.
   impatience = { "focus" },
}

--- Blockers with no cure: they end on their own. Listed so the "every blocker has an
--- escape" invariant can tell a lock with no key from one that times out. Each has a
--- wear-off line in svof's trigger set ("You manage to cough away the mucous filling your
--- lungs.", "Clarity returns to your mind as the echoing accusations fade from memory.",
--- "Feeling returns to your left arm." / "...right arm.") and a `waitingfor` rather than a
--- cure in its dictionary (raw-svo.dict.lua).
M.wearsOff = {
   mucous         = true,
   inquisition    = true,
   numbedleftarm  = true,
   numbedrightarm = true,
}

--- Afflictions that stop you acting until you writhe free. These are not cured by items;
--- the cure is ONE WRITHE per entanglement, then waiting -- a second WRITHE while one is
--- under way prolongs it (HELP ENTANGLEMENT; see engine.onWritheStart). They lock
--- movement and attacks while active (act.blocked's `entangled`).
M.writhes = {
   transfixed = true,
   -- svof's gamename for transfixed.
   transfixation = true,
   impaled    = true,
   bound      = true,
   webbed     = true,
   roped      = true,
   hoisted    = true,
   dragonflex = true,
}

--- Both arms disabled at once blocks touching a tattoo -- it takes a working hand to reach
--- it. Reported in play: `touch tree` refused with both arms broken, the same way paralysis
--- refuses it (see queue.WHILE_PARALYSED and its 2026-08-03 evidence).
---
--- THE REAL TIERS, per an informant (Anzerloi) live in-game 2026-08-05 -- not HELP-verified,
--- but explicit and specific, and kept alongside the tiers already modelled below rather
--- than replacing them (see the crippled*/mutilated* entries' own note): `brokenleftarm`
--- (tier 1, cured by mending) -> `damagedleftarm` (tier 2, cured by restoration) ->
--- `mangledleftarm` (tier 3). Accumulative: "if you have damagedleftarm, you definitely have
--- brokenleftarm" -- a higher tier does not replace a lower one, it stacks on top of it.
---
--- Any severity tier counts on each side for the tattoo-block check -- crippled/mangled/
--- mutilated and broken/damaged/mangled are both escalating damage to the SAME arm, not
--- independent thresholds for whether it still reaches a tattoo, so every name is listed per
--- side. `unknowncrippledarm`/`unknowncrippledlimb` are deliberately absent: the name does
--- not say which arm, so it cannot be ANDed against a specific side without guessing which
--- one.
M.armAfflictions = {
   left  = { "crippledleftarm",  "mangledleftarm",  "mutilatedleftarm",
             "brokenleftarm",    "damagedleftarm" },
   right = { "crippledrightarm", "mangledrightarm", "mutilatedrightarm",
             "brokenrightarm",   "damagedrightarm" },
}

--- Defences maintained with the same machinery as cures. Kept here so
--- curing/defkeepup.lua can restore them with the right command, rather than duplicating
--- the herb knowledge.
M.defenceCures = {
   insomnia   = { vector = "herb",  item = "cohosh",    alt = "gypsum"    },
   kola       = { vector = "herb",  item = "kola",      alt = "quartz"    },
   myrrh      = { vector = "herb",  item = "myrrh",     alt = "bisemutum" },
   thirdeye   = { vector = "herb",  item = "echinacea", alt = "dolomite"  },
   deathsight = { vector = "herb",  item = "skullcap",  alt = "azurite"   },
   rebounding = { vector = "smoke", item = "skullcap",  alt = "malachite" },
   sileris    = { vector = "salve", item = "sileris",   alt = "quicksilver", location = "body" },
}

--- The afflictions themselves.
M.afflictions = {
   -- See docs/afflictions.md for the shape and for how entries are verified.
   ablaze = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "body" } },
      priority = { salve = 30 },
   },
   addiction = {
      cures = { { vector = "herb", item = "ginseng", alt = "ferrum" } },
      priority = { herb = 34 },
   },
   aeon = {
      cures = { { vector = "smoke", item = "elm", alt = "cinnabar" } },
      priority = { smoke = 1 },
   },
   agoraphobia = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" }, { vector = "focus" } },
      priority = { herb = 39, focus = 17 },
   },
   airdisrupt = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" }, { vector = "focus" } },
      priority = { herb = 53, focus = 11 },
   },
   -- ANOREXIA IS RANK 1 ON FOCUS, AHEAD OF EVERY MENTAL AFFLICTION.
   --
   -- Reported in play: "if you get anorexia, you want it away urgently even at the cost of
   -- maybe getting another mental... choose between veering closer to being sapped of a lot
   -- of mana, or being locked. Choose former."
   --
   -- The trade is asymmetric. A mental affliction left up is a slow loss -- against a
   -- Priest, 2% more sapping potential each. Anorexia is a shut vector, and the vector it
   -- shuts is where most cures live, so it does not cost a percentage, it stops the engine
   -- curing anything by eating. Ranked below a mental affliction it would wait behind one,
   -- which is the one ordering that turns a survivable position into a lock.
   anorexia = {
      cures = { { vector = "salve", item = "epidermal", alt = "sensory", location = "body" }, { vector = "focus" } },
      priority = { salve = 1, focus = 1 },
   },
   asthma = {
      cures = { { vector = "herb", item = "kelp", alt = "aurum" } },
      priority = { herb = 4 },
   },
   -- RENAMED from "blindaff" and the separate (now-removed) "blind" entry deleted.
   -- This table once carried both "blind" (cured by eating bayberry) and "blindaff"
   -- (cured by applying epidermal). Three independent sources now agree
   -- the real GMCP name is "blindness", cured by epidermal only: Achaea's own help page,
   -- an independent affliction dictionary, and another implementation's ignore
   -- list (which treats "blindness" as a defence-adjacent state, not a plain affliction --
   -- see defkeepup.lua's own unrelated "blind" defensive-skill entry). The curatives
   -- glossary says bayberry CAUSES blindness rather than curing it, which made "blind"
   -- actively harmful if it were ever selected: the engine would burn a herb balance
   -- making the affliction worse. See docs/afflictions.md.
   blindness = {
      cures = { { vector = "salve", item = "epidermal", alt = "sensory", location = "head" } },
      priority = { salve = 32 },
   },
   -- Per an informant (Anzerloi), live in-game 2026-08-05: tier 1 of the limb-break scale
   -- (arms AND legs, both sides), cured by mending -- distinct from, and one rung below,
   -- damagedleft*/damagedright* (tier 2, restoration; see there). Accumulative: whenever a
   -- higher tier is present, this one is too. Tier 2/3 breaks "generally only happen from
   -- limb damage events, namely equalling or exceeding 100% accumulated damage to that limb
   -- before its reset" -- per the same informant. See M.armAfflictions' own note for the
   -- full tier chain.
   brokenleftarm = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "arms" } },
      priority = { salve = 11 },
   },
   brokenleftleg = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "legs" } },
      priority = { salve = 7 },
   },
   brokenrightarm = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "arms" } },
      priority = { salve = 12 },
   },
   brokenrightleg = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "legs" } },
      priority = { salve = 8 },
   },
   caloric = {
      cures = { { vector = "salve", item = "caloric", alt = "exothermic", location = "body" } },
      priority = { salve = 36 },
   },
   charredburn = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "body" } },
      priority = { salve = 5 },
   },
   -- RENAMED from "cholerichumour" -- the real GMCP name uses a "temperedX" convention,
   -- not "Xhumour"; see docs/afflictions.md. Also a STACKING affliction: reports as
   -- "temperedcholeric (N)" with a live count in the name (gmcp/afflictions.lua strips it
   -- before this table is ever consulted).
   temperedcholeric = {
      cures = { { vector = "herb", item = "ginger", alt = "antimony" } },
      priority = { herb = 54 },
   },
   claustrophobia = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" }, { vector = "focus" } },
      priority = { herb = 29, focus = 5 },
   },
   clumsiness = {
      cures = { { vector = "herb", item = "kelp", alt = "aurum" } },
      priority = { herb = 19 },
   },
   confusion = {
      cures = { { vector = "herb", item = "ash", alt = "stannum" }, { vector = "focus" } },
      priority = { herb = 22, focus = 7 },
   },
   -- THESE FOUR WERE UNCURABLE. An empty `priority` makes afflist.priority() return nil for
   -- every vector, and engine.resolve() only ever considers ranked afflictions -- so the
   -- game reported them, the engine tracked them, and no cure was ever sent. All four are
   -- `apply health` damage from ordinary hunting, so the symptom was a fracture that never
   -- healed while everything else cured normally. Ranked after the existing salve list
   -- rather than guessed into the middle of it. test/run.lua asserts no entry can be left
   -- unrankable again.
   crackedribs = {
      cures = { { vector = "salve", item = "health", alt = "health", location = "torso" } },
      priority = { salve = 43 },
   },
   -- Tier 2 of the limb-break scale, one rung above broken* (see there for the full chain
   -- and its provenance) -- per the same informant, live in-game 2026-08-05. Head and torso
   -- are different from arms/legs: no tier-1 "broken" state for them at all ("you only break
   -- them with prep damage"), and restoration is applied by location ("apply restoration to
   -- head"/"...to torso") rather than the generic "arms"/"legs" the paired limbs take.
   -- damagedhead's name is independently corroborated: it appears verbatim as real Achaea
   -- text in an unrelated live transcript from earlier the same session (a Jester target's
   -- status line showed "(damagedleftleg) (damagedhead)").
   damagedhead = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "head" } },
      priority = { salve = 19 },
   },
   damagedleftarm = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "arms" } },
      priority = { salve = 23 },
   },
   damagedleftleg = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "legs" } },
      priority = { salve = 20 },
   },
   damagedrightarm = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "arms" } },
      priority = { salve = 24 },
   },
   damagedrightleg = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "legs" } },
      priority = { salve = 21 },
   },
   damagedtorso = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "torso" } },
      priority = { salve = 25 },
   },
   -- Confirmed live by the user, 2026-08-05: restoration/reconstructive, not mending/renewal
   -- -- matching mangledleftarm/mangledrightarm/etc below, the next tier up on the same
   -- escalating scale (see M.armAfflictions' comment). mending was simply wrong here.
   crippledleftarm = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "arms" } },
      priority = { salve = 16 },
   },
   crippledleftleg = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "legs" } },
      priority = { salve = 9 },
   },
   crippledrightarm = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "arms" } },
      priority = { salve = 15 },
   },
   crippledrightleg = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "legs" } },
      priority = { salve = 10 },
   },
   darkshade = {
      cures = { { vector = "herb", item = "ginseng", alt = "ferrum" } },
      priority = { herb = 20 },
   },
   deadening = {
      cures = { { vector = "smoke", item = "elm", alt = "cinnabar" } },
      priority = { smoke = 9 },
   },
   -- RENAMED from "deafaff"; the separate "deaf" entry (cured by eating hawthorn) is
   -- removed for the same reason as "blind" above -- see that comment.
   deafness = {
      cures = { { vector = "salve", item = "epidermal", alt = "sensory", location = "head" } },
      priority = { salve = 33 },
   },
   dementia = {
      cures = { { vector = "herb", item = "ash", alt = "stannum" }, { vector = "focus" } },
      priority = { herb = 35 },
   },
   depression = {
      cures = { { vector = "herb", item = "goldenseal", alt = "plumbum" } },
      priority = { herb = 11 },
   },
   disloyalty = {
      cures = { { vector = "smoke", item = "valerian", alt = "realgar" } },
      priority = { smoke = 7 },
   },
   dissonance = {
      cures = { { vector = "herb", item = "goldenseal", alt = "plumbum" } },
      priority = { herb = 42 },
   },
   dizziness = {
      cures = { { vector = "herb", item = "goldenseal", alt = "plumbum" }, { vector = "focus" } },
      priority = { herb = 24, focus = 9 },
   },
   earthdisrupt = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" } },
      priority = { herb = 55 },
   },
   epilepsy = {
      cures = { { vector = "herb", item = "goldenseal", alt = "plumbum" }, { vector = "focus" } },
      priority = { herb = 23, focus = 15 },
   },
   extremeburn = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "body" } },
      priority = { salve = 6 },
   },
   -- COMPOSE first. HELP AFFLICTIONS: "Fear: Compose"; HELP COMPOSE: "a state of panic
   -- ... If this happens to you, COMPOSE." svof has it as a misc action ahead of focus
   -- (dict.fear.misc, action "compose"). It costs no curing balance, so it goes on `special`.
   -- COMPOSE only. svof's dict.fear.focus is switched off outright (`return false`, with
   -- the old condition commented out), so focus is not a fear cure there at all.
   fear = {
      cures = { { vector = "special", command = "compose" } },
      priority = { special = 1 },
   },
   -- DISRUPTED EQUILIBRIUM. HELP COMPOSE: equilibrium "will not return no matter how long
   -- you wait. If this happens to you, simply CONCENTRATE." -- and confusion prevents
   -- concentrating. The name is svof's gamename for dict.disrupt; svof concentrates only
   -- when not confused (and not asleep, which act.blocked covers).
   disrupted = {
      cures = { { vector = "special", command = "concentrate", unless = { "confusion" } } },
      priority = { special = 2 },
   },
   firedisrupt = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" }, { vector = "focus" } },
      priority = { herb = 58, focus = 10 },
   },
   -- ADDED from a later cross-check -- see docs/afflictions.md. No priority data exists
   -- anywhere for these, so each
   -- is appended after the existing ranked herb list (59+) rather than guessed into the
   -- middle of it; reprioritize once you have actually needed to cure one in a fight.
   flushings = {
      cures = { { vector = "herb", item = "ginseng", alt = "ferrum" } },
      priority = { herb = 64 },
   },
   frost = {
      cures = { { vector = "elixir", item = "frost", alt = "endothermia" } },
      priority = { elixir = 2 },
   },
   frozen = {
      cures = { { vector = "salve", item = "caloric", alt = "exothermic", location = "body" } },
      priority = { salve = 12 },
   },
   generosity = {
      cures = { { vector = "herb", item = "bellwort", alt = "cuprum" }, { vector = "focus" } },
      priority = { herb = 30, focus = 6 },
   },
   -- ADDED from the tk cross-check; see the comment above flushings.
   guilt = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" } },
      priority = { herb = 59 },
   },
   haemophilia = {
      cures = { { vector = "herb", item = "ginseng", alt = "ferrum" } },
      priority = { herb = 26 },
   },
   hallucinations = {
      cures = { { vector = "herb", item = "ash", alt = "stannum" }, { vector = "focus" } },
      priority = { herb = 40 },
   },
   healthleech = {
      cures = { { vector = "herb", item = "kelp", alt = "aurum" } },
      priority = { herb = 43 },
   },
   heartseed = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "torso" } },
      priority = { salve = 2 },
   },
   hellsight = {
      cures = { { vector = "smoke", item = "valerian", alt = "realgar" } },
      priority = { smoke = 6 },
   },
   hypersomnia = {
      cures = { { vector = "herb", item = "ash", alt = "stannum" } },
      priority = { herb = 37 },
   },
   hypochondria = {
      cures = { { vector = "herb", item = "kelp", alt = "aurum" } },
      priority = { herb = 14 },
   },
   hypothermia = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "torso" } },
      priority = { salve = 11 },
   },
   illness = {
      cures = { { vector = "herb", item = "ginseng", alt = "ferrum" } },
      priority = { herb = 41 },
   },
   impatience = {
      cures = { { vector = "herb", item = "goldenseal", alt = "plumbum" } },
      priority = { herb = 8 },
   },
   inlove = {
      cures = { { vector = "herb", item = "bellwort", alt = "cuprum" } },
      priority = { herb = 38 },
   },
   itching = {
      cures = { { vector = "salve", item = "epidermal", alt = "sensory", location = "body" } },
      priority = { salve = 37 },
   },
   justice = {
      cures = { { vector = "herb", item = "bellwort", alt = "cuprum" } },
      priority = { herb = 44 },
   },
   laceratedthroat = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "head" } },
      priority = { salve = 24 },
   },
   lethargy = {
      cures = { { vector = "herb", item = "ginseng", alt = "ferrum" } },
      priority = { herb = 47 },
   },
   levitation = {
      cures = { { vector = "elixir", item = "levitation", alt = "hovering" } },
      priority = { elixir = 5 },
   },
   loneliness = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" }, { vector = "focus" } },
      priority = { herb = 32, focus = 12 },
   },
   madness = {
      cures = { { vector = "smoke", item = "elm", alt = "cinnabar" } },
      priority = { smoke = 5 },
   },
   manaleech = {
      cures = { { vector = "smoke", item = "valerian", alt = "realgar" } },
      priority = { smoke = 8 },
   },
   -- The higher (and, per the informant, final) of head's two levels -- confirmed directly,
   -- live in-game 2026-08-05, name and all: "there are damagedhead and mangledhead
   -- afflictions the curing system acknowledges, that's how they should show on gmcp events
   -- as well." See damagedhead's own note above for the head/torso tier chain.
   mangledhead = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "head" } },
      priority = { salve = 26 },
   },
   mangledleftarm = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "arms" } },
      priority = { salve = 17 },
   },
   mangledleftleg = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "legs" } },
      priority = { salve = 14 },
   },
   mangledrightarm = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "arms" } },
      priority = { salve = 18 },
   },
   mangledrightleg = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "legs" } },
      priority = { salve = 13 },
   },
   -- NOT independently confirmed like mangledhead was -- inferred by symmetry with head's
   -- own two-level chain ("head and torso are slightly different... they go up 2 levels,
   -- both requiring restoration"), same informant, same session. If this name turns out
   -- wrong live, torso's tier-2 affliction will surface as an unknown DIAG/GMCP name rather
   -- than silently mis-cure -- see afflist.known()'s callers.
   mangledtorso = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "torso" } },
      priority = { salve = 27 },
   },
   masochism = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" }, { vector = "focus" } },
      priority = { herb = 25, focus = 18 },
   },
   mass = {
      cures = { { vector = "salve", item = "mass", alt = "density", location = "body" } },
      priority = { salve = 3 },
   },
   -- RENAMED from "melancholichumour"; see the comment above temperedcholeric.
   temperedmelancholic = {
      cures = { { vector = "herb", item = "ginger", alt = "antimony" } },
      priority = { herb = 52 },
   },
   meltingburn = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "body" } },
      priority = { salve = 4 },
   },
   mildconcussion = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "head" } },
      priority = { salve = 8 },
   },
   mildtrauma = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "torso" } },
      priority = { salve = 23 },
   },
   mutilatedleftarm = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "arms" } },
      priority = { salve = 21 },
   },
   mutilatedleftleg = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "legs" } },
      priority = { salve = 20 },
   },
   mutilatedrightarm = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "arms" } },
      priority = { salve = 22 },
   },
   mutilatedrightleg = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "legs" } },
      priority = { salve = 19 },
   },
   -- ADDED from the tk cross-check; see the comment above flushings.
   mycalium = {
      cures = { { vector = "herb", item = "goldenseal", alt = "plumbum" } },
      priority = { herb = 65 },
   },
   -- CONFIRMED live 2026-08-03 15:52:00-15:52:11 against a bard (Anzerloi): both cure
   -- strings came straight off Char.Afflictions.Add, not a guess --
   --   {cure="EAT GINSENG" desc="Nausea causes intermittent, painful vomiting."
   --    name="nausea"}
   -- Before this it was untracked entirely: the engine logged "Tracking unknown affliction
   -- nausea" and never queued a cure for it, because the herb vector was monopolised every
   -- tick by paralysis/addiction and the server-suggestion fallback in engine.lua only fires
   -- when a vector has nothing else queued. Appended after the existing ranked herb list for
   -- the same reason as mycalium above -- no priority data exists yet.
   nausea = {
      cures = { { vector = "herb", item = "ginseng", alt = "ferrum" } },
      priority = { herb = 67 },
   },
   -- CONFIRMED live 2026-08-03 15:52:03-15:52:17, same bout as nausea above. Previously
   -- listed in docs/afflictions.md's open questions as "observed named but no confirmed
   -- cure" (with horror, pyre and the unweaving* effects) -- this closes that for crescendo.
   -- Verbatim: {cure="EAT ASH" desc="" name="crescendo (1)"} through "(6)", the number
   -- being the stack count gmcp/afflictions.lua strips before lookup. The engine already
   -- treated it correctly via the server-suggestion fallback ("No cure defined for
   -- crescendo -- using the server's own suggestion: eat ash"); this just gives it a real
   -- table entry instead of leaning on that fallback every time.
   crescendo = {
      cures = { { vector = "herb", item = "ash", alt = "stannum" } },
      priority = { herb = 68 },
   },
   pacifism = {
      cures = { { vector = "herb", item = "bellwort", alt = "cuprum" }, { vector = "focus" } },
      priority = { herb = 18, focus = 16 },
   },
   paralysis = {
      cures = { { vector = "herb", item = "bloodroot", alt = "magnesium" } },
      priority = { herb = 6 },
   },
   paranoia = {
      cures = { { vector = "herb", item = "ash", alt = "stannum" }, { vector = "focus" } },
      priority = { herb = 31 },
   },
   parasite = {
      cures = { { vector = "herb", item = "kelp", alt = "aurum" } },
      priority = { herb = 13 },
   },
   parestoarms = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "arms" } },
      priority = { salve = 41 },
   },
   parestolegs = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "legs" } },
      priority = { salve = 38 },
   },
   peace = {
      cures = { { vector = "herb", item = "bellwort", alt = "cuprum" } },
      priority = { herb = 17 },
   },
   -- RENAMED from "phlegmatichumour"; see the comment above temperedcholeric.
   temperedphlegmatic = {
      cures = { { vector = "herb", item = "ginger", alt = "antimony" } },
      priority = { herb = 51 },
   },
   -- ADDED from the tk cross-check; see the comment above flushings.
   rebbies = {
      cures = { { vector = "herb", item = "kelp", alt = "aurum" } },
      priority = { herb = 60 },
   },
   recklessness = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" }, { vector = "focus" } },
      priority = { herb = 15, focus = 3 },
   },
   relapsing = {
      cures = { { vector = "herb", item = "ginseng", alt = "ferrum" } },
      priority = { herb = 3 },
   },
   retribution = {
      cures = { { vector = "herb", item = "bellwort", alt = "cuprum" } },
      priority = { herb = 12 },
   },
   -- ADDED from the tk cross-check; see the comment above flushings.
   sandfever = {
      cures = { { vector = "herb", item = "goldenseal", alt = "plumbum" } },
      priority = { herb = 66 },
   },
   -- RENAMED from "sanguinehumour"; see the comment above temperedcholeric.
   temperedsanguine = {
      cures = { { vector = "herb", item = "ginger", alt = "antimony" } },
      priority = { herb = 56 },
   },
   scalded = {
      cures = { { vector = "salve", item = "epidermal", alt = "sensory", location = "head" } },
      priority = { salve = 26 },
   },
   -- ADDED from the tk cross-check; see the comment above flushings.
   scytherus = {
      cures = { { vector = "herb", item = "ginseng", alt = "ferrum" } },
      priority = { herb = 63 },
   },
   selarnia = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "torso" } },
      priority = { salve = 35 },
   },
   sensitivity = {
      cures = { { vector = "herb", item = "kelp", alt = "aurum" } },
      priority = { herb = 21 },
   },
   seriousconcussion = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "head" } },
      priority = { salve = 7 },
   },
   serioustrauma = {
      cures = { { vector = "salve", item = "restoration", alt = "reconstructive", location = "torso" } },
      priority = { salve = 25 },
   },
   severeburn = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "body" } },
      priority = { salve = 29 },
   },
   shadowmadness = {
      cures = { { vector = "herb", item = "goldenseal", alt = "plumbum" } },
      priority = { herb = 10 },
   },
   shivering = {
      cures = { { vector = "salve", item = "caloric", alt = "exothermic", location = "body" } },
      priority = { salve = 27 },
   },
   shyness = {
      cures = { { vector = "herb", item = "goldenseal", alt = "plumbum" }, { vector = "focus" } },
      priority = { herb = 36, focus = 14 },
   },
   skullfractures = {
      cures = { { vector = "salve", item = "health", alt = "health", location = "head" } },
      priority = { salve = 42 },
   },
   slashedthroat = {
      cures = { { vector = "salve", item = "epidermal", alt = "sensory", location = "head" } },
      priority = { salve = 28 },
   },
   slickness = {
      cures = { { vector = "herb", item = "bloodroot", alt = "magnesium" }, { vector = "smoke", item = "valerian", alt = "realgar" } },
      priority = { herb = 5, smoke = 3 },
   },
   speed = {
      cures = { { vector = "elixir", item = "speed", alt = "haste" } },
      priority = { elixir = 3 },
   },
   -- ADDED from the tk cross-check; see the comment above flushings.
   spiritburn = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" } },
      priority = { herb = 61 },
   },
   spiritdisrupt = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" } },
      priority = { herb = 16 },
   },
   -- HERB CURE RESTORED. It was removed after 20:57:29-20:58:04, when goldenseal was eaten
   -- every ~5s without clearing stupidity -- but HELP AFFLICTIONS ("Stupidity: Eat
   -- Goldenseal / Plumbum") and svof (dict.stupidity.herb, eatcure goldenseal/plumbum) both
   -- say it is the cure, and svof outranks this table on curing. That capture predates the
   -- fix for eating inside herb balance ("The plant has no effect.", docs/game/balance.md),
   -- which fits the symptom exactly. Rank 7 is what it had before removal.
   stupidity = {
      cures = { { vector = "herb", item = "goldenseal", alt = "plumbum" }, { vector = "focus" } },
      priority = { herb = 7, focus = 2 },
   },
   stuttering = {
      cures = { { vector = "salve", item = "epidermal", alt = "sensory", location = "head" } },
      priority = { salve = 31 },
   },
   -- ADDED from the tk cross-check; see the comment above flushings.
   tenderskin = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" } },
      priority = { herb = 62 },
   },
   timeloop = {
      cures = { { vector = "herb", item = "bellwort", alt = "cuprum" } },
      priority = { herb = 9 },
   },
   torntendons = {
      cures = { { vector = "salve", item = "health", alt = "health", location = "legs" } },
      priority = { salve = 44 },
   },
   unknowncrippledarm = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "arms" } },
      priority = { salve = 39 },
   },
   unknowncrippledleg = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "legs" } },
      priority = { salve = 34 },
   },
   unknowncrippledlimb = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "arms" } },
      priority = { salve = 40 },
   },
   unknownmental = {
      cures = { { vector = "focus" } },
      priority = { focus = 19 },
   },
   venom = {
      cures = { { vector = "elixir", item = "venom", alt = "toxin" } },
      priority = { elixir = 4 },
   },
   vertigo = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" }, { vector = "focus" } },
      priority = { herb = 45, focus = 4 },
   },
   voyria = {
      cures = { { vector = "elixir", item = "immunity", alt = "antigen" } },
      priority = { elixir = 1 },
   },
   waterbubble = {
      cures = { { vector = "herb", item = "pear", alt = "calcite" } },
      priority = { herb = 57 },
   },
   waterdisrupt = {
      cures = { { vector = "herb", item = "lobelia", alt = "argentum" }, { vector = "focus" } },
      priority = { herb = 49, focus = 8 },
   },
   weakness = {
      cures = { { vector = "herb", item = "kelp", alt = "aurum" } },
      priority = { herb = 33 },
   },
   wristfractures = {
      cures = { { vector = "salve", item = "health", alt = "health", location = "arms" } },
      priority = { salve = 45 },
   },
}

--- THE SERVER'S NAMES, per svof. svof keeps its own internal names and records what the
--- server calls each in a `gamename` field (raw-svo.dict.lua: "what serverside calls this
--- by -- names can be different as they were revealed years after Svof was made"). Where
--- that differs from the key this table uses, the server's name is added as an alias of
--- the same definition, so an affliction is cured whichever name Char.Afflictions uses.
--- Aliases share the definition table: one cure, one rank, never two to keep in step.
M.ALIASES = {
   lovers            = "inlove",
   weariness         = "weakness",
   pacified          = "pacifism",
   airpocket         = "waterbubble",
   burning           = "ablaze",
   whisperingmadness = "madness",
   -- The AFFLICTION is `blind`/`deaf`; `blindness`/`deafness` are the DEFENCES from bayberry
   -- and hawthorn (svof: blindaff -> "blind", blind -> "blindness").
   blind             = "blindness",
   deaf              = "deafness",
}
for alias, target in pairs(M.ALIASES) do
   M.afflictions[alias] = M.afflictions[target]
end

--- WHEN NOT TO CURE, per svof. Each entry is the extra condition in svof's
--- dict.<affliction>.<balance>.isadvisable beyond "we have it" -- the cases where the cure
--- would be wasted, undone, or done in the wrong order:
---
---   unless          don't, while any of these afflictions is up
---   unlessInFlight  don't, while a cure is in flight on any of these balances
---
--- Applied onto the cure options below at load, so have.cure() checks them for every
--- caller. svof's internal names are translated to the server's (see M.ALIASES): its
--- `madness` is `whisperingmadness`, `mutilated` is `mangled`, `mangled` is `damaged`,
--- `crippled` is `broken`. Both spellings of madness are listed, as both are keyed here.
local MADNESS = { "madness", "whisperingmadness" }
local function plus(list, ...)
   local out = {}
   for _, name in ipairs(list) do out[#out + 1] = name end
   for _, name in ipairs({ ... }) do out[#out + 1] = name end
   return out
end

M.CONDITIONS = {
   -- Mental afflictions are not cured under whispering madness (herb and focus alike).
   masochism      = { herb = { unless = MADNESS }, focus = { unless = MADNESS } },
   recklessness   = { herb = { unless = MADNESS }, focus = { unless = MADNESS } },
   vertigo        = { herb = { unless = MADNESS }, focus = { unless = MADNESS } },
   loneliness     = { herb = { unless = MADNESS }, focus = { unless = MADNESS } },
   dementia       = { herb = { unless = MADNESS }, focus = { unless = MADNESS } },
   paranoia       = { herb = { unless = MADNESS }, focus = { unless = MADNESS } },
   hallucinations = { herb = { unless = MADNESS }, focus = { unless = MADNESS } },
   confusion      = { herb = { unless = MADNESS }, focus = { unless = MADNESS } },
   hypersomnia    = { herb = { unless = MADNESS } },
   stupidity      = { focus = { unless = MADNESS },
                      -- A focus in flight may cure it; eating goldenseal on top wastes the herb.
                      herb = { unlessInFlight = { "focus" } } },
   dissonance     = { herb = { unlessInFlight = { "focus" } } },
   dizziness      = { herb = { unlessInFlight = { "focus" } } },
   shyness        = { herb = { unlessInFlight = { "focus" } } },
   epilepsy       = { herb = { unlessInFlight = { "focus" } } },
   -- "curing impatience before hypochondria will make it get re-applied" -- svof, and the
   -- same for lethargy, illness (the server's nausea) and addiction.
   impatience     = { herb = { unless = plus(MADNESS, "hypochondria"),
                               unlessInFlight = { "focus" } } },
   lethargy       = { herb = { unless = plus(MADNESS, "hypochondria") } },
   nausea         = { herb = { unless = plus(MADNESS, "hypochondria") } },
   illness        = { herb = { unless = plus(MADNESS, "hypochondria") } },
   addiction      = { herb = { unless = plus(MADNESS, "hypochondria") } },
   -- Smoke: valerian is not smoked for hellsight under inquisition; elm not for madness
   -- under hecate.
   hellsight      = { smoke = { unless = { "inquisition" } } },
   madness        = { smoke = { unless = { "hecate" } } },
   -- Bloodroot does not clear slickness under stain.
   slickness      = { herb = { unless = { "stain" } } },
   -- Salves, in svof's order: torso trauma first; frozen and hypothermia before shivering;
   -- blind before scalded (the same epidermal cures both).
   heartseed      = { salve = { unless = { "mildtrauma" } } },
   hypothermia    = { salve = { unless = { "mildtrauma" } } },
   frozen         = { salve = { unless = { "hypothermia" } } },
   shivering      = { salve = { unless = { "frozen", "hypothermia" } } },
   scalded        = { salve = { unless = { "blind" } } },
   -- LIMBS, worst first. A damaged limb waits for any mangled one on that pair of limbs; a
   -- broken one for its own limb's mangled or damaged state, and for paresthesia.
   damagedleftleg  = { salve = { unless = { "mangledleftleg", "mangledrightleg" } } },
   damagedrightleg = { salve = { unless = { "mangledleftleg", "mangledrightleg" } } },
   damagedleftarm  = { salve = { unless = { "mangledleftarm", "mangledrightarm" } } },
   damagedrightarm = { salve = { unless = { "mangledleftarm", "mangledrightarm" } } },
   brokenleftleg   = { salve = { unless = { "mangledleftleg", "damagedleftleg", "parestolegs" } } },
   brokenrightleg  = { salve = { unless = { "mangledrightleg", "damagedrightleg", "parestolegs" } } },
   brokenleftarm   = { salve = { unless = { "mangledleftarm", "damagedleftarm", "parestoarms" } } },
   brokenrightarm  = { salve = { unless = { "mangledrightarm", "damagedrightarm", "parestoarms" } } },
}

for name, byVector in pairs(M.CONDITIONS) do
   local definition = M.afflictions[name]
   for _, option in ipairs(definition and definition.cures or {}) do
      local condition = byVector[option.vector]
      if condition then
         option.unless = option.unless or condition.unless
         option.unlessInFlight = condition.unlessInFlight
      end
   end
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

--- Shared empty result. Returned instead of a fresh `{}` from the query functions below,
--- which are called dozens of times per prompt and whose empty answer is the common one.
--- Never handed out anywhere that mutates it.
---
--- Declared HERE, above the first query that returns it, and not further down beside
--- curesVia() where it used to live: a `local` is only in scope for what follows it, so a
--- function written above this line would silently read a nil GLOBAL of the same name and
--- return nil where it promised a list.
local EMPTY = {}

-- WHY EVERY QUERY BELOW TRIES THE BARE KEY FIRST
-- ----------------------------------------------
-- `tostring(name or ""):lower()` costs 0.149us and allocates a string, and these functions
-- are asked ~164 times per prompt between them -- about 24us, roughly a fifth of the tick,
-- spent turning "paralysis" into "paralysis".
--
-- It is the same shape as the inventory bug in docs/performance.md #1: normalising on read
-- what was already normalised on write. engine.add() lowercases before it stores, so every
-- key in engine.tracked is ALREADY lowercase, and the engine is what does the asking.
--
-- So: look the name up as given, and only normalise if that misses. An already-lowercase
-- name costs one hash lookup and allocates nothing; a name typed by a human still works
-- exactly as before, one lookup later. No second set of raw* entry points to keep in step,
-- and no cache to invalidate -- the tables these read are written at load and never mutated.

--- Definition for an affliction, or nil if we do not know it.
function M.get(name)
   local direct = M.afflictions[name]
   if direct ~= nil then return direct end
   return M.afflictions[tostring(name or ""):lower()]
end

--- Afflictions Achaea reports through Char.Afflictions that are NOT cured by an item or a
--- cure vector, but by a state change we already model elsewhere.
---
--- `prone` is the worked example, and it is the reason this table exists: we were inferring
--- being knocked down from per-denizen text ("...sending you sprawling"), one message per
--- attack per creature, when the game had been reporting it by name in Char.Afflictions the
--- whole time. GMCP is authoritative and complete where a hand-built pattern corpus can only
--- ever be partial.
---
--- Value is the module that owns the response, for the reader's benefit only.
M.STATES = {
   prone   = "curing/detect (STAND)",
   stunned = "curing/detect (waits it out)",
   -- The GMCP name is "sleeping", not "asleep" -- confirmed from a live Char.Afflictions.Add
   -- at 06:02:59 ({cure="" desc="While asleep, you can do little but dream, and wake up."
   -- name="sleeping"}). It arrives with an EMPTY cure field, so engine.serverCure() cannot
   -- help either; the response is WAKE and it lives in curing/detect.
   sleeping = "curing/detect (WAKE)",
}

--- Is this handled as a state rather than by a cure vector?
function M.isState(name)
   if M.STATES[name] ~= nil then return true end
   return M.STATES[tostring(name or ""):lower()] ~= nil
end

function M.known(name)
   return M.get(name) ~= nil
end

--- Which vectors, if any, this affliction shuts down. Always a list -- anorexia shuts two.
function M.blockedVectors(name)
   local direct = M.blocks[name]
   if direct ~= nil then return direct end
   return M.blocks[tostring(name or ""):lower()] or EMPTY
end

function M.isWrithe(name)
   if M.writhes[name] == true then return true end
   return M.writhes[tostring(name or ""):lower()] == true
end

--- affliction -> vector -> list of cure options, built on first use.
---
--- M.afflictions is a static table -- it is written at load and never mutated at runtime --
--- so the answer for a given pair cannot change, and recomputing it per call was pure waste:
--- resolve() asks this for every tracked affliction on every one of the six vectors, every
--- prompt, and each call allocated a list to hold one or two entries.
local viaCache = {}

--- Cure options for an affliction that use a given vector.
---
--- The returned list is shared and must be treated as read-only.
function M.curesVia(name, vector)
   -- The cache is keyed on the name AS GIVEN, so an already-lowercase name -- which is what
   -- the engine always has -- resolves in one lookup and never normalises. A mixed-case name
   -- gets its own cache entry pointing at the same inner table; the cost is one extra slot
   -- for a table that is bounded by the affliction list, not by anything a user can grow.
   local byVector = viaCache[name]
   if not byVector then
      name = tostring(name or ""):lower()
      byVector = viaCache[name]
   end
   if not byVector then
      local definition = M.afflictions[name]
      if not definition then return EMPTY end
      byVector = {}
      for _, cure in ipairs(definition.cures or EMPTY) do
         local list = byVector[cure.vector]
         if not list then
            list = {}
            byVector[cure.vector] = list
         end
         list[#list + 1] = cure
      end
      viaCache[name] = byVector
   end
   return byVector[vector] or EMPTY
end

--- Rank of an affliction within one vector's priority list; nil when the affliction
--- cannot be cured by that vector at all.
function M.priority(name, vector)
   local definition = M.afflictions[name]
   if definition == nil then
      name = tostring(name or ""):lower()
      definition = M.afflictions[name]
      if not definition then return nil end
   end
   -- A user override always wins.
   -- The fallback is the shared EMPTY rather than a literal `{}`: Lua builds the default
   -- table on every call whether or not it is used, and this is one of the hottest calls
   -- in the engine -- once per tracked affliction per vector per prompt.
   local overrides = emunah.config.get("priorities", EMPTY)
   -- `next()` rather than a length test: `priorities` is a map, and it is empty for
   -- essentially every user. Skipping the lookup entirely in that case is what makes the
   -- common path a single table read.
   if next(overrides) ~= nil then
      local override = overrides[name]
      if type(override) == "table" and override[vector] then return override[vector] end
   end
   return (definition.priority or EMPTY)[vector]
end

--- affliction -> ordered vector list, built on first use. Same argument as viaCache above:
--- M.afflictions never changes at runtime, so this answer cannot either.
local vectorsCache = {}

--- Every vector that can cure this affliction, in the table's preference order.
---
--- The returned list is shared and must be treated as read-only. It used to allocate TWO
--- tables per call (the list and a `seen` set) and is asked once per affliction per repaint
--- by ui/affpanel.lua, which redraws on every affliction event in a fight.
function M.vectorsFor(name)
   local hit = vectorsCache[name]
   if hit then return hit end

   local definition = M.get(name)
   if not definition then return EMPTY end

   local out, seen = {}, {}
   for _, cure in ipairs(definition.cures or EMPTY) do
      if not seen[cure.vector] then
         seen[cure.vector] = true
         out[#out + 1] = cure.vector
      end
   end
   vectorsCache[name] = out
   return out
end

--- Sorted list of every affliction we know about.
function M.names()
   return emunah.util.keys(M.afflictions)
end

function M.count()
   return emunah.util.count(M.afflictions)
end

return M

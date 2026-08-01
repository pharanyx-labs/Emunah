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
   anorexia  = { "herb", "moss" },
   slickness = { "salve" },
   asthma    = { "smoke" },
}

--- Afflictions that stop you acting until you writhe free. These are not cured by items;
--- the cure is repeated WRITHE, and they lock movement and most attacks while active.
M.writhes = {
   transfixed = true,
   impaled    = true,
   bound      = true,
   webbed     = true,
   roped      = true,
   hoisted    = true,
   dragonflex = true,
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
   anorexia = {
      cures = { { vector = "salve", item = "epidermal", alt = "sensory", location = "body" }, { vector = "focus" } },
      priority = { salve = 1, focus = 2 },
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
   crippledleftarm = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "arms" } },
      priority = { salve = 16 },
   },
   crippledleftleg = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "legs" } },
      priority = { salve = 9 },
   },
   crippledrightarm = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "arms" } },
      priority = { salve = 15 },
   },
   crippledrightleg = {
      cures = { { vector = "salve", item = "mending", alt = "renewal", location = "legs" } },
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
   fear = {
      cures = { { vector = "focus" } },
      priority = { focus = 20 },
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
   stupidity = {
      cures = { { vector = "herb", item = "goldenseal", alt = "plumbum" }, { vector = "focus" } },
      priority = { herb = 7, focus = 1 },
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

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

--- Definition for an affliction, or nil if we do not know it.
function M.get(name)
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
}

--- Is this handled as a state rather than by a cure vector?
function M.isState(name)
   return M.STATES[tostring(name or ""):lower()] ~= nil
end

function M.known(name)
   return M.get(name) ~= nil
end

--- Which vectors, if any, this affliction shuts down. Always a list -- anorexia shuts two.
function M.blockedVectors(name)
   return M.blocks[tostring(name or ""):lower()] or {}
end

function M.isWrithe(name)
   return M.writhes[tostring(name or ""):lower()] == true
end

--- Cure options for an affliction that use a given vector.
function M.curesVia(name, vector)
   local definition = M.get(name)
   if not definition then return {} end
   local out = {}
   for _, cure in ipairs(definition.cures or {}) do
      if cure.vector == vector then out[#out + 1] = cure end
   end
   return out
end

--- Rank of an affliction within one vector's priority list; nil when the affliction
--- cannot be cured by that vector at all.
function M.priority(name, vector)
   local definition = M.get(name)
   if not definition then return nil end
   -- A user override always wins.
   local overrides = emunah.config.get("priorities", {})
   local override = overrides[tostring(name):lower()]
   if type(override) == "table" and override[vector] then return override[vector] end
   return (definition.priority or {})[vector]
end

--- Every vector that can cure this affliction, in the table's preference order.
function M.vectorsFor(name)
   local definition = M.get(name)
   if not definition then return {} end
   local out, seen = {}, {}
   for _, cure in ipairs(definition.cures or {}) do
      if not seen[cure.vector] then
         seen[cure.vector] = true
         out[#out + 1] = cure.vector
      end
   end
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

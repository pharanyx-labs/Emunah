--- What raises each defence.
---
--- Pure data and lookup, split out of defkeepup.lua so that "what command raises X" and
--- "when should X be raised" are separate concerns. The tables below grow every time a
--- defence is verified; the behaviour beside them does not, and reading either was getting
--- harder for the other being in the way.
---
--- Nothing here touches the queue, the config or the game. It answers one question --
--- given a defence name, what do we send, on which vector, and what has to be true first --
--- and it answers it the same way whether keep-up is running or not.

local M = {}

local util    = emunah.util
local afflist = emunah.curing.afflist
local have    = emunah.have
local event   = emunah.event

--- Defences we know how to raise but that are not in afflist.defenceCures -- these are
--- plain commands rather than item cures. Extend via `emunah def add <name> <command>`.
M.commands = {
   -- name        = { vector, command }
   -- THE SKILL, NOT COHOSH (the user, 2026-10-04: "stop using cohosh as we can send the
   -- commands insomnia and relax insomnia"). The reference system's dict.insomnia.misc sends the same bare
   -- `insomnia` when its `conf.insomnia` is on, as a misc action: check_misc refuses it only
   -- while stunned, unconscious or asleep, never for balance or equilibrium, so it rides the
   -- free vector. The reference system's isadvisable also wants mana above `manause` and no hypersomnia;
   -- those are M.HOLDS.insomnia, with the voluntary sleep the user asked for. Lines [reference]:
   -- "You clench your fists, grit your teeth, and banish all possibility of sleep." and
   -- "You are already an insomniac." Confirmed in play 10:38:23.09: Char.Defences.Add
   -- insomnia, about 3% mana, no balance or equilibrium spent.
   insomnia     = { vector = "free",        command = "insomnia" },
   deathsight   = { vector = "herb",        command = "eat skullcap" },
   thirdeye     = { vector = "herb",        command = "eat echinacea" },
   -- ITEM, so keep-up asks have.pipe before it smokes. Without it the command is not an
   -- item raise: the pipe check and the pending window are both skipped, and `smoke
   -- skullcap` goes out of an unlit pipe. Login 2026-10-18 05:00:30.89 and 05:00:40.38,
   -- the second after the pipes had already been given up.
   rebounding   = { vector = "smoke",       command = "smoke skullcap", item = "skullcap" },
   -- NAMES UNVERIFIED. This is the last elixir left unchecked; whether Char.Defences calls
   -- the defence by the same word has not been confirmed, and the rest of this family shows
   -- it often does not. `emunah defs names` lists what the game actually reports, and the
   -- attempt budget names the mismatch when there is one.
   --
   -- IT LANDS SECONDS AFTER THE DRINK. Login 2026-10-18 09:40: drunk 26.22 with no line of
   -- its own, "Tiny tremours spread through your body as the world seems to slow down." at
   -- 31.17. The 2s confirm wait ran out in that gap and a second sip went at 27.84. `lands`
   -- holds the raise that long after the send (defkeepup's raise-pending window).
   speed        = { vector = "purgative",   command = "drink speed", lands = 7.0 },
   -- The DEFENCE is `poisonresist`; the ELIXIR is venom. Confirmed by the payload:
   --   Char.Defences.Add { name = "poisonresist",
   --                       desc = "Granted by the venom elixir or toxin tonic, this allows
   --                               you some resistance to poison damage." }
   -- Keyed on `poisonresist` because that is the only name Char.Defences ever uses, and
   -- this table is matched against it. Filed here rather than under `venom` after keep-up
   -- spent three elixirs raising a defence that had been up since the first one -- see
   -- M.ALIASES for how the elixir's name still resolves.
   poisonresist = { vector = "purgative",   command = "drink venom" },
   -- `immunity` IS THIS SAME DEFENCE, NOT A SEPARATE ONE. Not a naming mismatch -- a
   -- duplicate: drinking it produces the exact DEF line "Your resistance to damage by
   -- poison has been increased.", word for word what poisonresist already shows. Confirmed
   -- live 18:28:28-18:28:48: sipping it while poisonresist was already up did not just waste
   -- the sip --
   --   The elixir flows down your throat without effect.
   --   As the antivenom ravages your system, you feel very unwell.
   --   You are confused as to the effects of the venom.
   -- -- an actual affliction from the redundant dose, not a silent no-op like the mismatches
   -- above. No entry of its own: M.ALIASES folds `immunity` into `poisonresist` so keep-up
   -- recognises it as already up under either name and never sends `drink immunity` at all.
   -- The DEFENCE is `levitating`; the ELIXIR is levitation. Same family of bug, confirmed
   -- live 18:20:50-18:21:03: three sips of the levitation elixir each came back "The elixir
   -- flows down your throat without effect", and the attempt budget's own diagnostic named
   -- the mismatch outright --
   --   [emunah] Not raising levitation again: the sip had no effect, so it is already up
   --            under a different Char.Defences name
   --   [emunah]   Char.Defences is reporting these, which nothing here claims: ...,
   --              levitating, ...
   -- -- with "You are walking on a small cushion of air." sitting in DEF's own sixteen-
   -- defence readout the whole time. Keyed on `levitating` for the same reason as
   -- `poisonresist`; see M.ALIASES for how the elixir's name still resolves.
   levitating   = { vector = "purgative",   command = "drink levitation" },
   -- The DEFENCE is `temperance`; the ELIXIR is frost. Same family of bug, confirmed live
   -- 18:39:57.43-18:39:57.62: a sip came back "The elixir flows down your throat without
   -- effect", and the attempt budget's own diagnostic named the mismatch outright --
   --   [emunah] Not raising frost again: the sip had no effect, so it is already up under a
   --            different Char.Defences name
   --   [emunah]   Char.Defences is reporting these, which nothing here claims: ...,
   --              temperance, ...
   -- Keyed on `temperance` for the same reason as `levitating`; see M.ALIASES for how the
   -- elixir's name still resolves.
   temperance   = { vector = "purgative",   command = "drink frost" },
   -- Equilibrium-cost defences. Skills, not items, so they are gated on have.skill().
   -- VERIFIED IN PLAY, 16:07:10.56 on 2026-09-28: "touch cloak" -> "You caress the tattoo and
   -- immediately you feel a cloak of protection surround you. Equilibrium used: 1.00s.", and
   -- once up, "You are already protected by the cloak tattoo." A tattoo, touched, like
   -- mindseye -- the bare `cloak` this held before was never a command.
   -- NEEDS BALANCE, SPENDS EQUILIBRIUM. Login 2026-10-17 11:26:45.09: sent in the
   -- same line as `vault pegasus510623` (`vault pegasus510623|touch cloak`), the vault
   -- announced "Balance used: 1.0s." and this came back "You must regain balance first."
   -- Alone, at 11:26:47.58, "Equilibrium used: 1.00s." Standing, as every other
   -- balanceful defence here: nothing has shown it working while prone.
   cloak        = { vector = "equilibrium", command = "touch cloak", skill = "cloak",
                    needs = { bal = true, eq = true, standing = true } },
   shield       = { vector = "balance",     command = "touch shield", skill = "shield" },
   -- FREE. HELP NIGHTSIGHT lists no cooldown, and at login 2026-10-17 11:26:52.31 the
   -- prompt stayed `exckdb` either side of it, with no "Equilibrium used" line.
   -- Filing it under equilibrium made its send mark equilibrium spent.
   nightsight   = { vector = "free",        command = "nightsight",   skill = "nightsight" },
   -- VERIFIED IN PLAY: "touch mindseye" -> "Touching the mindseye tattoo, your senses are
   -- suddenly heightened. Equilibrium used: 3.00s." The bare `mindseye` command this held
   -- before was never watched working -- it is the tattoo, touched, not a stanced ability --
   -- and blind/deaf require this defence, so a wrong command here left the character with no
   -- way to raise the one thing that lets them function while deliberately blind and deaf.
   mindseye     = { vector = "equilibrium", command = "touch mindseye", skill = "mindseye" },

   -- BLIND AND DEAF ARE DEFENCES, and they REQUIRE MINDSEYE.
   --
   -- They are deliberate: blinding and deafening yourself is protection against attacks
   -- that need you to see or hear. But without mindseye up you then genuinely cannot see
   -- or hear anything -- mindseye is what lets you perceive while holding them.
   --
   -- So raising either without mindseye is not a partial success, it is actively harmful,
   -- and `requires` is enforced before the command is ever sent. Raising them in the wrong
   -- order leaves the character blind and deaf in a room they cannot read.
   --
   -- NOT A SKILL -- A HERB. The bare `blind`/`deaf` verbs this held before were guessed and
   -- DISPROVEN IN PLAY at 16:04:11 and 16:04:35 ("I don't know what \"blind\" does." /
   -- "I cannot fathom the meaning of \"blind\""). The real mechanism, verified 16:07:54-
   -- 16:08:08: `eat bayberry` while already blind answered "The bayberry has no effect. You
   -- are already blind." -- bayberry CAUSES blindness, not cures it (docs/afflictions.md
   -- carries the same fact for the OPPOSITE reason: it is why the old `blind` affliction-cure
   -- entry was removed from afflist.lua). `eat hawthorn` was followed immediately by "The
   -- aural world fades to silence." -- deafness onset -- the same relationship for deaf. Both
   -- then showed up in DEF ("You are blind."/"You are deaf.") among eleven defences at
   -- 16:08:08.80. No skill gate: these are ordinary herbs, not a trained ability.
   -- `item` is named explicitly (rather than left to be parsed back out of `command`) so
   -- curelist.restockables() can pull these from the rift the same way it does every other
   -- herb this character eats -- without it, keep-up would raise blind/deaf until the rift
   -- stock ran out and never top back up.
   --
   -- KEYED ON `blindness`, NOT `blind` -- Char.Defences does not use the verb. Confirmed
   -- live: with `blind` on keep-up, three raises of `eat bayberry` each answered "You are
   -- already blind" and never registered, and the attempt budget's own diagnostic named the
   -- mismatch outright --
   --   [emunah] Raised blind 3 times and it never appeared in Char.Defences -- stopping.
   --   [emunah]   Char.Defences is reporting these, which nothing here claims: blindness, ...
   -- -- the same family of bug as venom/poisonresist below, and the same fix: key on what
   -- Char.Defences actually says. Surprising in its own way: Char.Afflictions ALSO calls this
   -- state `blindness` (see M.DELIBERATE), so one word now names both channels. DIAG's bare
   -- state text is a THIRD, independent vocabulary that still says `blind` -- see
   -- M.DIAG_STATES; do not fold that comparison back into this table.
   --
   -- `deaf` HAD the same open question and is now answered THE SAME WAY. Confirmed live:
   -- three raises of `eat hawthorn` each answering "The aural world fades to silence." (or,
   -- once already deaf, no distinct refusal at all -- the onset message is the only
   -- confirmation, and it is a trigger-line, not a Char.Defences update, so it can print well
   -- before DEF or Char.Defences catches up) --
   --   [emunah] Raised deaf 3 times and it never appeared in Char.Defences -- stopping.
   --   [emunah]   Char.Defences is reporting these, ...: boartattoo, deafness, mosstattoo, ...
   -- -- `deafness` named outright, same as `blindness` was.
   deafness     = { vector = "herb", command = "eat hawthorn", item = "hawthorn",
                    requires = "mindseye" },
   blindness    = { vector = "herb", command = "eat bayberry", item = "bayberry",
                    requires = "mindseye" },
   -- `fangbarrier` was here as a skill command of its own, never seen working. It is what
   -- sileris grants [reference: sileris.gamename], so it is raised by the salve now --
   -- afflist.defenceCures.fangbarrier.

   -- Priest (Devotion). `perform inspiration`, equilibrium 3.50s -- both verified, see
   -- docs/game/defences.md. Reported by GMCP as:
   --   Char.Defences.Add    { desc = "Divine inspiration increases your strength.",
   --                          name = "inspiration" }
   --   Char.Defences.Remove { "inspiration" }
   -- and it lapses on its own after about ten minutes, which is exactly the shape keep-up
   -- exists for: nothing strips it, it simply runs out.
   --
   -- NO SKILL GATE, for the reason recorded at `perform hands` in curing/engine.lua: the
   -- ability's name in the skill index has not been observed, and a wrong one disables the
   -- defence silently the moment the index finishes loading. The attempt budget above is
   -- the backstop if it turns out not to be trained -- three tries, then it says so.
   --
   -- IT NEEDS BALANCE AND EQUILIBRIUM AND TO BE STANDING. All three, or the command is
   -- refused and the attempt is spent for nothing -- and with only three attempts in the
   -- budget, three refusals while prone in a fight retire the defence for the rest of the
   -- session. `eq` is already implied by the vector; it is stated anyway so the entry reads
   -- as the whole requirement rather than half of it split across two mechanisms.
   inspiration  = { vector = "equilibrium", command = "perform inspiration",
                    needs = { bal = true, eq = true, standing = true } },

   -- Priest (Devotion). `perform bliss`, equilibrium 6.50s -- verified in play ("You pour
   -- blessings of bliss over yourself, granting visions of the majesty of the divine.") --
   -- but the resulting buff produces NO Char.Defences line at all, confirmed the same
   -- session: DEF's own ten-defence readout, taken 22 minutes into the buff, never named it.
   -- Exactly the failure mode `bliss` and `satiation` were originally removed for -- see
   -- "Invisible defences cannot be kept up", below -- except this time kept, deliberately,
   -- as an unconfirmable one-shot rather than removed outright.
   --
   -- NOW TRACKED FROM ITS OWN LINES, like the reference system (defs_data.bliss: invisibledef, with three
   -- `on` lines and one for another player's blessing) -- see M.SYNTHETIC.bliss. It used to
   -- be `unconfirmable`, satisfied the moment it was sent; that lived only in memory, so every
   -- `emreload` forgot it and sent `perform bliss` again. Same needs as inspiration; see the
   -- note there on `perform` commands wanting balance and equilibrium both.
   bliss        = { vector = "equilibrium", command = "perform bliss",
                    needs = { bal = true, eq = true, standing = true } },

   -- Priest (Spirituality). `angel summon` -- verified live via `emunah debug gmcp`
   -- 07:44:53-07:44:59: "Equilibrium used: 2.00s.", matching HELP SUMMON's stated 2.00s
   -- cooldown. NOT a normal M.commands entry in one respect: "up" is not read from here at
   -- all, because Char.Defences never reports it -- see M.SYNTHETIC below, which is what
   -- M.isUp() actually consults for `trackangel`. This entry only says how to raise it.
   trackangel   = { vector = "equilibrium", command = "angel summon" },
}

--- Afflictions that are somebody's DEFENCE when they are holding it deliberately.
---
--- `blind` and `deaf` are defences, and the game reports the resulting state as an
--- affliction as well -- so the curing engine sees `blindness` and reaches for epidermal
--- while the user is deliberately blind. Watched at 13:55:02: "Cannot cure blindness:
--- epidermal is in the rift, not in hand", with DEF listing "You are blind." among twelve
--- defences at the same time. Only the missing salve stopped it stripping the defence.
---
--- affliction name -> the Char.Defences name that means it was wanted.
---
--- Char.Defences and Char.Afflictions use `blindness`/`deafness` for each state, confirmed
--- live for both (see M.commands.blindness / .deafness). The affliction's other name is
--- `blind`/`deaf`: the reference system's gamename (blindaff -> "blind"), the darkness trigger
--- (`textGain("blind")`), and DIAG's bare word. Those share the epidermal cure through
--- afflist.ALIASES. Without a key here, classify() treats a tracked `blind` as a real
--- affliction and have.cure() then refuses the salve, which is the warning at 17:31:33.81:
--- "Cannot cure blind: epidermal would also cure blind/deaf, which are held on purpose."
--- The alias points at the defence. It does not make `blind` a second defence to raise.
---
--- `insomnia` is the same shape, confirmed live 17:59:54-18:00:04: `eat cohosh` raised
--- BOTH Char.Afflictions.Add and Char.Defences.Add for "insomnia" in the same GMCP burst,
--- and afflist has no cure entry for it (see M.commands.insomnia), so engine.lua's
--- server-suggested-cure fallback took the GMCP payload's own "cure" field -- EAT
--- GOLDENSEAL -- at face value and ate the defence straight back off, ten seconds later.
--- Unlike blindness/deafness this one is not a mindseye-gated pair; the fallback path
--- itself had no deliberate() guard at all, which is the bug -- see the guard added at
--- the call site in engine.lua.
M.DELIBERATE = {
   blindness = "blindness",
   deafness  = "deafness",
   -- The text/the reference system name of the same state. Value is the Char.Defences name.
   blind     = "blindness",
   deaf      = "deafness",
   insomnia  = "insomnia",
}

--- The word DIAG's bare-state line uses for each deliberate defence -- ITS OWN vocabulary,
--- independent of the Char.Defences name above. Verified only for `blind` (see
--- curing/detect/diag.lua's module header and docs/game/help/who-listings.txt); `deaf` is
--- carried across by the same reasoning that produced the old M.DELIBERATE entry, unverified.
--- Kept apart from M.DELIBERATE on purpose -- folding it back in was exactly the bug that
--- made M.commands.blindness necessary: one table cannot serve both a GMCP name and a DIAG
--- word once the two diverge, and here they already have.
M.DIAG_STATES = {
   blindness = "blind",
   deafness  = "deaf",
}

--- Is this affliction actually a defence the character is holding on purpose?
---
--- The bare-key lookup first, then the normalised one, for the reason spelled out over
--- afflist.get(): this was the single hottest line in the profile, asked 53 times per
--- prompt, and all but a handful of those were the engine handing back a name it had
--- already lowercased itself when it stored it. M.DELIBERATE is a handful of entries, so the
--- overwhelmingly common answer is "no" from one hash lookup that allocates nothing.
function M.deliberate(affliction)
   local defence = M.DELIBERATE[affliction]
   if defence == nil then
      defence = M.DELIBERATE[tostring(affliction or ""):lower()]
   end
   if not defence then return false end

   local defences = emunah.gmcp.defences
   if defences ~= nil and defences.has(defence) then return true end

   -- Char.Defences CAN LAG THE AFFLICTION MESSAGE. On login especially, "You are blind and
   -- can see nothing but darkness." prints before the defences list arrives -- watched at
   -- login, the engine spent a whole tick chasing epidermal for a defence held on purpose,
   -- because the only source consulted here had not answered yet. If keep-up is the one
   -- raising and holding this defence, that is proof of intent on its own; it does not need
   -- to wait on a GMCP round trip to say what it already knows.
   local defkeepup = emunah.curing.defkeepup
   return defkeepup ~= nil and defkeepup.mode(defence) ~= nil
end

--- Names people type, mapped to the name Char.Defences uses.
---
--- These diverge more often than they look like they should: a defence is usually known by
--- whatever grants it, and the game names it after what it does. `venom` is the elixir,
--- `poisonresist` is the defence, and typing the first is the obvious thing to do.
---
--- Kept as a map rather than as duplicate table entries so there is exactly one key per
--- defence -- two entries for one defence means two grid cells, two attempt budgets and two
--- ways to be half-configured.
M.ALIASES = {
   venom      = "poisonresist",
   -- Not a naming mismatch like the others here -- `immunity` IS `poisonresist`, confirmed
   -- by an identical DEF line. See the comment on M.commands.poisonresist.
   immunity   = "poisonresist",
   levitation = "levitating",
   frost      = "temperance",
   -- `blind`/`deaf` are the verbs that raise these (M.commands.blindness/deafness) and
   -- DIAG's own words for them (M.DIAG_STATES); Char.Defences calls the defences themselves
   -- `blindness`/`deafness`. Keeps typing and config under the old, natural names working.
   blind = "blindness",
   deaf  = "deafness",
   -- The item, not the defence [reference: gamename]. See afflist.defenceCures.
   sileris     = "fangbarrier",
   quicksilver = "fangbarrier",
   myrrh       = "scholasticism",
   bisemutum   = "scholasticism",
}

--- What the grid calls a defence whose server name nobody would recognise: you apply
--- sileris and eat myrrh, whatever Char.Defences says.
M.LABELS = {
   fangbarrier   = "sileris",
   scholasticism = "myrrh",
}

--- The Char.Defences name for whatever the user typed.
function M.canonical(name)
   name = util.trim(tostring(name or "")):lower()
   return M.ALIASES[name] or name
end

--- Defences whose commands have NOT been verified in play.
---
--- WHY THIS IS A SEPARATE TABLE instead of more entries above: everything in M.commands has
--- been watched working, and nothing here has. That difference has to survive contact with
--- the code rather than living in someone's memory, so these are kept apart and they LOSE
--- to anything above -- M.resolve() consults M.commands first and only falls through here.
---
--- Scoped to defences every character can use, plus Devotion and Spirituality. Adding the
--- rest of the game's classes would bury the sixteen entries that matter for this character
--- in a grid of abilities they cannot train.
---
--- THE VECTOR here records only whether the command is believed to spend physical balance.
--- Where that was ambiguous the cautious reading won: requiring balance costs a delay, while
--- not requiring one costs a refusal and one of only three attempts.
---
--- EVERY ENTRY NEEDS STANDING. None of these is known to work while prone, and the cost of
--- assuming otherwise is a wasted attempt from a budget of three.
---
--- THE NAMES have not been checked against Char.Defences on a live character either, and
--- that is the likeliest thing to be wrong. When one is, the defence simply never appears,
--- the attempt budget stops after three tries and says so, and
--- `emunah defs add <name> <command>` corrects it. That is the intended way to find out,
--- and it is why none of these is enabled by default.
M.IMPORTED = {
   -- Everyone. Costing no balance:
   bell           = { vector = "free", command = "touch bell" },
   coldresist     = { vector = "free", command = "activate cold resistance" },
   electricresist = { vector = "free", command = "activate electric resistance" },
   fireresist     = { vector = "free", command = "activate fire resistance" },
   magicresist    = { vector = "free", command = "activate magic resistance" },
   groundwatch    = { vector = "free", command = "groundwatch on" },
   skywatch       = { vector = "free", command = "skywatch on" },
   treewatch      = { vector = "free", command = "treewatch on" },
   softfocus      = { vector = "free", command = "softfocus on" },
   telesense      = { vector = "free", command = "telesense on" },
   -- Equilibrium, not balance, from play (2026-10-04): refused "You must regain equilibrium
   -- first." at 11:36:49.41 with balance up, raised at 11:36:51.40 with balance down from a
   -- vault. Costs neither: the prompt kept its `e`.
   vigilance      = { vector = "free", command = "vigilance on",
                      needs = { eq = true, standing = true } },

   -- Everyone. Costing a balance of some kind -- see BALANCEFUL below.
   alertness      = { vector = "balance", command = "alertness on" },
   clinging       = { vector = "balance", command = "cling" },
   curseward      = { vector = "balance", command = "curseward" },
   -- EQUILIBRIUM, NOT BALANCE. HELP HYPERSIGHT: "Cooldown: 3.00 seconds of equilibrium."
   -- Login 2026-10-17 11:26:31.34: "Equilibrium used: 3.00s." and the prompt lost its
   -- `e`. On the balance vector it left the equilibrium slot free, so `touch mindseye`
   -- went out in the same batch and came back "You must regain equilibrium first."
   hypersight     = { vector = "equilibrium", command = "hypersight on" },
   -- Antitheft: a pickpocket fails against it, and stripping it is the thief's opening
   -- move (HELP THIEVERY: "setup selfishness as a defence"). Command and lines are the reference system's
   -- (its defs file), and the cost is from play, 2026-10-04 08:09:39.34:
   --   selfishness -> "You rub your hands together greedily." "Equilibrium used: 0.50s."
   -- with the prompt going excdb -> xcdb. It NEEDS balance too: 2026-10-18 10:00:37.01,
   -- typed straight behind a vault that had just taken balance, it came back "You must
   -- regain balance first." So it waits out a vault, and cannot go in front of one.
   selfishness    = { vector = "equilibrium", command = "selfishness",
                      needs = { bal = true, eq = true, standing = true } },

   -- Priest. HUNT HERESY costs "4.00 seconds of equilibrium" and 400 mana (GMCP ability
   -- text, docs/game/help/abilities-2026-10-15.txt); it was filed under balance. Needs both,
   -- as every balanceful defence here does until play shows otherwise.
   heresy         = { vector = "equilibrium", command = "hunt heresy",
                      skillset = "spirituality" },
}

-- WHAT IS NOT HERE, AND WHY: INVISIBLE DEFENCES
--
-- `bliss` and `satiation` were in this table and had to be removed. Neither appears in DEF
-- output at all, and therefore neither appears in Char.Defences. Every part of this module
-- rests on "if it is not in the list, it is not up", so a defence that can never be in the
-- list can never be confirmed: keep-up raises it, sees nothing, raises it again, and retires
-- it after three tries having spent the balance each time.
--
-- Observed exactly that, 13:24:45.03 onward. `perform bliss` worked -- "You pour blessings
-- of bliss over yourself" -- and the next two attempts came back "That person is already
-- experiencing bliss." before:
--
--   [emunah] Raised bliss 3 times and it never appeared in Char.Defences -- stopping.
--
-- Three raises at 6.50s of equilibrium each, for a defence that was up the whole time.
-- A defence with no DEF line is not usable here without a separate trigger-driven way to
-- know it is up.
--
-- `bliss` IS BACK, ABOVE, kept apart from this warning deliberately: it is now
-- `unconfirmable = true` rather than a plain M.commands entry, and defup marks it satisfied
-- on SEND rather than on Char.Defences confirmation -- see the comment on the entry itself.
-- `satiation` has not been given the same treatment and stays out. Check `invisibledef` and
-- the presence of a `def` line before adding more this way, or as a plain entry either.

-- "COSTS A BALANCE" DOES NOT MEAN "THE BALANCE VECTOR"
--
-- Achaea has several balances and knowing that a command spends one of them does not say
-- which. `perform bliss` was recorded here as costing balance and announced
-- "Equilibrium used: 6.50s." in play -- so putting it on the `balance` vector was wrong,
-- and would have fired these into "You must regain balance first." whenever equilibrium was
-- the resource actually missing.
--
-- Until each is observed, the honest requirement for an unverified one of these is BOTH
-- -- it costs one of them and we do not know which. That is conservative in the only
-- direction that is cheap: waiting costs a delay, guessing wrong costs a refusal and one of
-- three attempts. The real cost timer still comes from the game's own
-- "Equilibrium used: N.NNs." / "Balance used: N.NNs." line.
--
-- COSTING NOTHING DOES NOT MEAN NEEDING NOTHING. The reference system sends its balanceless defences only
-- with balance, equilibrium and both arms ([reference] check_balanceless_acts), and `vigilance on`
-- went out here without equilibrium and was refused (11:36:49.41, 2026-10-04). So the free
-- ones need both as well, until play shows one does not -- as vigilance has, for balance.
for _, entry in pairs(M.IMPORTED) do
   entry.source = "imported"
   entry.needs  = entry.needs or { bal = true, eq = true, standing = true }
end

-- ---------------------------------------------------------------------------
-- Synthetic defences: no Char.Defences entry at all.
-- ---------------------------------------------------------------------------
--
-- gmcp/defences.lua's whole premise is "Char.Defences is complete -- if it is not in the
-- list, it is not up", and every ordinary entry above relies on that. `trackangel` and
-- `trackmace` do not fit it: confirmed live via `emunah debug gmcp`, neither the guardian
-- angel (07:44:53-07:45:32: `angel summon`/`angel fade` produce only a Char.Vitals
-- equilibrium line) nor the mace (07:49:40: `call mace` produces a Char.Items.Update and
-- nothing else) ever touches Char.Defences or Char.Status. "Up" for these two has to come
-- from somewhere else, which is what M.SYNTHETIC and M.isUp() below are for -- kept apart
-- from the ordinary lookup so gmcp/defences.lua itself stays a pure mirror of the GMCP feed.

--- name -> function returning whether the defence is up right now.
M.SYNTHETIC = {
   -- curing/detect's own text-trigger flag; see patterns.lua's "Guardian angel" section.
   trackangel = function()
      local detect = emunah.curing.detect
      return detect ~= nil and detect.isAngelSummoned()
   end,
   -- Char.Items when we can see it. While blind without mindseye that feed goes silent
   -- (gmcp/items.lua), so a wield the game just confirmed in text is the only truth until
   -- sight returns. Once sighted, GMCP wins: a text flag must not keep reading "up" over
   -- an inventory that no longer holds the mace.
   trackmace = function()
      local items = emunah.gmcp.items
      if items then
         local mace = items.first("spiritual mace", "inv")
         if mace then
            local attrib = items.attrib(mace)
            return attrib.wielded_left or attrib.wielded_right
         end
      end
      local place = emunah._persist and emunah._persist.macePlace
      if place ~= "wielded" then return false end
      return items ~= nil and not items.sighted()
   end,
   -- Invisible to Char.Defences and to DEF alike (confirmed 22 minutes into the buff; the reference system
   -- marks it `invisibledef` too), so up comes from its own lines -- patterns.lua, "Bliss" --
   -- and is kept in emunah._persist so `emreload` does not forget it. Cleared on death and
   -- disconnect. No wear-off line is known (the reference system has none either): until one is captured,
   -- bliss reads as up for the rest of the login once seen.
   bliss = function()
      return emunah._persist ~= nil and emunah._persist.blissUp == true
   end,
}

--- Bliss seen going up (or already up). Raises the same event a Char.Defences add would,
--- so keep-up confirms it the ordinary way.
function M.setBliss(up)
   emunah._persist = emunah._persist or {}
   local was = emunah._persist.blissUp == true
   emunah._persist.blissUp = up and true or nil
   if up and not was then event.raise("defence.added", "bliss") end
   if was and not up then event.raise("defence.lost", "bliss") end
end

event.register("emunah.character.died", function() M.setBliss(false) end, "curing.deflist")

--- WHAT BLISS GRANTS, which DEFENCES does list. Bliss itself never appears there, but the
--- three defences it provides do (the user, 2026-09-28: "it provides toughness, resistance
--- and constitution"; their DEFENCES listing the same day, verbatim, with bliss up):
---   You are using your superior constitution to prevent nausea.
---   You are resisting magical damage.
---   Your skin is toughened.
--- So a DEFENCES listing settles bliss either way: all three up means bliss is up, and any
--- one missing means it is down and keep-up casts it. This is what stops `perform bliss`
--- after a reload or a restart, when the remembered state is stale or gone -- keep-up holds
--- until that listing is read (defkeepup.checkDefences) -- and it catches bliss wearing
--- off, whose own line has never been recorded.
M.BLISS_GRANTS = { "toughness", "resistance", "constitution" }

--- Settle bliss from a parsed DEFENCES listing (names, as DEF_LINES gives them).
function M.blissFromListing(names)
   local listed = {}
   for _, name in ipairs(names or {}) do listed[tostring(name):lower()] = true end
   for _, name in ipairs(M.BLISS_GRANTS) do
      if not listed[name] then
         M.setBliss(false)
         return false
      end
   end
   M.setBliss(true)
   return true
end

--- Is this defence up right now?
---
--- Ordinarily this is exactly `emunah.gmcp.defences.has(name)` -- Char.Defences is complete
--- for everything else in this file. M.SYNTHETIC is the named exception, checked first, for
--- the two defences GMCP says nothing about at all.
function M.isUp(name)
   name = M.canonical(name)
   local synthetic = M.SYNTHETIC[name]
   if synthetic then return synthetic() end
   local defences = emunah.gmcp.defences
   return defences ~= nil and defences.has(name)
end

--- Has a spiritual mace ever been seen this login? Persisted across `emreload` (this is
--- exactly what `emunah._persist` is for) and cleared only on a real disconnect -- an
--- `emreload` re-executing this file must not forget a mace already standing and pay to
--- conjure a second one. Set on sight, not only on our own SUMMON: a mace summoned before
--- keep-up was ever told to track it must not be summoned again either.
local function markMaceSeen(_, location, item)
   if location ~= "inv" then return end
   if not (item and item.search and item.search:find("spiritual mace", 1, true)) then return end
   emunah._persist = emunah._persist or {}
   emunah._persist.maceSummoned = true
   -- The recall landed, or it was picked up: "call for it" and "on the ground" are no
   -- longer the latest word.
   local place = emunah._persist.macePlace
   if place ~= "land" and place ~= "ground" then return end
   emunah._persist.macePlace = nil
   -- Picked up: the GET is answered, so the wield may go on this same prompt rather than
   -- after the GET's confirm wait (2.5s at 16:47:04.30-06.78; 12s with no prompt between,
   -- 16:39:33.99-45.98).
   local defkeepup = emunah.curing.defkeepup
   if defkeepup and defkeepup.clearSent then defkeepup.clearSent("trackmace") end
end
event.register("emunah.items.added",   markMaceSeen, "curing.deflist")
event.register("emunah.items.updated", markMaceSeen, "curing.deflist")

-- A full inventory list, once we can see, is allowed to retire a text flag. Not while
-- blind: that list is the one taken before the summon, and Char.Items.Add never arrives
-- to correct it (gmcp/items.lua).
event.register("emunah.items.list", function(_, key)
   if key ~= "inv" then return end
   local items = emunah.gmcp.items
   local persist = emunah._persist
   if not (items and persist) then return end
   if not items.sighted() then return end
   if items.first("spiritual mace", "inv") then return end
   if persist.macePlace == "hand" or persist.macePlace == "wielded" then
      persist.macePlace = nil
   end
end, "curing.deflist")

-- THE MACE GOING UP OR DOWN IS SAID, as a real defence's is. Char.Defences never mentions
-- it, so nothing else tells the panel or keep-up when an inventory change makes it wielded
-- or not. After a reload the inventory comes a second or two late; the mace, wielded all
-- along, stayed yellow in the defence panel until some unrelated defence event repainted
-- it, "after a minute or so" (the user, 2026-10-16).
local maceWasUp = nil
local function maceChanged(_, key)
   if key ~= nil and key ~= "inv" then return end
   local items = emunah.gmcp.items
   if not (items and items.inventoryListed) then return end
   -- Its id, so a mace dropped where another priest's lies is the one picked up.
   local held = items.first("spiritual mace", "inv")
   if held and held.id then
      emunah._persist = emunah._persist or {}
      emunah._persist.maceId = held.id
   end
   local up = M.SYNTHETIC.trackmace() and true or false
   if up == maceWasUp then return end
   local was = maceWasUp
   maceWasUp = up
   -- The first reading after a load only matters when it is up: down is what everything
   -- already assumes of a defence it has not heard about.
   if up or was ~= nil then event.raise(up and "defence.added" or "defence.lost", "trackmace") end
end
for _, name in ipairs({ "emunah.items.list", "emunah.items.added", "emunah.items.updated",
                        "emunah.items.removed" }) do
   event.register(name, maceChanged, "curing.deflist")
end

event.register("sysDisconnectionEvent", function()
   if emunah._persist then
      emunah._persist.maceSummoned = nil
      emunah._persist.macePlace = nil
      emunah._persist.maceId = nil
      emunah._persist.maceSummoning = nil
      emunah._persist.blissUp = nil
   end
end, "curing.deflist")

--- Where the mace is, from the game's own lines, when Char.Items cannot say.
---
--- "hand"    -- summon succeeded: "you hold a spiritual mace within your grasp."
--- "land"    -- "You have a mace in the land, which you should call for."
--- "wielded" -- "You start to wield a spiritual mace in your left hand."
--- nil       -- trust GMCP and maceSummoned alone.
local function rememberMace(place)
   emunah._persist = emunah._persist or {}
   emunah._persist.maceSummoned = true
   emunah._persist.macePlace = place
   emunah._persist.maceSummoning = nil
   -- The summons that provoked the line were the wrong verb, not evidence the defence
   -- cannot be raised. trackmace never appears in Char.Defences, so those attempts would
   -- otherwise retire it ("Raised trackmace 3 times...") with the mace still unwielded.
   local defkeepup = emunah.curing.defkeepup
   if defkeepup and defkeepup.resetBudget then defkeepup.resetBudget("trackmace") end
end

function M.noteMaceInHand()
   rememberMace("hand")
   if emunah.queue then emunah.queue.confirm("balance") end
end

function M.noteMaceInLand()
   rememberMace("land")
   if emunah.queue then emunah.queue.confirm("balance") end
end

--- Seconds a summon may take from its start line before it counts as not happening, and
--- keep-up may summon again. The reference system's waitingformace `customwait`; play took 2.48s (the start
--- line at 11:36:47.39, the mace at 11:36:49.87, 2026-10-04).
M.MACE_SUMMON_WAIT = 3.0

--- A summon has started (the reference system's "Mace start" line), or the game says one already has.
--- Keep-up's confirm wait runs from the SEND, and is shorter than the summon: at 11:36:49.22
--- it lapsed and `summon mace` went again, answered "You are already summoning your mace."
function M.noteMaceSummoning()
   emunah._persist = emunah._persist or {}
   emunah._persist.maceSummoning = util.now()
end

--- The reference system's "Mace interrupted": nothing is coming, so summoning may go again.
function M.noteMaceSummonFoiled()
   if emunah._persist then emunah._persist.maceSummoning = nil end
end

--- "You drop a spiritual mace in your terror." Fear from angel panic drops what is
--- wielded (2026-10-23 16:12:47.42). The mace is on the ground now, not wielded: the
--- remembered place made keep-up send WIELD MACE at nothing until it gave up ("Raised
--- trackmace 3 times and it still is not up -- stopping").
function M.noteMaceDropped()
   -- Not rememberMace(): its budget reset clears keep-up's record of the GET already sent
   -- on the GMCP that came first, and a second GET followed into "I see no "428794" to
   -- take." (16:47:04.30).
   emunah._persist = emunah._persist or {}
   emunah._persist.maceSummoned = true
   emunah._persist.macePlace = "ground"
end

--- Our mace lying in the room, or nil: by the id it had in our pack, else by name.
function M.maceOnGround()
   local items = emunah.gmcp.items
   if not items then return nil end
   local id = emunah._persist and emunah._persist.maceId
   if id then
      for _, item in ipairs(items.at("room")) do
         if item.id == id then return item end
      end
      return nil
   end
   return items.first("spiritual mace", "room")
end

function M.noteMaceWielded()
   rememberMace("wielded")
   if emunah.queue then emunah.queue.confirm("free") end
   maceWasUp = true
   event.raise("defence.added", "trackmace")
end

--- Which command raises `trackmace` depends on which of three states the mace is actually
--- in, and that can only be read live -- no other entry in this file needs three different
--- commands for one defence.
---
---   in inventory, not wielded  -> WIELD MACE. Confirmed live: no cost line at all -- the
---      command spends neither balance nor equilibrium, but needs both, and needs the
---      wielding arm not broken (confirmed by the user directly). Gated on
---      have.bothArmsBroken() -- the one verified predicate for "needs a working hand" (see
---      curing/engine.lua's queueTree()) -- rather than a single-arm check nothing here has
---      confirmed; that is the conservative direction; see this file's own note on
---      unverified M.IMPORTED costs for why.
---   summoned before, not in inventory -> CALL MACE. Confirmed live 07:49:40.91-07:49:44.93:
---      "Equilibrium used: 4.00s.", and the GMCP payload is a Char.Items.UPDATE carrying the
---      SAME item id (616546) seen wielded earlier -- it recalls the existing mace, it does
---      not create a new one. The game also says this outright when SUMMON is the wrong
---      verb: "You have a mace in the land, which you should call for." (12:49:20.11).
---      While blind without mindseye that line is the only signal -- Char.Items.Add does
---      not fire, so a summon that already worked never set maceSummoned, and the next
---      tick summoned again.
---   never summoned this login -> SUMMON MACE. Costs 2.90s of balance (AB SPIRITUALITY MACE),
---      and only when it makes one -- free with a mace held or in the land (the user). The
---      first capture of it was chained (`summon
---      mace;;wield mace`), which is also why that chain is not what this sends: the wield
---      half fired before the mace existed ("What do you wish to wield?" at 07:39:16.19,
---      preceding the conjuring message by 0.01s) and had to be typed again by hand. Sending
---      one command at a time and re-resolving next tick, the way every other keep-up
---      defence already works, is what avoids that -- not a chain.
--- Always answers "what raises it", even while it is currently up -- the same as every
--- other entry in this file (`deflist.resolve("shield")` names "touch shield" whether or
--- not shield is up right now). Whether to actually SEND it is a separate question, already
--- answered by M.isUp() at every call site that matters (M.missing(), the queue's own
--- `valid` closure) -- conflating the two here made the keep-up grid show trackmace as "no
--- command known" the moment it was wielded, which is backwards: WIELD MACE is exactly what
--- would go out if it dropped, wielded or not, because unwielding does not remove the item
--- from "inv" -- only its attrib changes.
--- `unconfirmable` is deliberately NOT set here, unlike `bliss`. That flag means "Char.
--- Defences never lists this, so `up` can never read true either" -- true for bliss, false
--- for trackmace, whose `up` comes from M.isUp() reading live Char.Items and genuinely does
--- turn true once wielded. Setting it anyway would buy defup mode a "done (lapsed)" label
--- at the cost of the keep-up grid's tooltip claiming a wielded mace "never shows as up",
--- which is worse: a defup mace that lapses shows MISSING instead, same as any other
--- untracked-satisfaction defence -- cosmetic, and not what was asked for.
local function resolveTrackmace()
   local items = emunah.gmcp.items
   local persist = emunah._persist
   local place = persist and persist.macePlace
   local mace = items and items.first("spiritual mace", "inv")
   -- A sighted inventory entry is live. An unsighted one can be the snapshot from before
   -- the mace left the pack, which is exactly when the server says to call for it.
   local liveMace = mace and (not items or items.sighted())

   if place == "land" and not liveMace then
      return "equilibrium", "call mace", nil, nil, nil
   end

   -- ON THE GROUND: picked up, and wielded on the next pass. GET spends neither balance
   -- ("You scoop up a kite shield." with no cost line, 16:18:52) but needs both. Unseen
   -- (blind), the drop line is all there is, and GET MACE names it.
   if not liveMace then
      local dropped = items and items.sighted() and M.maceOnGround()
      if dropped or place == "ground" then
         local what = dropped and dropped.id and tostring(dropped.id) or "mace"
         return "free", "get " .. what, { bal = true, eq = true }, nil, nil
      end
   end

   if mace or place == "hand" or place == "wielded" then
      if have.bothArmsBroken and have.bothArmsBroken() then
         return nil, nil, nil, nil, nil
      end
      return "free", "wield mace", { bal = true, eq = true }, nil, nil
   end

   if persist and persist.maceSummoned then
      return "equilibrium", "call mace", nil, nil, nil
   end

   return "balance", "summon mace", nil, nil, nil
end

--- name -> function() returning the same five values as M.resolve(). For defences where no
--- single fixed command answers "how do I raise this" -- see resolveTrackmace() above.
M.DYNAMIC = {
   trackmace = resolveTrackmace,
}

--- What each equilibrium raise costs, in seconds: keep-up raises the cheapest first
--- (defkeepup.order). Every figure is the game's own "Equilibrium used:" line at the
--- 2026-10-18 08:24 login, except heresy (its ability text, 4.00s).
M.COSTS = {
   selfishness = 0.5, cloak = 1.0, trackangel = 2.0, mindseye = 3.0, hypersight = 3.0,
   inspiration = 3.5, heresy = 4.0, bliss = 6.5,
}

--- An equilibrium raise whose cost has not been seen: the middle of the known ones.
M.COST_DEFAULT = 3.0

--- Seconds of equilibrium this defence costs to raise. 0 for one that costs none.
function M.cost(name)
   name = M.canonical(name)
   if M.COSTS[name] then return M.COSTS[name] end
   local vector = M.resolve(name)
   if vector == "equilibrium" then return M.COST_DEFAULT end
   return 0
end

--- Defence herbs and elixirs that take no balance: any number go on one prompt, and none
--- holds back a cure. Keep-up sends them without a queue slot (defkeepup.costless).
---
--- The 2026-10-18 08:24 login: echinacea, kola and skullcap eaten and four defence elixirs
--- drunk, and not one "You may eat another plant or mineral." or "You may drink another
--- affliction-healing elixir." after any of them. At 08:35:24 `eat kola|eat echinacea`
--- went out as one line and both were eaten; at 08:37:18 `drink frost|drink speed` the
--- same, both drunk. Each was waiting on its vector's fallback timer (herb 3.5s,
--- purgative 6.0s), so the elixirs went out six seconds apart.
---
--- Only these. Hawthorn's deafness is followed by the herb balance line (defkeepup's
--- raise-pending note), and nothing has been seen for myrrh or the rest.
M.COSTLESS = {
   kola = true, thirdeye = true, deathsight = true,
   speed = true, poisonresist = true, levitating = true, temperance = true,
}

--- Defences that are raisable but must not be raised RIGHT NOW: name -> function returning
--- the reason, or nil. Keep-up holds them quietly, without spending an attempt, and asks
--- again at the moment of sending (defkeepup's queue `valid`), because each of these can
--- change while the raise waits for its slot.
M.HOLDS = {
   -- WHILE YOU ATTACK, NOT AT ALL. Your own blow drops it -- "Your aura of weapons rebounding
   -- disappears." comes before every smite line -- and the smoke takes 8.5s to land (smoked
   -- 14:35:29.74, aura 38.24; 14:37:11.41, aura 19.97; 2026-10-23). At a smite every 2.3s it
   -- never lands, and each try spends a skullcap puff and the smoke balance the curing's own
   -- smokes need. Raised again in the defence mode, and once PvP stops.
   rebounding = function()
      local pvp = emunah.pvp
      if pvp and pvp.enabled and pvp.mode and pvp.mode() ~= "defence" then
         return "your own blows drop it while you attack"
      end
      return nil
   end,
   trackmace = function()
      -- NOT KNOWING WHAT WE CARRY IS NOT CARRYING NOTHING, the rule keep-up already holds item
      -- defences to. A reload starts with an empty inventory until Char.Items.Inv answers,
      -- and the mace, wielded, was read as missing: `wield mace` went out twice into "You
      -- are already wielding that." (06:31:10.55 and 06:31:11.27, 2026-10-16), before the
      -- list arrived. Held until it has.
      local items = emunah.gmcp.items
      if items and not items.inventoryListed then return "the inventory is not listed yet" end
      local at = emunah._persist and emunah._persist.maceSummoning
      if at and util.now() - at < M.MACE_SUMMON_WAIT then return "the mace is being summoned" end
      return nil
   end,
   insomnia = function()
      -- The user, 2026-10-04: "ensure insomnia is not raised while i sleep". From the moment
      -- SLEEP is typed (RELAX INSOMNIA goes first) until the character wakes.
      local detect = emunah.curing.detect
      if detect and detect.sleepWanted() then return "you are going to sleep" end
      -- The reference system: `not affs.hypersomnia` -- "Your hypersomnia prevents your insomnia."
      if emunah.act.afflicted("hypersomnia") then return "hypersomnia prevents it" end
      -- The reference system: can_usemana() -- the skill costs mana, and it stops above `manause`. The same
      -- floor FOCUS uses (have.vectorBlocked).
      local vitals = emunah.gmcp.vitals
      local floor = tonumber(emunah.config.get("curing.focusMinMana", have.FOCUS_MIN_MANA))
         or have.FOCUS_MIN_MANA
      if vitals and vitals.maxmp > 0 and (vitals.percent.mp or 100) <= floor then
         return "mana below " .. floor .. "%"
      end
      return nil
   end,
}

--- Why this defence is held right now, or nil. See M.HOLDS.
function M.held(name)
   local hold = M.HOLDS[M.canonical(name)]
   return hold and hold() or nil
end

--- Resolve how to raise a defence.
---
--- The third return is what the COMMAND requires beyond its vector -- balance, equilibrium,
--- being upright. A vector says which balance the action spends; it does not say what has
--- to be true before the game will accept it, and for some abilities those differ.
---
--- The fourth return is the item the command actually consumes, when there is one -- so a
--- caller can check possession before sending. Resolving it here rather than leaving callers
--- to re-derive it matters because it is not always the same word as the command: minerals
--- mode substitutes `alt` for `item`, and `curelist.command()` is what already knows that.
---
--- The fifth return marks a defence whose confirmation is never coming -- `bliss`, which
--- produces no Char.Defences line at all. A caller doing defup's "satisfied on confirmation"
--- bookkeeping needs to know to satisfy on SEND instead, or it waits forever.
--- @return string|nil vector, string|nil command, table|nil needs, string|nil item,
---   boolean|nil unconfirmable
function M.resolve(name)
   -- A command supplied through `emunah defs add <name> <command>` wins: it is the only
   -- source that came from someone looking at the real defence name. No item to check --
   -- a hand-paired command's possession requirement is whatever the user made it.
   local custom = (emunah.config.get("defences.commands", {}) or {})[name]
   if custom and custom.command then
      return custom.vector or "balance", custom.command, custom.needs, nil, nil
   end

   -- Item-based defences share the cure machinery.
   local cure = afflist.defenceCures[name]
   if cure then
      local command, item = emunah.curing.curelist.command(cure)
      return cure.vector, command, nil, item, nil
   end

   -- Resolved live rather than from a static entry -- see resolveTrackmace().
   local dynamic = M.DYNAMIC[name]
   if dynamic then return dynamic() end

   -- Verified table first, unverified only as a fallback. Where both hold a defence, the
   -- one that has been watched working is the answer -- see the note on M.IMPORTED.
   local entry = M.commands[name] or M.IMPORTED[name]
   if not entry then return nil, nil, nil, nil, nil end
   if entry.skill and not have.skill(entry.skill) then return nil, nil, nil, nil, nil end
   return entry.vector, entry.command, entry.needs, entry.item, entry.unconfirmable
end

--- Seconds after its send that a raise with no item to wait on can still land, or nil.
function M.lands(name)
   name = M.canonical(name)
   local entry = M.commands[name] or M.IMPORTED[name]
   return entry and entry.lands or nil
end

--- The defence that must already be up before this one may be raised, or nil.
function M.requires(name)
   name = M.canonical(name)
   local entry = M.commands[name] or M.IMPORTED[name]
   return entry and entry.requires or nil
end

--- How much a defence's command is trusted: "yours" if you paired it, "emunah" if it has
--- been watched working, "imported" if it has not.
function M.source(name)
   name = tostring(name or ""):lower()
   if (emunah.config.get("defences.commands", {}) or {})[name] then return "yours" end
   if M.commands[name] then return "emunah" end
   if afflist.defenceCures[name] then return "emunah" end
   if M.DYNAMIC[name] then return "emunah" end
   if M.IMPORTED[name] then return "imported" end
   return nil
end

--- The defences panel's heading for an item defence, by the vector it goes out on. A herb
--- defence taken as its mineral is filed as one (see M.raisedBy()).
local ITEM_CATEGORY = {
   herb = "Herbs", moss = "Herbs", salve = "Salves", smoke = "Pipes",
   elixir = "Elixirs", purgative = "Elixirs",
}

--- Defences that are another defence's effect rather than raised in their own right: the
--- three bliss grants (M.BLISS_GRANTS).
local GRANTED_BY = {}
for _, granted in ipairs(M.BLISS_GRANTS) do GRANTED_BY[granted] = "bliss" end

--- The skillset an ability belongs to, as Char.Skills names it, or nil.
local function skillGroup(word)
   local skills = emunah.gmcp.skills
   local group = skills and skills.groupOf(word)
   if not group then return nil end
   local entry = skills.groups[group]
   return entry and entry.name or util.capitalise(group)
end

--- The skillset behind a command: its declared skill, else the first of its words, from the
--- LAST, that the skill index knows. From the last because the verb comes first and is often
--- a skill of its own: `touch cloak` is the cloak tattoo, and `touch` is a Spirituality
--- ability (the 2026-10-15 ability dump) that would file every tattoo under it.
local function commandGroup(command, skill)
   local group = skill and skillGroup(skill)
   if group then return group end
   local words = {}
   for word in tostring(command):gmatch("%S+") do words[#words + 1] = word:lower() end
   for index = #words, 1, -1 do
      group = skillGroup(words[index])
      if group then return group end
   end
   return nil
end

--- What the defences panel files a defence under, and what raises it: the item for an item
--- defence, the command for an ability.
---
--- Read from the same tables M.resolve() reads, in the same order, but not gated on the
--- skill: a defence that is UP was raised by something, whether or not the skill index has
--- finished loading. An ability's heading is its skillset from Char.Skills, so it is the
--- server's word ("Devotion", "Tattoos") and needs no list of our own; until the index
--- arrives, or for a command it does not know, it is "Abilities".
---
--- For a defence none of the tables raise, the name itself is tried against the skill index,
--- with a "(weapon)" or "tattoo" suffix taken off: Char.Defences reports `parrying (mace)`,
--- `boartattoo` and `mosstattoo` (docs/game/defences.md), and `parrying`, `boar` and `moss`
--- are abilities in the dump. Nothing found is "Other", with no source: a guess there would
--- be worse than a blank.
--- @return string category, string|nil source
function M.raisedBy(name)
   name = M.canonical(name)

   local granter = GRANTED_BY[name]
   if granter then return (M.raisedBy(granter)), granter end

   local custom = (emunah.config.get("defences.commands", {}) or {})[name]
   if custom and custom.command then
      return commandGroup(custom.command) or "Abilities", custom.command
   end

   local cure = afflist.defenceCures[name]
   if cure then
      local _, item = emunah.curing.curelist.command(cure)
      item = item or cure.item
      local category = ITEM_CATEGORY[cure.vector] or "Other"
      if category == "Herbs" and item == cure.alt then category = "Minerals" end
      return category, item
   end

   local command, vector, skill, item
   local dynamic = M.DYNAMIC[name]
   if dynamic then
      vector, command = dynamic()
   else
      local entry = M.commands[name] or M.IMPORTED[name]
      if entry then
         vector, command, skill, item = entry.vector, entry.command, entry.skill, entry.item
      end
   end

   if command then
      local category = ITEM_CATEGORY[vector]
      if category then
         -- `drink speed`, `eat skullcap`: the item is the command's object.
         return category, item or command:match("^%S+%s+(.+)$") or command
      end
      return commandGroup(command, skill) or "Abilities", command
   end

   local bare = name:gsub("%s*%b()$", ""):gsub("tattoo$", "")
   local group = skillGroup(bare)
   if group then return group, nil end
   return "Other", nil
end

--- Every defence we know how to raise, sorted.
---
--- Three sources, and all three have to be here or the toggle grid becomes a list of the
--- things one particular table happens to hold: the plain commands in M.commands, the
--- item-based ones that go through the cure machinery, and anything the user paired up
--- themselves with `emunah defs add <name> <command>`.
--- @param extra table|nil further names to include -- the caller's wanted list, which may
---   name a defence we hold no command for and which must still appear
--- @return table array of names
function M.known(extra)
   local seen = {}
   for name in pairs(M.commands) do seen[name] = true end
   for name in pairs(M.IMPORTED) do seen[name] = true end
   for name in pairs(afflist.defenceCures) do seen[name] = true end
   for name in pairs(M.DYNAMIC) do seen[name] = true end
   for name in pairs(emunah.config.get("defences.commands", {}) or {}) do
      seen[name] = true
   end

   -- Anything already asked for belongs on the grid whether or not we can resolve it --
   -- otherwise a defence the user selected would silently not appear in the very view they
   -- would use to find out what happened to it. Passed in rather than read: this module
   -- deliberately knows nothing about what is currently switched on.
   for _, name in ipairs(extra or {}) do seen[name] = true end

   local out = {}
   for name in pairs(seen) do out[#out + 1] = name end
   table.sort(out)
   return out
end

-- ---------------------------------------------------------------------------
-- DEF output, line by line
-- ---------------------------------------------------------------------------
--
-- DEFENCES prints one line per defence, and none of them names it. This is how a line is
-- turned back into the server's name, so a DEFENCES listing can be read (see
-- gmcp/defences.lua's applyDefListing and patterns.lua's "DEFENCES" section).
-- Generated from the reference system's defs_data (its defs module): each defence's line in DEF output,
-- mapped to the server's name through the reference system's gamename table. Invisible defences are omitted.
M.DEF_LINES = {
   ["A basilisk spirit co-habits your body."] = "basilisk",
   ["A bear spirit co-habits your body."] = "bear",
   ["A cheetah spirit co-habits your body."] = "cheetah",
   ["A condor spirit co-habits your body."] = "condor",
   ["A curseward has been established about your person."] = "curseward",
   ["A gopher spirit co-habits your body."] = "gopher",
   ["A gorilla spirit co-habits your body."] = "gorilla",
   ["A hydra spirit co-habits your body."] = "hydra",
   ["A hyena spirit co-habits your body."] = "hyena",
   ["A jackdaw spirit co-habits your body."] = "jackdaw",
   ["A jaguar spirit co-habits your body."] = "jaguar",
   ["A nightingale spirit co-habits your body."] = "nightingale",
   ["A sloth spirit co-habits your body."] = "sloth",
   ["A songbird is perched upon your shoulder."] = "songbird",
   ["A squirrel spirit co-habits your body."] = "squirrel",
   ["A turtle spirit co-habits your body."] = "turtle",
   ["A wildcat spirit co-habits your body."] = "wildcat",
   ["A wolf spirit co-habits your body."] = "wolf",
   ["A wolverine spirit co-habits your body."] = "wolverine",
   ["A wyvern spirit co-habits your body."] = "wyvern",
   ["An aura of bedevilment has been established about your person."] = "bedevilaura",
   ["An eagle spirit co-habits your body."] = "eagle",
   ["An elephant spirit co-habits your body."] = "elephant",
   ["An icewyrm spirit co-habits your body."] = "icewyrm",
   ["An owl spirit co-habits your body."] = "owl",
   ["As an insubstantial astral light, you are immune from many attacks."] = "astralform",
   ["Cobra-like, you are weaving back and forth to dodge blows."] = "weaving",
   ["Concealed by a shifting veil of shadow."] = "shadowveil",
   ["Diamond-hard skin protects you."] = "diamondskin",
   ["Fury rages in your eyes."] = "fury",
   ["Magically supple granite coats your body."] = "stoneskin",
   ["Phased slightly out of reality, you are effectively untouchable."] = "phased",
   ["Serpentine scales protect your body."] = "scales",
   ["Surrounded by the power of Arctar."] = "arctar",
   ["The Drunken Sailor stance protects you."] = "drunkensailor",
   ["The Heart's Fury stance protects you."] = "heartsfury",
   ["The devilmark is upon your breast."] = "devilmark",
   ["The swiftcurse is upon you."] = "swiftcurse",
   ["Travelling the world more quickly due to time dilation."] = "blur",
   ["You are able to detect wormholes due to possessing the second sight."] = "secondsight",
   ["You are able to navigate forests more easily."] = "fleetness",
   ["You are acknowledged by Jy'Barrak Golgotha, Emperor of Chaos."] = "golgothagrace",
   ["You are alert to incoming projectiles."] = "projectiles",
   ["You are alert to those who would pursue you."] = "elusiveness",
   ["You are annihilating knowledge from the minds around you."] = "psivanish",
   ["You are attempting to deflect arrows toward less vital areas."] = "deflect",
   ["You are attempting to pluck arrows from the air."] = "arrowcatching",
   ["You are attuned to local telepathic interference."] = "telesense",
   ["You are aware of all nearby ship movements."] = "shipwarning",
   ["You are aware of movement in the skies."] = "skywatch",
   ["You are aware of movement on the ground."] = "groundwatch",
   ["You are balancing on the balls of your feet."] = "balancing",
   ["You are bathed in an aura of radiant sunlight."] = "vigour",
   ["You are bathed in the glorious protection of decaying flesh."] = "putrefaction",
   ["You are blind."] = "blindness",
   ["You are bolstered by the energy of mercury."] = "mercury",
   ["You are bolstered by the energy of sulphur."] = "sulphur",
   ["You are bonded to your spirit totem."] = "bonding",
   ["You are bouncing around acrobatically."] = "acrobatics",
   ["You are circulating electricity throughout your body."] = "circulate",
   ["You are cloaking your attempts at establishing a mindlock."] = "mindcloak",
   ["You are coated in an insulating unguent."] = "caloric",
   ["You are concentrating on clotting your wounds."] = "firstaid",
   ["You are concentrating on maintaining control over your faculties."] = "antiforce",
   ["You are concentrating on maintaining distance from the dreamworld."] = "metawake",
   ["You are concentrating on mastery of bladecraft."] = "blademastery",
   ["You are deaf."] = "deafness",
   ["You are deep within the Shin trance."] = "shintrance",
   ["You are diverting excess Shin energy into regeneration."] = "bind",
   ["You are emanating an aura of death."] = "deathaura",
   ["You are enacting the Gaital form."] = "gaital",
   ["You are enacting the Tykonos form."] = "tykonos",
   ["You are enacting the Willows in Rain Storm form."] = "rain",
   ["You are enacting the Willows shaken by the Wind form."] = "willow",
   ["You are enacting the the Live Oak form."] = "oak",
   ["You are enacting the the Unrelenting Storm form."] = "maelstrom",
   ["You are enchanted against cold damage."] = "coldresist",
   ["You are enchanted against electric damage."] = "electricresist",
   ["You are enchanted against fire damage."] = "fireresist",
   ["You are enchanted against magic damage."] = "magicresist",
   ["You are enhancing your durability against denizens."] = "durability",
   ["You are enhancing your ocular prowess."] = "truestare",
   ["You are enhancing your precision through the power of Terminus."] = "precision",
   ["You are extremely heavy and difficult to move."] = "density",
   ["You are feeling extremely energetic."] = "kola",
   ["You are feeling quite selfish."] = "selfishness",
   ["You are flailing a wielded quarterstaff."] = "flail",
   ["You are flying evasively."] = "evasion",
   ["You are focussing your vast intellect on comprehending language."] = "psicomprehend",
   ["You are hunting heretics."] = "heresy",
   ["You are in the Arash stance."] = "arash",
   ["You are in the Bear stance."] = "bear",
   ["You are in the Cat stance."] = "cat",
   ["You are in the Doya stance."] = "doya",
   ["You are in the Dragon stance."] = "dragon",
   ["You are in the Eagle stance."] = "eagle",
   ["You are in the Horse stance."] = "horse",
   ["You are in the Mir stance."] = "mir",
   ["You are in the Rat stance."] = "rat",
   ["You are in the Sanya stance."] = "sanya",
   ["You are in the Scorpion stance."] = "scorpion",
   ["You are in the Thyr stance."] = "thyr",
   ["You are lipreading to overcome deafness."] = "lipreading",
   ["You are listening in on another conversation."] = "listen",
   ["You are looking a little shady today."] = "slippery",
   ["You are maintaining consciousness at all times."] = "consciousness",
   ["You are masking your egress."] = "disperse",
   ["You are of transcendent mind."] = "psitranscend",
   ["You are paced for bursts of exertion."] = "pacing",
   ["You are performing retaliatory strikes against your attackers."] = "retaliation",
   ["You are poised to glide across the surface of water."] = "waterwalking",
   ["You are preparing to impale onrushing attackers."] = "impaling",
   ["You are protected by a layer of flexible armour."] = "secondskin",
   ["You are protected by a reflective barrier."] = "tin",
   ["You are protected by the bell tattoo."] = "belltattoo",
   ["You are protected by the power of a Frost Spiritshield."] = "frostblessing",
   ["You are protected by the power of a Thermal Spiritshield."] = "thermalblessing",
   ["You are protected by the power of an Earth Spiritshield."] = "earthblessing",
   ["You are protected from damage by a tune of safety."] = "tune",
   ["You are protected from hand-held weapons with an aura of rebounding."] = "rebounding",
   ["You are protected from the creation of physical images of yourself."] = "lay",
   ["You are protected from the fangs of serpents."] = "fangbarrier",
   ["You are pushing your mind beyond its limits."] = "psibreakthrough",
   ["You are regenerating endurance at an increased rate."] = "enduranceblessing",
   ["You are regenerating lost health through the power of Kaido."] = "regeneration",
   ["You are regenerating willpower at an increased rate."] = "willpowerblessing",
   ["You are resisting magical damage."] = "resistance",
   ["You are seeing the world around you with greater clarity of vision."] = "clarity",
   ["You are shimmering with a ghostly light."] = "ghost",
   ["You are soaring high above the ground."] = "flying",
   ["You are standing firm against attempts to move you."] = "standingfirm",
   ["You are standing within a prismatic barrier."] = "lyre",
   ["You are surrounded by a cloak of protection."] = "cloak",
   ["You are surrounded by a healing mist."] = "panacea",
   ["You are surrounded by a nearly invisible magical shield."] = "shield",
   ["You are surrounded by a non-conducting chargeshield."] = "chargeshield",
   ["You are surrounded by a pocket of air."] = "airpocket",
   ["You are surrounded by draconic armour."] = "dragonarmour",
   ["You are surrounded by one reflection of yourself."] = "reflections",
   ["You are tempered against fire damage."] = "frost",
   ["You are temporarily numbed to damage."] = "numb",
   ["You are trying to absorb blows to your body."] = "bodyblock",
   ["You are using Tekura to evade incoming attacks."] = "evadeblock",
   ["You are using your hypersense."] = "hypersense",
   ["You are using your superior constitution to prevent nausea."] = "constitution",
   ["You are using your telesense."] = "mindtelesense",
   ["You are utilising hypersight."] = "hypersight",
   ["You are utilising the trance to store Kai energy."] = "kaitrance",
   ["You are vigilantly watching for potential danger."] = "vigilance",
   ["You are walking on a small cushion of air."] = "levitating",
   ["You are walking with the grace of the stars."] = "starburst",
   ["You are watching the skies for danger."] = "dodging",
   ["You are watching the trees or rigging above for signs of movement."] = "treewatch",
   ["You have a great affinity with your spirit form."] = "affinity",
   ["You have a will of iron."] = "ironwill",
   ["You have accepted a blessing for aid in times of need."] = "preaching",
   ["You have augmented your own body for enhanced defence."] = "bodyaugment",
   ["You have boosted the power of your Kai Trance."] = "kaiboost",
   ["You have cast a mindnet over the local area."] = "mindnet",
   ["You have distorted your own aura."] = "distortedaura",
   ["You have divined the future."] = "extispicy",
   ["You have enhanced your vision to be able to see traces of lifeforce."] = "lifevision",
   ["You have insomnia, and cannot easily go to sleep."] = "insomnia",
   ["You have softened the focus of your eyes."] = "softfocusing",
   ["You have summoned your draconic breath weapon."] = "dragonbreath",
   ["You have sworn vengeance upon those who would slay you."] = "vengeance",
   ["You have taken the form of the Viridian."] = "viridian",
   ["You have tentacles flailing from your body."] = "tentacles",
   ["You have used great guile to conceal yourself."] = "hiding",
   ["You is suffused with indomitable might."] = "indomitability",
   ["You possess the sight of the third eye."] = "thirdeye",
   ["You will call upon your fortitude in need."] = "vitality",
   ["You will try to pinch block a weakened foe."] = "pinchblock",
   ["Your actions are cloaked in secrecy."] = "shroud",
   ["Your being is protected by the soulcage."] = "soulcage",
   ["Your blood is being heated by the sun."] = "basking",
   ["Your blows will rupture veins and arteries with every strike."] = "rupturesight",
   ["Your body is weathering the storm of life a little better."] = "weathering",
   ["Your fists are covered with dense granite."] = "stonefist",
   ["Your hands are gripping your wielded items tightly."] = "gripping",
   ["Your health is enhanced by the beauties of an Aria."] = "aria",
   ["Your limbs are suffused with divinely-inspired strength."] = "inspiration",
   ["Your mind has been attuned to the realm of Death."] = "deathsight",
   ["Your mind is focussed to perfection."] = "mentalclarity",
   ["Your mind is racing with enhanced speed."] = "scholasticism",
   ["Your mind is split, allowing constant meditation."] = "splitmind",
   ["Your movements are incredibly stealthy."] = "stealth",
   ["Your movements are trailed by profusions of wild growth."] = "wildgrowth",
   ["Your person is surrounded by black demonic armour."] = "armour",
   ["Your regeneration is boosted."] = "boostedregeneration",
   ["Your resistance to damage by poison has been increased."] = "poisonresist",
   ["Your sense of time is heightened, and your reactions are speeded."] = "speed",
   ["Your senses are attuned to nearby movement."] = "alertness",
   ["Your senses are magically heightened."] = "mindseye",
   ["Your skin is hard and tough like the bark of an oak tree."] = "barkskin",
   ["Your skin is toughened."] = "toughness",
   ["Your strikes are guided by unnatural luck."] = "guidedstrike",
   ["Your vision is heightened to see in the dark."] = "nightsight",
   ["Your water weird allows you to walk on water."] = "waterweird",
}

return M

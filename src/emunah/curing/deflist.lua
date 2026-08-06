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
   insomnia     = { vector = "herb",        command = "eat cohosh" },
   deathsight   = { vector = "herb",        command = "eat skullcap" },
   thirdeye     = { vector = "herb",        command = "eat echinacea" },
   rebounding   = { vector = "smoke",       command = "smoke skullcap" },
   -- NAMES UNVERIFIED. This is the last elixir left unchecked; whether Char.Defences calls
   -- the defence by the same word has not been confirmed, and the rest of this family shows
   -- it often does not. `emunah defs names` lists what the game actually reports, and the
   -- attempt budget names the mismatch when there is one.
   speed        = { vector = "elixir",      command = "drink speed" },
   -- The DEFENCE is `poisonresist`; the ELIXIR is venom. Confirmed by the payload:
   --   Char.Defences.Add { name = "poisonresist",
   --                       desc = "Granted by the venom elixir or toxin tonic, this allows
   --                               you some resistance to poison damage." }
   -- Keyed on `poisonresist` because that is the only name Char.Defences ever uses, and
   -- this table is matched against it. Filed here rather than under `venom` after keep-up
   -- spent three elixirs raising a defence that had been up since the first one -- see
   -- M.ALIASES for how the elixir's name still resolves.
   poisonresist = { vector = "elixir",      command = "drink venom" },
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
   levitating   = { vector = "elixir",      command = "drink levitation" },
   -- The DEFENCE is `temperance`; the ELIXIR is frost. Same family of bug, confirmed live
   -- 18:39:57.43-18:39:57.62: a sip came back "The elixir flows down your throat without
   -- effect", and the attempt budget's own diagnostic named the mismatch outright --
   --   [emunah] Not raising frost again: the sip had no effect, so it is already up under a
   --            different Char.Defences name
   --   [emunah]   Char.Defences is reporting these, which nothing here claims: ...,
   --              temperance, ...
   -- Keyed on `temperance` for the same reason as `levitating`; see M.ALIASES for how the
   -- elixir's name still resolves.
   temperance   = { vector = "elixir",      command = "drink frost" },
   -- Equilibrium-cost defences. Skills, not items, so they are gated on have.skill().
   cloak        = { vector = "equilibrium", command = "cloak",        skill = "cloak" },
   shield       = { vector = "balance",     command = "touch shield", skill = "shield" },
   nightsight   = { vector = "equilibrium", command = "nightsight",   skill = "nightsight" },
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
   fangbarrier  = { vector = "balance",     command = "fangbarrier",  skill = "fangbarrier" },

   -- Priest (Devotion). `perform inspiration`, equilibrium 3.50s -- both verified, see
   -- mechanics.md. Reported by GMCP as:
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
   -- `unconfirmable = true` says the confirmation is never coming: defup marks it satisfied
   -- the moment the command is SENT (defkeepup.lua's onSent), not when Char.Defences agrees,
   -- because it never will. Keepup mode is still reachable through the ordinary toggle cycle
   -- but is a poor fit for it -- `satisfied` does not gate keepup's re-raise, so it would
   -- retry every tick until the normal 3-attempt budget stops it, spending up to 19.5s of
   -- equilibrium for a buff that was already up. Same needs as inspiration; see the note
   -- there on `perform` commands wanting balance and equilibrium both.
   bliss        = { vector = "equilibrium", command = "perform bliss", unconfirmable = true,
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
--- Both map to themselves now: Char.Defences and Char.Afflictions use the same word for
--- each state, confirmed live for both (see M.commands.blindness / .deafness).
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
--- already lowercased itself when it stored it. M.DELIBERATE has three entries, so the
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
   vigilance      = { vector = "free", command = "vigilance on" },

   -- Everyone. Costing a balance of some kind -- see BALANCEFUL below.
   alertness      = { vector = "balance", command = "alertness on" },
   clinging       = { vector = "balance", command = "cling" },
   curseward      = { vector = "balance", command = "curseward" },
   hypersight     = { vector = "balance", command = "hypersight on" },

   -- Priest.
   heresy         = { vector = "balance", command = "hunt heresy",
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
for _, entry in pairs(M.IMPORTED) do
   entry.source = "imported"
   entry.needs  = entry.vector == "balance"
      and { bal = true, eq = true, standing = true }
      or  { standing = true }
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
      return detect ~= nil and detect.angel == true
   end,
   -- Nothing to trigger on -- the truth is already sitting in Char.Items. Read live rather
   -- than cached, so a mace stripped in combat (or re-wielded) is seen the same tick.
   trackmace = function()
      local items = emunah.gmcp.items
      if not items then return false end
      local mace = items.first("spiritual mace", "inv")
      if not mace then return false end
      local attrib = items.attrib(mace)
      return attrib.wielded_left or attrib.wielded_right
   end,
}

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
end
event.register("emunah.items.added",   markMaceSeen, "curing.deflist")
event.register("emunah.items.updated", markMaceSeen, "curing.deflist")

event.register("sysDisconnectionEvent", function()
   if emunah._persist then emunah._persist.maceSummoned = nil end
end, "curing.deflist")

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
---      not create a new one.
---   never summoned this login -> SUMMON MACE. Costs 2.9s of balance, confirmed by the user
---      directly rather than GMCP -- the only capture taken was chained (`summon
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
   if items then
      local mace = items.first("spiritual mace", "inv")
      if mace then
         if have.bothArmsBroken and have.bothArmsBroken() then
            return nil, nil, nil, nil, nil
         end
         return "free", "wield mace", { bal = true, eq = true }, nil, nil
      end
   end

   if emunah._persist and emunah._persist.maceSummoned then
      return "equilibrium", "call mace", nil, nil, nil
   end

   return "balance", "summon mace", nil, nil, nil
end

--- name -> function() returning the same five values as M.resolve(). For defences where no
--- single fixed command answers "how do I raise this" -- see resolveTrackmace() above.
M.DYNAMIC = {
   trackmace = resolveTrackmace,
}

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

return M

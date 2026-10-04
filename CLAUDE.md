# Working on Emunah

Achaea automation for Mudlet. Lua 5.1 (Mudlet's runtime) — no `goto`, no integer division,
`loadstring` not `load`.

## The rule that matters most

**Do not guess at game mechanics.** Every expensive mistake in this repo's history has the
same shape: a plausible assumption about what Achaea does, shipped, and wrong. `clot` sent
to a character without the lesson. Herb balance treated as shared with attack balance.
`Room.Players` assumed to exclude you. Each cost several rounds of play-test-and-report.

Before writing code that depends on how the game behaves:

1. **Grep `docs/game/`.** Verified facts live there, with the evidence that established
   them, split by topic: `curing.md`, `combat.md`, `balance.md`, `incapacitation.md`,
   `priest-abilities.md`, `defences.md`, `sustenance.md`, `prompt.md`, `gmcp.md`, `api.md`.
   `docs/game/help/` holds verbatim HELP files. `curing.md` and `combat.md` are the
   overview, and each claim in them is tagged with its source.
2. **Then check svof.** [svof](https://github.com/svof/svof) is the reference the user has
   named for curing methodology and balance blockers: gates in `raw-svo.skeleton.lua`
   (`check_herb`, `check_sip`, ...), per-action rules in `raw-svo.dict.lua`
   (`isadvisable`, and `gamename` for the server's name of each affliction), and verbatim
   game lines in `svo (install the zip, not me).xml`. **On curing and balances, svof's
   logic is more credible than Emunah's own** (the user's ruling). Where they disagree,
   change Emunah to match unless a timestamped transcript shows svof is wrong for today's
   game (it dates from 2021). Cite it as `[svof]` in `docs/game/`.
3. **If it is not in either, ask.** One question costs the user a paste. A wrong guess costs a
   play session, a bug report, and a round trip — and tends to surface as a *worse* bug than
   the one being fixed.
4. **Never infer a command's existence or syntax.** If the exact string is not in
   `docs/game/`, ask for the `HELP` output.

Landing a guess that "looks right" is the failure mode, not being slow.

## Before anything sends a command

Most "it acted without the balance" bugs are a command whose requirements were never
declared. Answer these from `docs/game/`, not from memory, for every new or changed send:

1. **Which vector does it spend?** One slot per balance (`core/queue.lua`). HELP names four
   curing balances: salve, herb (plants *and* minerals), elixir (health/mana elixirs *and*
   tonics), moss (irid *and* potash). Play adds smoke, focus and tree; svof adds purgative
   (the affliction-healing elixirs: immunity, frost, venom, speed, levitation). The combat balances
   are bal and eq.
2. **What else must be up, even though it isn't spent?** Declare it in `needs`
   (`core/act.lua`). HELP's default for bal/eq abilities: "not having balance prevents you
   from using an ability that requires equilibrium, and vice versa", so assume both until
   a transcript shows otherwise (`perform hands` spends eq and needs bal). Cures don't
   need bal/eq: svof's curing gates never check them, and play agrees for eating. Don't add
   that requirement without evidence.
3. **Which states block it?** Stun and sleep block everything, paralysis everything but
   eating, prone only what needs you upright, entanglement anything that needs footing.
   The full per-action table, with where each rule is enforced, is in `curing.md`
   (*What gates each action*). A new blocker goes into `afflist.blocks` (per vector) or
   `act.blocked` (per `needs`) so that every sender picks it up, never into one call site.
   The queue re-asks `have.vectorBlocked()` at send time, because a block can land after
   a cure is queued.
4. **Is repeating it harmful?** Most cures are safe to resend after a lost confirmation.
   **WRITHE and WAKE are not**: HELP says a repeat makes them take longer.
5. **What confirms it, and what rejects it?** Exact wording from `balance.md`. A rejection
   nobody matches leaves the vector wedged until its timeout.
6. **Is the character dead, unconscious, or short an arm's balance?** All three hold
   everything they should in `act.blocked`. Death pauses Emunah completely by the user's
   rule. Don't add a command that bypasses `act.send` or the queue.

`EmunahTriggers.xml` is generated from svof's trigger set by
`tools/build-trigger-package.py`. Change the generator and regenerate; never hand-edit the
XML. Its triggers may only call `detect.text*`. Anti-illusion is svof's, in four layers
documented at the top of that section of `curing/detect/init.lua`:
- text reports wait for the prompt;
- an illusion discards the block;
- a cure line needs its cure in flight;
- the server must confirm a gain (`engine.TEXT_CONFIRM`).
Don't add a path that applies text immediately.

Achaea's server-side curing is **off** for this character, and the user turned off its
sipping and defence upkeep by hand. Don't send `CURING` commands at login.

## Commands and help

There is one prefix, `emset`, plus `emhelp`. Keep it that way:
- A command belongs to a module in `src/emunah/help.lua`. The test suite fails if a handler is
  undocumented, or documented but missing.
- A new setting only needs a `help.lua` entry with its module. `emset <setting> <value>`
  and `emhelp <module>` pick it up with no command code.
- Don't add bare aliases or a second prefix. `sleep` (relaxes insomnia and marks a
  voluntary sleep), `emreload` (works when commands fail to load), `buy [qty] <number>` (the
  user's request; it only catches a digits-only item, which the game refuses anyway) and
  `pp` (the user's request: pause/resume curing and defences) are the only exceptions.
- After changing `help.lua`, run `lua tools/build-commands-page.lua` to regenerate
  `website/commands.html`.

## The website

`website/` is the public site (emunah.pharanyx.co.uk), static files with no build step,
published by `.github/workflows/pages.yml` on every push to `main` that touches it.
- Every page carries the same header and footer between `<!-- site:header -->` and
  `<!-- site:footer -->` markers; the suite fails if one drifts or any internal link or
  anchor is dead. Change them on every page together.
- `commands.html` is generated, and takes its header, menu and footer from
  `getting-started.html`. Edit the generator, never the output.
- Figures on the site (module count, test count, `engine.tick()` cost) are checked
  against README, the manifest and `docs/performance.md`. Update them together.
- Every claim about behaviour must match the code as it stands. Check before writing.

## Verify before implementing

- Read the code you are about to change, not just the function named in the request.
- Check consumers before changing a shared signal (`grep` the symbol). Several bugs here
  came from fixing a producer and missing that three modules read it.
- When a fix is based on a transcript, quote the timestamps in the commit message. Future
  sessions rely on that provenance.
- Prefer one targeted investigation over a broad refactor. If a change touches more than a
  few modules, say why first.
- Before restructuring the core abstractions (`core/act.lua`, `core/queue.lua`, the
  reload/manifest machinery in `emunah.lua`), read `docs/design.md` — it records why each is
  shaped the way it is and which specific bug shaped it.

## Evidence beats reasoning

A GMCP trace or a timestamped transcript settles in one read what reasoning about "what
should happen" gets wrong repeatedly. Ask for one:

- `emset debug` — every command sent, and every command held with the reason
- `emset debug gmcp` — every GMCP message in and out, payloads summarised
- A prompt with `*s` in it (`CONFIG PROMPT CUSTOM`) — timestamps make ordering unambiguous

## Tests

`lua test/run.lua` — must be green before committing. Mudlet is stubbed in
`test/mock_mudlet.lua`; if a test cannot express something, the mock is usually the gap
(it did not fill `speedWalkPath`, which hid a real bug). Fix the mock rather than skipping
the case.

Every behavioural fix gets a regression test that would have caught the original report.

Performance-sensitive changes (anything touching `curing/engine.lua`'s per-prompt path or a
UI repaint): `lua test/bench.lua` and `lua test/profile.lua` measure cost and locate it.
`docs/performance.md` has the current numbers and the rules for keeping them that way.

## Style

Comments explain *why*, especially where the obvious implementation is wrong — that is the
house style and it is load-bearing. Match the surrounding density. Do not narrate what the
code already says.

`CONTRIBUTING.md` states these same rules for a human contributor browsing the repo; this
file is the agent-facing version.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

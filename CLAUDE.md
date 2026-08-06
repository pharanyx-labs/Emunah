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
   them, split by topic: `balance.md`, `incapacitation.md`, `priest-abilities.md`,
   `defences.md`, `sustenance.md`, `prompt.md`, `gmcp.md`, `api.md`.
2. **If it is not there, ask.** One question costs the user a paste. A wrong guess costs a
   play session, a bug report, and a round trip — and tends to surface as a *worse* bug than
   the one being fixed.
3. **Never infer a command's existence or syntax.** If the exact string is not in
   `docs/game/`, ask for the `HELP` output.

Landing a guess that "looks right" is the failure mode, not being slow.

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

- `emunah debug` — every command sent, and every command held with the reason
- `emunah debug gmcp` — every GMCP message in and out, payloads summarised
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

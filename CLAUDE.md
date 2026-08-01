# Working on Emunah

Achaea automation for Mudlet. Lua 5.1 (Mudlet's runtime) — no `goto`, no integer division,
`loadstring` not `load`.

## The rule that matters most

**Do not guess at game mechanics.** Every expensive mistake in this repo's history has the
same shape: a plausible assumption about what Achaea does, shipped, and wrong. `clot` sent
to a character without the lesson. Herb balance treated as shared with attack balance.
`Room.Players` assumed to exclude you. Each cost several rounds of play-test-and-report.

Before writing code that depends on how the game behaves:

1. **Grep `docs/game/`.** Verified facts live there, with the evidence that established them.
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

## Style

Comments explain *why*, especially where the obvious implementation is wrong — that is the
house style and it is load-bearing. Match the surrounding density. Do not narrate what the
code already says.

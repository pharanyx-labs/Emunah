# Contributing

## Before writing code that depends on game behaviour

**Do not guess at game mechanics.** If a change depends on how Achaea behaves — a balance
cost, a rejection message, a GMCP payload shape — it has to be traceable to something the
game actually emitted:

1. **Grep `docs/game/`.** Verified facts live there, with the evidence that established
   them, split by topic (`balance.md`, `incapacitation.md`, `priest-abilities.md`,
   `defences.md`, `sustenance.md`, `prompt.md`, `gmcp.md`, `api.md`).
2. **If it is not there, ask** rather than shipping a plausible assumption. A wrong guess
   tends to surface as a worse bug than the one being fixed, several play sessions later.
3. **Never infer a command's existence or syntax.** If the exact string is not in
   `docs/game/`, get the real `HELP` output first.

When a change does establish a new fact — a HELP capture, a GMCP payload, a timestamped
transcript — add it to the relevant file in `docs/game/` with the evidence, not just the
conclusion. See that directory's own [README](docs/game/README.md) for the format.

## Before changing existing code

- Read the code you are about to change, not just the function named in the request.
- Check consumers before changing a shared signal (`grep` the symbol) — a producer fix that
  misses a reader elsewhere is a common source of regressions here.
- When a fix is based on a transcript, quote the timestamps in the commit message.

## Tests

```sh
lua test/run.lua
```

Must be green before committing. Mudlet is stubbed in `test/mock_mudlet.lua`; if a test
cannot express something, the mock is usually the gap — fix the mock rather than skipping
the case.

Every behavioural fix gets a regression test that would have caught the original report. See
[docs/design.md](docs/design.md) for the testing approach and the failure modes already
pinned by tests.

## Style

Default to no comments. Add one only when the *why* is non-obvious — a hidden constraint, a
subtle invariant, a workaround for a specific game or Mudlet bug, behaviour that would
surprise a reader. Do not narrate what the code already says by being well-named.

Match the surrounding module's density: some files (the affliction and defence data,
`class/priest.lua`, `core/act.lua`) carry dense, load-bearing comments recording confirmed
game facts with timestamps — that density is intentional and should be preserved, not
trimmed for its own sake.

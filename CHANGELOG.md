# Changelog

This project does not keep a single flat changelog. Substantive corrections are recorded
next to the data they correct, so the entry stays next to the evidence that justifies it
rather than in a separate file that drifts out of sync with the reasoning behind a change.

- **The affliction cure table** — see the "Change history" section of
  [docs/afflictions.md](docs/afflictions.md) for every substantive correction to
  `src/emunah/curing/afflist.lua`, most recent first, each with the transcript or capture
  that established it.
- **Game mechanics** — [docs/game/](docs/game/) is itself a running record: each fact states
  what established it and when, so the directory's own git history is the change log for how
  Emunah's understanding of Achaea evolved.
- **Everything else** — `git log` on the relevant file. Commit messages in this repository
  are written to carry the "why," including transcript timestamps where a fix was based on
  one, per this project's contribution rules.

## Adding an entry

A change belongs in a per-topic "Change history" section (see `docs/afflictions.md` for the
pattern) when it corrects previously-shipped data or behaviour based on new evidence — not
for routine feature work, which the commit message already covers.

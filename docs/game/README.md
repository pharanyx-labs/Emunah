# Primary sources

Verbatim game facts, and the evidence for them. This directory exists so that a fact only
has to be established **once** — by a HELP file, a GMCP payload, or a real transcript —
rather than re-guessed every time it comes up.

Everything here must be traceable to something the game actually emitted. If a claim cannot
be sourced, it does not belong here; an honest gap is worth more than a confident guess,
because a gap prompts a question and a guess ships a bug.

## Files

| File | Holds |
|---|---|
| `balance.md` | Balance and equilibrium: costs, rejection wording, what fails for free |
| `incapacitation.md` | Stun, prone, sleep — what blocks a command and what clears it |
| `priest-abilities.md` | Priest attacks, Devotion, Zeal verses, limb breaks, absolve |
| `defences.md` | Tattoos, FOCUS, TOUCH TREE, DIAG, and defence-naming mismatches |
| `sustenance.md` | Rift, containers, shops, pipes, the manna rite |
| `prompt.md` | `CONFIG PROMPT CUSTOM` tokens |
| `gmcp.md` | What GMCP actually sends, with real payloads |
| `api.md` | The Achaea web API: real payloads, and what is NOT in them |
| `help/` | Verbatim `HELP` output, one file per topic |

## Adding a source

Paste it in, or drop the file in yourself. Both work:

- **A HELP file** → `help/<topic>.txt`, verbatim, including the `MORE` continuations.
  Then add the derived fact to whichever topic file it belongs under (`balance.md`,
  `incapacitation.md`, `priest-abilities.md`, `defences.md`, `sustenance.md`, `prompt.md`),
  with a pointer to the HELP file.
- **A GMCP payload** → add it to `gmcp.md` under the message name, exactly as it arrived.
  `emunah debug gmcp` prints these.
- **A transcript** showing a behaviour → quote the relevant lines with their timestamps in
  whichever file the fact belongs to.

The useful unit is the *verbatim text*, not a summary of it. Message wording is what
triggers match against, and paraphrase loses exactly the detail that matters.

## Status

Seeded from evidence gathered in play. Coverage is thin and deliberately honest about it —
each file marks what is verified and what is still assumed.

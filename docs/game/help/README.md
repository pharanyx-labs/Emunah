# Verbatim HELP output

One file per topic, exactly as the game printed it — including `MORE` continuations and
the surrounding prompt lines. Paraphrase loses the detail that matters: exact command
syntax, exact message wording, exact token names.

Naming: lowercase, hyphenated. Most files match a HELP topic directly (`shops.txt` is
`HELP SHOPS`); a few, like `who-listings.txt`, are a capture of related in-game listing
commands (`CW`, `CLWHO`, `QW`, `HONOURS`, `DIAG`) grouped under one descriptive name because
no single HELP topic covers them.

Captured so far: `shops.txt` (`HELP SHOPS`), `who-listings.txt` (`CW`/`CLWHO`/`QW`/`HONOURS`/
`DIAG` output). `HELP CONFIG PROMPT` and the affliction cure pages remain the two most
load-bearing gaps — the affliction corpus in `src/emunah/curing/afflist.lua` is a seed
precisely because that text has never been available.

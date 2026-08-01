# Verbatim HELP output

One file per topic, exactly as the game printed it — including `MORE` continuations and
the surrounding prompt lines. Paraphrase loses the detail that matters: exact command
syntax, exact message wording, exact token names.

Naming: lowercase, hyphenated, matching the HELP topic. `config-prompt.txt`,
`afflictions-and-what-cures-them.txt`.

Nothing captured yet. `HELP CONFIG PROMPT` and the affliction cure pages are the two most
load-bearing gaps — the affliction corpus in `src/emunah/curing/afflist.lua` is a seed
precisely because that text has never been available.

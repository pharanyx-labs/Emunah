# Verbatim HELP output

One file per topic, exactly as the game printed it — including `MORE` continuations and
the surrounding prompt lines. Paraphrase loses the detail that matters: exact command
syntax, exact message wording, exact token names.

Naming: lowercase, hyphenated. Most files match a HELP topic directly (`shops.txt` is
`HELP SHOPS`); a few, like `who-listings.txt`, are a capture of related in-game listing
commands (`CW`, `CLWHO`, `QW`, `HONOURS`, `DIAG`) grouped under one descriptive name because
no single HELP topic covers them.

Captured so far: `shops.txt` (`HELP SHOPS`), `who-listings.txt` (`CW`/`CLWHO`/`QW`/`HONOURS`/
`DIAG` output), `ab-spirituality-mace.txt` (`AB SPIRITUALITY MACE`). These are in-game
captures.

Fetched 2026-09-28 from the website copy of the help (achaea.com/game-help), one file per
page, body verbatim below a two-line source header: HELP 13 *The Principles of Battle*
(`13-principles-of-battle.txt`) and its combat and curing sub-files (`combatprinciples`,
`preparation`, `defence`, `defending`, `heal`, `healinglist`, `afflictions`,
`curing-balances`, `compose`, `smoking`, `entanglement`, `curingsystem`, `denizencombat`,
`bodypartdamage`, `target`, `combattips`, `fleeing`, `saferooms`), plus the pages they link
to on character state (`equilibrium`, `sleeping`, `bleeding`, `breathing`, `health`, `mana`,
`endurance`, `willpower`, `hunger`, `death`) and equipment (`rift`, `vials`, `tattoos`,
`defences`, `venom`, `avoidance`, `curses`). The website copy can lag the live game. Where
it disagrees with a transcript, the transcript wins (see `../curing.md`).

`HELP CONFIG PROMPT` is still the most load-bearing gap.

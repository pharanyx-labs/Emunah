# Prompt

`CONFIG PROMPT CUSTOM` builds a custom prompt. Tokens verified from `HELP` (see
`help/config-prompt.txt` when captured): `*%h *%m *%e *%w` percentages, `*b` balances,
`*d` defences, `*t` target name, `*s` server time (GMT, `HH:MM:SS.hh`), `#r`/`#R` etc for
colour. Percentage tokens do **not** append `%` — add it literally.

`*t` reflects whatever `SETTARGET` holds, so it shows a replica number for denizens and a
name for players without any special-casing.

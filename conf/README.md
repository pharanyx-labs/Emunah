# conf/

Settings kept in plain files, for anyone who would rather edit a file than type `emset`.
`src/emunah/conf.lua` reads them on every load and every `emreload`.

| File | Holds | In force |
|---|---|---|
| `healing.conf` | when to sip, eat moss, lay hands and clot | always |
| `curing.conf`, `defences.conf`, `hunting.conf`, `pvp.conf`, `loot.conf`, `antitheft.conf`, `pipes.conf`, `riding.conf`, `people.conf`, `interface.conf`, `system.conf` | every other documented setting, one file per `emhelp` module | always |
| `priorities.conf` | your own cure ranks | only while `emset ownprios on` |
| `situations.conf` | the situational curing rules: switch one off, or change its ranks | only while `emset ownprios on` |

Every line ships commented out, so the files change nothing until you edit one. A setting
you pin in a file wins over the saved one, and `emset` on it says where it is pinned
instead of appearing to work. A line Emunah can't use (an unknown setting, the wrong type,
an affliction with no such cure) is reported when the files are read, with its file and
line number.

`emset ownprios on|off` is the only switch. It covers `priorities.conf` and
`situations.conf` together, so you can try your own ranks and drop them again without
editing anything.

**Updating:** `emreload` fast-forwards this checkout from `main`. Your edits here don't
stop that unless the same file also changed upstream. In that case the update is skipped
and Emunah says so. Keep a copy of your lines, take the update, and put them back.

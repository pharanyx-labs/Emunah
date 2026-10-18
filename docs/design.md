# Design

Why the code is shaped the way it is. Five ideas carry most of it, followed by five failure
modes specific to this environment that each cost a bug before they were fixed.

## Five ideas

**One gate for every command.** `core/act.lua` is the single place that knows when the game
will refuse an action — stunned, prone, no balance, rate-limited. Call sites declare what a
command *costs*, never when it is allowed.

**One slot per resource.** Achaea has several independent balances, so `core/queue.lua` is
not a single FIFO but one slot per vector. Eating a herb, applying a salve and drinking an
elixir can all be in flight simultaneously; two herbs cannot.

**Sent is not executed.** The game reports a balance as available until it actually runs a
command, so state alone cannot prevent a duplicate send. Every action that spends a balance
arms a short guard on dispatch, replaced by the exact cooldown the moment the game announces
it. Needing a balance is not spending it: a command that needs both and spends one holds
only the one it spends, and the other vectors of that prompt still go. A command that needs
a balance the line has already spent, and spends nothing that the commands it passes need,
is placed ahead of the spender (`act.ahead`): `wield mace|light pipes|hypersight on` works
where `hypersight on|wield mace` is refused.

**Choosing per prompt.** Keep-up takes, on each balance, the first defence that can go now,
not the first in line: one held for a balance it needs used to keep the slot from one that
could have gone. Equilibrium defences go cheapest first (`deflist.COSTS`) unless the user
sets an order (`emset defs order`), so the dearest goes last, where its cost delays nothing.
Raises that spend nothing (the free vector, `deflist.COSTLESS`) hold no slot and all go
together. While curing is tracking an affliction keep-up raises only those.

**One line per prompt.** What a prompt decides leaves together: every `act.send()` between
the balance changes of a `Char.Vitals` and the end of its tick, and everything sent when a
timer lapses or a confirmation times out, is collected and sent as one line joined by the
game's own command separator (CONFIG SEPARATOR), ten to a line, as the reference system
sends. The game splits the line and runs each command in order. The separator is learned
from the game each session (`core/separator.lua` asks `config commandseparator` on the first
prompt and hides the answer); until the game has named one, every command goes on a line of
its own, because a separator the game does not have would turn two commands into one it
cannot run. Mudlet's own `;;` is not used: Mudlet splits at it before sending, so it never
saved a line. Batching changes no balance rule: each command passed the gate and marked
what it spends when it was added, so a later command of the same prompt that needs that
balance is held exactly as before. Emunah writes a pair that must run in order with nothing
between them as one command joined by `act.JOIN` (`;;`): a herb only in the rift goes out
as `outr <herb>` then `eat <herb>`, as the reference system eats one, and every restock trip
due goes at once. `act.send()` splits it again, so it reaches the game as one line with the
game's separator, or as consecutive lines without one. `queue.chain` off sends every command
alone.

**Nothing is recomputed that the game has not changed.** The curing engine runs on every
prompt, so anything it does per tick is paid several times a second on Mudlet's UI thread —
shared with every other package the user has installed. Inventory counts, cure-table lookups
and settings are all memoised against an explicit generation counter or invalidated on
write, never against a clock. See [docs/performance.md](performance.md) for what that costs
today and the rules for keeping it that way.

Notes on the game's own mechanics — verified costs, message wording, GMCP payload shapes —
live in [docs/game/](game/).

## Five failure modes, each pinned by a test

- **Handler leaks on reload.** Event handlers registered at module scope survive a reload,
  so each reload stacks a new generation on the previous one and every GMCP message is
  processed repeatedly. `core/event.lua` tracks handler ids on a registry that outlives the
  reload and tears down the previous generation first.
- **Unconditional `pcall` assignment.** Assigning the result of `pcall(require, name)`
  regardless of success installs the error string as the module, and every later call fails
  far from the real fault. A failed load aborts and rolls back.
- **Update handlers copying the wrong record.** Rebuilding an inventory entry from the
  existing record rather than the incoming one means updates never land.
- **Removing an absent element.** `table.remove(t, table.index_of(t, item))` drops the last
  element when the item is absent, silently corrupting a room list.
- **A reload that cannot reload the loader.** A load function closing over its own module
  manifest can never pick up a newly added module. `emunahReload()` re-executes the loader
  file itself, rebuilding manifest, loader and namespace together.

One Achaea-specific trap is worth stating outright: `Char.Vitals.bal` and `.eq` arrive as
the **strings** `"1"` and `"0"`. In Lua `"0"` is truthy, so `if gmcp.Char.Vitals.bal then`
evaluates true when the character has no balance. All GMCP booleans route through
`util.bool()`.

## Testing approach

Every behavioural fix carries a regression test that would have caught the original report.
The mock is deliberately strict: each mocked Geyser class exposes only the methods the real
one has, constructor fields are validated against the legal set, and the trigger and alias
matchers implement the regex subset Mudlet actually uses rather than Lua patterns. Two
shipped bugs — a method that does not exist, and a constructor field Geyser silently ignores
— reached players because an earlier, permissive mock accepted anything.

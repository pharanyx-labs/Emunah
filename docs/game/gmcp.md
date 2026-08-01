# GMCP, as actually observed

Captured with `emunah debug gmcp`. Payloads are as they arrived.

## Ordering on a room change

This order is stable and load-bearing:

```
Char.Items.List   {items=[1] location="room"}     <- the room being ENTERED
Room.Info         {... num=6181}                   <- arrival
Room.Info         {... num=6181}                   <- sent TWICE, identically
Room.Players      [1]
Char.Vitals       {...}
```

**The item list arrives before `Room.Info`.** So mid-movement, the tracked room contents
already describe the room ahead. Anything acting on room contents must know whether it has
arrived; message ordering alone cannot tell you, because a manual `LOOK` produces an
unsolicited list for the room you are *standing in*. Ask the walker instead.

**`Room.Info` is duplicated** on every room change. Harmless — handlers early-return on an
unchanged room number — but do not read the second as a second movement.

## Room.Players includes you

Standing alone:

```lua
{ { fullname = "Saemora", name = "Saemora" } }
```

Every consumer wants "others here", so self must be excluded. Identify from `Char.Name`,
**not** `Char.Status` — see below.

## Char.Status does not arrive on room changes

An ordinary room change carries `Char.Vitals`, `Char.Items.List`, `Room.Info` and
`Room.Players`. No `Char.Status`. Anything needing the character's own name must use
`Char.Name` (sent once at connect, retained in the raw `gmcp` table across a reload).

## Char.Status.target is NOT a replica number

It is **stale**, not merely different. Observed twice: reading `21240` while attacking
replica `302211`, and later `110208` -- the goat from the *previous* fight, several kills
earlier -- while attacking `572474`. Char.Status is not re-sent on retargeting or on room
changes, so the field lags arbitrarily far behind.

Originally recorded as: observed live while attacking replica `302211`, with
`IRE.Target.Set "302211"` sent by us and the prompt showing `T:[porcupine302211]`,
`Char.Status.target` read **`21240`** -- a value with no evident relationship to anything in
the room.

Unresolved. Until it is, nothing compares the two fields for the purpose of correcting our
target; watch.lua reports the difference and takes no action. `IRE.Target.Set` and
`IRE.Target.Info` are the trustworthy pair for what we are attacking.

## Char.Afflictions reports physical states

`prone` arrives as a named affliction, alongside the ordinary ones. Presumably `stunned` and
others do too. This matters: knockdown was being inferred from per-denizen text ("...sending
you sprawling"), one message per attack per creature, of which exactly one was ever
observed -- while the game had been reporting it by name the whole time.

GMCP is authoritative and complete here where a hand-built pattern corpus can only ever be
partial. See `afflist.STATES` for the ones mapped to state flags rather than cure vectors.

## Char.Vitals

```
{... charstats=[7] ep="2798" eq="1" hp="900" maxhp="900" wp="2980"}
```

- `bal` and `eq` are the **strings** `"1"` / `"0"`. `"0"` is truthy in Lua.
- **Fields are omitted when unchanged** — a partial update is not a balance loss. Note
  `bal` is absent from the sample above.
- Arrives with essentially every prompt, which makes it the system heartbeat.

## Char.Items

Room contents come through `Char.Items` with `location = "room"` — there is no separate
`Room.Items` module. Request with `Char.Items.Room`.

An empty room may produce `{items={} location="room"}`, but a request can also go
**unanswered entirely** when there is nothing to report. Silence has to be read as "empty"
after bounded retries, or the consumer waits forever.

### Grouped stacks

A stack is **one entry**, and the count is in the name. Verbatim, after `outr 5 irid`:

```
Char.Items.Add {item={attrib="gre" icon="curative" id="344362"
                      name="a group of 5 pieces of irid moss"} location="inv"}
```

So `items.count()` answers 1 and `items.quantity()` answers 5 — the wording it parses is
`a group of N ...`, and `g` in `attrib` marks the entry as grouped. An entry with no number
is one item.

There is no numeric quantity field, so the name is the only source. `engine.queueRestock()`
still stops after `STOCK_ATTEMPTS` pulls that do not move the count, in case a wording
turns up that this does not parse.

## IRE.Rift

`IRE.Rift.List` is the full contents, `IRE.Rift.Change` a single commodity after it moves.
Request with `IRE.Rift.Request`. Amounts are authoritative — unlike inventory, there is a
real number in the payload.

**`name` is the generic commodity and `desc` is the qualifier**, and it is the *qualifier*
that OUTR takes:

```
IRE.Rift.Change {amount="493" desc="irid" name="moss"}      <- after `outr 5 irid`
```

A lookup keyed on `name` alone answers 0 for "irid" against a rift holding 493 of it, so
`ire.riftFind()` matches either field. Entries are keyed `"<desc> <name>"` when they have a
qualifier, so two kinds of moss cannot overwrite each other.

The rift survives death and inventory does not, which is why the restocker has a ceiling.

## Death

Reported from play: **channel capture stops after dying and does not resume on its own.**
Nothing client-side explains it — Mudlet's anonymous event handlers survive anything short
of a reload, and `gmcp/comm.lua` holds ordinary ones — so the subscription is being lost
upstream of the client.

Not confirmed which edge drops it, so `gmcp/init.lua` re-negotiates on both: entering death
and returning from it. `Core.Supports.Add` is additive and idempotent, so a redundant
re-negotiation costs one packet.

Death itself is detected from `Char.Vitals` reporting `hp` at zero, not from a message.
Message wording varies by what killed you; the vitals feed does not.

## Other observed messages

| Message | Payload | Notes |
|---|---|---|
| `Room.WrongDir` | `"e"` | Bare direction string when an exit does not exist |
| `IRE.Time.Update` | `{daynight="42"}` | |
| `Char.Name` | `{name=..., fullname=...}` | Once at connect. The reliable self-identifier |
| `Core.KeepAlive` | — | Sent by us |

## Enabled modules

`Core.Supports.Add` — see `src/emunah/gmcp/init.lua` for the current list.

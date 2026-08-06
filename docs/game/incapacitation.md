# Incapacitation

Verified from play unless marked otherwise. Each entry says what established it.

## Incapacitation

**Stunned blocks every command.** Not just attacks — everything, including `STAND`.

Onset (the tail varies by denizen and attack, so anchor only the head):

```
You are momentarily stunned as the massive bulk of a guard pig smashes into you.
```

Clears with `You are no longer stunned.`

**Attacking needs equilibrium as well as balance.** Confirmed live: after `perform hands`
took equilibrium, the prompt read `x-` (balance, no equilibrium) and three smites in a row
came back `You must regain equilibrium first.` So the heal and the attack compete, and a
system that models smite as balance-only throws away every attack during that window.

**`You are not fallen or kneeling.`** is the reply to `STAND` when already upright -- not
"You are already standing.", which has never been observed.

**STAND costs balance.** Confirmed live: knocked down at `08:12:57.54` with the prompt
reading `e-`, the stand went out immediately and came back `You must regain balance first.`
A single refused attempt left the character flat for twelve seconds.

**Prone blocks only what needs you upright.** Attacks and `GET` do; eating a herb and
drinking an elixir do not. Detected from `You must be standing first.`, cleared by
`You stand up.` or `You are already standing.`

Knockdown onset messages are per attack per denizen. Observed so far:

```
Springing forward, a wildcat soldier launches forward into you, sending you sprawling.
```

### Sleep

**The `Char.Afflictions` name is `sleeping`, not `asleep`.** Verbatim from the capture:

```
[gmcp] << Char.Afflictions.Add {cure="" desc="While asleep, you can do little but dream,
                                and wake up." name="sleeping"}
```

The `cure` field is **empty**, so `engine.serverCure()` cannot help — the response has to be
known here. `Char.Afflictions.Remove` carries it as a bare name in an array, like everything
else.

- **Blocks every command**, like stun rather than like prone. The one exception is `WAKE`,
  which the rejection itself names.
- **`WAKE` neither requires nor consumes balance or equilibrium** *(stated by the user)*.
  Being asleep is a special state rather than a balance.
- **Duration is variable**, sometimes up to ~10s.
- **`prone` is applied at the same time.** This is the important one for anything automated:
  the knockdown response fires while asleep and every `STAND` is thrown away.

> `06:02:59.94` `sleep` → `Char.Afflictions.Add sleeping` → `Char.Afflictions.Add prone` →
> `06:03:03.06` `You close your eyes, curl up in a ball, and fall asleep.`
> `STAND` at `06:03:03.27`, `06:03:12.85`, `06:03:13.06` → each `You are asleep and can do
> nothing. WAKE will attempt to wake you.`
> `06:03:15.10` `You open your eyes and stretch languidly, feeling deliciously well-rested.`
> (`Char.Afflictions.Remove` for `sleeping`, then for `prone`) →
> `06:03:15.31` `You stand up.`

Sleep is therefore driven from GMCP, not from text. **Two messages are still unknown** and
must not be guessed: what an *opponent's* sleep prints on onset, and what a successful `WAKE`
prints. The wake line above is specifically the rested one at the end of a full sleep.

One hit can cause both stun and knockdown. Stun clears first, and only the next action
reveals you are still down.

> Guard pig charge, `00:17:19.00` → stun. `00:17:21.98` → `You are no longer stunned.`
> `00:17:22.18` → `You must be standing first.`

## Aggressive denizens do not stop when you do

Confirmed live: a safety stop fired mid-fight and the goat carried on ramming for ~270 a
time -- `08:43:02`, `43:08`, `43:14`, `43:21` -- while the character stood there tanking and
drinking, neither fighting nor leaving. Disengaging is not an escape from something that is
already attacking you.

So the damage-rate check is advisory in combat and only the critical health floor applies;
out of combat it stands, because a drain nothing is fighting back against -- bleeding, a
room effect -- is exactly the case where stopping IS the remedy.

Also observed on that goat's kick: `Balance used: 0.5s.` on ITS attack, i.e. some denizen
attacks cost the victim balance. Not yet acted on.

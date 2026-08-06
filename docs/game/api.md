# The Achaea web API, as actually observed

Captured with `curl` on 2026-08-02. Payloads are verbatim.

This is a **primary source in the same sense as `gmcp.md`**: it is what the game itself
publishes about a character, not text a pattern has to be guessed at. `namedb/api.lua` is
written against exactly what is below.

## One character

`GET https://api.achaea.com/characters/<name>.json` — the name is case-insensitive.

```json
{"name":"Saemora","fullname":"Saemora, of Targossas","city":"targossas",
 "house":"(none)","level":"44","class":"priest","mob_kills":"290","player_kills":"0",
 "xp_rank":"1017","explorer_rank":"1074"}
```

More, showing the variation that matters:

```json
{"name":"Erishka","fullname":"Lady Sultana Erishka Khalimat, Auroran Knight",
 "city":"targossas","house":"harbingers","level":"104","class":"paladin",
 "mob_kills":"14886","player_kills":"720","xp_rank":"272","explorer_rank":"311"}

{"name":"Thelek","fullname":"'The' Mistell Magnet, Thelek Ar'kena","city":"targossas",
 "house":"(none)","level":"138","class":"monk","mob_kills":"451k","player_kills":"7",
 "xp_rank":"34","explorer_rank":"296"}

{"name":"Lokri","fullname":"Lokri, Tenebrous Operative","city":"hashan",
 "house":"somatikos","level":"89","class":"runewarden","mob_kills":"4855",
 "player_kills":"9","xp_rank":"484","explorer_rank":"366"}
```

### Facts established here

- **Every value is a string**, including every number. `"level":"44"`, not `44`.
- **`mob_kills` is sometimes abbreviated**: `"451k"`. `tonumber("451k")` is `451` — wrong by
  three orders of magnitude and entirely plausible-looking in a roster. It is therefore
  stored as text, never converted. This is the single most dangerous field here.
- **`city`, `house` and `class` are lowercase.** The record title-cases city and house for
  display and keeps class lowercase, matching how the rest of Emunah stores classes.
- **"there is none" is the literal string `"(none)"`**, seen for `house`. Mapped to nil, so
  nobody ends up a member of a House called None.
- `name` is the character's canonical spelling. It is used in preference to whatever
  spelling we resolved, which is what lets a honorific be *confirmed* rather than guessed.
- **Not carried:** order, city rank, might, marks, infamy, Dragon status, enemy status.
  Those still need `HONOURS` and the enemy listings — see `namedb.sources`.

### A name that is not a character

**HTTP 403**, not 404, with a body:

```json
{"error":{"code":403,"message":"Character not found: zzzznotarealname"}}
```

Both the status and the body are usable. `namedb/api.lua` treats either as a definite
"no such character" and caches it, so a mis-resolved honorific is not re-asked forever. A
*timeout* is explicitly not cached — it says nothing about whether the character exists,
and caching it would blacklist a real person over a dropped packet.

## Everyone online

`GET https://api.achaea.com/characters.json`

```json
{"count":37,"characters":[
 {"uri":"https:\/\/api.achaea.com\/characters\/aeowynn.json","name":"Aeowynn"},
 {"uri":"https:\/\/api.achaea.com\/characters\/akri.json","name":"Akri"}]}
```

Forward slashes are escaped (`\/`), which the decoder has to handle — this is the payload
every honorific resolution depends on.

One request for the entire online population. That is what makes reading a CW or CLWHO
listing cheap: the set of names those listings can possibly contain is small, known, and
already in hand, so a honorific is resolved by lookup instead of by slicing a string.

Observed `count` was 37 while `QW` reported 46 total with 8 unsensed. The two are close but
**not identical**, and nothing here assumes the roster is exhaustive.

## Response headers

No rate-limit headers of any kind are sent:

```
HTTP/1.1 200 OK
Server: nginx/1.22.1
Content-Type: application/json
Access-Control-Allow-Origin: *
```

Since the service does not state a limit, `namedb/api.lua` imposes its own rather than
assuming there is none: requests are serialised through a single queue with a minimum
interval between them, results are cached for 6 hours and misses for 24. Walking into a
market square must not become thirty simultaneous requests to a volunteer-run service.

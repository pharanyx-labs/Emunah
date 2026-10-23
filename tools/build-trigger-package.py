#!/usr/bin/env python3
"""Generate EmunahTriggers.xml -- the reference system's affliction and state triggers, wired to Emunah.

The reference system carries ~2250 Mudlet triggers: the onset, cure and wear-off
lines for most afflictions in the game, collected over years of play. Emunah's own
patterns (curing/detect/patterns.lua) are deliberately few, because every line in them has
to be sourced. The user has named the reference system as that source, and ruled it more credible than
Emunah on curing, so this turns its trigger set into an importable Mudlet package whose
only code is a call into Emunah's detect module:

    emunah.curing.detect.textGain("<server name>")          -- affliction gained
    emunah.curing.detect.textCure("<server name>"[, via])   -- cured / worn off
    emunah.curing.detect.textState("<state>", on)           -- stunned, prone, sleeping, unconscious
    emunah.curing.detect.textIllusion("<reason>")           -- this block is an illusion
    emunah.curing.detect.textLine() / textPrompt()          -- the reference system's Prompt trigger

ANTI-ILLUSION is the reference system's, in the same layers (see curing/detect/init.lua): reports wait for
the prompt and are discarded with the whole block if one of the reference system's "Generic illusions"
triggers fires in it; a cure line tied to a balance needs that cure in flight, not sooner
than half the ping; and the server must confirm a gained affliction.

WHAT IS TAKEN, AND WHAT IS NOT
------------------------------
A trigger is converted only when its meaning is certain from the reference system's own script. Every
statement has to be a bare `<ns>.valid.<fn>()` call whose name says what happened:

    simple<aff>, proper_<aff>, venom_<aff>            -> gained
    <balance>_cured_<aff>, generic_<aff>, cured_<aff>  -> cured
    <aff>_woreoff                                      -> cured (wore off)

Anything else -- a conditional, an illusion check, a DIAG line (diag.lua parses those in
context), a class tracker, an argument -- is skipped rather than interpreted. So are
multi-line, filter, colour and chained triggers, Lua-function and line-spacer patterns,
and the reference system's inactive triggers.

Names are translated to the SERVER'S name through the reference system's own `gamename` table
(its dictionary file), because Emunah confirms a text report against Char.Afflictions by name
(engine.TEXT_CONFIRM). A name Emunah does not know is dropped: it could never be cured,
and would only sit in the panel.

A pattern that the reference system uses to cure two DIFFERENT afflictions is ambiguous without the reference system's
action tracking, and its cure is dropped. Lines Emunah's own patterns.lua already handles
are skipped, so nothing fires twice.

Usage:
    python3 tools/build-trigger-package.py <source-dir-or-xml> [--dict <dictionary file>] [output]

<source-dir-or-xml> is the reference system's checkout (the repo root, or its output/ folder after a build)
or the path to its `<ns> (install the zip, not me).xml` itself. Output defaults to
EmunahTriggers.xml at the repository root.

<ns> is the reference system's Lua namespace. It is never written here: it is read from the
main XML's file name, and the script calls, trigger names and file names are matched by it.
"""
import argparse
import pathlib
import re
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
AFFLIST = ROOT / "src" / "emunah" / "curing" / "afflist.lua"
PATTERNS = ROOT / "src" / "emunah" / "curing" / "detect" / "patterns.lua"
MAIN_XML = " (install the zip, not me).xml"   # after the namespace

# The reference system internal name -> Emunah state. These are states Emunah models directly
# (curing/detect), not afflictions the engine cures.
STATES = {
    "stun": "stunned",
    "prone": "prone",
    "sleep": "sleeping",
    "unconsciousness": "unconscious",
}

# Mudlet pattern types that are plain line matches: 0 substring, 1 perl regex,
# 2 begin-of-line substring, 3 exact match. 4 (Lua function), 5 (line spacer),
# 6 (colour) and 7 (prompt) depend on context this package does not carry.
PLAIN_TYPES = {"0", "1", "2", "3"}

GAIN = [re.compile(r"^simple(\w+)$"), re.compile(r"^proper_(\w+)$"), re.compile(r"^venom_(\w+)$")]
# A cure line tied to a curing balance: accepted only while that balance's cure is in
# flight (detect.textCure's `via`, the reference system's checkany over the balance's actions).
VIA = re.compile(r"^(herb|salve|focus|smoke|tree)_cured_(\w+)$")
CURE = [re.compile(r"^generic_(\w+)$"), re.compile(r"^cured_?(\w+)$"),
        re.compile(r"^(\w+)_woreoff$")]
# The reference system's namespace, and the patterns built on it (set_namespace).
NS = None
# Its plain illusion flag, optionally behind its anti-illusion switch.
ILLUSION = None
CALL = None
# Its fight tracker: `<ns>.startedfighting("alchemist", multimatches[2][2])` on a line only
# that class sends. Bookkeeping, not curing, so it never stops a trigger converting; it
# becomes detect.textFoe(class, attacker) when the attacker's capture can be carried over,
# and is dropped when it cannot.
FOE = None
# Its trigger names start with the namespace; Emunah's do not.
PREFIX = None


def set_namespace(ns):
    global NS, ILLUSION, CALL, FOE, PREFIX
    NS = ns
    n = re.escape(ns)
    ILLUSION = re.compile(rf"^(?:if {n}\.conf\.aillusion then )?{n}\.ignore_illusion\("
                          r"(?:\"[^\"]*\"|'[^']*')?\)(?: end)?$")
    CALL = re.compile(rf"^{n}\.valid\.(\w+)\(\)$")
    FOE = re.compile(rf"^{n}\.startedfighting\(\s*[\"'](\w+)[\"']\s*,\s*"
                     r"(?:matches\[(\d+)\]|multimatches\[(\d+)\]\[(\d+)\])\s*\)$")
    PREFIX = re.compile(rf"^{n}\s+")


# The reference system's functions that are not a plain gain or cure but whose meaning is fixed, and what each
# becomes. Nothing here is interpreted from a name: each is read from the function's body.
VALID_MAP = {
    # Its valid.main file: homunculus_throat() is lostbal_focus() and nothing else. Its
    # paragraph_length check (the shriek "needs to be on it's own line") is NOT carried over:
    # Anzerloi's arena log of 2026-10-15 has the real shriek second in its paragraph, after
    # the homunculus's stare and before two glowers (docs/game/alchemist.md).
    "homunculus_throat": ("spent", "focus"),
    # Both only add the reference system's `unknownany` placeholder, which this generator drops anyway (the
    # server never sends that name). The affliction itself comes by GMCP; the line still says
    # who is attacking, as what.
    "humour_wrack": None,
    "humour_truewrack": None,
}
# Names the reference system's tables do not give, from evidence. Its swellskin is the
# server's homunculusmercury: its own trigger for the bite is named "Homunculus mercury
# (swellskin) bite", its serverside table (in its dictionary file) lists
# `homunculusmercury` as a server name, and Anzerloi's system tagged that same bite line
# `homunculusmercury` (docs/game/alchemist.md).
EXTRA_GAMENAMES = {"swellskin": "homunculusmercury"}


def find_inputs(source, dict_arg):
    source = pathlib.Path(source)
    if source.is_file():
        xml_path, base = source, source.parent
    else:
        candidates = sorted(source.glob("*" + MAIN_XML)) + sorted((source / "output").glob("*" + MAIN_XML))
        xml_path = next((c for c in candidates if c.is_file()), None)
        if not xml_path:
            sys.exit(f"no '<namespace>{MAIN_XML}' under {source} (or its output/)")
        base = source
    if not xml_path.name.endswith(MAIN_XML):
        sys.exit(f"{xml_path} is not named '<namespace>{MAIN_XML}'")
    ns = xml_path.name[:-len(MAIN_XML)]
    if dict_arg:
        dict_path = pathlib.Path(dict_arg)
    else:
        dict_name = f"raw-{ns}.dict.lua"
        search = [base / dict_name, base.parent / dict_name, base / ns, base.parent / ns]
        dict_path = next((c for c in search if c.is_file()), None)
        if not dict_path:
            sys.exit(f"cannot find {dict_name} (or the compiled `{ns}` file) for the reference system's "
                     "gamename table -- pass --dict")
    return xml_path, dict_path, ns


def gamenames(dict_path):
    text = dict_path.read_text(encoding="utf-8", errors="replace")
    names = {m.group(1): m.group(2) for m in
             re.finditer(r"\n\s*(\w+) = \{\s*\n\s*gamename = [\"']([^\"']+)[\"']", text)}
    # The reference system's serverside table maps the SERVER's name to its own (`corruption =
    # "corrupted"`, `temperedsanguine = "sanguinehumour"`). Read backwards, it names the
    # afflictions whose dictionary entry carries no gamename. Never over a gamename.
    table = re.search(rf"\n\s*ssto{re.escape(NS)}a = \{{(.*?)\n\s*\}}", text, re.S)
    if table:
        for server, own in re.findall(r"(\w+)\s*=\s*[\"'](\w+)[\"']", table.group(1)):
            names.setdefault(own, server)
    for own, server in EXTRA_GAMENAMES.items():
        names.setdefault(own, server)
    return names


def emunah_known():
    """Every name afflist.lua lets the engine act on: cure-table keys, aliases, writhes,
    blockers and wear-offs."""
    text = AFFLIST.read_text(encoding="utf-8")
    known = set(re.findall(r"\n   (\w+) = \{\n      cures = ", text))

    def keys_of(table):
        match = re.search(r"\nM\." + table + r" = \{\n(.*?)\n\}", text, re.S)
        return set(re.findall(r"^\s+(\w+)\s*=", match.group(1), re.M)) if match else set()

    for table in ("ALIASES", "writhes", "blocks", "wearsOff"):
        known |= keys_of(table)
    return known


def native_lines():
    """Lines patterns.lua already matches, as plain text, so they are not duplicated."""
    text = PATTERNS.read_text(encoding="utf-8")
    lines = set()
    for raw in re.findall(r"\[\[(\^?[^\]]*?\$?)\]\]", text):
        if "(" in raw or "\\w" in raw or "\\d" in raw:
            continue
        lines.add(re.sub(r"\\(.)", r"\1", raw.strip("^$")))
    return lines


def classify(fn):
    """(kind, affliction, via)"""
    for pattern in GAIN:
        match = pattern.match(fn)
        if match:
            return "gain", match.group(1), None
    match = VIA.match(fn)
    if match:
        return "cure", match.group(2), match.group(1)
    for pattern in CURE:
        match = pattern.match(fn)
        if match:
            return "cure", match.group(1), None
    return None, None, None


def statements(script):
    out = []
    for line in re.split(r"[\n;]", script or ""):
        line = line.split("--", 1)[0].strip()
        if line:
            out.append(line)
    return out


def walk(element, inside_group, found, chained=None):
    for child in element:
        if child.tag == "TriggerGroup":
            walk(child, True, found, chained)
        elif child.tag == "Trigger":
            has_children = any(c.tag in ("Trigger", "TriggerGroup") for c in child)
            if inside_group and not has_children:
                found.append(child)
            # A trigger with children is a chain; its children only fire inside it, so
            # neither it nor they are plain line matches. Not converted -- but its
            # children are kept aside, to name the routes of a cure line (main()).
            if has_children and chained is not None:
                walk_chain(child, chained)


def walk_chain(element, chained):
    for child in element:
        if child.tag in ("Trigger", "TriggerGroup"):
            if child.tag == "Trigger":
                chained.append(child)
            walk_chain(child, chained)


def convert_illusion(trigger):
    """The reference system's plain illusion triggers -- a pair of lines that cannot really arrive together
    -- copied with their multi-line settings, the script swapped for detect.textIllusion."""
    script = re.sub(r"\s+", " ", (trigger.findtext("script") or "").strip())
    if not ILLUSION.match(script):
        return None
    if trigger.get("isActive") != "yes":
        return "inactive"
    patterns = [s.text or "" for s in trigger.find("regexCodeList") or []]
    types = [i.text for i in trigger.find("regexCodePropertyList") or []]
    if not patterns or not set(types) <= PLAIN_TYPES | {"5"}:
        return "illusion pattern type needs context"
    name = PREFIX.sub("", trigger.findtext("name") or "illusion")
    name = ILLUSION_NAMES.get(name, name)
    # The reason is printed mid-sentence: "Ignored as an illusion: asthma with sleep".
    return ([("illusion", name[:1].lower() + name[1:])], list(zip(patterns, types)),
            trigger.get("isMultiline") == "yes", trigger.findtext("conditonLineDelta") or "0")


def literal(regex):
    """The fixed text a regex starts with, unescaped, up to its first metacharacter."""
    out = []
    index = 1 if regex.startswith("^") else 0
    while index < len(regex):
        char = regex[index]
        if char == "\\" and index + 1 < len(regex):
            following = regex[index + 1]
            if following.isalnum():
                break                      # \w, \d, \s: not literal
            out.append(following)
            index += 2
            continue
        if char in ".[]()*+?{}|^$":
            break
        out.append(char)
        index += 1
    return "".join(out)


def collapse(patterns, types):
    """A multi-line AND trigger whose patterns are all on ONE line (line delta 0) and amount to
    a substring prefilter in front of a regex: the reference system's idiom for a cheap first
    test. The regex alone matches exactly the same lines, so it is kept alone. Returns the
    regex's 1-based position, or None when the trigger is anything else."""
    regexes = [i for i, t in enumerate(types) if t == "1"]
    if len(regexes) != 1:
        return None
    regex = patterns[regexes[0]]
    head = literal(regex)
    for i, (pattern, kind) in enumerate(zip(patterns, types)):
        if i == regexes[0]:
            continue
        if kind == "2" and regex.startswith("^") and head.startswith(pattern):
            continue
        if kind == "0" and pattern in head:
            continue
        return None
    return regexes[0] + 1


def convert(trigger, names, known, native):
    """(kind, [(action, name)], patterns, types) or a skip reason."""
    if trigger.get("isActive") != "yes":
        return "inactive"
    for flag in ("isFilterTrigger", "isColorTrigger", "isColorizerTrigger"):
        if trigger.get(flag) == "yes":
            return "not a plain line trigger"
    if (trigger.findtext("mStayOpen") or "0") != "0":
        return "not a plain line trigger"
    patterns = [s.text or "" for s in trigger.find("regexCodeList") or []]
    types = [i.text for i in trigger.find("regexCodePropertyList") or []]
    if not patterns or len(patterns) != len(types) or not set(types) <= PLAIN_TYPES:
        return "pattern type needs context"
    # The regex's position in a collapsed multi-line trigger: multimatches[<it>] is matches.
    collapsed = None
    if trigger.get("isMultiline") == "yes":
        collapsed = collapse(patterns, types)
        if (trigger.findtext("conditonLineDelta") or "0") != "0" or not collapsed:
            return "not a plain line trigger"
        patterns, types = [patterns[collapsed - 1]], ["1"]

    actions = []
    for statement in statements(trigger.findtext("script")):
        foe = FOE.match(statement)
        if foe:
            # The attacker's capture in the trigger as it is written out: a single-line
            # trigger's own matches[n]; a collapsed one's multimatches[<the regex>][n]. Any
            # other reference names a pattern that is gone, and the report is dropped.
            if collapsed is None:
                group = foe.group(2)
            else:
                group = foe.group(4) if foe.group(3) and int(foe.group(3)) == collapsed else None
            if group:
                actions.append(("foe", (foe.group(1).lower(), int(group))))
            continue
        call = CALL.match(statement)
        if not call:
            return "script is more than plain valid calls"
        if call.group(1) in VALID_MAP:
            mapped = VALID_MAP[call.group(1)]
            if mapped:
                actions.append(mapped)
            continue
        kind, aff, via = classify(call.group(1))
        if not kind:
            return "valid function is not a gain/cure"
        if aff in STATES:
            actions.append(("state_on" if kind == "gain" else "state_off", STATES[aff]))
            continue
        server = names.get(aff, aff)
        # The reference system's unknown* placeholders track "something, not sure what" -- the server never
        # sends those names, so they could never be confirmed.
        if server not in known or server.startswith("unknown"):
            continue                       # Emunah cannot act on it; drop this statement
        actions.append(("cure@" + via if kind == "cure" and via else kind, server))
    if not actions:
        return "no affliction Emunah knows"
    # A line that only says who is attacking must at least say it of someone: a capture.
    if all(a == "foe" for a, _ in actions) and not any("(" in p for p in patterns):
        return "no affliction Emunah knows"

    # Drop lines patterns.lua already owns; keep the rest of the trigger.
    kept = [(p, t) for p, t in zip(patterns, types)
            if not (t in ("2", "3") and p in native)
            and not (t == "1" and re.sub(r"\\(.)", r"\1", p.strip("^$")) in native)]
    if not kept:
        return "already handled by patterns.lua"
    return actions, kept


def lua_call(action, name):
    if action == "gain":
        return f'emunah.curing.detect.textGain("{name}")'
    if action == "cure":
        return f'emunah.curing.detect.textCure("{name}")'
    if action.startswith("cure@"):
        vias = action[5:].split(",")
        via = f'"{vias[0]}"' if len(vias) == 1 else "{ " + ", ".join(f'"{v}"' for v in vias) + " }"
        return f'emunah.curing.detect.textCure("{name}", {via})'
    if action == "illusion":
        return f'emunah.curing.detect.textIllusion({lua_string(name)})'
    if action == "foe":
        return f'emunah.curing.detect.textFoe("{name[0]}", matches[{name[1]}])'
    if action == "spent":
        return f'emunah.curing.detect.textSpent("{name}")'
    return f'emunah.curing.detect.textState("{name}", {"true" if action == "state_on" else "false"})'


def lua_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


TRIGGER = """{indent}<Trigger isActive="yes" isFolder="no" isTempTrigger="no" isMultiline="{multiline}" isPerlSlashGOption="no" isColorizerTrigger="no" isFilterTrigger="no" isSoundTrigger="no" isColorTrigger="no" isColorTriggerFg="no" isColorTriggerBg="no">
{indent}    <name>{name}</name>
{indent}    <script>{script}</script>
{indent}    <triggerType>0</triggerType>
{indent}    <conditonLineDelta>{delta}</conditonLineDelta>
{indent}    <mStayOpen>0</mStayOpen>
{indent}    <mCommand></mCommand>
{indent}    <packageName></packageName>
{indent}    <mFgColor>#ff0000</mFgColor>
{indent}    <mBgColor>#ffff00</mBgColor>
{indent}    <mSoundFile></mSoundFile>
{indent}    <colorTriggerFgColor>#000000</colorTriggerFgColor>
{indent}    <colorTriggerBgColor>#000000</colorTriggerBgColor>
{indent}    <regexCodeList>
{patterns}
{indent}    </regexCodeList>
{indent}    <regexCodePropertyList>
{types}
{indent}    </regexCodePropertyList>
{indent}</Trigger>"""

GROUP_OPEN = """{indent}<TriggerGroup isActive="yes" isFolder="yes" isTempTrigger="no" isMultiline="no" isPerlSlashGOption="no" isColorizerTrigger="no" isFilterTrigger="no" isSoundTrigger="no" isColorTrigger="no" isColorTriggerFg="no" isColorTriggerBg="no">
{indent}    <name>{name}</name>
{indent}    <script>{script}</script>
{indent}    <triggerType>0</triggerType>
{indent}    <conditonLineDelta>0</conditonLineDelta>
{indent}    <mStayOpen>0</mStayOpen>
{indent}    <mCommand></mCommand>
{indent}    <packageName>{package}</packageName>
{indent}    <mFgColor>#ff0000</mFgColor>
{indent}    <mBgColor>#ffff00</mBgColor>
{indent}    <mSoundFile></mSoundFile>
{indent}    <colorTriggerFgColor>#000000</colorTriggerFgColor>
{indent}    <colorTriggerBgColor>#000000</colorTriggerBgColor>
{indent}    <regexCodeList />
{indent}    <regexCodePropertyList />"""

HEADER_NOTE = """-- EmunahTriggers: affliction, state and illusion lines for Emunah's curing.
--
-- Generated by tools/build-trigger-package.py. Regenerate it rather than editing by hand.
--
-- Each trigger reports what its line means to emunah.curing.detect and does nothing else,
-- and nothing at all when Emunah is not loaded. Reports are checked before they count:
--   * nothing is applied until the prompt that ends the block of output;
--   * a block containing an illusion (two lines that cannot arrive together) is discarded whole;
--   * a cure line counts only while that cure is in progress;
--   * a gained affliction must be confirmed by the server (GMCP Char.Afflictions).
-- `emset curing.antiIllusion false` turns off the first two checks."""

# One line in each folder's script, so the package explains itself in Mudlet's editor.
GROUP_NOTES = {
    "Prompt": "-- Closes each block of output: its reports are applied, or discarded as an illusion.",
    "Anti-illusion": "-- Pairs of lines that cannot arrive together. Either one marks its block as an illusion.",
    "Afflictions gained": "-- Lines that give an affliction. Named for the affliction and the line it matches.",
    "Afflictions cured": "-- Lines that cure an affliction or report that it wore off. A balance in parentheses\n"
                         "-- must have its cure in progress for the line to count.",
    "States": "-- Lines that leave you prone, stunned or asleep, often with an affliction as well.",
    "Balances": "-- Lines that take a curing balance from you.",
    "Attackers": "-- Lines only one class sends. Each says who is attacking you, and as what.",
}

# Readable names for the illusion pairs, which also appear in-game as the reason a block was
# ignored. Keyed by the source trigger's name; a pair not listed keeps that name.
ILLUSION_NAMES = {
    "Aeon+sleep": "Aeon wearing off with sleep",
    "Poor strip+chaosrays": "Speed stripped with chaos rays",
    "Aeon tarot+asthma": "Aeon tarot with asthma",
    "Asthma + aeon wore off": "Asthma with aeon wearing off",
    "Stuttering/clumsiness": "Stuttering with clumsiness",
    "Focus/impatience": "Focus succeeding and failing",
    "Pacifism/stuttering": "Pacifism with stuttering",
    "Asthma/stuttering": "Asthma with stuttering",
    "Paralysis/stuttering": "Paralysis with stuttering",
    "Darkshade/impatience": "Darkshade with impatience",
    "Flay/applied": "Sileris flayed and applied",
    "Sleep/sluggish": "Sleep with sluggishness",
    "Impatience/kalmia": "Impatience with asthma",
    "Herb bal/mind paralysis": "Herb balance with paralysis",
    "Hallucinations/epilepsy": "Hallucinations with epilepsy",
    "Empty pipe/asthma": "Empty pipe with asthma",
    "Arms crippled vibe/asthma": "Both arms broken with asthma",
    "Asthma+sleep": "Asthma with sleep",
    "Serious concussion + SoA": "Serious concussion through a shield",
    "Bomb+limb": "Dust bomb with leg damage",
    "Mild concussion + SoA": "Mild concussion through a shield",
    "Stuttering/sensitivityralysis": "Stuttering with paralysis",
    "Peace illusion": "Peace with a strange feeling",
}

# Server names that run words together, spelled out for trigger names.
DISPLAY = {
    "airdisrupt": "air disrupt", "earthdisrupt": "earth disrupt", "firedisrupt": "fire disrupt",
    "spiritdisrupt": "spirit disrupt", "waterdisrupt": "water disrupt",
    "charredburn": "charred burn", "extremeburn": "extreme burn", "meltingburn": "melting burn",
    "severeburn": "severe burn", "crackedribs": "cracked ribs", "skullfractures": "skull fractures",
    "torntendons": "torn tendons", "wristfractures": "wrist fractures",
    "slashedthroat": "slashed throat", "damagedhead": "damaged head", "mangledhead": "mangled head",
    "pacified": "pacifism", "disrupted": "disrupted", "inquisition": "inquisition",
    "numbedleftarm": "numbed left arm", "numbedrightarm": "numbed right arm",
}
for _state in ("broken", "damaged", "mangled", "crippled"):
    for _side in ("left", "right"):
        for _limb in ("arm", "leg"):
            DISPLAY[_state + _side + _limb] = f"{_state} {_side} {_limb}"


def display(name):
    return DISPLAY.get(name, name)


def summary(actions):
    """What a trigger reports, for its name: "Prone, paralysis", "Fear (tree, herb)"."""
    parts = []
    for action, name in actions:
        if action == "foe":
            label = f"{name[0]} attack"
        elif action == "spent":
            label = f"{name} balance lost"
        else:
            label = display(name)
        if action.startswith("cure@"):
            label += " (" + ", ".join(action[5:].split(",")) + ")"
        if label not in parts:
            parts.append(label)
    text = ", ".join(parts)
    return text[:1].upper() + text[1:]


def excerpt(pattern, kind, limit=60):
    """The start of the line a trigger matches, readable whether it is text or a regex."""
    text = pattern
    if kind == "1":
        text = text.strip("^$")
        text = re.sub(r"\\[wdsS][+*?]*|\.[+*]\??", "...", text)
        text = re.sub(r"\(\?:([^|()]*)\|[^()]*\)", r"\1", text)   # (?:his|her) -> his
        text = re.sub(r"\([^()]*\)", "...", text)
        text = re.sub(r"\\(.)", r"\1", text)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > limit:
        text = text[:limit].rsplit(" ", 1)[0].rstrip(",.;:") + "..."
    return text


PROMPT_PATTERN = ("if isPrompt() then return true else "
                  "if emunah and emunah.curing and emunah.curing.detect then "
                  "emunah.curing.detect.textLine() end return false end")
PROMPT_SCRIPT = ("if emunah and emunah.curing and emunah.curing.detect then\n"
                 "   emunah.curing.detect.textPrompt()\nend")


def render(groups):
    out = ['<?xml version="1.0" encoding="UTF-8"?>', "<!DOCTYPE MudletPackage>",
           '<MudletPackage version="1.001">', "    <TriggerPackage>"]
    out.append(GROUP_OPEN.format(indent="        ", name="EmunahTriggers",
                                 script=escape(HEADER_NOTE), package="EmunahTriggers"))
    indent = " " * 12

    def trigger(name, script, kept, multiline=False, delta="0"):
        return TRIGGER.format(
            indent=indent + "    ", name=escape(name), script=escape(script),
            multiline="yes" if multiline else "no", delta=escape(delta),
            patterns="\n".join(f"{indent}            <string>{escape(p)}</string>"
                               for p, _ in kept),
            types="\n".join(f"{indent}            <integer>{t}</integer>" for _, t in kept))

    # THE PROMPT, first: the reference system's own `Prompt` trigger, a Lua-function pattern that fires on
    # the prompt line and counts every other line as it goes (its paragraph_length). Here
    # the prompt closes the block -- reports applied or, on an illusion, discarded -- and
    # stands in for Char.Vitals as the heartbeat when none arrived.
    out.append(GROUP_OPEN.format(indent=indent, name="Prompt",
                                 script=escape(GROUP_NOTES["Prompt"]), package=""))
    out.append(trigger("Emunah prompt", PROMPT_SCRIPT, [(PROMPT_PATTERN, "4")]))
    out.append(indent + "</TriggerGroup>")

    for title, triggers in groups:
        if not triggers:
            continue
        out.append(GROUP_OPEN.format(indent=indent, name=escape(title),
                                     script=escape(GROUP_NOTES.get(title, "")), package=""))
        for name, actions, kept, multiline, delta in triggers:
            calls = "\n".join("   " + lua_call(a, n) for a, n in actions)
            script = f"if emunah and emunah.curing and emunah.curing.detect then\n{calls}\nend"
            out.append(trigger(name, script, kept, multiline, delta))
        out.append(indent + "</TriggerGroup>")
    out += ["        </TriggerGroup>", "    </TriggerPackage>", "</MudletPackage>", ""]
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("source", help="the reference system's checkout, its output/ folder, or its main XML")
    parser.add_argument("output", nargs="?", default=str(ROOT / "EmunahTriggers.xml"))
    parser.add_argument("--dict", help="its dictionary file (or the compiled one named after its namespace)")
    args = parser.parse_args()

    xml_path, dict_path, ns = find_inputs(args.source, args.dict)
    set_namespace(ns)
    names = gamenames(dict_path)
    if not names:
        sys.exit(f"no gamename entries found in {dict_path}")
    known = emunah_known()
    native = native_lines()

    root = ET.parse(xml_path).getroot()
    found, chained = [], []
    walk(root.find("TriggerPackage"), False, found, chained)

    skipped = {}
    converted = []
    for trigger in found:
        # Named without the source's own prefix: the names describe the line, not where it came from.
        name = PREFIX.sub("", trigger.findtext("name") or "trigger")
        result = convert_illusion(trigger)
        if result is None:
            result = convert(trigger, names, known, native)
            if not isinstance(result, str):
                result = (*result, False, "0")
        if isinstance(result, str):
            skipped[result] = skipped.get(result, 0) + 1
            continue
        converted.append((name, *result))

    # A line the reference system uses to cure two DIFFERENT afflictions needs the reference system's action tracking to
    # tell which; without it, drop the cure rather than guess.
    def is_cure(action):
        return action == "cure" or action.startswith("cure@")

    cures_by_line = {}
    for _, actions, kept, _, _ in converted:
        cured = {n for a, n in actions if is_cure(a)}
        for pattern, _ in kept:
            cures_by_line.setdefault(pattern, set()).update(cured)
    ambiguous = {p for p, cured in cures_by_line.items() if len(cured) > 1}

    # ONE LINE, SEVERAL ROUTES. The reference system has a trigger per route for the same cure line --
    # herb_cured_X, tree_cured_X, generic_X -- and firing them all would both double the
    # cure and log the routes that were not in flight as illusions. Merged per line and
    # affliction: if the reference system also takes it as a general cure, no balance has to be in flight
    # (the reference system believes it then too); otherwise any one of the listed balances will do.
    merged, order = {}, []
    for name, actions, kept, multiline, delta in converted:
        if len(actions) == 1 and is_cure(actions[0][0]) and not multiline:
            key = (tuple(kept), actions[0][1])
            via = actions[0][0][5:] if actions[0][0].startswith("cure@") else None
            if key not in merged:
                merged[key] = (name, kept, set())
                order.append(("cure", key))
            merged[key][2].add(via)
        else:
            order.append(("other", (name, actions, kept, multiline, delta)))
    # A CHAINED ROUTE FOR A LINE WE ALREADY HAVE. The reference system's smoke cures sit
    # inside its pipe chain, so "Thankfully, the visions of Hell have left you." came out as
    # a tree cure only, and a valerian smoke's cure was logged as an illusion (2026-10-23
    # 16:15:22.53). A chained cure adds its route to the same line's cure; it never makes a
    # trigger of its own.
    for trigger in chained:
        result = convert(trigger, names, known, native)
        if isinstance(result, str):
            continue
        actions, kept = result
        if len(actions) != 1 or not actions[0][0].startswith("cure@"):
            continue
        for pattern in kept:
            key = ((pattern,), actions[0][1])
            if key in merged:
                merged[key][2].add(actions[0][0][5:])

    converted = []
    for kind, item in order:
        if kind == "other":
            converted.append(item)
            continue
        name, kept, vias = merged[item]
        if None in vias:
            action = "cure"
        else:
            action = "cure@" + ",".join(sorted(vias))
        converted.append((name, [(action, item[1])], kept, False, "0"))

    groups = {"Anti-illusion": [], "Afflictions gained": [], "Afflictions cured": [],
              "States": [], "Balances": [], "Attackers": []}
    seen = set()
    dropped_ambiguous = 0
    for name, actions, kept, multiline, delta in converted:
        if any(p in ambiguous for p, _ in kept):
            before = len(actions)
            actions = [(a, n) for a, n in actions if not is_cure(a)]
            dropped_ambiguous += before - len(actions)
            if not actions:
                continue
        key = (tuple(kept), tuple(actions))
        if key in seen:
            continue
        seen.add(key)
        kinds = {a for a, _ in actions}
        if "illusion" in kinds:
            group = "Anti-illusion"
        elif kinds & {"state_on", "state_off"}:
            group = "States"
        elif "gain" in kinds:
            group = "Afflictions gained"
        elif any(is_cure(a) for a in kinds):
            group = "Afflictions cured"
        elif "spent" in kinds:
            group = "Balances"
        else:
            group = "Attackers"
        # Named for what the trigger reports and the line it matches, rather than the
        # source's own labels, which are inconsistent and often private shorthand.
        if group == "Anti-illusion":
            reason = actions[0][1]
            name = reason[:1].upper() + reason[1:]
        else:
            name = f"{summary(actions)}: {excerpt(*kept[0])}"
        groups[group].append((name, actions, kept, multiline, delta))

    output = pathlib.Path(args.output)
    output.write_text(render(list(groups.items())), encoding="utf-8")
    ET.parse(output)                        # the result must at least be well-formed XML

    total = sum(len(v) for v in groups.values()) + 1
    print(f"wrote {output} -- {total} triggers from {len(found)} in {xml_path.name}")
    print(f"  {'Prompt':20} 1")
    for title, triggers in groups.items():
        print(f"  {title:20} {len(triggers)}")
    print("skipped:")
    for reason, count in sorted(skipped.items(), key=lambda kv: -kv[1]):
        print(f"  {count:5}  {reason}")
    if dropped_ambiguous:
        print(f"  {dropped_ambiguous:5}  cure actions on a line the reference system uses for two afflictions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

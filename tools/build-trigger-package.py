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
statement has to be a bare `svo.valid.<fn>()` call whose name says what happened:

    simple<aff>, proper_<aff>, venom_<aff>            -> gained
    <balance>_cured_<aff>, generic_<aff>, cured_<aff>  -> cured
    <aff>_woreoff                                      -> cured (wore off)

Anything else -- a conditional, an illusion check, a DIAG line (diag.lua parses those in
context), a class tracker, an argument -- is skipped rather than interpreted. So are
multi-line, filter, colour and chained triggers, Lua-function and line-spacer patterns,
and the reference system's inactive triggers.

Names are translated to the SERVER'S name through the reference system's own `gamename` table
(raw-svo.dict.lua), because Emunah confirms a text report against Char.Afflictions by name
(engine.TEXT_CONFIRM). A name Emunah does not know is dropped: it could never be cured,
and would only sit in the panel.

A pattern that the reference system uses to cure two DIFFERENT afflictions is ambiguous without the reference system's
action tracking, and its cure is dropped. Lines Emunah's own patterns.lua already handles
are skipped, so nothing fires twice.

Usage:
    python3 tools/build-trigger-package.py <source-dir-or-xml> [--dict raw-svo.dict.lua] [output]

<source-dir-or-xml> is the reference system's checkout (the repo root, or its output/ folder after a build)
or the path to `svo (install the zip, not me).xml` itself. Output defaults to
EmunahTriggers.xml at the repository root.
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
MAIN_XML = "svo (install the zip, not me).xml"

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
# The reference system's plain illusion flag, optionally behind its anti-illusion switch.
ILLUSION = re.compile(r"^(?:if svo\.conf\.aillusion then )?svo\.ignore_illusion\("
                      r"(?:\"[^\"]*\"|'[^']*')?\)(?: end)?$")
CALL = re.compile(r"^svo\.valid\.(\w+)\(\)$")


def find_inputs(source, dict_arg):
    source = pathlib.Path(source)
    if source.is_file():
        xml_path, base = source, source.parent
    else:
        candidates = [source / MAIN_XML, source / "output" / MAIN_XML]
        xml_path = next((c for c in candidates if c.is_file()), None)
        if not xml_path:
            sys.exit(f"no '{MAIN_XML}' under {source} (or its output/)")
        base = source
    if dict_arg:
        dict_path = pathlib.Path(dict_arg)
    else:
        search = [base / "raw-svo.dict.lua", base.parent / "raw-svo.dict.lua",
                  base / "svo", base.parent / "svo"]
        dict_path = next((c for c in search if c.is_file()), None)
        if not dict_path:
            sys.exit("cannot find raw-svo.dict.lua (or the compiled `svo` file) for the reference system's "
                     "gamename table -- pass --dict")
    return xml_path, dict_path


def gamenames(dict_path):
    text = dict_path.read_text(encoding="utf-8", errors="replace")
    return {m.group(1): m.group(2) for m in
            re.finditer(r"\n\s*(\w+) = \{\s*\n\s*gamename = [\"']([^\"']+)[\"']", text)}


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


def walk(element, inside_group, found):
    for child in element:
        if child.tag == "TriggerGroup":
            walk(child, True, found)
        elif child.tag == "Trigger":
            has_children = any(c.tag in ("Trigger", "TriggerGroup") for c in child)
            if inside_group and not has_children:
                found.append(child)
            # A trigger with children is a chain; its children only fire inside it, so
            # neither it nor they are plain line matches. Not descended into.


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
    name = trigger.findtext("name") or "illusion"
    return ([("illusion", "the reference system: " + name)], list(zip(patterns, types)),
            trigger.get("isMultiline") == "yes", trigger.findtext("conditonLineDelta") or "0")


def convert(trigger, names, known, native):
    """(kind, [(action, name)], patterns, types) or a skip reason."""
    if trigger.get("isActive") != "yes":
        return "inactive"
    for flag in ("isMultiline", "isFilterTrigger", "isColorTrigger", "isColorizerTrigger"):
        if trigger.get(flag) == "yes":
            return "not a plain line trigger"
    if (trigger.findtext("mStayOpen") or "0") != "0":
        return "not a plain line trigger"
    patterns = [s.text or "" for s in trigger.find("regexCodeList") or []]
    types = [i.text for i in trigger.find("regexCodePropertyList") or []]
    if not patterns or len(patterns) != len(types) or not set(types) <= PLAIN_TYPES:
        return "pattern type needs context"

    actions = []
    for statement in statements(trigger.findtext("script")):
        call = CALL.match(statement)
        if not call:
            return "script is more than plain svo.valid calls"
        kind, aff, via = classify(call.group(1))
        if not kind:
            return "svo.valid function is not a gain/cure"
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

HEADER_NOTE = """-- EmunahTriggers: the reference system's affliction, state and anti-illusion lines, feeding Emunah.
-- Generated by tools/build-trigger-package.py -- regenerate rather than edit by hand.
-- Every trigger only calls emunah.curing.detect.text*, and does nothing when Emunah is not
-- loaded. Anti-illusion is the reference system's: nothing counts until the prompt, one illusion discards
-- the whole block, a cure line needs its cure in flight, and the server must confirm a
-- gained affliction (engine.TEXT_CONFIRM). `emunah set curing.antiIllusion false` turns
-- the first two off, as the reference system's `vconfig aillusion` does."""


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
    out.append(GROUP_OPEN.format(indent=indent, name="Prompt", script="", package=""))
    out.append(trigger("Emunah prompt", PROMPT_SCRIPT, [(PROMPT_PATTERN, "4")]))
    out.append(indent + "</TriggerGroup>")

    for title, triggers in groups:
        if not triggers:
            continue
        out.append(GROUP_OPEN.format(indent=indent, name=escape(title), script="",
                                     package=""))
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
    parser.add_argument("--dict", help="raw-svo.dict.lua (or the compiled svo file)")
    args = parser.parse_args()

    xml_path, dict_path = find_inputs(args.source, args.dict)
    names = gamenames(dict_path)
    if not names:
        sys.exit(f"no gamename entries found in {dict_path}")
    known = emunah_known()
    native = native_lines()

    root = ET.parse(xml_path).getroot()
    found = []
    walk(root.find("TriggerPackage"), False, found)

    skipped = {}
    converted = []
    for trigger in found:
        # Named without the source's own prefix: the names describe the line, not where it came from.
        name = re.sub(r"^svo\s+", "", trigger.findtext("name") or "trigger")
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
              "States": []}
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
        else:
            group = "Afflictions cured"
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

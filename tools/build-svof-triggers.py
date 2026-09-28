#!/usr/bin/env python3
"""Generate EmunahTriggers.xml -- svof's affliction and state triggers, wired to Emunah.

svof (github.com/svof/svof) carries ~2250 Mudlet triggers: the onset, cure and wear-off
lines for most afflictions in the game, collected over years of play. Emunah's own
patterns (curing/detect/patterns.lua) are deliberately few, because every line in them has
to be sourced. The user has named svof as that source, and ruled it more credible than
Emunah on curing, so this turns its trigger set into an importable Mudlet package whose
only code is a call into Emunah's detect module:

    emunah.curing.detect.textGain("<server name>")     -- affliction gained
    emunah.curing.detect.textCure("<server name>")     -- affliction cured / worn off
    emunah.curing.detect.textState("<state>", on)      -- stunned, prone, sleeping, unconscious

WHAT IS TAKEN, AND WHAT IS NOT
------------------------------
A trigger is converted only when its meaning is certain from svof's own script. Every
statement has to be a bare `svo.valid.<fn>()` call whose name says what happened:

    simple<aff>, proper_<aff>, venom_<aff>            -> gained
    <balance>_cured_<aff>, generic_<aff>, cured_<aff>  -> cured
    <aff>_woreoff                                      -> cured (wore off)

Anything else -- a conditional, an illusion check, a DIAG line (diag.lua parses those in
context), a class tracker, an argument -- is skipped rather than interpreted. So are
multi-line, filter, colour and chained triggers, Lua-function and line-spacer patterns,
and svof's inactive triggers.

Names are translated to the SERVER'S name through svof's own `gamename` table
(raw-svo.dict.lua), because Emunah confirms a text report against Char.Afflictions by name
(engine.TEXT_CONFIRM). A name Emunah does not know is dropped: it could never be cured,
and would only sit in the panel.

A pattern that svof uses to cure two DIFFERENT afflictions is ambiguous without svof's
action tracking, and its cure is dropped. Lines Emunah's own patterns.lua already handles
are skipped, so nothing fires twice.

Usage:
    python3 tools/build-svof-triggers.py <svof-dir-or-xml> [--dict raw-svo.dict.lua] [output]

<svof-dir-or-xml> is the svof checkout (the repo root, or its output/ folder after a build)
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

# svof internal name -> Emunah state. These are states Emunah models directly
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
CURE = [re.compile(r"^\w+?_cured_(\w+)$"), re.compile(r"^generic_(\w+)$"),
        re.compile(r"^cured_?(\w+)$"), re.compile(r"^(\w+)_woreoff$")]
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
            sys.exit("cannot find raw-svo.dict.lua (or the compiled `svo` file) for svof's "
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
    for pattern in GAIN:
        match = pattern.match(fn)
        if match:
            return "gain", match.group(1)
    for pattern in CURE:
        match = pattern.match(fn)
        if match:
            return "cure", match.group(1)
    return None, None


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
            name = (child.findtext("name") or "").lower()
            if "illusion" in name:          # svof's illusion catchers: never afflictions
                continue
            walk(child, True, found)
        elif child.tag == "Trigger":
            has_children = any(c.tag in ("Trigger", "TriggerGroup") for c in child)
            if inside_group and not has_children:
                found.append(child)
            # A trigger with children is a chain; its children only fire inside it, so
            # neither it nor they are plain line matches. Not descended into.


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
        kind, aff = classify(call.group(1))
        if not kind:
            return "svo.valid function is not a gain/cure"
        if aff in STATES:
            actions.append(("state_on" if kind == "gain" else "state_off", STATES[aff]))
            continue
        server = names.get(aff, aff)
        # svof's unknown* placeholders track "something, not sure what" -- the server never
        # sends those names, so they could never be confirmed.
        if server not in known or server.startswith("unknown"):
            continue                       # Emunah cannot act on it; drop this statement
        actions.append((kind, server))
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
    return f'emunah.curing.detect.textState("{name}", {"true" if action == "state_on" else "false"})'


TRIGGER = """{indent}<Trigger isActive="yes" isFolder="no" isTempTrigger="no" isMultiline="no" isPerlSlashGOption="no" isColorizerTrigger="no" isFilterTrigger="no" isSoundTrigger="no" isColorTrigger="no" isColorTriggerFg="no" isColorTriggerBg="no">
{indent}    <name>{name}</name>
{indent}    <script>{script}</script>
{indent}    <triggerType>0</triggerType>
{indent}    <conditonLineDelta>0</conditonLineDelta>
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

HEADER_NOTE = """-- EmunahTriggers: svof's affliction and state lines, feeding Emunah.
-- Generated by tools/build-svof-triggers.py -- regenerate rather than edit by hand.
-- Every trigger only calls emunah.curing.detect.textGain / textCure / textState, and does
-- nothing when Emunah is not loaded. An affliction reported here is dropped unless the
-- server confirms it within a couple of seconds (engine.TEXT_CONFIRM), so a faked line
-- cannot leave Emunah curing a phantom."""


def render(groups):
    out = ['<?xml version="1.0" encoding="UTF-8"?>', "<!DOCTYPE MudletPackage>",
           '<MudletPackage version="1.001">', "    <TriggerPackage>"]
    out.append(GROUP_OPEN.format(indent="        ", name="EmunahTriggers",
                                 script=escape(HEADER_NOTE), package="EmunahTriggers"))
    for title, triggers in groups:
        if not triggers:
            continue
        out.append(GROUP_OPEN.format(indent="            ", name=escape(title), script="",
                                     package=""))
        for name, actions, kept in triggers:
            calls = "\n".join("   " + lua_call(a, n) for a, n in actions)
            script = f"if emunah and emunah.curing and emunah.curing.detect then\n{calls}\nend"
            indent = " " * 16
            out.append(TRIGGER.format(
                indent=indent, name=escape(name), script=escape(script),
                patterns="\n".join(f"{indent}        <string>{escape(p)}</string>"
                                   for p, _ in kept),
                types="\n".join(f"{indent}        <integer>{t}</integer>" for _, t in kept)))
        out.append("            </TriggerGroup>")
    out += ["        </TriggerGroup>", "    </TriggerPackage>", "</MudletPackage>", ""]
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("svof", help="svof checkout, its output/ folder, or the main svof XML")
    parser.add_argument("output", nargs="?", default=str(ROOT / "EmunahTriggers.xml"))
    parser.add_argument("--dict", help="raw-svo.dict.lua (or the compiled svo file)")
    args = parser.parse_args()

    xml_path, dict_path = find_inputs(args.svof, args.dict)
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
        result = convert(trigger, names, known, native)
        if isinstance(result, str):
            skipped[result] = skipped.get(result, 0) + 1
            continue
        converted.append((trigger.findtext("name") or "svof trigger", *result))

    # A line svof uses to cure two DIFFERENT afflictions needs svof's action tracking to
    # tell which; without it, drop the cure rather than guess.
    cures_by_line = {}
    for _, actions, kept in converted:
        cured = {n for a, n in actions if a == "cure"}
        for pattern, _ in kept:
            cures_by_line.setdefault(pattern, set()).update(cured)
    ambiguous = {p for p, cured in cures_by_line.items() if len(cured) > 1}

    groups = {"Afflictions gained": [], "Afflictions cured": [], "States": []}
    seen = set()
    dropped_ambiguous = 0
    for name, actions, kept in converted:
        if any(p in ambiguous for p, _ in kept):
            before = len(actions)
            actions = [(a, n) for a, n in actions if a != "cure"]
            dropped_ambiguous += before - len(actions)
            if not actions:
                continue
        key = (tuple(kept), tuple(actions))
        if key in seen:
            continue
        seen.add(key)
        kinds = {a for a, _ in actions}
        if kinds & {"state_on", "state_off"}:
            group = "States"
        elif "gain" in kinds:
            group = "Afflictions gained"
        else:
            group = "Afflictions cured"
        groups[group].append((name, actions, kept))

    output = pathlib.Path(args.output)
    output.write_text(render(list(groups.items())), encoding="utf-8")
    ET.parse(output)                        # the result must at least be well-formed XML

    total = sum(len(v) for v in groups.values())
    print(f"wrote {output} -- {total} triggers from {len(found)} in {xml_path.name}")
    for title, triggers in groups.items():
        print(f"  {title:20} {len(triggers)}")
    print("skipped:")
    for reason, count in sorted(skipped.items(), key=lambda kv: -kv[1]):
        print(f"  {count:5}  {reason}")
    if dropped_ambiguous:
        print(f"  {dropped_ambiguous:5}  cure actions on a line svof uses for two afflictions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

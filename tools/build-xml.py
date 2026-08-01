#!/usr/bin/env python3
"""Generate Emunah.xml -- the no-toolchain install path.

muddler produces a proper .mpackage but needs a JVM. This script produces an equivalent
importable Mudlet package XML from the same bootstrap source, so the only hard requirement
to install Emunah is Mudlet itself.

There is exactly one copy of the bootstrap code (package/src/scripts/Emunah/bootstrap.lua);
both build paths consume it, so the two installers can never drift apart.

Usage: python3 tools/build-xml.py [output]
"""
import pathlib
import re
import sys
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
BOOTSTRAP = ROOT / "package" / "src" / "scripts" / "Emunah" / "bootstrap.lua"
OUTPUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "Emunah.xml"

# Mudlet fires an event handler by compiling "return <ScriptName>", so the script name
# must be a valid Lua identifier AND must match a global function the script defines.
SCRIPT_NAME = "EmunahBootstrap"

TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE MudletPackage>
<MudletPackage version="1.001">
    <ScriptPackage>
        <ScriptGroup isActive="yes" isFolder="yes">
            <name>Emunah</name>
            <packageName>Emunah</packageName>
            <script></script>
            <eventHandlerList />
            <Script isActive="yes" isFolder="no">
                <!-- MUST be a valid Lua identifier and MUST match the global function
                     defined in bootstrap.lua. Mudlet fires an event handler by compiling
                     "return <ScriptName>", so any space here breaks every handler. -->
                <name>{name}</name>
                <packageName></packageName>
                <script>{script}</script>
                <eventHandlerList>
                    <string>sysLoadEvent</string>
                    <string>sysInstall</string>
                </eventHandlerList>
            </Script>
        </ScriptGroup>
    </ScriptPackage>
</MudletPackage>
"""


def main() -> int:
    if not BOOTSTRAP.is_file():
        print(f"missing bootstrap source: {BOOTSTRAP}", file=sys.stderr)
        return 1

    source = BOOTSTRAP.read_text(encoding="utf-8")

    if not re.fullmatch(r"[A-Za-z_]\w*", SCRIPT_NAME):
        print(f"script name {SCRIPT_NAME!r} is not a valid Lua identifier", file=sys.stderr)
        return 1

    if f"function {SCRIPT_NAME}(" not in source:
        print(
            f"bootstrap.lua defines no global function {SCRIPT_NAME}() -- "
            "event handlers would fail at runtime",
            file=sys.stderr,
        )
        return 1

    # Mudlet stores script bodies as XML text. escape() handles & < >; quotes are safe
    # inside element text and escaping them would corrupt Lua string literals.
    OUTPUT.write_text(
        TEMPLATE.format(name=SCRIPT_NAME, script=escape(source)), encoding="utf-8"
    )

    print(f"wrote {OUTPUT.relative_to(ROOT)} ({OUTPUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

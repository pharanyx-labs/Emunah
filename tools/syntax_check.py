#!/usr/bin/env python3
"""Compile-only syntax check for every Lua file in the repo.

Mudlet ships LuaJIT (5.1 semantics); lupa here is 5.5. That is fine for catching
syntax errors, but we additionally grep for constructs that are valid in 5.2+ and
would break under Mudlet's 5.1.
"""
import pathlib
import re
import sys

import lupa

LUA51_INCOMPATIBLE = [
    (re.compile(r"::\w+::"), "goto label (5.2+); not available in Mudlet's LuaJIT 5.1"),
    (re.compile(r"[^/]//[^/]"), "integer division // (5.3+)"),
    (re.compile(r"\bmath\.type\b"), "math.type (5.3+)"),
    (re.compile(r"\btable\.move\b"), "table.move (5.3+)"),
    (re.compile(r"\bmath\.tointeger\b"), "math.tointeger (5.3+)"),
]

# Valid in 5.1 but removed later - we must NOT use these either, since we compile
# under 5.5 to check. Listed so the report explains any false alarm.
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
runtime = lupa.LuaRuntime()
loadstring = runtime.eval("function(src, name) return load(src, name) end")

files = sorted(root.rglob("*.lua"))
if not files:
    print("no lua files found")
    sys.exit(1)

errors = 0
warnings = 0
for path in files:
    src = path.read_text(encoding="utf-8")
    rel = path.relative_to(root)

    chunk, err = None, None
    result = loadstring(src, f"@{rel}")
    if isinstance(result, tuple):
        chunk, err = result
    else:
        chunk = result

    if chunk is None:
        print(f"SYNTAX  {rel}: {err}")
        errors += 1
        continue

    for line_no, line in enumerate(src.splitlines(), 1):
        stripped = line.split("--", 1)[0]
        for pattern, why in LUA51_INCOMPATIBLE:
            if pattern.search(stripped):
                print(f"COMPAT  {rel}:{line_no}: {why}")
                warnings += 1

    print(f"ok      {rel}")

print(f"\n{len(files)} files, {errors} syntax error(s), {warnings} compat warning(s)")
sys.exit(1 if errors else 0)

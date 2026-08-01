#!/usr/bin/env python3
"""Run the Emunah Lua test suite under lupa."""
import sys
import pathlib
import lupa

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
rt = lupa.LuaRuntime(unpack_returned_tuples=True)

# Give the suite an `arg` table so it can locate the repo root the way `lua` would.
rt.execute(f'arg = {{ [0] = "{root}/test/run.lua" }}')

# os.exit would kill the interpreter; capture the status instead.
rt.execute("""
    _EXIT = nil
    local realexit = os.exit
    os.exit = function(code) _EXIT = code or 0; error("__EXIT__", 0) end
""")

src = (root / "test" / "run.lua").read_text(encoding="utf-8")
chunk = rt.eval("function(s, n) return load(s, n) end")(src, "@test/run.lua")
if chunk is None:
    print("failed to compile test/run.lua")
    sys.exit(1)

try:
    chunk()
except lupa.LuaError as exc:
    if "__EXIT__" not in str(exc):
        print("\nLUA ERROR:", exc)
        sys.exit(2)

code = rt.eval("_EXIT")
sys.exit(int(code) if code is not None else 0)

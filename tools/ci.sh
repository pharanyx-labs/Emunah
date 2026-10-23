#!/bin/sh
# One gate for a change: every first-party Lua file must compile as Lua 5.1,
# then the suite must pass. Mudlet ships Lua 5.1. `lua` on a developer machine
# and on GitHub's runners is a later version, and it accepts syntax this
# codebase cannot run. Invoke this, or `lua5.1 test/run.lua`, never plain `lua`.
set -eu

cd "$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

if ! command -v lua5.1 >/dev/null 2>&1; then
   echo "lua5.1 is required. The plain lua binary is not Lua 5.1." >&2
   exit 1
fi

echo "interpreter: $(lua5.1 -v 2>&1)"

# These names parse under 5.1 and then fail inside Mudlet. goto, //, and the
# bitwise operators are syntax errors there, so the compile below catches them.
if grep -RInE --include='*.lua' 'math\.type\b|table\.move\b|math\.tointeger\b' src test tools; then
   echo "Lua 5.3 function used. Mudlet runs Lua 5.1." >&2
   exit 1
fi

list=$(mktemp)
trap 'rm -f "$list"' EXIT
find src test tools -name '*.lua' -print | sort > "$list"
if [ ! -s "$list" ]; then
   echo "no Lua files found under src, test, or tools" >&2
   exit 1
fi

n=0
while IFS= read -r file; do
   n=$((n + 1))
   # A filename after -e would be executed. The path goes in the environment,
   # and loadstring is the 5.1 compiler (load does not compile source).
   LUA_FILE=$file lua5.1 -e '
      local path = assert(os.getenv("LUA_FILE"), "LUA_FILE unset")
      local handle = assert(io.open(path, "r"))
      local src = handle:read("*a")
      handle:close()
      local chunk, err = loadstring(src, "@" .. path)
      if not chunk then
         io.stderr:write(tostring(err), "\n")
         os.exit(1)
      end
   ' || exit 1
done < "$list"

echo "compiled $n Lua files as 5.1"
exec lua5.1 test/run.lua

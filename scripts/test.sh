#!/bin/bash
# Runs the test suite. Use this instead of plain `swift test`: with only the
# Command Line Tools installed (no Xcode), Swift Testing needs the CLT's
# Testing.framework on the framework search path and the runtime rpath.
# Extra arguments go to `swift test` (e.g. `scripts/test.sh --filter Label`).
set -euo pipefail
cd "$(dirname "$0")/.."

F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

flags=()
if [ -d "$F/Testing.framework" ]; then
  flags=(
    -Xswiftc -F -Xswiftc "$F"
    -Xlinker -F -Xlinker "$F"
    -Xlinker -rpath -Xlinker "$F"
    -Xlinker -rpath -Xlinker "$L"
  )
fi

exec swift test ${flags[@]+"${flags[@]}"} "$@"

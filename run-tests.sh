#!/bin/bash
# Runs the test suite.
#
# With only Command Line Tools installed (no full Xcode), Swift Testing's
# framework and its support dylib live in non-default locations, so we pass
# the search paths explicitly. With full Xcode installed, a plain
# `swift test` works too.
set -euo pipefail
cd "$(dirname "$0")"

CLT=/Library/Developer/CommandLineTools
FWK="$CLT/Library/Developer/Frameworks"
INTEROP="$CLT/Library/Developer/usr/lib"

exec swift test \
    -Xswiftc -F -Xswiftc "$FWK" \
    -Xlinker -F"$FWK" \
    -Xlinker -rpath -Xlinker "$FWK" \
    -Xlinker -rpath -Xlinker "$INTEROP" \
    "$@"

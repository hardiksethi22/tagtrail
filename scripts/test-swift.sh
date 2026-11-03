#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
mkdir -p .build

# Select a compatible macOS SDK when building with CLT-only toolchain.
# shellcheck source=scripts/sdk-env.sh
source "$ROOT/scripts/sdk-env.sh"
PROBE_LOG="$(mktemp "$ROOT/.build/xctest-probe.XXXXXX")"
trap 'rm -f "$PROBE_LOG"' EXIT

if printf 'import XCTest\n' | swiftc -typecheck - >"$PROBE_LOG" 2>&1; then
    swift test
elif grep -Fq "no such module 'XCTest'" "$PROBE_LOG"; then
    echo "note: XCTest is unavailable in this toolchain; running CoreChecks instead. XCTest has not passed." >&2
    swift run CoreChecks
    "$ROOT/scripts/test-app-services.sh"
else
    cat "$PROBE_LOG" >&2
    echo "error: XCTest availability probe failed for a reason other than missing XCTest." >&2
    exit 1
fi

"$ROOT/scripts/build-app.sh" debug
if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 (standard library only) is required for bounded native app smoke checks." >&2
    exit 1
fi
python3 "$ROOT/scripts/smoke_app.py" "$ROOT/.build/TagTrail-Dev.app/Contents/MacOS/TagTrail"

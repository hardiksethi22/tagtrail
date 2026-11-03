#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

# Select a compatible macOS SDK when building with CLT-only toolchain.
# shellcheck source=scripts/sdk-env.sh
source "$ROOT/scripts/sdk-env.sh"

# release: .build/TagTrail.app (packaging input; worker is bundled by package.sh)
# debug:   .build/TagTrail-Dev.app (DEBUG app resolves worker/.venv/bin/python -m worker)
CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
    release) APP="$ROOT/.build/TagTrail.app" ;;
    debug) APP="$ROOT/.build/TagTrail-Dev.app" ;;
    *) echo "usage: build-app.sh [release|debug]" >&2; exit 2 ;;
esac

swift build --configuration "$CONFIGURATION" --product TagTrail
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
EXECUTABLE="$BIN_DIR/TagTrail"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: SwiftPM did not produce executable: $EXECUTABLE" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ThirdPartyNotices"
cp "$EXECUTABLE" "$APP/Contents/MacOS/TagTrail"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/worker/fixtures/protocol-v1.json" "$APP/Contents/Resources/protocol-v1.json"
cp "$ROOT/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/ThirdPartyNotices/THIRD_PARTY_NOTICES.txt"
chmod 755 "$APP/Contents/MacOS/TagTrail"
echo "Built local $CONFIGURATION app bundle: $APP"

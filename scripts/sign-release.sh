#!/bin/bash
set -euo pipefail

APP="${1:?usage: DEVELOPER_ID_IDENTITY='Developer ID Application: ...' NOTARY_PROFILE=name sign-release.sh APP_BUNDLE}"
IDENTITY="${DEVELOPER_ID_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-}"
if [[ ! -d "$APP/Contents" ]]; then
    echo "error: not an application bundle: $APP" >&2
    exit 1
fi
if [[ -f "$APP/Contents/Resources/DevelopmentPythonOverride.txt" || -f "$APP/Contents/Resources/DevelopmentBuildOverride.txt" ]]; then
    echo "error: this app was built with a development-only override and is not release-eligible." >&2
    exit 1
fi
if [[ -z "$IDENTITY" || -z "$PROFILE" ]]; then
    echo "error: set DEVELOPER_ID_IDENTITY and a preconfigured NOTARY_PROFILE; no signing credentials are stored by this script." >&2
    exit 1
fi
for command in codesign security xcrun ditto file spctl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "error: $command is required for Developer ID signing and notarization." >&2
        exit 1
    fi
done
if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 (standard library only) is required to validate the bundled worker protocol." >&2
    exit 1
fi
if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$IDENTITY\""; then
    echo "error: the requested Developer ID Application identity is not available in the login keychain." >&2
    exit 1
fi
xcrun notarytool --help >/dev/null 2>&1 || {
    echo "error: xcrun notarytool is unavailable; install full Xcode command line tools." >&2
    exit 1
}

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKER="$APP/Contents/Resources/worker/tagtrail-worker"
if [[ ! -x "$WORKER" ]]; then
    echo "error: bundled worker is missing: $WORKER" >&2
    exit 1
fi
REQUEST_ID="release-preflight-$(date +%s)"
DOCTOR_OUTPUT="$(printf '{"protocol_version":1,"request_id":"%s","command":"doctor","timeout_ms":45000}\n' "$REQUEST_ID" | "$WORKER")"
printf '%s\n' "$DOCTOR_OUTPUT" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
result = [event for event in events if event.get("event") == "result"]
if len(result) != 1 or result[0].get("payload", {}).get("protocol_version") != 1:
    raise SystemExit("bundled worker doctor preflight failed")
if not result[0]["payload"].get("python", "").startswith("3.12."):
    raise SystemExit("Developer ID release packages require the bundled Python 3.12 runtime")
'
while IFS= read -r -d '' path; do
    if file -b "$path" | grep -q 'Mach-O'; then
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$path"
    fi
done < <(find "$APP/Contents" -type f -print0)
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ARCHIVE_DIR="$ROOT/.build/notarization"
mkdir -p "$ARCHIVE_DIR"
ARCHIVE="$ARCHIVE_DIR/TagTrail-$(uname -m).zip"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Developer ID signing and notarization verified: $APP"

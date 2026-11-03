#!/bin/bash
set -euo pipefail

APP="${1:?usage: sign-local.sh APP_BUNDLE}"
if [[ ! -d "$APP/Contents" ]]; then
    echo "error: not an application bundle: $APP" >&2
    exit 1
fi
if ! command -v codesign >/dev/null 2>&1; then
    echo "error: codesign is required for local ad-hoc signing." >&2
    exit 1
fi

sign_macho_files() {
    local directory="$1" path
    [[ -d "$directory" ]] || return 0
    while IFS= read -r -d '' path; do
        if file -b "$path" | grep -q 'Mach-O'; then
            codesign --force --sign - --timestamp=none "$path"
        fi
    done < <(find "$directory" -type f -print0)
}

sign_macho_files "$APP/Contents/Resources/worker"
sign_macho_files "$APP/Contents/Frameworks"
sign_macho_files "$APP/Contents/MacOS"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
echo "Ad-hoc signed for local development only: $APP"

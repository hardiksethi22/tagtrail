#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
XCODEGEN="${XCODEGEN:-$(command -v xcodegen || true)}"
[[ -n "$XCODEGEN" || ! -x /opt/homebrew/bin/xcodegen ]] || XCODEGEN=/opt/homebrew/bin/xcodegen

if [[ -z "$XCODEGEN" ]]; then
    echo "error: XcodeGen 2.46.0 is required; install it and rerun make project." >&2
    exit 1
fi

version="$("$XCODEGEN" --version | sed -E 's/^Version: //')"
if [[ "$version" != "2.46.0" ]]; then
    echo "error: expected XcodeGen 2.46.0, found $version ($XCODEGEN)." >&2
    exit 1
fi

cd "$ROOT"
"$XCODEGEN" generate --spec project.yml --project "$ROOT"

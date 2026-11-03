#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$ROOT/.build/TagTrail-Dev.app"
if [[ ! -d "$APP" ]]; then
    echo "error: app bundle is missing; run make build first." >&2
    exit 1
fi

# Demo is an ephemeral launch flag, not a persisted preference. Clearing the
# stored key keeps `make run` (live mode) from silently booting into demo.
defaults delete app.tagtrail.desktop TagTrail.demoMode 2>/dev/null || true

open -n "$APP" --args -TagTrail.demoMode YES

#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$ROOT/.build/TagTrail-Dev.app"
if [[ ! -d "$APP" ]]; then
    echo "error: app bundle is missing; run make build first." >&2
    exit 1
fi

# Launch in live (Google) mode. A previous demo run persists
# TagTrail.demoMode in UserDefaults, so clear it before launching.
defaults delete app.tagtrail.desktop TagTrail.demoMode 2>/dev/null || true

open -n "$APP"

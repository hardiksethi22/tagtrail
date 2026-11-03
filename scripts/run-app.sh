#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$ROOT/.build/TagTrail-Dev.app"
if [[ ! -d "$APP" ]]; then
    echo "error: app bundle is missing; run make build first." >&2
    exit 1
fi
open -n "$APP"

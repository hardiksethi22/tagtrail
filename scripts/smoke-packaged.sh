#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ARCH="$(uname -m)"
APP="$ROOT/dist/TagTrail-$ARCH/TagTrail.app"
if [[ ! -d "$APP" ]]; then
    echo "error: packaged app not found: $APP; run make package first." >&2
    exit 1
fi
PYTHON="${PYTHON:-$(command -v python3 || true)}"
if [[ -z "$PYTHON" ]]; then
    echo "error: python3 is required to validate the smoke-test protocol output." >&2
    exit 1
fi
exec "$PYTHON" "$ROOT/scripts/smoke-packaged.py" "$APP"

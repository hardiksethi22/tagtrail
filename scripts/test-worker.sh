#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VENV="${WORKER_VENV:-$ROOT/worker/.venv}"
if [[ ! -x "$VENV/bin/python" ]]; then
    echo "error: worker environment is missing; run make bootstrap first." >&2
    exit 1
fi
if [[ ! -d "$ROOT/worker/tests" ]]; then
    echo "error: worker/tests is missing; Python worker tests are required." >&2
    exit 1
fi
if [[ -z "${TAGTRAIL_WORKER_BINARY:-}" ]]; then
    ARCH="$(uname -m)"
    PACKAGED_WORKER="$ROOT/dist/TagTrail-$ARCH/TagTrail.app/Contents/Resources/worker/tagtrail-worker"
    if [[ -x "$PACKAGED_WORKER" ]]; then
        TAGTRAIL_WORKER_BINARY="$PACKAGED_WORKER"
        export TAGTRAIL_WORKER_BINARY
    fi
fi
cd "$ROOT"
"$VENV/bin/python" -m unittest discover -s worker/tests -v

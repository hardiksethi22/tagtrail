#!/bin/bash
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
status=0

echo "== Swift tests =="
if ! "$ROOT/scripts/test-swift.sh"; then
    status=1
fi

echo "== Worker tests =="
if ! "$ROOT/scripts/test-worker.sh"; then
    status=1
fi

exit "$status"

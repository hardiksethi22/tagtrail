#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

REQUIRED_SWIFT="6.4.2"
REQUIRED_XCODEGEN="2.46.0"
REQUIRED_UV="0.13.7"
REQUIRED_PYTHON="3.12"
status=0

fail() {
    echo "error: $*" >&2
    status=1
}

[[ "$(uname -s)" == "Darwin" ]] || { echo "error: bootstrap is supported on macOS only." >&2; exit 1; }

if command -v swift >/dev/null 2>&1; then
    swift_version="$(swift --version 2>&1 | sed -nE 's/.*Apple Swift version ([0-9.]+).*/\1/p' | head -1)"
    [[ "$swift_version" == "$REQUIRED_SWIFT" ]] || fail "Swift $REQUIRED_SWIFT is required; found ${swift_version:-unknown}."
else
    fail "Swift $REQUIRED_SWIFT is required (Command Line Tools or Xcode)."
fi
xcode-select -p >/dev/null 2>&1 || fail "no Apple developer directory is selected (xcode-select -p)."

XCODEGEN="${XCODEGEN:-$(command -v xcodegen || true)}"
[[ -n "$XCODEGEN" || ! -x /opt/homebrew/bin/xcodegen ]] || XCODEGEN=/opt/homebrew/bin/xcodegen
if [[ -z "$XCODEGEN" ]]; then
    fail "XcodeGen $REQUIRED_XCODEGEN is required."
else
    xcodegen_version="$("$XCODEGEN" --version | sed -E 's/^Version: //')"
    [[ "$xcodegen_version" == "$REQUIRED_XCODEGEN" ]] || fail "XcodeGen $REQUIRED_XCODEGEN is required; found $xcodegen_version at $XCODEGEN."
fi

UV="${UV:-$(command -v uv || true)}"
[[ -n "$UV" || ! -x "$HOME/.local/bin/uv" ]] || UV="$HOME/.local/bin/uv"
if [[ -z "$UV" ]]; then
    fail "uv $REQUIRED_UV is required; install it for this user."
else
    uv_version="$("$UV" --version | awk '{print $2}')"
    [[ "$uv_version" == "$REQUIRED_UV" ]] || fail "uv $REQUIRED_UV is required; found $uv_version at $UV."
fi

if [[ "$status" -ne 0 ]]; then
    echo "Bootstrap prerequisites are missing or mismatched; no project dependencies were changed." >&2
    exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "note: full Xcode is unavailable; xcodebuild and XCTest gates cannot run. make test uses CoreChecks and reports that XCTest did not run." >&2
fi
export XCODEGEN
"$ROOT/scripts/generate-project.sh"

# Native TLS uses the macOS trust store; certificate verification stays enabled.
export UV_NATIVE_TLS=true
export UV_PYTHON_INSTALL_DIR="$ROOT/worker/.python"
export UV_CACHE_DIR="$ROOT/worker/.uv-cache"

VENV="$ROOT/worker/.venv"
if [[ ! -x "$VENV/bin/python" ]]; then
    if ! PYTHON="$("$UV" python find --python-preference only-managed "$REQUIRED_PYTHON" 2>/dev/null)"; then
        "$UV" python install --no-bin "$REQUIRED_PYTHON"
        PYTHON="$("$UV" python find --python-preference only-managed "$REQUIRED_PYTHON")"
    fi
    case "$PYTHON" in
        "$ROOT/worker/.python/"*) ;;
        *) echo "error: uv selected non-project Python: $PYTHON" >&2; exit 1 ;;
    esac
    "$UV" venv --python "$PYTHON" "$VENV"
fi

python_version="$("$VENV/bin/python" -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')"
base_prefix="$("$VENV/bin/python" -c 'import os, sys; print(os.path.realpath(sys.base_prefix))')"
if [[ "$python_version" != "$REQUIRED_PYTHON" ]]; then
    echo "error: worker/.venv uses Python $python_version; remove it and rerun make bootstrap for Python $REQUIRED_PYTHON." >&2
    exit 1
fi
case "$base_prefix/" in
    "$ROOT/"*) ;;
    *) echo "error: worker/.venv uses non-project Python at $base_prefix; remove it and rerun make bootstrap." >&2; exit 1 ;;
esac
"$UV" pip sync --python "$VENV/bin/python" worker/requirements.lock

echo "Bootstrap complete: Swift $REQUIRED_SWIFT, XcodeGen $REQUIRED_XCODEGEN, uv $REQUIRED_UV, project-local Python $python_version."

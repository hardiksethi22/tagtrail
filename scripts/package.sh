#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
VENV="$ROOT/worker/.venv"
DEV_PYTHON=0
if [[ -n "${TAGTRAIL_DEV_WORKER_VENV:-}" ]]; then
    DEV_VENV="$TAGTRAIL_DEV_WORKER_VENV"
    [[ "$DEV_VENV" = /* ]] || DEV_VENV="$ROOT/$DEV_VENV"
    if [[ ! -d "$DEV_VENV" ]]; then
        echo "error: development worker environment does not exist: $DEV_VENV" >&2
        exit 1
    fi
    VENV="$(cd -- "$DEV_VENV" && pwd -P)"
    case "$VENV/" in
        "$ROOT/"*) ;;
        *) echo "error: development worker environment must be inside the project." >&2; exit 1 ;;
    esac
    DEV_PYTHON=1
    echo "warning: explicitly overriding the default worker environment: $VENV" >&2
fi
PYINSTALLER="$VENV/bin/pyinstaller"
if [[ ! -x "$PYINSTALLER" ]]; then
    echo "error: packaged worker dependencies are missing in $VENV; run make bootstrap first." >&2
    exit 1
fi
PYTHON_VERSION="$("$VENV/bin/python" -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')"
if [[ "$DEV_PYTHON" -eq 0 && "$PYTHON_VERSION" != "3.12" ]]; then
    echo "error: packaging requires Python 3.12; found $PYTHON_VERSION. Run make bootstrap." >&2
    exit 1
fi
if [[ ! -f "$ROOT/worker/TagTrailWorker.spec" ]]; then
    echo "error: worker/TagTrailWorker.spec is missing." >&2
    exit 1
fi

DEV_BUILD=0
if [[ "${TAGTRAIL_DEV_SKIP_APP_BUILD:-0}" == "1" ]]; then
    DEV_BUILD=1
    if [[ ! -x "$ROOT/.build/TagTrail.app/Contents/MacOS/TagTrail" ]]; then
        echo "error: no existing .build/TagTrail.app executable is available for the explicit build-skip override." >&2
        exit 1
    fi
    echo "warning: reusing the existing app executable by explicit development-only override." >&2
else
    "$ROOT/scripts/build-app.sh" release
fi
ARCH="$(uname -m)"
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "error: unsupported host architecture: $ARCH" >&2; exit 1 ;;
esac

WORK="$ROOT/.build/pyinstaller"
DIST="$WORK/dist"
rm -rf "$WORK"
mkdir -p "$WORK"
PYINSTALLER_CONFIG_DIR="$ROOT/worker/.pyinstaller-cache" "$PYINSTALLER" --noconfirm --clean --log-level WARN --distpath "$DIST" --workpath "$WORK/work" worker/TagTrailWorker.spec

WORKER_DIST="$DIST/TagTrailWorker"
if [[ ! -x "$WORKER_DIST/TagTrailWorker" ]]; then
    echo "error: expected PyInstaller one-directory executable is missing: $WORKER_DIST/TagTrailWorker" >&2
    exit 1
fi

APP="$ROOT/dist/TagTrail-$ARCH/TagTrail.app"
rm -rf "$ROOT/dist/TagTrail-$ARCH"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/worker"
cp "$ROOT/.build/TagTrail.app/Contents/MacOS/TagTrail" "$APP/Contents/MacOS/TagTrail"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/.build/TagTrail.app/Contents/Resources/protocol-v1.json" "$APP/Contents/Resources/protocol-v1.json"
cp -R "$WORKER_DIST/." "$APP/Contents/Resources/worker/"
mv "$APP/Contents/Resources/worker/TagTrailWorker" "$APP/Contents/Resources/worker/tagtrail-worker"
ln -s tagtrail-worker "$APP/Contents/Resources/worker/TagTrailWorker"
if [[ "$DEV_PYTHON" -eq 1 ]]; then
    printf 'Development-only Python environment override; not eligible for release signing.\n' \
        > "$APP/Contents/Resources/DevelopmentPythonOverride.txt"
fi
if [[ "$DEV_BUILD" -eq 1 ]]; then
    printf 'Development-only app build skip override; not eligible for release signing.\n' \
        > "$APP/Contents/Resources/DevelopmentBuildOverride.txt"
fi
cp "$ROOT/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/ThirdPartyNotices.txt"
"$VENV/bin/python" "$ROOT/scripts/collect-third-party-notices.py" "$VENV/bin/python" "$APP/Contents/Resources/ThirdPartyNotices"
cp "$ROOT/vendor/GoogleFindMyTools/LICENSE" "$APP/Contents/Resources/ThirdPartyNotices/GoogleFindMyTools-LICENSE.txt"
chmod 755 "$APP/Contents/Resources/worker/tagtrail-worker"
"$VENV/bin/python" "$ROOT/scripts/check-macos-minimum.py" "$APP"
"$ROOT/scripts/sign-local.sh" "$APP"
echo "Packaged local ad-hoc-signed $ARCH app: $APP"
echo "This is not a Developer ID-signed or notarized release."
if [[ "$DEV_PYTHON" -eq 1 ]]; then
    echo "This package used an explicit development-only Python $PYTHON_VERSION override and is not release-eligible."
fi
if [[ "$DEV_BUILD" -eq 1 ]]; then
    echo "This package reused an existing app executable and is not release-eligible."
fi

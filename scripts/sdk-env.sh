#!/bin/bash
# sdk-env.sh — Selects a compatible macOS SDK for Command-Line-Tools-only builds.
#
# macOS 27+ SDKs declare @State in SwiftUICore as an external macro backed by
# SwiftUIMacros.dylib, which ships only inside Xcode.app.  When building with
# the stand-alone Command Line Tools we pin SDKROOT to MacOSX26.5.sdk, the
# newest SDK whose SwiftUICore still uses the traditional property-wrapper path.
#
# Usage: source scripts/sdk-env.sh   (sets SDKROOT in the calling shell)
#    or: eval "$(scripts/sdk-env.sh)" (from a non-sourcing context)

CLT_SDKS="/Library/Developer/CommandLineTools/SDKs"
PREFERRED_SDK="$CLT_SDKS/MacOSX26.5.sdk"

# If SDKROOT is already set (Xcode / CI), leave it alone.
if [[ -n "${SDKROOT:-}" ]]; then
    return 0 2>/dev/null || true
fi

# If the preferred SDK exists, use it.
if [[ -d "$PREFERRED_SDK" ]]; then
    export SDKROOT="$PREFERRED_SDK"
    return 0 2>/dev/null || true
fi

# Fallback: pick the highest MacOSX2*.sdk that does NOT contain StateMacro.
for sdk_path in $(ls -d "$CLT_SDKS"/MacOSX*.sdk 2>/dev/null | sort -rV); do
    iface="$sdk_path/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
    if [[ -f "$iface" ]] && ! grep -q "StateMacro" "$iface" 2>/dev/null; then
        export SDKROOT="$sdk_path"
        return 0 2>/dev/null || true
    fi
done

# No compatible SDK found — warn but do not override SDKROOT.
echo "warning: No SwiftUIMacros-free SDK found. Build may fail with CLT-only toolchain." >&2

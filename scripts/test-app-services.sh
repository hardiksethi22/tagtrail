#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

# Select compatible SDK if needed
source "$ROOT/scripts/sdk-env.sh"

BUILD_DIR="$(swift build --show-bin-path)"
OBJ_DIR="$BUILD_DIR/../tmp_appservice_checks"
mkdir -p "$OBJ_DIR"

CSQLITE_FLAGS=(-I "$ROOT/Sources/CSQLite" -Xcc -fmodule-map-file="$ROOT/Sources/CSQLite/module.modulemap")

# 1. Compile TagTrailCore as its own static library module
swiftc -emit-library -emit-module -static \
    Sources/TagTrailCore/Database.swift \
    Sources/TagTrailCore/Display.swift \
    Sources/TagTrailCore/Models.swift \
    "${CSQLITE_FLAGS[@]}" \
    -module-name TagTrailCore \
    -emit-module-path "$OBJ_DIR/TagTrailCore.swiftmodule" \
    -o "$OBJ_DIR/libTagTrailCore.a" \
    -target arm64-apple-macos14.0 \
    -sdk "$SDKROOT"

# 2. Compile TagTrail/App service sources as module TagTrail (imports TagTrailCore)
# Excludes TagTrailApp.swift which carries its own @main TagTrailApp
TAGTRAIL_SOURCES=(
  App/AppModel.swift
  App/AppSmokeRunner.swift
  App/Services/Clock.swift
  App/Services/ConnectivityMonitor.swift
  App/Services/DatabaseOpener.swift
  App/Services/DemoProvider.swift
  App/Services/GeocodingService.swift
  App/Services/GoogleTrackerProvider.swift
  App/Services/KeychainCredentialStore.swift
  App/Services/ObservationHistory.swift
  App/Services/PollCoordinator.swift
  App/Services/ProtocolFixtureChecks.swift
  App/Services/SchedulingPolicy.swift
  App/Services/TrackerProvider.swift
  App/Services/WorkerProcessClient.swift
)

swiftc -emit-library -emit-module -static \
    "${TAGTRAIL_SOURCES[@]}" \
    "${CSQLITE_FLAGS[@]}" \
    -I "$OBJ_DIR" \
    -module-name TagTrail \
    -emit-module-path "$OBJ_DIR/TagTrail.swiftmodule" \
    -o "$OBJ_DIR/libTagTrail.a" \
    -enable-testing \
    -target arm64-apple-macos14.0 \
    -sdk "$SDKROOT"

# 3. Compile the portable service-test harness (imports both modules)
# Under direct swiftc (not SwiftPM), SWIFT_PACKAGE is undefined, so
# PortableTestRunner's @main enum AppServiceChecks is the entry point —
# no test_entry_point.o / Testing framework needed.
swiftc -o "$BUILD_DIR/TagTrailAppServiceChecks" \
    AppTests/PortableTestRunner.swift \
    AppTests/ServiceTests.swift \
    "$OBJ_DIR/libTagTrailCore.a" \
    "$OBJ_DIR/libTagTrail.a" \
    -I "$OBJ_DIR" \
    -I "$ROOT/Sources/CSQLite" \
    -Xcc -fmodule-map-file="$ROOT/Sources/CSQLite/module.modulemap" \
    -lsqlite3 \
    -target arm64-apple-macos14.0 \
    -sdk "$SDKROOT"

"$BUILD_DIR/TagTrailAppServiceChecks"

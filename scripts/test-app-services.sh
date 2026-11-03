#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

# CLT can compile the conditional test harness but cannot link XCTest.
swift build --target TagTrailAppTests
BUILD_DIR="$(swift build --show-bin-path)"
swiftc -o "$BUILD_DIR/TagTrailAppServiceChecks" \
    "$BUILD_DIR"/TagTrailAppTests.build/*.swift.o \
    "$BUILD_DIR"/TagTrailCore.build/*.swift.o \
    "$BUILD_DIR"/TagTrail.build/{Clock,DemoProvider,GeocodingService,KeychainCredentialStore,ObservationHistory,PollCoordinator,ProtocolFixtureChecks,TrackerProvider,WorkerProcessClient}.swift.o \
    -lsqlite3
"$BUILD_DIR/TagTrailAppServiceChecks"

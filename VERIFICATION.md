# Verification evidence

## Environment observed

Inspected 2026-11-03:

| Item | Observed |
|---|---|
| Host | macOS 26.7, build 25G229 |
| Architecture | arm64 |
| Developer directory | `/Library/Developer/CommandLineTools` |
| Swift | Apple Swift 6.2.3 |
| SDK | macOS 26.2 |
| XcodeGen | 2.45.4 |
| uv | 0.8.3 |
| Initial Python | shell Python 3.13.3; Homebrew Python 3.14.4 |
| Pinned GoogleFindMyTools | `660be5395702ff7f1a6174f4ec4c865a57c7b527` |

There is no full Xcode selected. `xcodebuild -version` failed explicitly:
the tool requires Xcode, but the selected directory is a Command Line Tools
instance. Neither `import XCTest` nor `import Testing` is available in that
toolchain. Those failures are recorded, not counted as passing tests.

## Native core commands executed

`swift build --target TagTrailCore` succeeded.

`swift build --target TagTrailCoreTests` failed because XCTest is unavailable.
The repository retains XCTest tests for a full Xcode environment.

`swift run CoreChecks` succeeded using actual system SQLite and production
core code. It exercised fresh creation, mode 0600 permissions, v1-to-v2
migration, rejection of newer schema, foreign-key rollback, reopen persistence,
idempotent fingerprints, distinct same-time observations and report IDs,
out-of-order ingestion, semantic-only data, zero coordinates, missing time and
accuracy, invalid range/nonfinite values, indexed pagination, newest retrieval,
raw/simplified grouping, Haversine distance, route gap segmentation, CSV
Unicode/escaping/formula protection, persisted settings, geocode no-result
cache, explicit semantic mappings, retention and scoped deletion.

Measured on the above arm64 host in a debug build with synthetic observations:

| Dataset | Operation | Measured result |
|---|---|---|
| 10,000 observations | transaction ingestion | 0.451887458 seconds |
| 10,000 observations | indexed filtered 100-row query | 0.000481333 seconds |

The query assertion requires 100 rows and elapsed time below two seconds.
These numbers do not establish UI responsiveness, memory consumption, startup
time, macOS 14 performance, or Intel performance.

## Live-account evidence

No real account credentials, private sightings, or physical trackers were
provided. No live authentication, account device discovery, provider report
retrieval, or geographic decryption was performed. Integration fixture tests
must not be described as real-account verification.

## Required manual / environment-gated checks

Full Xcode build and XCTest/UI-test execution; keyboard and VoiceOver usability;
permission-denied and locked real Keychain behavior; live browser challenges;
authorized account device discovery and real response/decryption; offline map
tile usability; sleep/wake behavior over real sleep; macOS 14 runtime coverage;
Intel runtime and binary coverage; Developer ID signing and notarization.

Application, adapter, and packaging results are recorded separately below as
the implementation checks finish. No gate is inferred from another gate.

## Python worker and integration checks

The integration agent executed 28 passing tests with project-local Python
3.12.11 arm64, including pinned-upstream adapters, synthetic real cryptographic
decoding, actual subprocess NDJSON, credential validation/redaction, bounded
cancellation, and relocated bundled-worker checks:

```sh
TAGTRAIL_WORKER_BINARY=worker/dist/TagTrailWorker/TagTrailWorker \
  worker/.venv/bin/python -m unittest discover -s worker/tests -q
```

The packaging agent also executed the same 28 checks against the final
app-bundled renamed executable
`dist/TagTrail-arm64/TagTrail.app/Contents/Resources/worker/tagtrail-worker`.
Worker `doctor` checks actual upstream imports and succeeded after relocation
to a directory with spaces/Unicode, without an external Python or checkout.
Empty imported credentials were rejected rather than accepted.

The final runtime is managed Python 3.12.11. An initial host Python 3.13
bundle was rejected because its libpython required macOS 26.3. The replacement
bundle's audited native components have deployment targets at or below macOS
11. This is binary target evidence, not execution on macOS 14.

The parent reran `swift run CoreChecks` and the 28-test worker suite against
the actual app-bundled executable: both passed; Python elapsed time was
22.930 seconds. The packaging agent audited 59 bundled Mach-O files against
the macOS 14 maximum deployment target and verified ad-hoc signing. This is
not Developer ID signing or notarization.

The inspected adapter uses actual upstream FCM, action construction,
generated protobufs, identity-key CBC/GCM, own-report GCM, and foreign-report
SECP160r1/HKDF/AES-EAX paths. See `UPSTREAM_INTEGRATION.md` for exact symbols,
dependency lock, credential lifecycle, unsupported formats, and the narrow
memory-cache patch. No real-account verification is implied.

## Native transport progress

The native integration agent reports 15 service/parser checks passing,
covering credential-update shapes, Unicode, malformed/empty output, EOF,
version and request-ID mismatch, post-terminal events, and error-code parsing.
Additional checks cover newest-page/full raw export pagination and semantic
mapping persistence without changing raw evidence.
The actual app's `--smoke-demo` passed offline worker `doctor` and isolated
demo database ingestion/idempotence. These service checks are not a claim of
Xcode UI testing or manual interface verification. Final combined make/package
checks remain separate.
The native agent also reports a successful release build and expanded
demo smoke assertions for persisted cooldown, successful old/no-new reports
not changing sighting freshness, and only the chosen first tracker enabled.
Final combined packaging evidence must still confirm the latest source.

The parent's initial combined `make test` run did **not** pass: core checks
and 28 worker tests passed, but the portable native service-test link failed
with unresolved `ObservationHistory` symbols. This result requires a corrected
combined rerun; the earlier individual native checks do not override it.

The Python adapter now directly consumes canonical shared protocol fixtures
at `worker/fixtures/protocol-v1.json` (also consumed by Swift and bundled smoke).
Python additionally consumes `AppTests/protocol-v1.json` as a sequence fixture.
The new targeted fixture test passed,
bringing the worker suite to 29 tests pending a full rerun.

## Final combined results (serial, arm64, macOS 26.7, Command Line Tools)

| Command | Result |
|---|---|
| `make test` | PASS: CoreChecks; 15 native service checks; app `--self-test`; app `--smoke-demo`; 29 worker tests |
| `make package` | PASS: arm64 ad-hoc-signed `dist/TagTrail-arm64/TagTrail.app` (68 MB); 59 Mach-O files have deployment target <= 14.0 |
| `make smoke-packaged` | PASS: relocated copy in a path with spaces; bundled worker `doctor` (Python 3.12.11, upstream `660be539...`); empty credentials rejected as authentication-required; packaged `--self-test` and `--smoke-demo`; app launch |

Native checks added in the final pass: a structurally malformed sighting no
longer aborts a poll result (valid rows are kept and the malformed entry counts
as rejected), and cancelling a request queued behind an active worker operation
returns promptly without waiting for it.

An earlier packaged-smoke failure came from a stale protocol-fixture copy in
`scripts/build-app.sh`; it now copies `worker/fixtures/protocol-v1.json`.

## Gate status

- **Application gate:** PASSED for fixture-backed launch, persistence, services and smoke. No rendered-UI, VoiceOver, keyboard-navigation or 10,000-record UI responsiveness review was performed.
- **Integration gate:** PARTIAL. Adapter, crypto-format, transport and credential-validation tests pass; **no live Google authentication, device discovery or real report retrieval has been verified**.
- **Distribution gate:** PASSED for a relocated arm64 ad-hoc-signed package without developer Python or checkout. Not Developer ID signed or notarized; macOS 14 runtime, x86_64 and universal builds unverified.

## Not verified (required follow-up on suitable hardware/accounts)

Full Xcode build and XCTest (`xcodebuild` and XCTest are unavailable with Command Line Tools); real Keychain save/refresh and locked/denied behavior; live reverse-geocoder failure/retry; real sleep/wake and connectivity notifications; rendered interaction, accessibility and large-history UI performance; live browser authentication; Developer ID signing and notarization.

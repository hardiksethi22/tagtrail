# TagTrail

A native macOS menu bar recorder for available sightings from authorized
Google Find Hub trackers. SwiftUI/AppKit, MapKit, Swift-owned SQLite, macOS
Keychain, and a pinned Python integration worker. macOS 14 is the deployment
target; consult `VERIFICATION.md` for tested OS/architecture coverage.

This repository was created under `mcps/TagTrail`, preserving sibling projects.

## Commands

```sh
cd TagTrail
make bootstrap
make test
make build
make run-demo
make run
make package
make smoke-packaged
```

Bootstrap diagnoses prerequisites and prepares project-local tools and the
generated Xcode project. Build produces a local native application. Packaging
freezes and bundles the worker; packaged smoke checks are separate from source
tests. Full Xcode is necessary for `xcodebuild` and Xcode UI tests; Command Line
Tools support the SwiftPM fallback. No root access or system security changes
are required. The scripts identify actual artifact paths and missing tools.

Use **Try Demo** to explore synthetic, clock-relative sightings without a
Google account. Demo is visibly labeled and separate from live history. Map
tiles can require network access even though fixture history is local.

## Live connection

Read `UPSTREAM_INTEGRATION.md` before connecting. Use only an authorized
account and devices. The upstream-supported browser procedure and export
format are not generic OAuth and may need browser prerequisites and account
challenges. Do not paste credentials into a conversation.

Import a complete upstream credential export using the app's native file
picker. The parent validates the bundle and persists it to Keychain. The
original import file remains sensitive and is not automatically deleted.
The inspected upstream cache/export is `Auth/secrets.json` in the user's
GoogleFindMyTools checkout. A complete import includes `username`, `aas_token`,
an `owner_key` or `shared_key`, and full `fcm_credentials`: GCM registration,
matching P256 ECE keys, registration token, and installation/refresh tokens.
A lone access token is insufficient. Exact validation rules are documented
in `worker/README.md`.

The explicit browser helper requires installed visible Chrome and a matching,
user-supplied ChromeDriver; it does not download a driver or replace real
account/2FA challenges. Its `authenticate` request uses a five-minute deadline
and an explicit `browser_helper` configuration. See **Explicit local browser
helper** in `worker/README.md` for the exact local invocation. Do not run it
with an ordinary shell transcript: credential-update stdout is secret-bearing
and must be captured by a trusted parent for Keychain persistence, not logged.
The helper keeps one permission-restricted sign-in profile under its data
directory so the Google session is remembered between attempts, reuses the
user's existing browser session when macOS privacy settings allow, and is not
a disk-free authentication flow. Delete the `browser-artifacts` folder there
to sign the helper out.

Select the first tracker to enable scheduled collection; other devices require
explicit enabling. Live discovery and decryption remain unverified until
tested with an authorized real account.

## History and interpretation

The default window is 24 hours and retention 90 days. Auto-poll targets are
Off, 5, 15, 30, or 60 minutes, with account-level pacing. The application must
be running and the Mac awake and connected. Poll success, provider report
time, and new local ingestion are distinct.

Raw unique observations are preserved. Simplification affects display only;
CSV always uses raw observations. Coordinates and accuracy are never invented
for semantic-only reports. Map connectors describe observation order, not
the actual traveled route. Optional user mappings are approximate annotations.

Local data belongs under the user's Application Support/TagTrail directory.
Demo and live use distinct files. Credentials are stored in a dedicated
TagTrail Keychain service, not SQLite. Do not move a live database to iCloud
Drive or network/shared storage. SQLite history is not application-level
encrypted; see `SECURITY.md`.

## Reset and recovery

Disconnect removes the connection credentials while retaining local history.
Delete history separately using the confirmed Settings action. Avoid editing
SQLite while the app runs. Preserve imported credentials privately if needed
for recovery; a locked/denied Keychain requires local user action.

Read `ARCHITECTURE.md` for the ownership and observation-integrity decisions,
`KNOWN_LIMITATIONS.md` for scope and blockers, and `VERIFICATION.md` for evidence.
Third-party code and distribution require license review; see the notices and
the preserved upstream license.

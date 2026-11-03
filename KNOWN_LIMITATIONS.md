# Known limitations and acceptance boundaries

## Product boundaries

TagTrail records available reports while the application is running and the
Mac is awake and connected. It cannot promise a fresh report on every poll,
complete historical backfill, continuous GPS, a fixed upstream cache duration,
or immunity from account restrictions.

Google-paired JioTag 2 is **targeted**, not live-verified. Moto Tag, Chipolo ONE
Point, and other provider-supported trackers are compatibility candidates, not
verified devices. Discovery alone is not proof of geographic decryption.
No device has been live-verified during this build: no authorized Google account
or tracker credentials were supplied.

Apple-paired JioTag, Apple Find My, cloud sync, Docker companions, geofencing,
dwell alerts, BLE ringing, precision finding, and native Swift cryptography
are out of scope.

## Data boundaries

Missing timestamps and accuracy remain missing. Provider timestamps may denote
report creation rather than physical detection. Repeated equivalent reports
without stable identities or timestamps cannot be distinguished reliably.
Semantic labels are not measured coordinates. A user mapping is approximate
and cannot establish a route through the place.

SQLite history is not application-level encrypted. Map tiles need external
services even in demo mode; the feed should remain usable without tiles.
Geocoding is optional and rate-paced, not a promise of an address for each row.

## Verification boundaries

The build environment has macOS 26.7 on arm64 and Command Line Tools with
Swift 6.2.3 and macOS SDK 26.2, but no selected full Xcode installation.
An Xcode build and Xcode UI testing cannot be claimed from a SwiftPM build.
The macOS 14 deployment target does not prove runtime or bundled Python
extension compatibility on macOS 14. Intel execution is not verified on an
arm64 host. Ad-hoc signing does not establish distributable release status.

See `VERIFICATION.md` for executed commands, actual results, and any remaining
required v1 work. Missing required behavior is not reclassified as optional
future work.

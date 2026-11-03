# TagTrail v1 decisions

TagTrail records reports available from an unofficial Google Find Hub integration.
It is not a continuous GPS recorder, a guarantee of historical backfill, or an
Apple Find My client.

## Ownership

The native application owns all database writes through the `Database` actor.
The Python worker communicates through private stdin/stdout pipes and never
opens the history database. Swift owns migrations, ingestion, retention,
derived geocode cache entries, and explicit semantic-place mappings. Credential
updates are handled by the parent through Keychain, not SQLite.

SQLite uses WAL, a three-second busy timeout, foreign keys, short synchronous
transactions inside an actor, and versioned transactional migrations. WAL does
not eliminate locks. Do not put the database on a network filesystem or share a
live database between Macs. The application creates its directory with mode
0700 and database with mode 0600.

## Observation identity and time

UTC epoch milliseconds are stored as signed 64-bit integers. A missing provider
timestamp remains null. Display and retention fall back to first ingestion
time; this fallback is not a physical detection time.

Where the adapter supplies a verified report identity, identity is the SHA-256
of a JSON array of local device identity, source, and provider report identity.
Otherwise, SHA-256 hashes sorted-key JSON containing device, source, kind,
timestamp, timestamp provenance, coordinates, altitude, accuracy, and semantic
label. Optional fields consistently omit absent values, numbers use Swift's
JSON encoding of normalized Double values, and negative zero normalizes to
zero. There is no spatial rounding. Ingestion time, local row UUID, and request
UUID do not participate. Equivalent untimestamped reports cannot establish
that a new physical observation occurred; they are intentionally idempotent.

The first stored raw report is preserved. A repeated report identity does not
overwrite it with changed derived information. Different coordinates or
different verified report identities at the same timestamp survive.

## Raw versus displayed evidence

All valid unique observations remain in SQLite. Simplification groups only
consecutive geographic records with known accuracy, within 30 minutes, using
Haversine distance with a 6,371,000-meter radius and threshold
`max(10, min(50, max(accuracyA, accuracyB)))` meters. A group's representative
is its newest observation; its count and original time range remain available.
Unknown accuracy prevents grouping.

Polyline segments break at semantic reports or gaps exceeding 60 minutes.
Connectors indicate observation order, not roads, the traveled route, speed,
distance traveled, or authoritative dwell time. Explicit semantic mappings are
derived approximate user annotations, never changes to raw coordinates.

## Modes and distribution

Demo and live data use separate databases and credential namespaces. Demo
fixtures are relative to an injected clock and have synthetic addresses; they
must not trigger live account access or reverse geocoding.

Development and packaged builds are distinct. Distributed applications must
launch a worker inside their own bundle without using a shell, source checkout,
or external Python. Ad-hoc local signing is not Developer ID signing or
notarization. Coverage on the host architecture is not evidence of a universal
binary or macOS 14 runtime compatibility.

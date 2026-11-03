# TagTrail worker

The worker executes the pinned Google Find My protocol and cryptography. It is
not a demo provider and never substitutes fixtures when authentication or the
network fails. Google/FCM is contacted only for `authenticate`, `list_devices`,
or `poll`; `doctor` is an offline import check.

## Development and packaging

From the repository root, using project-local `uv` caches/runtime:

```sh
UV_CACHE_DIR=worker/.uv-cache UV_PYTHON_INSTALL_DIR=worker/.python \
  uv --native-tls python install 3.12 --no-bin
UV_CACHE_DIR=worker/.uv-cache uv venv worker/.venv \
  --python worker/.python/cpython-3.12.11-macos-aarch64-none/bin/python3.12
UV_CACHE_DIR=worker/.uv-cache uv --native-tls pip sync worker/requirements.lock \
  --python worker/.venv/bin/python
worker/.venv/bin/python -m unittest discover -s worker/tests -v
PYINSTALLER_CONFIG_DIR=worker/.pyinstaller-cache worker/.venv/bin/pyinstaller \
  --noconfirm --distpath worker/dist --workpath worker/build worker/TagTrailWorker.spec
TAGTRAIL_WORKER_BINARY=worker/dist/TagTrailWorker/TagTrailWorker \
  worker/.venv/bin/python -m unittest worker.tests.test_packaging -v
```

The exact downloaded interpreter here is 3.12.11 arm64; the path is
architecture/version-specific, not a cross-platform runtime locator. Dependencies
are hash-locked in `requirements.lock`; regenerate only intentionally:

```sh
UV_CACHE_DIR=worker/.uv-cache uv --native-tls pip compile worker/requirements.in \
  --generate-hashes --python worker/.venv/bin/python -o worker/requirements.lock
```

`--native-tls` uses the machine's trusted certificate store: it does **not**
disable HTTPS certificate verification. The local corporate trust configuration
required it when resolving Python wheels. No system Python/package installation
is needed. Developer caches and runtime directories must remain ignored.

The one-directory bundle is `worker/dist/TagTrailWorker/`; copy **the whole
directory**, including `_internal`, into app resources. Launch its
`TagTrailWorker` executable via an absolute bundle-resolved path. No developer
Python, shell PATH, checkout, or working-directory dependency is needed for
normal commands. `gpsoauth` and `urllib3` distribution metadata are explicitly
bundled because actual import-time version lookup requires them.

## Wire protocol v1

Development invocation: `worker/.venv/bin/python -m worker` with the repository
root as working directory. One UTF-8 NDJSON request per worker process:

```json
{"protocol_version":1,"request_id":"example","command":"doctor","timeout_ms":45000}
```

Close stdin after sending the line. Commands: `doctor`, `authenticate`,
`list_devices`, `poll`. Poll also requires `device_id`. The latter three require
`credential_bundle`, an opaque JSON dictionary using the upstream cache schema.
See [`fixtures/protocol-v1.json`](fixtures/protocol-v1.json) for shared examples.

Events contain `protocol_version`, `request_id`, and `event`. Nonterminal events:
`ready`, `progress` (allowlisted stage in `payload`), and `credential_update`
(new complete dictionary in **top-level** `credential_bundle`). The parent must
persist the latter in Keychain promptly and must never log it. Terminal events
are `result` (`payload`) or `error` (**top-level** `code`, optional
`retry_after_ms`), exactly one per request. Errors exit 1; results exit 0.
Malformed input without a usable identifier uses request ID `invalid`; valid
IDs are retained when another required field fails validation.

Result schemas:

* `doctor`: `{status:"ok", upstream_commit, python, cryptography, protobuf,
  protocol_version:1, live_account_verified:false}`.
* `authenticate`: `{status:"authenticated", credential_storage:"parent-keychain"}`.
  This means a real scoped OAuth exchange succeeded and imported/shared owner-key
  material is available. It does not prove every tracker can be decrypted or
  that the parent saved a Keychain update.
* `list_devices`: `{devices:[{id,name,network:"google"}]}`. Only SPOT trackers
  are exposed; discovery does not mutate/register/refresh custom trackers.
* `poll`: `{sightings:[...],rejected_count}`. Geographic sightings contain
  `device_id`, `kind:"geographic"`, latitude/longitude, nullable
  altitude/accuracy, optional `provider_timestamp_ms`,
  `timestamp_provenance:"provider"|"unknown"`, and `source:"google-find-my"`.
  Semantic sightings contain `kind:"semantic"` and `semantic_label`, not
  fabricated coordinates. The upstream protobuf has no stable report ID.
  Missing times remain unknown, not replaced by polling time. Proto3's
  zero-coordinate defaults are retained; absent/zero scalar altitude/accuracy
  cannot establish presence and are treated as unknown.

Allowlisted errors: `authentication-required`, `credentials-locked`,
`unsupported-device`, `rate-limited`, `network-unavailable`, `timeout`,
`protocol-error`, `decryption-error`, `internal-error`. `credentials-locked`
normally originates in the parent Keychain layer, not this worker.

Limits: 1 MiB request/event lines; 512 KiB credential dictionary; 8 MiB emitted
data; IDs 1–128 characters; exactly one command per invocation. Unknown request
fields, duplicate keys, nonfinite JSON constants, bad versions, oversized lines,
and missing newline fail closed. Stdin must supply its request within 5 seconds.
Request deadlines are bounded by 45 seconds for polling/noninteractive work and
5 minutes for authentication. Cleanup has an additional bounded allowance
(FCM up to 4 seconds; browser up to 5 seconds). The parent must still impose its
60-second poll hard deadline and cancellation escalation.

Third-party stdout/stderr and logging are discarded, not regex-redacted.
Stdout is JSON only. Stderr has only `TagTrailWorker: <allowlisted-code>`.
No traceback, Google error body, raw protobuf, coordinate, account identifier,
device name, token or key is logged.

## Credential import

Import the existing upstream `Auth/secrets.json` dictionary through the app,
not a token on the command line. Required:

* Nonempty `username`, `aas_token`.
* Complete `fcm_credentials`: `gcm.android_id`/`security_token` digit strings,
  `gcm.app_id`/`token`; `keys.private`/`public`/`secret`;
  `fcm.registration.token`, `fcm.installation.token`/`refresh_token`.
* Hexadecimal `owner_key` or `shared_key` (16/24/32-byte AES key).

Google scoped authentication validates the imported account credential.
FCM key material must decode to a P-256 DER private key, matching uncompressed
public key and 16-byte ECE authentication secret; GCM identifiers must fit
nonzero unsigned 64-bit integers. Incomplete or malformed material is rejected.
If only `shared_key` is imported, the real Spot GetEidInfo API retrieves and
decrypts the owner key, producing `credential_update`. FCM re-registration
also emits complete updates. Every upstream cache access in the worker is
configured in-memory before upstream operations. The original import file is
neither modified nor deleted; it remains sensitive and should be protected by
its owner. The worker never opens the application database.

## Explicit local browser helper

Import is the ordinary recovery path. An explicitly enabled helper can use
the real upstream EmbeddedSetup cookie exchange and finder_hw security-domain
vault callback. It is **not** a fictional generic OAuth sign-in:

```json
{"protocol_version":1,"request_id":"setup","command":"authenticate","timeout_ms":300000,"credential_bundle":{"username":"YOUR_ACCOUNT_EMAIL"},"browser_helper":{"enabled":true,"chromedriver_path":"/absolute/path/to/a/matching/chromedriver","artifact_directory":"browser-artifacts"}}
```

Visible Chrome and a compatible preinstalled ChromeDriver are prerequisites.
No auto-download, headless fallback, fake challenge answer, or stdin prompt is
used. Required account/2FA/security-domain challenges are completed in the
visible browser. The worker does not read passwords. It only quits its own
driver/browser, verifies captured process creation times before escalation,
and never kills unrelated Chrome instances.

The helper's working directory must be writable. `artifact_directory` must
be relative and contained in that directory. A unique mode-0700 profile,
cache, and crash-dump directory are created under it, and removed after
shutdown. This flow **does create sensitive browser disk artifacts** while
authentication runs; it is not disk-free. A parent force-kill/power loss can
leave an owned profile behind, requiring documented cleanup. ChromeDriver/
Chrome authentication was not exercised with a real account here.

## Verification boundary

Tests exercise real worker pipes, validation, deadlines, SIGTERM, credential
updates, large diagnostic suppression, HTTP/OAuth encoding, Spot owner-key
decryption, FCM lifecycle/callbacks, CBC/GCM EIKs, GCM own reports,
SECP160r1/HKDF/AES-EAX foreign reports, semantic reports, malformed crypto and
unknown timestamps/accuracy. Network/browser setup is intercepted with
synthetic fixtures; no real Google account was available.

Python 3.13.3 passed the initial source suite, but its locally compiled
libpython requires macOS 26.3, so that bundle was rejected for macOS 14.
The final project-local Python 3.12.11 arm64 bundle has native dependency
deployment targets ≤ macOS 11.0. Relocated offline doctor and dependency-target
tests run on macOS 26.7 arm64. This is deployment-target evidence, **not**
an actual macOS 14 runtime test, x86_64/universal validation, notarization, or
live-service acceptance.

Tested resolved versions: gpsoauth 2.0.0, protobuf 6.33.6, cryptography 50.0.2,
pycryptodomex 3.24.1, ecdsa 0.19.2, aiohttp 3.14.5, httpx 0.28.1,
http-ece 1.2.1, selenium 4.52.0, psutil 7.2.2 and PyInstaller 6.22.3.
gpsoauth emits an upstream SSLContext deprecation warning in source tests;
worker diagnostics suppress it. Actual protocol and crypto compatibility are
covered by adapter tests, not assumed from version constraints.

The complete source + built-package validation command tested here:

```sh
TAGTRAIL_WORKER_BINARY=worker/dist/TagTrailWorker/TagTrailWorker \
  worker/.venv/bin/python -m unittest discover -s worker/tests -q
```

The packaged validation originally passed all 28 tests. A subsequent targeted
shared-fixture consumption test also passes, bringing the suite to 29 tests.
Without that environment variable the 27 source tests run and the two packaging
tests are explicitly skipped. Both language transports consume the canonical
`worker/fixtures/protocol-v1.json` request/event examples, copied to
`Resources/protocol-v1.json` for release checks. Python additionally consumes
the `AppTests/protocol-v1.json` sequence fixture.

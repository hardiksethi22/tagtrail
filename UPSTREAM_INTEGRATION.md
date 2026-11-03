# GoogleFindMyTools integration

Canonical upstream: <https://github.com/leonboe1/GoogleFindMyTools>

Pinned full commit: `660be5395702ff7f1a6174f4ec4c865a57c7b527`.
The vendored checkout is retained under `vendor/GoogleFindMyTools`. Its original
[`LICENSE`](vendor/GoogleFindMyTools/LICENSE) is unchanged: GNU GPL version 3.
Original copyright headers are retained. Shipping a subprocess is not an
exemption from GPL obligations: distribute the vendored source, modifications,
worker source, build instructions and dependency lock alongside the release's
corresponding source. Review combined application distribution/license
obligations before publishing.

## Inspected source contracts

* `Auth/auth_flow.py`, `aas_token_retrieval.py`, `token_retrieval.py`,
  `username_provider.py`: visible Chrome EmbeddedSetup supplies `oauth_token`;
  `gpsoauth.exchange_token` produces the cached account master token; scoped
  Android OAuth exchanges are required. A generic access token is insufficient.
* `Auth/token_cache.py`: original CLI reads/writes `Auth/secrets.json`.
* `Auth/fcm_receiver.py` and `Auth/firebase_messaging/`: FCM credential/key
  material is cached; FCM must register/listen before the locate action. Original
  receiver creates two event loops, retries indefinitely, and does not join/
  close its owned listener loop. Push payloads require ECE decryption and
  `com.google.android.apps.adm.FCM_PAYLOAD` base64 decoding.
* `NovaApi/ListDevices/nbe_list_devices.py`, `NovaApi/nova_request.py`:
  SPOT DevicesListRequest protobuf, Android Nova endpoints and headers.
  Original human CLI includes prompts and custom tracker mutation; HTTP has no
  timeout and prints server error bodies.
* `NovaApi/ExecuteAction/LocateTracker/location_request.py`,
  `NovaApi/ExecuteAction/nbe_execute_action.py`: register FCM first, send action
  with UUID/registration/canonical tracker ID; correlate FCM UUID. Original
  request waits forever. TagTrail additionally correlates canonical device ID.
* `LocateTracker/decrypt_locations.py`, `ProtoDecoders/Common.proto`,
  `DeviceUpdate.proto`, generated `_pb2.py`: recent/network reports have parallel
  timestamps, semantic/geo variants and proto3 presence limitations. Original
  decryption prints results and may call `exit`, not return structured data.
* `KeyBackup/cloud_key_decryptor.py`, `shared_key_retrieval.py`,
  `shared_key_flow.py`, `response_parser.py`, Spot GetEidInfo/get_owner_key:
  shared vault key -> AES-GCM owner key -> AES-CBC (48-byte envelope) or AES-GCM
  (60-byte envelope) identity key. Owner keys/version resets can permanently
  prevent report decryption.
* `FMDNCrypto/foreign_tracker_cryptor.py`, `eid_generator.py`: SECP160r1
  ECDH/HKDF-SHA256/AES-EAX foreign reports; own reports use AES-GCM with
  SHA256(identity key); MCU trackers flip encrypted identity bits and use zero
  time offset. Unsupported/invalid cryptographic material fails closed.
* `chrome_driver.py`: original helper kills unrelated Chrome processes and
  falls back to headless operation. TagTrail **never invokes this helper**.

## Narrow upstream modification

Only `Auth/token_cache.py` is modified. `configure_memory_store`,
`memory_snapshot`, and an update callback introduce an opt-in, thread-safe,
deep-copying process-local backend. TagTrail enables it before any upstream
operation. `get_cached_value`/`set_cached_value` then bypass all filesystem
access, including master tokens, username, shared/owner key and FCM state.
Updates are secret-bearing NDJSON messages persisted by the parent Keychain.
Without opt-in, upstream's standalone CLI behavior is unchanged.

Other adaptations live in `worker/adapter.py` and `worker/browser.py`, rather
than modifying broad upstream call graphs. They construct actual protobufs,
call actual Google endpoints, reuse upstream crypto/generated protobuf/FCM
code, return structured sightings, bound HTTP/FCM deadlines, and suppress raw
diagnostics. The FCM transport uses one owned asyncio loop and explicitly
closes sockets, registrations, tasks and thread. No console parsing is used.
The local helper uses existing visible ChromeDriver and upstream cookie/vault
contracts without the unsafe upstream process-killing helper.

## Runtime subset and lock

`worker/requirements.in` selects actual upstream runtime dependencies.
`worker/requirements.lock` locks the resolved complete transitive graph with
hashes, targeting project-local Python 3.12.11. Firmware, Frida owner-lookup,
and undetected-chromedriver auto-install facilities are excluded because the
worker does not invoke them. `psutil` adds creation-time-verified cleanup of
only owned browser processes. PyInstaller is an explicit build dependency.
No invented PyPI GoogleFindMyTools package is installed.

The final one-directory bundle includes required generated protobuf modules,
upstream license/proto definitions, Python runtime, crypto extensions, CA
certificates, and gpsoauth/urllib3 metadata required at import time.
See [`worker/README.md`](worker/README.md) for exact setup, protocol and test
commands. No credentials are placed in environment variables/command arguments.

## Proven and unproven behavior

Synthetic tests prove adapter/protobuf/crypto/FCM/transport behavior without a
Google account. A native arm64 bundle is import-tested after relocation with an
empty PATH and no source checkout in its working directory. Native deployment
targets are audited for macOS 14 eligibility, not a claim of macOS 14 execution.
The host Python 3.13.3 bundle was rejected because libpython's minimum OS was
26.3; the managed Python 3.12.11 bundle targets at most macOS 11.

No real Google account, Chrome login or FCM delivery was available for live
acceptance. FCM/Nova APIs are unofficial and may change. Poll returns the first
correctly correlated update, not proof of complete historical coverage.
No reports is not a fresh sighting; absent timestamps remain unknown. Imported
owner material may be obsolete after an E2EE reset. The browser setup's disk
artifacts and forced-termination limitations are explicitly documented; it is
not advertised as disk-free. x86_64, universal packaging, notarization and
actual macOS 14 runtime compatibility remain unverified.

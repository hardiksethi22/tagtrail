# Security and privacy

Use TagTrail only with trackers you own or are authorized to access. The
integration does not modify anti-stalking protections and is not a substitute
for them. The upstream provider is experimental and may change or stop working.

## Sensitive local data

Credentials belong in macOS Keychain. Never paste account credentials into a
chat, commit them, or include them in a bug report. Imported upstream exports
remain sensitive files: import does not modify or delete the original. Remove
the original yourself only when you understand recovery implications.

Keychain protects credentials, but the history SQLite database is **not
application-level encrypted**. Geographic history and user-defined places are
sensitive. Restrictive filesystem permissions and operating-system protections
are useful, but are not equivalent to encrypted history. FileVault is an
OS-level choice. Deleting records does not guarantee secure deletion from WAL,
backups, filesystem snapshots, or storage hardware.

The worker receives credentials through private stdin, not process arguments,
environment variables, HTTP, or a listening port. It is nevertheless trusted
code with access to those credentials. Process separation does not eliminate
that trust or guarantee memory zeroization.

## Network disclosure

Live polling contacts Google's services. MapKit tiles contact Apple's map
services. Optional reverse geocoding sends report coordinates to Apple; it must
be explicitly enabled. Showing existing reports does not require the Mac's
current-location or Bluetooth permission. Demo has synthetic address labels
and never needs Google credentials.

## Reports and recovery

Share only sanitized error categories, tool versions, architecture, and
reproduction steps. Do not share device names, account emails, tokens, key
material, credential-update events, precise coordinates, raw protobufs, or
private history files. Do not include a complete worker transcript.

Disconnect should cancel work and remove connection Keychain items without
deleting retained history. History deletion is a separate confirmed action.
A denied or locked Keychain must pause authentication-dependent work, not
discard history or enter an automatic authentication retry loop.

No release signing identity or notarization credentials are included. Local
ad-hoc artifacts are for local development only. Never disable Gatekeeper, SIP,
TLS validation, or other system protections to run this application.

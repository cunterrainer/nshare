# nshare v2 implementation

Scope: a Dart desktop CLI for LAN file/folder transfer. No relay, Internet
service, Flutter dependency, compression, or parallel file streams. The library
must remain usable by a future Flutter desktop/mobile adapter.

## Modules

- core: immutable models, structured errors, progress streams, cancellation,
  caller-provided approval policies; no terminal input/output.
- cli: arguments, prompts, stdout/stderr and exit codes.
- protocol: bounded binary framing, JSON control messages, explicit wire IDs.
- identity/transport: persistent certificate identity, TLS, verified pairing,
  pinned peer certificates. Never trust a discovery response as identity.
- discovery: bounded UDP requests/responses, multiple results, direct-IP fallback.
- storage: validated relative paths, conflict policies, staged writes/checkpoints.
- transfer: stateful sequential streams, SHA-256, final acknowledgments, resume.

## Delivery sequence

Each numbered milestone is a separate coherent commit, pushed immediately:

1. Architecture and baseline.
2. Reusable core models and policies.
3. CLI and standalone local interface/IP reporting.
4. Protocol v2 specification, bounded parser and state rules.
5. Certificate generation, TLS and verified persistent pairing.
6. Bounded UDP discovery and device selection.
7. Destination validation, conflict policies and staging.
8. Verified streaming transfer, progress/cancellation and acknowledgments.
9. Persistent resume from validated checkpoints.
10. Migration, real process tests, CI, documentation and executable build.

Work only on a newly created unique branch; never overwrite an existing branch
or force-push. Stop committing until a failed push is resolved.

## Behavior

`--show-ip` lists local IPv4/IPv6 interfaces without opening a listener. No args
shows help. `send`, `receive`, `devices`, and trust administration form the CLI.
A sender must explicitly select a device if discovery returns multiple results.
Initial peer certificates must be verified out of band (full SHA-256 fingerprint)
and approved by both callers before any file metadata is transferred. Stored
identity changes fail closed. Trust does not imply permission to overwrite files.

Protocol v2 intentionally breaks v1 compatibility; there is no plaintext fallback.
Bounded control metadata and fixed-size data chunks prevent peer-controlled
unbounded buffers. Errors, invalid states, EOF and missing acknowledgments must
not be reported as success. Hash and byte count must both match.

Staged files live on the destination filesystem; final names are exposed only
following verification. Reject unsafe paths, links, duplicate and case-folding
collisions. Default conflict policy is refusal. Resume records are bound to the
peer, manifest and destination, and retained bytes are verified before use.

## Validation

Run formatter, analyzer, meaningful unit tests, loopback socket/process tests and
native executable compilation. CI targets Linux/macOS/Windows. Include malformed
frames, invalid state ordering, traversal and symlink attacks, interrupted files,
changed sources, stale/corrupt checkpoints and lost acknowledgments. Measure
large-file and many-small-file scenarios. Physical two-device LAN tests and
mobile platform behavior require separate hardware validation; do not represent
loopback tests as those checks.

## Baseline

Original revision: 3adf003. The environment initially had no Dart executable;
a temporary SDK is installed outside the repository for baseline and validation.
Existing integration tests largely simulate components rather than exercise a
network transfer. Baseline results will be recorded when available.

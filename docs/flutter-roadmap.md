# Flutter / CLI delivery

Implementation branch: `feature/flutter-lan-suite-20261031`, based on `dc34848`.
Every coherent commit is pushed immediately; no force pushes. Failed pushes block
further commits. CLI remains independently buildable without Flutter.

## Milestones

1. Baseline and platform constraints.
2. Shared settings, durable jobs, application services and platform boundaries.
3. Flutter shell with real CLI interoperability.
4. Versioned extension protocol, bounded manifests and capability negotiation.
5. Better discovery, expiring QR invitations and camera-free pairing.
6. Large-folder streaming, checkpoints and bounded resources.
7. Persistent queue, cancellation, retry and recovery, CLI/UI parity.
8. Explicit opt-in compression with bounded decompression and logical offsets.
9. Approved text clipboard sharing, no passive clipboard monitoring.
10. Platform lifecycle, receiver status and background controls.
11. Expanded tests, packaging, CI and measured validation.

## Platform contract

Android/iOS/Windows/macOS/Linux Flutter targets; desktop CLI on Linux/macOS/Windows.
Desktop persistent receiving is possible. Android background receiving requires
an explicit foreground service and ongoing notification; OS start restrictions
apply. iOS cannot guarantee a listening LAN socket while suspended. Never show a
suspended receiver as reachable. Startup, automatic acceptance and compression
are separate opt-in settings. Hardware verification is recorded separately from
same-device sockets/process tests.

## Validation gates

Preserve 322 existing tests, add at least 300 meaningful cases, including at least
40 real end-to-end transfers. Verify formatter, fatal-info analysis, standalone
CLI compilation, Flutter widget tests and available native builds. Exercise large
folders (>1024 entries, >256 KiB metadata), compression, resume, queue recovery,
clipboard consent and invitation expiry. Stress target: 100,000 entries and a
multi-gigabyte file, with measured resource use; not a claim of current validation.

Existing recorded baseline: 322 passing tests, 48 native process transfers, Dart
3.13.7 on Linux. Fresh baseline validation is running during implementation.
Physical mobile/desktop matrix, camera, sleep and background service checks
require the corresponding host/device and must not be inferred from Linux tests.

## Delivered implementation

Shared services, all five Flutter project targets, negotiated extensions,
QR/copy pairing, disk-backed large folders, durable queues, bounded network
retries, opt-in compression, explicit clipboard sharing, native mobile folder
adapters and platform receiver lifecycle controls are implemented. Every commit
was pushed. Source, packaging workflows and the full validation record are in
[flutter-validation.md](flutter-validation.md). Physical-device runtime gates
remain pending; no simulated or loopback check is represented as hardware proof.


## Completion pass

Continuation branch: `feature/finish-flutter-plan-20261101`, created from
`faba6b0`. Commits are pushed individually without replacing the earlier branch.
This pass implements desktop multi-file/folder drop selection, throttled live
scanning counts, mutually confirmed session-code pairing in CLI and Flutter,
and iOS system Bonjour browsing/advertising. It adds native drop/pairing tests,
a portable device transfer/clipboard suite, Android emulator and iPhone simulator
CI, desktop runtime CI, installable/portable distributions and signing adapters.

Local registered test total: 781 (703 Dart, 73 Flutter, 3 native-window,
2 portable native-device cases), 459 beyond the original 322-test baseline.
The portable native suite verifies 1,050 actual file payloads and an empty folder.
See [validation](flutter-validation.md), [packaging](releases.md) and
[physical acceptance gates](device-validation.md). Physical-device checks and
credential-dependent signing/notarization are explicitly pending; the whole
release acceptance plan is not represented as completed without those results.

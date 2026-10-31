# Flutter and CLI delivery validation

Implementation branch: `feature/flutter-lan-suite-20261031`, created from
`dc34848`. Coherent implementation/test commits were pushed after each commit;
no existing branch was overwritten and no history was force-pushed.

## Implemented

- Standalone Dart CLI and responsive Android/iOS/Windows/macOS/Linux Flutter
  project, sharing services, trust, streaming transfers and settings.
- QR display, SVG export, phone scanner and camera-free invitation paste/direct
  address/full-fingerprint pairing. Expiring invitations are atomically consumed.
- Explicit capability negotiation over the existing encrypted v2 envelope;
  ordinary transfers interoperate with old v2 binaries.
- Disk-backed paginated manifests and collision indexes, persistent jobs,
  pause/resume/reorder/cancel/retry, bounded transient-network backoff, progress
  phases, history and JSON CLI event snapshots.
- IPv4/IPv6 mDNS plus UDP fallback, fresh discovery snapshots, remembered hints,
  network-interface advertisement refresh and dual-stack listening.
- CLI/Flutter existing-file policies and explicit restart after corrupt partials.
  A real queued TLS regression checks rejection followed by verified restart.
- User-enabled compression, independently bounded gzip blocks, original-offset
  resume, raw fallback for blocks that grow and original-content verification.
- Explicit clipboard text approval, stdin/stdout CLI workflows, no passive
  monitoring or clipboard text in ordinary logs/history.
- Desktop tray/startup integration, authenticated user-local service control,
  including CLI receiver startup through an existing GUI queue owner and accurate
  reporting of the owner's destination, approval and compression policies,
  Android foreground-service receiver with visible notification/Stop, and iOS
  foreground lifecycle handling.
- Android document-provider and iOS security-scoped folder import/export adapters.
  Individual mobile picker files are persisted before queueing, so clearing a
  provider cache cannot invalidate their queued sources.
  Mobile imports are private disk snapshots; staging consumes additional space.

The macOS desktop target intentionally uses direct distribution outside App
Sandbox so CLI/UI state and queued filesystem paths remain accessible. Store
submission, production signing/notarization and installers are not configured.

## Local automated evidence

Validated on Linux using Dart 3.13.7 and Flutter 3.47.9. Test inventory is generated
from runner events, excluding hidden setup/teardown and skipped cases. See
[the inventory](flutter-test-inventory.json) for individual test names and counts.

- Original baseline: all 322 tests passed before implementation.
- Expanded Dart suite: 664 passing tests, plus separately run real queue
  reconnection, picker-source persistence and restart/lifecycle and receiver-owner control regressions (683 distinct Dart tests
  in total).
- Flutter: 53 passing tests (50 widget/layout cases and 3 real controller
  interoperability tests), no skips.
- Normal packaged Linux app startup and isolated CLI/UI profile control succeeded;
  its receiver stayed off until explicitly started, and executable help exited 0.
- Native GTK desktop window: 2 passing integration tests. One clicks peer and
  transfer approval dialogs for a separate native CLI sender; the other enters
  a source/target in the GUI and queues a transfer to a separate CLI receiver.
- Total: 738 distinct registered tests, 416 additional tests beyond the baseline.
- Formatting, fatal-info Dart analysis, Flutter analysis and native CLI
  compilation pass. Native Linux Flutter debug build succeeds.

The 55 new native process checks include 40 real compressed-file cases, exact
UTF-8 clipboard delivery/consent, single-use pairing, queue pause/resume, service
control and command help. Existing native process transfer tests remain. Flutter
controller interoperability covers CLI → Flutter, Flutter → CLI and Flutter →
Flutter with real TLS/filesystem work and destination verification.

## Stress measurements

These are same-process loopback TLS observations on this development host, not
LAN throughput, mobile-memory guarantees or physical-device results.

| Workload | Result | Elapsed | Process peak RSS |
| --- | --- | --- | --- |
| 100,000 empty files plus root directory, JIT | All files/counts verified | 457.759 s | 443.3 MiB |
| 2 GiB + 1 byte, JIT | Original size and SHA-256 verified | 154.193 s | 996.9 MiB |
| 2 GiB + 1 byte, compiled native | Original size and SHA-256 verified | 112.978 s | 447.3 MiB |

The large-file workload contains zero bytes and explicitly enables compression.
Its network data payload was 3,145,729 bytes. Do not generalize those savings to
photos, videos or other incompressible data. RSS includes both peers in one
process; the JIT measurements also include compiler/runtime overhead. The
streaming frame limits are not an assertion that process RSS stays below 100 MiB.

See [JIT results](flutter-stress-jit.json) and
[native results](flutter-stress-native.json). Reproduce with:

```sh
dart run tool/stress.dart --entries 100000 --large-bytes 2147483649 --report results.json
dart compile exe tool/stress.dart -o stress
./stress --entries 0 --large-bytes 2147483649 --report native-results.json
```

The 1,100-file TLS test separately checks nonempty file contents, metadata beyond
256 KiB, deterministic manifests and idempotent retry with zero retransmitted
file bytes. Stress runs remove their temporary files afterward.

## Independent interoperability checks

Same-device native processes discovered a receiver through mDNS with the UDP
query port intentionally pointed at an unused port. Sending by the discovered
fingerprint then completed with verified destination bytes and exit 0 on both
sides. See [mDNS evidence](mdns-validation.json).

An old CLI was compiled directly from `dc34848`. v2 → new and new → v2 ordinary
transfers both exited 0 and reproduced destination contents. A compression
request to the v2 receiver failed explicitly on both sides without exposing a
final destination. See [results](v2-compatibility-results.json).

An independent ZXing C++ decoder recovered the complete invitation from both
exported SVG and rendered ANSI half-block terminal QR output. The tested terminal
QR occupied 65 columns. This validates encoded QR output, not a phone camera or
its permission UI. See [QR results](qr-validation.json).

## CI and hardware boundary

CI builds Linux/macOS/Windows CLI executables and runs Dart tests, including the
minimum Dart SDK. The Flutter workflow analyzes/tests the application and builds
Linux, Windows, macOS, Android debug APK and unsigned iOS targets. Linux also runs
the native-window integration suite under Xvfb. Build artifacts are retained by
GitHub Actions.

All five Flutter native build jobs succeeded in the initial build matrix:
[run 41208223514](https://github.com/cunterrainer/nshare/actions/runs/41208223514).
That run's analysis job caught formatting issues, subsequently fixed. Early core
CI also exposed asynchronous multicast errors on macOS; optional discovery now
handles those errors and cannot delay listener readiness. The standalone core matrix passed all four jobs after the fixes, including
Windows/macOS/Linux and Dart 3.8.0:
[run 41210238653](https://github.com/cunterrainer/nshare/actions/runs/41210238653).
The final application-source matrix passed all six jobs (analysis/tests plus all
five native targets), including Linux native-window tests:
[run 41224334878](https://github.com/cunterrainer/nshare/actions/runs/41224334878).
One Windows UDP fixture on that revision used a 250 ms timing window; its positive
control was starved under parallel native compilation. The fixture now uses the
same three-second discovery budget as the application, with all rejection and
positive-control assertions unchanged. The final core matrix passed all four jobs, including Windows:
[run 41224890775](https://github.com/cunterrainer/nshare/actions/runs/41224890775).
Application implementation revision: `ddbd5e4`; final timing-test revision:
`ab040d1`. Documentation commits do not change that validated implementation.

The following runtime checks still require corresponding physical devices/hosts:

- Android camera, selected document providers, foreground-service notification,
  locked screen, battery restrictions, forced termination and network changes.
- iOS camera, security-scoped providers, local-network permission, actual
  suspension/reopening and physical installation/signing. Raw UDP/multicast
  discovery also needs validation against signed-device networking capabilities;
  Apple multicast entitlement provisioning is not performed by this workspace.
  QR invitations and direct-IP transfers provide a discovery-independent path.
- Two-device LAN discovery, Wi-Fi client isolation, IPv6 link-local routing,
  firewall prompts and mixed desktop/mobile transfers.
- Windows/macOS tray, login startup, real sleep/wake and platform accessibility.

Native cross-platform build success does not establish any of those runtime
checks. iOS has no unrestricted always-listening background LAN receiver; the
implementation stops its foreground listener on suspension and restores it when
that app session resumes. Android's service remains subject to OS restrictions.

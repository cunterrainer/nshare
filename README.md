# nshare

Encrypted, resumable file, folder and text sharing on your local network. A Dart
CLI and a Flutter application share the same transfer engine. No account, relay,
cloud pairing service or Internet connection is required at runtime.

Flutter targets Android, iOS, Windows, macOS and Linux. The standalone CLI targets
Windows, macOS and Linux and builds without installing Flutter.

## Run

CLI (Dart 3.8+):

```sh
dart pub get
dart run bin/nshare.dart --help
dart compile exe bin/nshare.dart -o nshare
# Windows: -o nshare.exe
```

Flutter (validated with Flutter 3.47.9 / Dart 3.13.7):

```sh
cd apps/nshare_app
flutter pub get
flutter run -d linux     # or windows, macos, a connected Android/iOS device
# Desktop executable profiles also accept --state-dir and --output.
```

Linux desktop builds need clang, CMake, Ninja, pkg-config, GTK3 development files,
libayatana-appindicator3-dev and liblzma-dev. iOS requires macOS/Xcode, iOS 15.5+
and signing for physical installation. CI builds Android debug APKs and unsigned
iOS applications; production signing/distribution is a separate release step.

## Interfaces

The Flutter app has Devices, Send, Receive, Queue, History and Settings screens.
Choose or drop files/folders, select a nearby device or enter its address, verify its
identity and enqueue the transfer. Every incoming transfer and clipboard offer
requires separate approval. Discovery results do not establish identity trust.

Desktop Flutter and CLI share the default identity, settings and queue. Flutter
runs a user-local receiver/queue service; CLI queue commands can control its
persisted jobs. `service --action start` can also start a receiver through that
existing owner with the command's explicit approval and file policies. If a CLI service already owns the state, Flutter attaches to its
status. That service retains its existing approval policy. A standalone
foreground CLI transfer does not require the service or Flutter.

Mobile file selection persists a private copy before enqueueing, protecting jobs
from picker-cache eviction. Mobile folder selection imports a private snapshot using Android's document-tree
provider or iOS security-scoped access. Copying streams data rather than loading
whole files into memory, but requires additional disk space. Snapshots preserve
queue/resume access after the original picker permission ends. Receiving uses
app documents; stop receiving and use **Export received folder** to copy results
to a selected provider. Resume receipts are excluded from exports. Imported
snapshots remain in app storage; deleting a queue entry does not delete source
files. Desktop selections use ordinary filesystem paths.

## Current device IP

```sh
nshare --show-ip
nshare --show-ip --include-loopback
```

Lists local interface names, address families and addresses. It exits without
starting discovery/listeners, creating an identity, or querying a public IP
service. In Flutter, Receive → Choose this device IP lists the same interfaces.

## Pair with QR or without a camera

Start receiving, then display an invitation on that device. CLI example (two
terminals on the receiving device):

```sh
nshare receive --output ./received
nshare pair --host 192.168.1.42 --qr --svg pairing.svg
```

A phone can scan the QR in Flutter. A desktop without a camera can paste the
invitation into Flutter or use:

```sh
nshare pair --join 'nshare://pair?v=3&host=...'
```

You can also pair using only addresses and matching codes, with no camera or
pre-shared fingerprint. Start Receive on the other device, then choose **Pair by
code** in Flutter or run in an interactive terminal:

```sh
nshare pair --connect 192.168.1.42 --port 53317
```

Compare every digit of the displayed code on both devices and approve on both
screens. Decline unexpected or mismatching requests. Older peers must use a
verified invitation or the full fingerprint instead; code pairing never silently
downgrades. Paired peers can then send files and clipboard text normally.

Use an invitation obtained from a trusted device screen/copy channel. Invitations
pin the receiver's full certificate fingerprint, expire after five minutes, and
are single-use. The receiver must still verify and approve the joining device's
fingerprint. The CLI prints its own fingerprint while joining; `nshare trust`
also displays it. QR display/export never requires a camera. Use SVG output for
small terminals or long invitations.

Alternatively compare full SHA-256 fingerprints on both devices and approve the
first connection interactively. A fingerprint you have already verified can be
supplied for noninteractive use:

```sh
nshare receive --output ./received --once --accept --peer-fingerprint "$SENDER_FP"
nshare send ./photos --ip 192.168.1.42 --peer-fingerprint "$RECEIVER_FP"
```

Trusting an identity does not automatically accept file offers, overwrite files,
or replace clipboard contents. Changed identities at pinned endpoints fail
closed. `nshare trust --forget "$PEER_FP"` removes a remembered peer after you
have independently verified the identity change.

## Discovery and direct connections

```sh
nshare devices
nshare devices --json --remembered
nshare devices --watch
nshare send ./photos --to "$RECEIVER_FP"
nshare send ./photos --ip 192.168.1.42
```

Discovery combines IPv4/IPv6 mDNS/DNS-SD with IPv4 UDP fallback. Watched snapshots
expire absent devices; saved addresses are explicitly unverified for reachability.
Optional multicast failures do not prevent direct transfers. Wi-Fi client
isolation, VPNs, firewalls and mobile permissions can prevent discovery.

The receiver defaults to a dual-stack listener where available, with IPv4
fallback. Use `receive --bind` to choose a specific address. Direct IPv6 addresses
are supported, including interface-scoped link-local addresses. TCP defaults to
53317, UDP discovery to 1970, and mDNS to 5353. Configure your local-network
firewall profile accordingly. `--port` / `--discovery-port` override transfer and
UDP ports; mDNS uses its standard port.

## Large folders, conflicts and resume

Large manifests are paginated and spooled to temporary disk with a disk-backed
collision index. Limits: 1,000,000 total entries, 100,000 children in one source
directory, 512 MiB encoded manifest metadata. Individual control frames stay
bounded at 256 KiB; file chunks at 64 KiB. Disk exhaustion fails the operation.

- Default `--conflict refuse` leaves existing destination files untouched.
- `--conflict overwrite` replaces a file only after its replacement is verified.
- `--conflict skip` reports existing files as skipped, not verified.
- Resume is enabled by default; repeat the send or resume/retry a queued job.
- `send --no-resume` discards retained partial bytes for that offer, without
  authorizing replacement of finalized destinations.

Paths reject traversal, links, absolute paths, Windows reserved names, duplicates,
case collisions and Unicode-normalization collisions. Empty files/folders and
Unicode names are preserved. Permissions, timestamps, extended attributes, hard
links and sparse layout are not preserved.

Flutter's Receive screen also selects refuse/skip/replace policies while stopped.
Queue restart discards retained partial bytes; it does not authorize overwriting
finalized destinations. Normal resume/retry uses verified retained bytes.

Partial files and receipts live in the destination's `.nshare-state`, bound to
peer identity, deterministic manifest and canonical output root. Retained bytes
are rehashed on both sides before resume; completed destinations are rehashed
before receipt reuse. Final success requires receiver acknowledgment. Folder
transfers are not atomic: earlier files can be complete when a later file fails.
Only one receiver may write a given output root at once. Keep that root under
your control; portable Dart filesystem checks do not defeat a hostile local
process concurrently replacing path components.

Small uncompressed transfers remain compatible with v2 peers. Large manifests,
clipboard, invitation completion and compressed blocks require negotiated v3
extensions. Unsupported requests fail explicitly; authentication never falls back
to weaker trust rules.

## Queue and receiver service

```sh
nshare queue --action add --path ./photos --ip 192.168.1.42 --peer-fingerprint "$RECEIVER_FP"
nshare queue --json
nshare queue --action run
nshare queue --action pause --id "$JOB_ID"
nshare queue --action resume --id "$JOB_ID"
nshare queue --action retry --id "$JOB_ID"
nshare queue --action restart --id "$JOB_ID"
nshare queue --action move --id "$JOB_ID" --position 0
nshare queue --action cancel --id "$JOB_ID"
nshare queue --action remove --id "$JOB_ID"
nshare queue --action events
```

Jobs retain order and state across restarts. Compression is captured when a job
is added; changing its preference affects newly added jobs. Interrupted active jobs require
explicit resume/retry. Transient network failures receive at most three automatic retries with 1/2/4-second
backoff. Failed authentication, integrity failures and declined approvals are never
implicitly retried. Scheduling currently runs one outgoing job at a time.
`queue --action run` drains runnable jobs; paused/interrupted jobs remain pending.
`--watch` keeps a runner alive; `events` emits changed snapshots as newline-delimited
JSON. Queue capacity is 10,000 jobs, including history; remove old jobs as needed.

```sh
nshare service --action run --output ./received
nshare service --action start --output ./received --accept --peer-fingerprint "$SENDER_FP"
nshare service --action status
nshare service --action stop
```

`run` stays in the foreground; `start` launches a detached process. Detached
receiving needs an explicit offer policy and already verified trust because it
cannot display terminal prompts. The control endpoint binds only to loopback and
requires a bearer token stored in owner-only state. Desktop tray controls can
show the Flutter window, stop receiving or quit. Start-at-login and keeping the
window in the tray are separate opt-in settings.

## Compression is opt-in

Both outgoing compression and incoming decompression permission default to off.
Flutter exposes independent switches. CLI preferences and per-command overrides:

```sh
nshare settings
nshare settings --set compression --value true
nshare settings --set allowCompression --value true
nshare send ./photos --ip 192.168.1.42 --compress
nshare send ./photos --ip 192.168.1.42 --no-compress
nshare receive --output ./received --allow-compression
```

Each independently compressed gzip block retains original-file offsets for
resume. Blocks that grow are sent raw. The receiver bounds decompression and
verifies original sizes and SHA-256 hashes. Results distinguish original file
bytes from network data payload bytes (excluding TLS/framing overhead).

## Clipboard text

```sh
nshare clipboard --ip 192.168.1.42 --peer-fingerprint "$RECEIVER_FP" --text 'Hello'
printf 'Hello' | nshare clipboard --ip 192.168.1.42 --peer-fingerprint "$RECEIVER_FP"
nshare receive --once --accept-clipboard --peer-fingerprint "$SENDER_FP" > clipboard.txt
```

The CLI can exchange text through stdin/stdout without a desktop clipboard
provider. Flutter sends the current clipboard explicitly and offers incoming
text for approval before copying it. No passive clipboard monitoring or automatic
synchronization is enabled. Text is limited to 64 KiB UTF-8 and omitted from
ordinary logs/history. CLI receiving writes exact text when stdout is redirected;
terminal output replaces control characters for safe display. `--accept` for
files does not imply `--accept-clipboard`.

## Background behavior and state

Desktop can keep receiving with the window in its tray, or through the CLI service.
Android's opt-in background receiver uses a visible foreground-service
notification with a Stop action; pending approvals require opening the app. OS
start, battery and process restrictions still apply. It does not auto-start on
boot. iOS receiving works while active; suspending the app stops receiving and
reopening restores the listener. iOS cannot provide an unrestricted always-on
LAN receiver. App background operation is separately tested from native builds.

Global CLI `--state-dir` precedes the command. Defaults: `$XDG_CONFIG_HOME/nshare`
or `~/.config/nshare` on Unix, `%APPDATA%/nshare` on Windows. Mobile state lives in
app-private support storage. State contains a private key: keep it private. Unix
permissions are set through libc; Windows uses the selected user's inherited ACLs.
The macOS desktop build is intended for direct distribution, outside App Sandbox,
so CLI/UI state and queued source paths remain accessible across restarts.

Ctrl+C cancels foreground operations. Exit codes: 0 success, 1 failure, 64 usage,
130 cancellation. Progress and diagnostics go to stderr; results go to stdout.
`send --help`, `receive --help` and each other command's help list options.

## Development and evidence

```sh
dart format --output=none --set-exit-if-changed lib bin test example tool
dart analyze --fatal-infos
dart test
cd apps/nshare_app
flutter analyze
flutter test
# Native desktop UI + separate compiled CLI processes:
xvfb-run -a flutter test integration_test/desktop_transfer_test.dart -d linux
```

See [delivery and platform evidence](docs/flutter-validation.md), the
[v3 extension specification](docs/protocol-v3.md), the
[v2 transport specification](docs/protocol-v2.md), and the
[original baseline test inventory](docs/testing.md).

Installable/portable CLI and GUI distributions, platform signing configuration
and build commands are in [release instructions](docs/releases.md).
The [device validation guide](docs/device-validation.md) includes runnable native
transfer suites and the remaining physical-device acceptance matrix.

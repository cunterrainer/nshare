# nshare v2

A Dart CLI for encrypted, resumable file and folder transfers on a local network.
The UI-independent library can also back a future Flutter interface.

Requires Dart 3.8+. Desktop targets: Linux, macOS and Windows. No relay, cloud
account or Internet connection is required at runtime. Discovery is IPv4 UDP;
direct connections support IPv4 and IPv6. v2 is incompatible with v1.

## Build and run

```sh
dart pub get
dart run bin/nshare.dart --help
dart compile exe bin/nshare.dart -o nshare
```

On Windows use `-o nshare.exe`. Alternatively install from your checkout with
`dart pub global activate --source path .`, then run `nshare`.
The examples below use the compiled executable on PATH.

## Show this device's IP addresses

```sh
nshare --show-ip
nshare --show-ip --include-loopback
```

Lists interface name, address family, and address, then exits. This does not open
a listener, start discovery, create an identity, or query a public IP service.
Devices with Ethernet, Wi-Fi or VPN connections can have several addresses.

## Pair and transfer

On both devices, obtain your own certificate fingerprint:

```sh
nshare trust
```

Compare the full SHA-256 fingerprints through a trusted channel (for example,
read them directly from each device's screen). Then start the receiver:

```sh
nshare receive --output ./downloads
```

On the sender:

```sh
nshare devices
nshare send ./photos --ip 192.168.1.42
# Or choose the full fingerprint shown by discovery:
nshare send ./photos --to <receiver-fingerprint>
```

On first connection each side prompts to trust the peer after fingerprint
verification. Type `yes` only after the comparison. The receiver then separately
approves the transfer offer. Remembered identity trust does not automatically
accept offers. Sender input `./photos` becomes `downloads/photos/...`.
No arguments prints help; `send --help` and `receive --help` describe options.

For noninteractive use, supply fingerprints you have **already verified**:

```sh
nshare receive --output ./downloads --once --accept --peer-fingerprint <sender-fingerprint>
nshare send ./photos --ip 192.168.1.42 --peer-fingerprint <receiver-fingerprint>
```

`--accept` accepts offers only after peer authentication. It does not bypass
pairing. `--once` exits after the first transfer attempt. Otherwise the receiver
continues listening and handles one authenticated session at a time.

Transfer TCP port defaults to 53317; discovery UDP port defaults to 1970. Open
those inbound ports on the receiver's local-network firewall profile. Use
`--port` and `--discovery-port` to change them. Discovery never establishes trust.
If Wi-Fi client isolation, a VPN or a firewall blocks broadcast, use `--ip`.
For IPv6, bind the receiver with `--bind ::` and connect with a direct IPv6
address; link-local addresses may need an interface scope such as `%en0`.
Discovery currently returns IPv4 addresses only.

For a transfer between two processes on this same device, see the
[same-device test instructions and results](docs/same-device-test.md).

## Conflicts and resume

- Default `--conflict refuse`: existing destination files are left untouched.
- `--conflict overwrite`: replace a file only after its replacement is verified.
- `--conflict skip`: keep existing files and report them as skipped, not verified.
- Resume is enabled by default. Re-run the same send command after interruption.
- `send --no-resume` discards retained partial data for that offered file and
  restarts it; it does not authorize overwriting a finalized destination.

Partial files and completion receipts live in the output root's `.nshare-state`
directory, bound to the sender identity, deterministic manifest and canonical
output root. Receiver hashes its retained prefix; sender independently compares
it before continuing. Incomplete trailing chunks are discarded. Full SHA-256
and file size are checked before finalization. A changed source produces a new
manifest and cannot reuse old partial bytes. A corrupt prefix fails clearly;
retry with `--no-resume`.

Completed files are rehashed before a receipt is reused, allowing retries after
lost acknowledgments without sending data again. Transfer success requires the
receiver's final acknowledgment. A disconnection can leave earlier files
complete; folder transfers are not all-or-nothing transactions.

To discard all retained partials/receipts, stop the receiver and delete only
`.nshare-state` inside the selected output root. Finalized files remain. Retain
receipts if you want idempotent retries under the default refusal policy.

## Identity and local state

Global `--state-dir <directory>` must appear before the command. Default identity
and trust storage is `$XDG_CONFIG_HOME/nshare` or `~/.config/nshare` on Unix,
and `%APPDATA%/nshare` on Windows (with a user-profile fallback).

```sh
nshare trust
nshare trust --forget <fingerprint>
nshare --state-dir ./private-state receive --output ./downloads
```

The state directory contains a private key: keep it private. Unix permissions are
restricted using the platform `chmod` executable; Windows uses inherited ACLs
from the selected user directory. A changed identity at a pinned address is
rejected; verify the change before forgetting the old fingerprint. Certificates
last ten years; deliberate identity rotation requires fresh pairing.

## Limits and file policy

Offers are limited to 1024 entries and 256 KiB of encoded metadata. Split larger
folders into separate sends. Data chunks are 64 KiB and writes use backpressure;
file contents are never loaded entirely into memory. Files are hashed before
sending and verified again at the destination, adding disk reads intentionally.

Paths use portable relative names. Links, traversal, absolute paths, Windows
reserved names, case- or Unicode-normalization-colliding entries and unsupported filesystem objects are
rejected. Empty files, empty folders and Unicode names are preserved. Permission
bits, timestamps, hard-link relationships, sparse layout and extended attributes
are not preserved. Collision checks compare Unicode NFC and case-folded paths while preserving
original names. Other unsupported names fail through the destination filesystem;
names are not silently rewritten.

The caller-selected output root is canonicalized. Receiver-controlled paths below
it reject symlinks. Keep that root under your control: another local process
must not concurrently replace its components. Dart's portable filesystem API
does not provide race-free directory-relative file operations against a hostile
local writer. Run only one receiver per output root.

Ctrl+C cancels sending or stops receiving. Connection timeout is 10 seconds,
network inactivity timeout 60 seconds, approval timeout five minutes. Exit codes:
0 success, 1 operation failure, 64 usage error, 130 cancellation. Diagnostics and
progress go to stderr; results go to stdout.

## Library and development

Import `package:nshare/nshare.dart`. `sendPath`, `TransferReceiver`, typed approval
callbacks, `CancellationToken`, progress events and `TransferTask.progress`
separate transfer behavior from UI code. See [example/send.dart](example/send.dart).
Flutter itself is not required. Mobile permission, lifecycle, key-storage and
interface discovery adapters still require platform-specific work.

```sh
dart format --output=none --set-exit-if-changed lib bin test example tool
dart analyze --fatal-infos
dart test
```

Tests include real TLS sockets and compiled CLI processes, interruption/restart,
verified resume, and corruption/refusal cases. CI runs Linux, macOS and Windows,
plus the minimum Dart SDK on Linux. Physical two-device networking and mobile
behavior need separate hardware validation.

See [architecture](docs/architecture.md), [protocol v2](docs/protocol-v2.md), and
[validation record](docs/validation.md).

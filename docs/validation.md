# Rewrite validation

Validated in the Linux development workspace on 2026-10-31 with Dart 3.13.7.

## Local checks

- `dart format --output=none --set-exit-if-changed lib bin test example tool`: clean.
- `dart analyze --fatal-infos`: no issues.
- `dart test --reporter expanded`: all 322 tests passed (280 additional tests; zero failures or skips locally).
- Native compilation: `dart compile exe bin/nshare.dart` succeeded. The process
  integration test also builds and runs a fresh native executable.
- Native `--show-ip`: listed real IPv4/IPv6 interfaces and scoped link-local
  addresses without starting a receiver.
- `git diff --check`: clean.

Coverage includes every frame split boundary, seeded random fragmentation across
mixed frames, exact payload-size boundaries, fragmented/coalesced/malformed/oversized protocol frames,
truncated streams, invalid session ordering, real TLS authentication and identity
persistence, changed pin rejection, bounded loopback UDP discovery, path and
symlink rejection, Unicode/case collisions, total-size overflow, hash mismatch,
empty/nested/Unicode files, skip/overwrite policies, refused offers, cancellation,
approval/pairing shutdown without retained trust locks, inactivity deadlines, corrupt resume prefixes, explicit
restart, idempotent finalized-file retries, and missing final acknowledgments.

Native process tests also cover a successful mixed folder transfer, shared
sender/receiver identity and trust storage, zero-byte retries, three independent
sender sessions against one running receiver, default conflict refusal, and
IPv6 loopback (skipped only on hosts without IPv6). Malformed real TLS transfers
exercise invalid offsets, excess bytes, early completion, digest corruption,
wrong transfer IDs and extra data after the declared file size. Each failure
asserts that no final destination file is exposed.

The interruption process test kills a sender during a 32 MiB transfer,
checks that only a partial exists, restarts both processes, resumes with fewer
network bytes, and compares complete source/destination SHA-256 hashes.

See the [expanded test guide](testing.md) and [runner-derived test inventory](test-inventory.json)
for the breakdown. The expanded run includes 48 native process end-to-end tests
(42 new) and 34 new native CLI checks. Both sender and receiver are separate
compiled processes; successful cases verify destination content and both exit
codes. The new failure/recovery case kills the receiver mid-transfer and verifies
resumption after restart.

## Loopback measurements

Run `dart run tool/benchmark.dart` to repeat. Measurements include source hashing,
TLS, file writes, verification, receipt persistence and final acknowledgments.
These are single observations on this workspace, not LAN throughput guarantees.

| Workload | Files | Payload | Elapsed | Payload throughput |
| --- | ---: | ---: | ---: | ---: |
| Single file | 1 | 32 MiB | 1.68 s | 19.1 MiB/s |
| Small files | 128 | 512 KiB | 2.59 s | 0.193 MiB/s |

The initial small-file measurement was 9.20 seconds. Enabling TCP_NODELAY for
small acknowledgment-driven control frames reduced it to 2.59 seconds. No
compression or parallel file streams were introduced.

## CI and remaining platform validation

The workflow runs formatting, fatal-info analysis, the full tests and executable
compilation on Linux, macOS and Windows, plus Dart 3.8.0 on Linux. The workflow
results must be checked after pushing; defining the matrix alone is not evidence
that those platforms passed.

A separate same-device CLI smoke test successfully sent 19 files (2,097,519
bytes) through the host's non-loopback IPv4 interface, verified every file hash,
retried with zero file bytes, then discovered the receiver using `devices` and
sent another file using `--to`. Both sender and receiver exited 0 on all three
transfers. See [results and reproduction](same-device-test.md) and the
[per-file hash record](same-device-results.json).

Physical two-device discovery/transfer, Wi-Fi isolation and firewall behavior
have not been tested in this single-container workspace. Mobile Flutter adapters
and mobile permission/key-storage/lifecycle behavior are outside this release.
Windows ACL hardening uses the chosen user directory's inherited policy; Unix
permission changes use `chmod`. Destination directories must not be concurrently
modified by a hostile local writer; portable Dart path checks cannot eliminate
filesystem races against such a process.

## Original baseline

The source started at revision `3adf003`. Dart was absent from the environment;
a temporary SDK was installed outside the repository. The original locked test
runner attempted to load a frontend-server snapshot removed from modern Dart.
The rewrite updates test tooling and replaces legacy simulation/constructor tests
with tests of the v2 public behavior and real sockets/processes. Old generated
test-output text files and the plaintext v1 implementation were removed.

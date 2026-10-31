# Expanded test suite

The suite contains **322 independently registered tests**, up from 42:
**280 new tests**, including **42 new native end-to-end tests**. The local Linux
run passed every test with no skips. Setup/teardown hooks are excluded from these
counts. [The inventory](test-inventory.json) was derived from the Dart test
runner's JSON events, using non-hidden successful `testDone` events.

Parameterized tests have descriptive, unique names for their inputs and expected
behavior. Assertions inside one test are not counted as additional tests.

| New area | Registered tests | File |
| --- | ---: | --- |
| Portable paths and manifests | 108 | [path/manifest matrix](../test/path_manifest_matrix_test.dart) |
| Wire compatibility and malformed protocol fields | 60 | [protocol matrix](../test/protocol_matrix_test.dart) |
| Trust policy, persistence and concurrent updates | 12 | [trust matrix](../test/trust_matrix_test.dart) |
| Real UDP discovery validation and selection | 24 | [discovery matrix](../test/discovery_matrix_test.dart) |
| Native CLI behavior and exit codes | 34 | [CLI matrix](../test/cli_matrix_test.dart) |
| Native local end-to-end transfers | 42 | [end-to-end matrix](../test/native_e2e_matrix_test.dart) |
| **Additional tests** | **280** | |
| Existing tests retained | 42 | |
| **Total** | **322** | |

## Real local file transfers

```sh
dart test test/native_e2e_matrix_test.dart --reporter expanded
dart test test/process_test.dart --reporter expanded
```

These suites compile `bin/nshare.dart` to a native executable and launch actual
sender and receiver processes on the same device. They connect over local TCP/TLS,
authenticate real generated certificate identities, offer manifests, stream file
data, verify hashes, finalize destination files, and exchange acknowledgments.
The transfer engine, filesystem and network are not mocked.

The 42 new end-to-end cases cover:

- Fourteen file sizes, including zero, one byte, 4 KiB and 64 KiB boundaries,
  multiple chunks, and a file exceeding 1 MiB.
- Seven filename cases with accents, non-Latin characters, emoji, spaces,
  multiple dots, and hidden files.
- Eight directory shapes, including empty trees, deep nesting, 100 small files,
  Unicode directory names, hidden entries and every binary byte value.
- Refuse, skip and overwrite policies, including a file/directory collision.
- Completed-file retry without resending data, tampered destinations, changed
  sources, and explicit replacement.
- Shared same-device identity, remembered trust without new fingerprint
  arguments, incorrect sender pins, and declined noninteractive offers.
- Four independent sender processes using one persistent receiver.
- Abrupt receiver termination: the initial sender fails, only partial data remains,
  and a fresh receiver resumes with fewer transmitted bytes and a matching hash.

Each successful transfer checks both process exit codes and destination bytes or
SHA-256 digests. Folder tests also check directories and all manifest entries.
Failure tests check that rejected operations cannot report successful completion
or replace protected files. Child processes are terminated in `finally` blocks;
stdout/stderr are drained and readiness/completion have bounded deadlines.
Temporary identities and output trees are removed at suite teardown.

The six existing native process tests additionally cover IPv6 loopback and
killed-sender recovery. IPv6 is skipped explicitly on hosts without it; it passed
on this local device. Together these are **48 native end-to-end tests**.

For manual two-terminal commands and the separately recorded non-loopback local
transfer/discovery check, see [same-device testing](same-device-test.md).

## Other behavior covered

Protocol cases assert fixed wire IDs/byte order against explicit compatibility
vectors, malformed JSON and field types, magic/version rejection, undefined IDs,
and maximum advertised lengths rejected before allocation. Existing tests also
cover arbitrary fragmentation, frame-size boundaries, state ordering, invalid
offsets and corrupted data on real TLS connections.

Path/manifest cases exercise traversal, absolute/UNC paths, reserved device names,
control characters, UTF-8 byte limits, Unicode/case collisions, invalid field
types, entry counts, directory metadata and changed source identities.

Trust cases check rejection before approval, remembered identity, explicit pins,
forgetting peers, endpoint preservation, and concurrent mutations through separate
store instances. Discovery tests send malformed UDP responses followed by a valid
positive control, so receiving no traffic cannot produce a false pass.

Native CLI cases verify help/IP reporting without creating state, invalid
arguments and ports, malformed fingerprints, missing sources, trust persistence,
and documented exit codes. They run the compiled executable rather than call
argument parsing functions directly.

## Full verification

```sh
dart pub get
dart format --output=none --set-exit-if-changed lib bin test example tool
dart analyze --fatal-infos
dart test --reporter expanded
```

For inspectable event data, use `dart test --reporter json > test-events.jsonl`.
CI runs the same suite on Linux, macOS and Windows, plus Dart 3.8.0 on Linux.
Same-device tests do not establish that a particular two-device network permits
broadcast or inbound transfers; physical-network firewall/Wi-Fi checks remain
separate.

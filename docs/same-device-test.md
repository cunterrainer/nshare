# Same-device transfer check

The application was tested locally using separate compiled sender and receiver
processes on the same Linux device, with the same identity/trust directory.
No application mocks were used.

## Observed results

| Check | Result |
| --- | --- |
| Direct transfer through a non-loopback network interface | Sender 0; receiver 0 |
| Folder payload | 19 files; 2,097,519 bytes |
| SHA-256 and structure comparison | Every file matched; nested empty directory preserved |
| Names and content | Spaces, Unicode, empty file, full byte-range binary data, text |
| Repeat identical offer | 19 verified files; 0 file bytes resent |
| `devices` discovery | Found the local receiver's fingerprint |
| `send --to` using discovered device | 1 verified file; 40 bytes; both processes exited 0 |

[The JSON record](same-device-results.json) contains per-file hashes and both
processes' success summaries. Test identities were generated temporarily; no
private keys are included in the repository.

## Repeat it locally with two terminals

Build the executable first (`nshare.exe` on Windows):

```sh
dart pub get
dart compile exe bin/nshare.dart -o nshare
```

Run the executable by its local path if it is not on PATH (`./nshare` on Unix,
`.\nshare.exe` in Windows PowerShell). The following examples assume it is on PATH.

1. Create a small folder named `sample` with some files, outside the output folder.
2. Run `nshare trust` and note the `This device` SHA-256 fingerprint.
3. In terminal one, start the receiver:

   ```sh
   nshare receive --bind 127.0.0.1 --no-discover --once --accept --output ./local-received --peer-fingerprint <fingerprint>
   ```

4. In terminal two, using the same user/state directory, run:

   ```sh
   nshare send ./sample --ip 127.0.0.1 --peer-fingerprint <same-fingerprint>
   ```

Both processes should report `Complete` and exit 0. Check the files under
`local-received/sample`. Start the receiver again and repeat the send: with the
same source and retained completion receipts, it should verify the existing files
and report `0 bytes sent`.

For discovery, omit `--no-discover` from the receiver, run `nshare devices`, then
replace `--ip 127.0.0.1` with `--to <same-fingerprint>` on the sender. Broadcast
traffic must be permitted on the local interface. The automated process tests
use direct loopback to remain reliable on CI hosts with restricted broadcast.

## Expanded native end-to-end coverage

There are now 42 additional compiled-process end-to-end tests, alongside the six
original process tests. They exercise byte/chunk boundaries, portable names, eight
folder shapes, refusal/skip/overwrite, shared and remembered identity, repeated
sessions, modified destinations, and receiver-termination recovery.

```sh
dart test test/native_e2e_matrix_test.dart --reporter expanded
```

See [the test guide](testing.md) for the complete 322-test inventory.

## Original process coverage

```sh
dart test test/process_test.dart --reporter expanded
dart test test/receiver_validation_test.dart test/v2_protocol_test.dart
```

The first command builds a fresh executable and runs six process tests, including
IPv4, IPv6, successful folders, shared identity, persistent receiving, refusal,
and killed-sender resume. IPv6 is explicitly skipped if unavailable. Tests use
temporary state/output directories and clean them up afterward.

This confirms same-device behavior. Communication between two physical devices
still needs a separate test of that network's firewall and Wi-Fi settings.

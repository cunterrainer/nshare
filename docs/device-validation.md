# Device and release validation

This checklist distinguishes automated loopback transfers, simulator/emulator
runs and physical-device behavior. A build or simulator pass is not evidence of
camera, Wi-Fi multicast, OEM background policy, sleep/wake or document-provider
behavior. Record device/OS, commit, test date, logs and results for each row.

## Automated native runtime suite

Run with a device ID from `flutter devices`:

```
cd apps/nshare_app
flutter pub get
flutter test integration_test/device_transfer_test.dart -d DEVICE_ID --reporter expanded
```

This suite opens real TLS sockets on the device, sends a 1,052-entry folder through
the durable GUI queue with explicitly enabled compression, compares all 1,050
file payloads, and checks that clipboard refusal preserves the previous system
clipboard while approval changes it. It requires no host CLI process and runs on
Android, iOS, Linux, macOS and Windows. It does not claim two-device networking.
The **Mobile runtime transfers** workflow runs it on an Android emulator and an
iPhone simulator. Both platforms passed on implementation revision `d49bd51`:
[final mobile run](https://github.com/cunterrainer/nshare/actions/runs/41300355954).
The desktop runtime cases also passed on Linux, macOS and Windows. For physical
iOS tests, configure development signing in Xcode.

The separate desktop suite compiles and launches the native CLI, sends files in
both directions through a real Flutter window, selects an outgoing source via
the drop adapter, and confirms the matching-code dialog:

```
flutter test integration_test/desktop_transfer_test.dart -d linux --reporter expanded
# A headless Linux host needs xvfb-run -a before flutter.
```

## Two physical devices

Use a desktop plus Android/iPhone on the same LAN. Keep Dart CLI and Flutter app
on the same commit. In an interactive terminal on the receiver:

```
nshare --show-ip
nshare receive --output ./received
```

On the sender (replace the address with the receiver's shown LAN address):

```
nshare pair --connect 192.168.1.25
nshare send ./fixture-folder --ip 192.168.1.25
```

Compare every code digit on both screens before approving, then approve the file
offer. Repeat with GUI receiver / CLI sender and GUI sender / CLI receiver.
Compute and compare SHA-256 digests independently after transfers. For QR tests,
GUI Receive generates the invitation; the phone scans it. For PCs without cameras,
use **Pair by code** or copy the complete invitation URI into Pair. Decline
unexpected/mismatching code prompts and confirm neither endpoint records trust.

| Area | Physical acceptance check | State in this cloud workspace |
| --- | --- | --- |
| QR | Android and iOS camera permission allow/deny; decode an actual desktop QR; expiry and replay rejection | Pending hardware |
| Code pairing | Android↔desktop, iOS↔desktop, CLI↔GUI compare both displays; decline and retry | Loopback automated; physical pending |
| Discovery | Windows/macOS/Linux/Android/iOS on Wi-Fi; Bonjour permission allow/deny; IPv4 and scoped IPv6; change networks and refresh | iOS system Bonjour implemented; physical pending |
| Fallback | Multicast-blocked Wi-Fi: direct address and copied URI/code pairing still work | Loopback/direct tests pass; physical pending |
| Folder providers | Android SAF and iOS Files: local and cloud provider, duplicate names, denied access, cancellation, app restart | Native adapters compile; provider interaction pending |
| Desktop drop | Actual Explorer/Finder/Linux file manager multi-file and folder drag, cancel drop, queued send; macOS promised file retention | Widget and native adapter tests; OS drag pending |
| Queue | Restart app; pause/retry/restart interrupted transfer; destination conflicts; multiple large folders | Automated sockets/process coverage; physical pending |
| Large transfers | 100k entries, >2 GiB file, constrained storage, disconnect/reconnect, independent hashes | Prior Linux stress records retained; physical pending |
| Android background | Opt in; notification permission; receive with app backgrounded/screen locked; notification Stop; relaunch; OEM battery restrictions | Foreground service implemented; physical pending |
| iOS lifecycle | Background app: receiver stops and UI reports unavailable; return foreground: listener restored; no claim of suspended listening | Implemented; physical pending |
| Desktop background | Tray hide/show, explicit quit, startup opt in/off, user logout, sleep/wake then discovery and transfer | Linux runtime checks; full OS matrix pending |
| Clipboard | Reject preserves clipboard; accept writes exactly once; no passive collection | Automated platform suite; physical cross-device pending |
| Compression | Fresh settings off; enable outgoing and incoming separately; incompatible receiver error; verify logical hashes | Automated tests pass |
| Installed releases | Install/upgrade/uninstall Linux DEB, Windows setup and macOS DMG; CLI PATH; signed Android/iOS install | Linux extraction/transfers, Windows install/uninstall, macOS DMG startup pass in CI; signed/mobile install pending |
| Signing | Authenticode trust/timestamp; Developer ID hardened runtime/notarization/stapling; Android key; iOS profile distribution | Credential-dependent; not run |

## Recording results

Keep the model/OS and exact commit alongside each result, e.g.:

```
Commit:
Device / OS / transport:
Artifact SHA-256 and signing verification:
Scenario:
Steps / received digest:
Result: PASS / FAIL / BLOCKED
Logs or screenshot location:
```

No signing credentials or physical mobile devices are configured in the current
cloud environment. Those rows remain blocked until the owner supplies access;
they are not marked complete by simulated tests or unsigned CI builds.

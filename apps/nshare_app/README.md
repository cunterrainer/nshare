# nshare Flutter

Android/iOS/Windows/macOS/Linux client for the shared Dart nshare engine.

Run `flutter pub get`, then `flutter run -d <device>`. See the repository
[README](../../README.md) for setup, pairing, queue, compression and clipboard.

`flutter test` includes widget/layout tests and real controller interoperability
with a separately compiled CLI. These desktop-host tests need `dart` on PATH.
`integration_test/desktop_transfer_test.dart` drives a native desktop window and
separate CLI processes; on Linux run it under Xvfb with native build dependencies.
It is a desktop integration suite, not a physical-mobile test.

Native platform build success does not validate camera permissions, background
execution, network isolation or document-provider behavior on physical devices.
Android background receiving is opt-in and visible; iOS suspends its listener.
Production signing and store distribution are not configured.

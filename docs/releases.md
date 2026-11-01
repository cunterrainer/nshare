# Building and packaging nshare

The CLI and Flutter app share the Dart core. Desktop distributions always include
both executables; running the CLI does not require Flutter to be installed.
Nothing in these scripts publishes a release, uploads to an app store, or alters
an existing branch. CI artifacts are downloadable for review.

Run from a clean checkout with Python 3.11+, Dart and Flutter on PATH:

```
python3 tool/release/package.py --target linux
python tool/release/package.py --target windows
python3 tool/release/package.py --target macos
python3 tool/release/package.py --target android
python3 tool/release/package.py --target ios
```

Desktop targets require their native host. iOS requires macOS/Xcode. Linux needs
clang, cmake, ninja, pkg-config, GTK3, Ayatana AppIndicator and LZMA development
packages. Windows needs Visual Studio desktop C++ tools and Inno Setup 6 (`iscc`
on PATH or `ISCC` set to its executable). Use Flutter's Android toolchain for APK
and AAB builds. Outputs are under `build/distributions`, with the commit, version,
architecture, signing status and SHA-256 checksums. A pre-existing output directory
is rejected to preserve earlier results; choose a new `--output` for another run.
`--no-build` packages an existing Flutter release build and recompiles the CLI.

| Platform | Artifacts | Installation |
| --- | --- | --- |
| Linux | `.deb`, `.tar.gz` | Install DEB with the system package manager, or extract tar and run `nshare` / `nshare-gui`. DEB installs CLI and GUI launchers and a desktop entry. |
| Windows | setup `.exe`, portable `.zip` | Per-user installer adds Start Menu entries and optionally CLI PATH; uninstaller removes only its own PATH entry. Portable CLI is `nshare.exe`, GUI is `gui/nshare_app.exe`. |
| macOS | `.dmg` containing `.app` and CLI | Drag the app to Applications. Copy the separate `nshare` executable to a directory on PATH. |
| Android | release APK and AAB | Unsigned artifacts require distribution signing before installation/upload. A configured signed build produces an installable APK. |
| iOS | unsigned `.app` ZIP or signed `.ipa` | Unsigned builds validate compilation only. Install signed IPA through the provisioning profile's distribution method. |

## Platform signing

The **Distribution packages** workflow builds unsigned artifacts automatically
when packaging changes. Manually dispatch it with `signed=true` after configuring
secure secrets in the GitHub `release` environment. Signing is optional for local
development; Android release builds never fall back to debug signing.

| Target | Secure release environment configuration |
| --- | --- |
| Android | `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` |
| Windows | `WINDOWS_PFX_BASE64`, `WINDOWS_PFX_PASSWORD`; use a trusted Authenticode certificate supporting PFX import. Hardware-token/remote signing needs a provider-specific adapter. |
| macOS | `MACOS_CERTIFICATE_BASE64` (Developer ID Application P12), `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY`; notarization also requires `APPLE_API_KEY_BASE64` (P8), `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`. |
| iOS | `IOS_CERTIFICATE_BASE64` (Apple Distribution P12), `IOS_CERTIFICATE_PASSWORD`, `IOS_PROFILE_BASE64`, `APPLE_TEAM_ID`, `IOS_BUNDLE_ID`, `IOS_EXPORT_METHOD` (for example `release-testing` or `app-store-connect`). Exact profile team/bundle and expiry are checked. |

`signing_environment.py` creates temporary private files, imports Apple keys into
an isolated temporary keychain, restores the prior keychain list, and deletes
its temporary provisioning profile after the build. Use disposable CI runners.
The Windows adapter imports the PFX into the current-user store, timestamps and
verifies signatures, then removes its imported signing certificate. No private
keys or profiles belong in the repository. Native signed artifacts must still
be installed on devices and pass [device validation](device-validation.md).

For an already prepared signing host, `package.py --signed` uses environment
paths and identities directly. Android variables are `NSHARE_KEYSTORE_PATH`,
`NSHARE_KEYSTORE_PASSWORD`, `NSHARE_KEY_ALIAS`, `NSHARE_KEY_PASSWORD`. Windows uses
`WINDOWS_PFX_PATH` / `WINDOWS_PFX_PASSWORD`. macOS uses `MACOS_SIGN_IDENTITY` plus
`--notarize` and Apple API key variables above (`APPLE_API_KEY_PATH` points to P8).
iOS uses Runner signing settings (team, manual profile, bundle ID, identity)
and `IOS_EXPORT_OPTIONS_PLIST`. The CI adapter temporarily includes these settings
from Runner’s Release.xcconfig, restores it afterward, and leaves plugin framework
identifiers unchanged.

Signed and notarized paths have not been executed without owner credentials.
An unsigned build passing does not establish signing or store readiness.


## Package smoke checks

CI extracts the Linux DEB, launches its CLI and GUI, and sends real plain and
compressed folders with byte-for-byte verification. On the disposable Windows
runner it installs to a path containing spaces, checks CLI help/IP, native GUI
startup and PATH registration, then uninstalls and verifies the old PATH. macOS
CI mounts the DMG read-only, launches its CLI and GUI, validates the Applications
link and detaches the volume. These checks exercise unsigned development packages;
they do not replace signed installation or physical lifecycle acceptance.

All five unsigned distribution jobs and their desktop smoke checks passed for
implementation revision `d49bd51` on 2026-11-01:
[distribution artifacts and checks](https://github.com/cunterrainer/nshare/actions/runs/41300363423).

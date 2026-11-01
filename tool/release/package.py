#!/usr/bin/env python3
"""Build installable/portable CLI + Flutter distributions without publishing them."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'apps/nshare_app'


def run(args, cwd=ROOT, env=None):
    # Never print commands: signing tools may receive credentials as arguments.
    result = subprocess.run([str(a) for a in args], cwd=cwd, env=env)
    if result.returncode:
        raise RuntimeError(f'{Path(str(args[0])).name} failed (exit {result.returncode})')


def checksum(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def required(name):
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f'{name} must be configured for signed builds')
    return value


def archive_zip(source, target):
    # ditto preserves macOS bundle symlinks and metadata.
    if sys.platform == 'darwin':
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', source, target])
    else:
        with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as out:
            for path in sorted(source.rglob('*')):
                if path.is_file():
                    out.write(path, path.relative_to(source.parent))


def sign_windows(target):
    run(['powershell', '-NoProfile', '-NonInteractive', '-File',
         ROOT / 'tool/release/sign-windows.ps1', '-Target', target])


def sign_macos(app, cli):
    identity = required('MACOS_SIGN_IDENTITY')
    # Sign nested Mach-O objects before framework/app containers.
    for path in sorted(app.rglob('*'), key=lambda p: len(p.parts), reverse=True):
        if path.is_symlink():
            continue
        macho = path.is_file() and subprocess.run(
            ['file', '-b', str(path)], capture_output=True, text=True).stdout.startswith('Mach-O')
        if macho or path.suffix in ('.framework', '.app'):
            run(['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity, path])
    for path in (app, cli):
        args = ['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity]
        if path == app:
            args += ['--entitlements', APP / 'macos/Runner/Release.entitlements']
        run(args + [path])
        run(['codesign', '--verify', '--deep', '--strict', path])


def notarize(target):
    run(['xcrun', 'notarytool', 'submit', target, '--wait', '--key', required('APPLE_API_KEY_PATH'),
         '--key-id', required('APPLE_API_KEY_ID'), '--issuer', required('APPLE_API_ISSUER')])
    run(['xcrun', 'stapler', 'staple', target])
    run(['xcrun', 'stapler', 'validate', target])


def package(target, output, build, signed, notarized):
    host = {'linux': 'linux', 'win32': 'windows', 'darwin': 'macos'}.get(sys.platform)
    if target in ('linux', 'windows', 'macos') and target != host:
        raise RuntimeError(f'{target} must be built on a {target} host')
    if target == 'ios' and host != 'macos':
        raise RuntimeError('iOS packaging requires macOS/Xcode')
    if signed and target == 'linux':
        raise RuntimeError('Linux packages use repository/package checksums; --signed is for platform signing')
    if notarized and (target != 'macos' or not signed):
        raise RuntimeError('--notarize requires --target macos --signed')
    version = re.search(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)',
                        (APP / 'pubspec.yaml').read_text(), re.M).group(1)
    machine = platform.machine().lower()
    arch = 'arm64' if machine in ('aarch64', 'arm64') else 'x64'
    if target == 'android':
        arch = 'universal'
    elif target == 'ios':
        arch = 'arm64'
    output.mkdir(parents=True, exist_ok=True)
    # One target directory per run; never silently overwrite an earlier package.
    destination = output / f'nshare-{version}-{target}-{arch}-{("signed" if signed else "unsigned")}'
    destination.mkdir()
    try:
        with tempfile.TemporaryDirectory(prefix='nshare-release-') as temp:
            staging = Path(temp) / 'nshare'
            staging.mkdir()
            cli = staging / ('nshare.exe' if target == 'windows' else 'nshare')
            if build:
                run(['dart', 'pub', 'get'])
                run(['flutter', 'pub', 'get'], APP)
            if target in ('linux', 'windows', 'macos'):
                run(['dart', 'compile', 'exe', 'bin/nshare.dart', '-o', cli])
                run([cli, '--help'])
                if build:
                    run(['flutter', 'build', target, '--release'], APP)
                if target == 'linux':
                    bundle = APP / f'build/linux/{arch}/release/bundle'
                    shutil.copytree(bundle, staging / 'gui', symlinks=True)
                    launcher = staging / 'nshare-gui'
                    launcher.write_text('#!/bin/sh\nexec "$(dirname "$(readlink -f "$0")")/gui/nshare_app" "$@"\n')
                    launcher.chmod(0o755)
                    with tarfile.open(destination / 'nshare-linux.tar.gz', 'w:gz') as out:
                        out.add(staging, arcname='nshare')
                    deb = Path(temp) / 'deb'
                    shutil.copytree(staging, deb / 'opt/nshare', symlinks=True)
                    (deb / 'DEBIAN').mkdir()
                    (deb / 'DEBIAN/control').write_text(
                        f'Package: nshare\nVersion: {version}\nArchitecture: {"arm64" if arch == "arm64" else "amd64"}\n'
                        'Maintainer: nshare contributors\nSection: net\nPriority: optional\n'
                        'Depends: libgtk-3-0t64 | libgtk-3-0, libayatana-appindicator3-1, libstdc++6, liblzma5\n'
                        'Description: Local encrypted file and clipboard sharing with CLI and Flutter UI\n')
                    (deb / 'usr/bin').mkdir(parents=True)
                    for name in ('nshare', 'nshare-gui'):
                        (deb / f'usr/bin/{name}').symlink_to(f'/opt/nshare/{name}')
                    (deb / 'usr/share/applications').mkdir(parents=True)
                    (deb / 'usr/share/applications/nshare.desktop').write_text(
                        '[Desktop Entry]\nType=Application\nName=nshare\nExec=nshare-gui\nIcon=nshare\n'
                        'Terminal=false\nCategories=Network;FileTransfer;\n')
                    (deb / 'usr/share/icons/hicolor/256x256/apps').mkdir(parents=True)
                    shutil.copy2(APP / 'assets/tray.png',
                                 deb / 'usr/share/icons/hicolor/256x256/apps/nshare.png')
                    for path in [deb, *deb.rglob('*')]:
                        if not path.is_symlink():
                            path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)
                    run(['dpkg-deb', '--root-owner-group', '--build', deb, destination / 'nshare.deb'])
                elif target == 'windows':
                    shutil.copytree(APP / 'build/windows/x64/runner/Release', staging / 'gui')
                    if signed:
                        sign_windows(staging)
                    archive_zip(staging, destination / 'nshare-windows.zip')
                    run([required('ISCC') if os.environ.get('ISCC') else 'iscc',
                         f'/DSourceDir={staging}', f'/DOutputDir={destination}', f'/DAppVersion={version}',
                         ROOT / 'tool/release/windows.iss'])
                    if signed:
                        sign_windows(destination / 'nshare-setup.exe')
                else:
                    apps = list((APP / 'build/macos/Build/Products/Release').glob('*.app'))
                    if len(apps) != 1:
                        raise RuntimeError('Expected exactly one built macOS .app')
                    app = staging / 'nshare.app'
                    shutil.copytree(apps[0], app, symlinks=True)
                    if signed:
                        sign_macos(app, cli)
                    # Keep the CLI outside the app as a first-class executable.
                    (staging / 'Applications').symlink_to('/Applications')
                    dmg = destination / 'nshare-macos.dmg'
                    run(['hdiutil', 'create', '-volname', 'nshare', '-srcfolder', staging, '-ov', '-format', 'UDZO', dmg])
                    if notarized:
                        notarize(dmg)
            elif target == 'android':
                if signed:
                    for name in ('NSHARE_KEYSTORE_PATH', 'NSHARE_KEYSTORE_PASSWORD', 'NSHARE_KEY_ALIAS', 'NSHARE_KEY_PASSWORD'):
                        required(name)
                elif os.environ.get('NSHARE_KEYSTORE_PATH'):
                    raise RuntimeError('Signing environment present; explicitly use --signed')
                if build:
                    run(['flutter', 'build', 'apk', '--release'], APP)
                    run(['flutter', 'build', 'appbundle', '--release'], APP)
                apk = APP / 'build/app/outputs/flutter-apk/app-release.apk'
                sdk = Path(os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT') or
                           (Path.home() / ('Library/Android/sdk' if host == 'macos' else 'Android/Sdk')))
                signers = sorted((sdk / 'build-tools').glob('*/apksigner*'))
                if not signers:
                    raise RuntimeError('Android build-tools apksigner is required to verify package signing status')
                verified = subprocess.run([str(signers[-1]), 'verify', str(apk)], capture_output=True).returncode == 0
                if verified != signed:
                    raise RuntimeError('APK signing status does not match the requested distribution mode')
                shutil.copy2(apk, destination / ('nshare.apk' if signed else 'nshare-unsigned.apk'))
                shutil.copy2(APP / 'build/app/outputs/bundle/release/app-release.aab', destination / 'nshare.aab')
            else:
                if signed:
                    # Runner signing settings must be configured on the host;
                    # signing_environment.py supplies a temporary Runner-only include.
                    options = Path(required('IOS_EXPORT_OPTIONS_PLIST'))
                    run(['flutter', 'build', 'ipa', '--release', '--export-options-plist', options], APP)
                    ipas = list((APP / 'build/ios/ipa').glob('*.ipa'))
                    if len(ipas) != 1:
                        raise RuntimeError('Expected exactly one signed IPA')
                    shutil.copy2(ipas[0], destination / ipas[0].name)
                else:
                    if build:
                        run(['flutter', 'build', 'ios', '--release', '--no-codesign'], APP)
                    app = next((APP / 'build/ios/iphoneos').glob('*.app'))
                    archive_zip(app, destination / 'nshare-ios-unsigned.zip')
        artifacts = sorted(destination.iterdir())
        (destination / 'SHA256SUMS').write_text(''.join(
            f'{checksum(path)}  {path.name}\n'
            for path in artifacts))
        (destination / 'build.json').write_text(json.dumps({
            'version': version, 'target': target, 'architecture': arch,
            'platformSigned': signed, 'notarized': notarized,
            'dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip()),
            'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        }, indent=2) + '\n')
        print(f'Packages: {destination}')
    except BaseException:
        shutil.rmtree(destination)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['linux', 'windows', 'macos', 'android', 'ios'], required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/distributions')
    parser.add_argument('--no-build', action='store_true', help='Package an existing Flutter release build; CLI is always compiled')
    parser.add_argument('--signed', action='store_true')
    parser.add_argument('--notarize', action='store_true')
    args = parser.parse_args()
    try:
        package(args.target, args.output.resolve(), not args.no_build, args.signed, args.notarize)
    except (RuntimeError, OSError, StopIteration) as error:
        print(f'Packaging failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

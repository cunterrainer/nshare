#!/usr/bin/env python3
"""Prepare short-lived signing material on a disposable release runner."""
import argparse
import base64
import datetime
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import subprocess
import sys
import tempfile
from package import ROOT, APP, required


def quiet(args):
    result = subprocess.run([str(a) for a in args], capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{Path(str(args[0])).name} failed while configuring signing')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['windows', 'macos', 'android', 'ios'], required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/distributions')
    parser.add_argument('--notarize', action='store_true')
    args = parser.parse_args()
    old_keychains = None
    keychain = profile_path = None
    release_config = original_config = None
    with tempfile.TemporaryDirectory(prefix='nshare-signing-') as directory:
        temp = Path(directory)
        env = dict(os.environ)
        def material(secret, filename):
            path = temp / filename
            path.write_bytes(base64.b64decode(required(secret), validate=True))
            path.chmod(0o600)
            env.pop(secret, None)
            return path
        try:
            if args.target == 'android':
                env['NSHARE_KEYSTORE_PATH'] = str(material('ANDROID_KEYSTORE_BASE64', 'release.jks'))
            elif args.target == 'windows':
                env['WINDOWS_PFX_PATH'] = str(material('WINDOWS_PFX_BASE64', 'release.pfx'))
            else:
                p12 = material('APPLE_CERTIFICATE_BASE64', 'release.p12')
                password = required('APPLE_CERTIFICATE_PASSWORD')
                keychain = temp / 'release.keychain-db'
                key_password = secrets.token_hex(32)
                old_keychains = shlex.split(quiet(['security', 'list-keychains', '-d', 'user']).decode())
                quiet(['security', 'create-keychain', '-p', key_password, keychain])
                quiet(['security', 'unlock-keychain', '-p', key_password, keychain])
                quiet(['security', 'set-keychain-settings', '-lut', '21600', keychain])
                quiet(['security', 'import', p12, '-k', keychain, '-P', password, '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'])
                quiet(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', key_password, keychain])
                quiet(['security', 'list-keychains', '-d', 'user', '-s', keychain, *old_keychains])
                if args.target == 'ios':
                    profile = material('IOS_PROFILE_BASE64', 'release.mobileprovision')
                    data = plistlib.loads(quiet(['security', 'cms', '-D', '-i', profile]))
                    team, bundle = required('APPLE_TEAM_ID'), required('IOS_BUNDLE_ID')
                    if data['TeamIdentifier'] != [team] or data['Entitlements']['application-identifier'] != f'{team}.{bundle}':
                        raise RuntimeError('Provisioning profile must match the team and exact bundle ID')
                    if data['ExpirationDate'] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
                        raise RuntimeError('Provisioning profile has expired')
                    uuid = data['UUID']
                    profile_path = Path.home() / 'Library/MobileDevice/Provisioning Profiles' / f'{uuid}.mobileprovision'
                    if profile_path.exists():
                        profile_path = None
                        raise RuntimeError('Use a disposable runner: this provisioning profile already exists')
                    profile_path.parent.mkdir(parents=True, exist_ok=True)
                    profile_path.write_bytes(profile.read_bytes())
                    config = temp / 'signing.xcconfig'
                    config.write_text(f'DEVELOPMENT_TEAM = {team}\nPRODUCT_BUNDLE_IDENTIFIER = {bundle}\n'
                                      f'CODE_SIGN_STYLE = Manual\nCODE_SIGN_IDENTITY = Apple Distribution\n'
                                      f'PROVISIONING_PROFILE_SPECIFIER = {uuid}\n')
                    options = temp / 'ExportOptions.plist'
                    options.write_bytes(plistlib.dumps({'method': required('IOS_EXPORT_METHOD'), 'teamID': team,
                        'signingStyle': 'manual', 'provisioningProfiles': {bundle: uuid}}))
                    # Scope signing overrides to Runner; a global xcconfig would
                    # also change identifiers/profiles of plugin frameworks.
                    release_config = APP / 'ios/Flutter/Release.xcconfig'
                    original_config = release_config.read_bytes()
                    release_config.write_bytes(original_config + f'\n#include "{config}"\n'.encode())
                    env.pop('XCODE_XCCONFIG_FILE', None)
                    env['IOS_EXPORT_OPTIONS_PLIST'] = str(options)
                if args.notarize:
                    env['APPLE_API_KEY_PATH'] = str(material('APPLE_API_KEY_BASE64', 'AuthKey.p8'))
            command = [sys.executable, str(ROOT / 'tool/release/package.py'), '--target', args.target,
                       '--output', str(args.output), '--signed']
            if args.notarize:
                command.append('--notarize')
            return subprocess.run(command, cwd=ROOT, env=env).returncode
        finally:
            if release_config is not None and original_config is not None:
                release_config.write_bytes(original_config)
            if profile_path and profile_path.exists():
                profile_path.unlink()
            if old_keychains is not None:
                quiet(['security', 'list-keychains', '-d', 'user', '-s', *old_keychains])
            if keychain and keychain.exists():
                quiet(['security', 'delete-keychain', keychain])


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f'Signing setup failed: {error}', file=sys.stderr)
        sys.exit(1)

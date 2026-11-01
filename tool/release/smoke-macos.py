#!/usr/bin/env python3
"""Mount a built disk image and launch its bundled CLI and Flutter executable."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


def run(args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stdout}\n{result.stderr}')
    return result.stdout


with tempfile.TemporaryDirectory(prefix='nshare-dmg-smoke-') as temporary:
    mount = Path(temporary) / 'mounted'
    mount.mkdir()
    run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, Path(sys.argv[1]).resolve()])
    try:
        assert 'Usage:' in run([mount / 'nshare', '--help'])
        assert '127.0.0.1' in run([mount / 'nshare', '--show-ip', '--include-loopback'])
        app = mount / 'nshare.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        assert 'state-dir' in run([app / 'Contents/MacOS' / info['CFBundleExecutable'], '--help'])
        assert (mount / 'Applications').is_symlink()
        assert (mount / 'Applications').readlink() == Path('/Applications')
    finally:
        run(['hdiutil', 'detach', mount])
print('PASS: DMG mounts, bundled CLI help/IP and native GUI start, Applications link is valid')

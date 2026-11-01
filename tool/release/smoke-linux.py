#!/usr/bin/env python3
"""Extract the DEB, launch both programs, and transfer real files using its CLI."""
import hashlib
import os
from pathlib import Path
import re
import select
import socket
import subprocess
import sys
import tempfile


def run(args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stdout}\n{result.stderr}')
    return result.stdout


def main():
    deb = Path(sys.argv[1]).resolve()
    for line in (deb.parent / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split('  ', 1)
        path = (deb.parent / name).resolve()
        if path.parent != deb.parent:
            raise RuntimeError('Checksum path escapes distribution directory')
        with path.open('rb') as source:
            if hashlib.file_digest(source, 'sha256').hexdigest() != digest:
                raise RuntimeError(f'Checksum mismatch: {name}')
    with tempfile.TemporaryDirectory(prefix='nshare-package-smoke-') as temporary:
        root = Path(temporary)
        run(['dpkg-deb', '-x', deb, root / 'installed'])
        cli = root / 'installed/opt/nshare/nshare'
        assert 'Usage:' in run([cli, '--help'])
        if os.environ.get('DISPLAY'):
            assert 'state-dir' in run([root / 'installed/opt/nshare/gui/nshare_app', '--help'])
        else:
            raise RuntimeError('Run under xvfb-run or a desktop DISPLAY to verify the packaged GUI')
        pins = []
        states = [root / 'sender', root / 'receiver']
        for state in states:
            result = run([cli, '--state-dir', state, 'trust'])
            pins.append(re.search(r'This device: ([a-f0-9]{64})', result).group(1))
        folder = root / 'fixture'
        (folder / 'empty').mkdir(parents=True)
        (folder / 'binary').write_bytes(bytes(range(256)) * 4096)
        (folder / 'text.txt').write_text('Installed package transfer\n' * 1000)
        for compressed in (False, True):
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            output = root / ('compressed' if compressed else 'plain')
            args = [str(cli), '--state-dir', str(states[1]), 'receive', '--once', '--accept',
                    '--peer-fingerprint', pins[0], '--bind', '127.0.0.1', '--port', str(port),
                    '--no-discover', '--output', str(output)]
            if compressed:
                args.append('--allow-compression')
            receiver = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                while True:
                    if not select.select([receiver.stderr], [], [], 20)[0]:
                        raise RuntimeError('Installed receiver did not become ready')
                    line = receiver.stderr.readline()
                    if line.startswith('Listening on'):
                        break
                    if not line and receiver.poll() is not None:
                        raise RuntimeError('Installed receiver exited before listening')
                send = [cli, '--state-dir', states[0], 'send', folder, '--ip', '127.0.0.1',
                        '--port', str(port), '--peer-fingerprint', pins[1]]
                if compressed:
                    send.append('--compress')
                assert 'Complete:' in run(send)
                _, errors = receiver.communicate(timeout=30)
                if receiver.returncode:
                    raise RuntimeError(errors)
                for name in ('binary', 'text.txt'):
                    assert (output / 'fixture' / name).read_bytes() == (folder / name).read_bytes()
                assert (output / 'fixture/empty').is_dir()
            finally:
                if receiver.poll() is None:
                    receiver.terminate()
                    receiver.communicate(timeout=10)
        print('PASS: package checksums, extracted CLI/GUI startup, plain and compressed TLS folder transfers')


if __name__ == '__main__':
    main()

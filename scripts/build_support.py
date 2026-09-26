"""Shared version metadata and checksum-pinned distribution dependencies."""
import sys

if sys.version_info < (3, 11):
    raise SystemExit('RightClick build scripts require Python 3.11 or newer.')

import hashlib
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
SEVENZIP_VERSION = '26.03'
BOTTLE_SHA256 = '5833969c107401708c0ff136d79031831ae606e3d57962487ff85a71aa1bca50'
BOTTLE_URL = f'https://ghcr.io/v2/homebrew/core/sevenzip/blobs/sha256:{BOTTLE_SHA256}'
SOURCE_NAME = '7z2603-src.tar.xz'
SOURCE_URL = f'https://github.com/ip7z/7zip/releases/download/{SEVENZIP_VERSION}/{SOURCE_NAME}'
SOURCE_SHA256 = '9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4'


def project_version(root=ROOT):
    version = tomllib.loads((root / 'Cargo.toml').read_text())['package']['version']
    if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', version):
        raise ValueError('Release versions must use the stable X.Y.Z format.')
    return version


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def download_verified(url, destination, sha256, headers=()):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and digest(destination) == sha256:
        return destination
    temporary = destination.with_suffix(destination.suffix + '.download')
    args = ['curl', '--fail', '--location', '--retry', '3', '--retry-all-errors',
            '--connect-timeout', '15', '--max-time', '120']
    for header in headers:
        args.extend(['--header', header])
    subprocess.run([*args, '--output', str(temporary), url], check=True)
    if digest(temporary) != sha256:
        raise RuntimeError(f'Checksum mismatch: {destination.name}')
    temporary.replace(destination)
    return destination


def sevenzip_binary():
    """Use a fixed Sonoma/arm64 bottle, independent of the build host's macOS."""
    override = os.environ.get('RUSTCLICK_7ZZ')
    if override:
        binary = Path(override).resolve(strict=True)
    else:
        cache = ROOT / 'build' / 'dependencies'
        archive = download_verified(BOTTLE_URL, cache / 'sevenzip-26.03.arm64_sonoma.bottle.tar.gz',
                                    BOTTLE_SHA256, headers=('Authorization: Bearer QQ==',))
        binary = cache / 'sevenzip' / SEVENZIP_VERSION / '7zz'
        binary.parent.mkdir(parents=True, exist_ok=True)
        # Extract just the verified executable; do not unpack arbitrary archive paths or links.
        with tarfile.open(archive) as bundle:
            member = bundle.getmember(f'sevenzip/{SEVENZIP_VERSION}/bin/7zz')
            if not member.isfile():
                raise RuntimeError('7-Zip bottle executable is not a regular file')
            with bundle.extractfile(member) as stream:
                binary.write_bytes(stream.read())
        binary.chmod(0o755)
    banner = subprocess.check_output([str(binary), 'i'], text=True)
    if not re.search(rf'^7-Zip .*\b{re.escape(SEVENZIP_VERSION)}\b', banner, re.MULTILINE):
        raise RuntimeError(f'Expected 7-Zip {SEVENZIP_VERSION}')
    return binary

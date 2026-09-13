#!/usr/bin/env python3
"""Build and verify a self-contained, ad-hoc signed Apple Silicon DMG/ZIP."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / 'dist'
BUILD = ROOT / 'build'
APP = DIST / 'RightClick.app'
SOURCE_NAME = '7z2603-src.tar.xz'
SOURCE_URL = f'https://github.com/ip7z/7zip/releases/download/26.03/{SOURCE_NAME}'
SOURCE_SHA256 = '9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4'


def run(*args, capture=False, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, cwd=ROOT,
                          stdout=subprocess.PIPE if capture else None, **kwargs)


def output(*args):
    return run(*args, capture=True, text=True).stdout


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def bundle_manifest(app):
    entries = {}
    for path in sorted(app.rglob('*')):
        key = path.relative_to(app).as_posix()
        if path.is_symlink():
            entries[key] = ['symlink', os.readlink(path)]
        elif path.is_file():
            entries[key] = ['file', digest(path), path.stat().st_mode & 0o777]
    return entries


def include_licenses():
    licenses = APP / 'Contents/Resources/Licenses'
    licenses.mkdir()
    shutil.copy2(ROOT / 'LICENSE', licenses / 'RightClick-MIT.txt')
    shutil.copy2(ROOT / 'assets/7ZIP-LICENSE.txt', licenses / '7ZIP-LICENSE.txt')
    cargo = shutil.which('cargo') or Path.home() / '.cargo/bin/cargo'
    metadata = json.loads(output(cargo, 'metadata', '--locked', '--format-version', '1',
                                 '--filter-platform', 'aarch64-apple-darwin'))
    text = ['RightClick — Rust dependency notices',
            'Includes the locked dependency graph, including build and test tools.', '']
    for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
        if package['name'] == 'rustclick':
            continue
        directory = Path(package['manifest_path']).parent
        files = sorted(p for p in directory.iterdir() if p.is_file()
                       and p.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')))
        if not files:
            raise RuntimeError(f"Missing license text: {package['name']}")
        text.extend(['=' * 72, f"{package['name']} {package['version']}",
                     f"Declared license: {package['license']}", package.get('repository') or '', ''])
        for path in files:
            text.extend([path.name, path.read_text(), ''])
    (licenses / 'RUST-DEPENDENCIES.txt').write_text('\n'.join(text), encoding='utf-8')

    seven = APP / 'Contents/Resources/bin/7zz'
    if '26.03' not in output(seven, 'i').splitlines()[1]:
        raise RuntimeError('Update the corresponding source archive for this 7-Zip version')
    archive = BUILD / SOURCE_NAME
    if not archive.exists() or digest(archive) != SOURCE_SHA256:
        download = archive.with_suffix('.download')
        run('curl', '--fail', '--location', '--retry', '2', '--max-time', '90',
            '--output', download, SOURCE_URL)
        if digest(download) != SOURCE_SHA256:
            raise RuntimeError('7-Zip source checksum mismatch')
        download.replace(archive)
    shutil.copy2(archive, licenses / SOURCE_NAME)
    (licenses / '7ZIP-SOURCE.txt').write_text(
        '7-Zip 26.03 — unmodified upstream source included alongside the executable.\n'
        f'Source: {SOURCE_URL}\nSHA-256: {SOURCE_SHA256}\n\n'
        'The bundled standalone 7zz was built by Homebrew for arm64 macOS.\n'
        'RightClick invokes it as a separate process.\n'
        'Build from the included source on an Apple Silicon Mac with Command Line Tools:\n'
        '  tar -xf 7z2603-src.tar.xz\n'
        '  cd CPP/7zip/Bundles/Alone2\n'
        '  make -f ../../cmpl_mac_arm64.mak DISABLE_RAR_COMPRESS=1\n'
        '  # Output: b/m_arm64/7zz\n'
        'Full license and build documentation are in the source archive DOC directory.\n',
        encoding='utf-8')


def check_binaries():
    info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    minimum = tuple(map(int, info['LSMinimumSystemVersion'].split('.')))
    binaries = []
    for path in sorted(APP.rglob('*')):
        if not path.is_file() or 'Mach-O' not in output('file', '-b', path):
            continue
        if output('lipo', '-archs', path).strip() != 'arm64':
            raise RuntimeError(f'Expected arm64 binary: {path}')
        load_commands = output('otool', '-l', path)
        versions = re.findall(r'\bminos\s+([\d.]+)', load_commands)
        if not versions or any(tuple(map(int, v.split('.'))) > minimum for v in versions):
            raise RuntimeError(f'Binary exceeds declared macOS minimum: {path}, {versions}')
        for line in output('otool', '-L', path).splitlines()[1:]:
            dependency = line.strip().split(' (compatibility')[0]
            if not dependency.startswith(('/usr/lib/', '/System/Library/', '@rpath/', '@loader_path/')):
                raise RuntimeError(f'Nonportable dynamic library reference: {dependency}')
        binaries.append({'path': str(path.relative_to(APP)), 'arch': 'arm64', 'minOS': versions})
    if len(binaries) != 4:
        raise RuntimeError(f'Expected four packaged Mach-O binaries, found {len(binaries)}')
    return info, binaries


def smoke(app, temporary):
    # Loading the native library from this location also checks its runtime dependencies.
    # Run this in a child so dyld releases the mapped image before DMG unmount.
    run(sys.executable, '-c',
        "import ctypes,sys; lib=ctypes.CDLL(sys.argv[1]); "
        "getattr(lib,'rustclick_start'); getattr(lib,'rustclick_native')",
        app / 'Contents/Frameworks/libRustClickUI.dylib')
    executable = app / 'Contents/MacOS/RightClick'
    environment = {**os.environ, 'RUSTCLICK_DATA_DIR': str(temporary / 'preferences')}

    def call(**request):
        result = run(executable, '--request', json.dumps(request), capture=True, text=True,
                     env=environment)
        response = json.loads(result.stdout)
        if not response.get('ok'):
            raise RuntimeError(response)
        return response['data']

    created = call(cmd='create', dir=str(temporary), name='分发验证', format='md')
    original = Path(created['paths'][0])
    for format_name in ['zip', '7z']:
        archive = call(cmd='archive7z', paths=[str(original)], dir=str(temporary),
                       format=format_name, password='distribution-smoke')
        extracted = call(cmd='extract_auto', paths=archive['paths'], dir=str(temporary),
                         password='distribution-smoke')
        restored = Path(extracted['paths'][0]) / original.name
        if restored.read_bytes() != original.read_bytes():
            raise RuntimeError(f'{format_name} round-trip mismatch')
    print('PASS mounted app: native library, file creation, encrypted ZIP and 7z round trips')


def main():
    run(sys.executable, ROOT / 'scripts/build.py')
    include_licenses()
    shutil.copy2(ROOT / 'docs/INSTALL.zh-CN.txt', APP / 'Contents/Resources/安装说明.txt')
    run('codesign', '--force', '--sign', '-', APP)
    run('codesign', '--verify', '--deep', '--strict', APP)
    info, binaries = check_binaries()
    name = f"RightClick-{info['CFBundleShortVersionString']}-arm64"
    dmg = DIST / f'{name}.dmg'
    zip_path = DIST / f'{name}.zip'
    expected = bundle_manifest(APP)
    with tempfile.TemporaryDirectory(prefix='rightclick-package-', dir=BUILD) as workspace:
        temporary = Path(workspace)
        stage = temporary / 'image'
        stage.mkdir()
        run('ditto', APP, stage / APP.name)
        (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
        shutil.copy2(ROOT / 'docs/INSTALL.zh-CN.txt', stage / '安装说明.txt')
        run('hdiutil', 'create', '-volname', 'RightClick', '-fs', 'HFS+', '-format', 'UDZO',
            '-imagekey', 'zlib-level=9', '-srcfolder', stage, '-ov', dmg)
        run('hdiutil', 'verify', dmg)
        attachment = plistlib.loads(run('hdiutil', 'attach', '-readonly', '-nobrowse', '-plist',
                                       dmg, capture=True).stdout)
        mount = next(Path(e['mount-point']) for e in attachment['system-entities']
                     if 'mount-point' in e)
        try:
            mounted_app = mount / APP.name
            if bundle_manifest(mounted_app) != expected:
                raise RuntimeError('Mounted app differs from distribution build')
            if os.readlink(mount / 'Applications') != '/Applications':
                raise RuntimeError('Applications shortcut has an incorrect target')
            if (mount / '安装说明.txt').read_bytes() != (ROOT / 'docs/INSTALL.zh-CN.txt').read_bytes():
                raise RuntimeError('Installation instructions are missing or changed')
            run('codesign', '--verify', '--deep', '--strict', mounted_app)
            fixture = temporary / 'smoke'
            fixture.mkdir()
            smoke(mounted_app, fixture)
            print('PASS DMG: checksum, read-only mount, full app manifest, signatures, install shortcut')
        finally:
            run('hdiutil', 'detach', mount)
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', APP, zip_path)
        unzipped = temporary / 'unzipped'
        run('ditto', '-x', '-k', zip_path, unzipped)
        if bundle_manifest(unzipped / APP.name) != expected:
            raise RuntimeError('ZIP round-trip mismatch')
        print('PASS ZIP: full app manifest')
    checksum = DIST / f'{name}.sha256'
    checksum.write_text(''.join(f'{digest(p)}  {p.name}\n' for p in [dmg, zip_path]))
    report = {'version': info['CFBundleShortVersionString'], 'minimumMacOS': info['LSMinimumSystemVersion'],
              'architecture': 'arm64', 'signing': 'ad-hoc', 'notarized': False, 'binaries': binaries,
              'artifacts': [{'name': p.name, 'bytes': p.stat().st_size, 'sha256': digest(p)}
                            for p in [dmg, zip_path]]}
    (BUILD / 'distribution-verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    print(f'Ready to distribute: {dmg}')


if __name__ == '__main__':
    main()

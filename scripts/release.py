#!/usr/bin/env python3
"""Validate release metadata before building, and artifacts before publishing."""
import argparse
import json
import os
from pathlib import Path
import tomllib

from build_support import ROOT, digest, project_version


def metadata(root=ROOT, tag=None):
    version = project_version(root)
    if tag is not None and tag != f'v{version}':
        raise ValueError(f'Tag {tag!r} does not match Cargo.toml version v{version}')
    lock = tomllib.loads((root / 'Cargo.lock').read_text())
    package = next(p for p in lock['package'] if p['name'] == 'rustclick' and 'source' not in p)
    if package['version'] != version:
        raise ValueError('Cargo.lock is out of date; run cargo check before tagging')
    notes = root / 'docs' / 'releases' / f'v{version}.md'
    if not notes.is_file() or not notes.read_text().strip():
        raise ValueError(f'Missing release notes: {notes.relative_to(root)}')
    return {'version': version, 'notes': notes.relative_to(root).as_posix()}


def validate_artifacts(root, version):
    base = f'RightClick-{version}-arm64'
    checksum = root / 'dist' / f'{base}.sha256'
    actual = {}
    for suffix in ['dmg', 'zip']:
        path = root / 'dist' / f'{base}.{suffix}'
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f'Missing or empty release asset: {path.name}')
        actual[path.name] = digest(path)
    expected = '\n'.join(f'{sha}  {name}' for name, sha in actual.items()) + '\n'
    if checksum.read_text() != expected:
        raise ValueError('Release asset checksums do not match')
    report = json.loads((root / 'build' / 'distribution-verification.json').read_text())
    if report['version'] != version or report['architecture'] != 'arm64':
        raise ValueError('Distribution report version or architecture does not match')
    recorded = {p['name']: p['sha256'] for p in report['artifacts']}
    if recorded != actual:
        raise ValueError('Release assets differ from the verified distribution')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', help='Require this tag to match Cargo.toml')
    parser.add_argument('--artifacts', action='store_true', help='Also verify packaged release assets')
    args = parser.parse_args()
    result = metadata(tag=args.tag)
    if args.artifacts:
        validate_artifacts(ROOT, result['version'])
    if output := os.environ.get('GITHUB_OUTPUT'):
        with Path(output).open('a') as stream:
            for name, value in result.items():
                stream.write(f'{name}={value}\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()

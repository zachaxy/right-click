"""Exercise release gates without GitHub credentials or network access."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from build_support import bundle_version, project_version
from release import metadata, validate_artifacts


class ReleaseValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'Cargo.toml').write_text('[package]\nversion = "0.1.1"\n')
        (self.root / 'Cargo.lock').write_text('[[package]]\nname = "rustclick"\nversion = "0.1.1"\n')
        notes = self.root / 'docs/releases/v0.1.1.md'
        notes.parent.mkdir(parents=True)
        notes.write_text('# RightClick v0.1.1\n\n修复外接硬盘菜单。\n')

    def test_matching_tag_and_notes(self):
        self.assertEqual(metadata(self.root, 'v0.1.1'),
                         {'version': '0.1.1', 'notes': 'docs/releases/v0.1.1.md'})
        self.assertEqual(metadata(self.root)['version'], '0.1.1')

    def test_build_numbers_increase_from_legacy_release(self):
        previous = (1, 0, 0)
        for version in ['0.1.0', '0.1.1', '0.2.0', '1.0.0']:
            current = tuple(map(int, bundle_version(version).split('.')))
            self.assertGreater(current, previous)
            previous = current

    def test_wrong_tag_and_nonstable_version_rejected(self):
        for tag in ['v0.1.0', '0.1.1', 'v0.1.1-rc1', 'v0.1.1\nversion=bad']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                metadata(self.root, tag)
        (self.root / 'Cargo.toml').write_text('[package]\nversion = "0.1.1-rc1"\n')
        with self.assertRaises(ValueError):
            project_version(self.root)

    def test_stale_lock_rejected(self):
        (self.root / 'Cargo.lock').write_text('[[package]]\nname = "rustclick"\nversion = "0.1.0"\n')
        with self.assertRaises(ValueError):
            metadata(self.root)

    def test_missing_and_empty_notes_rejected(self):
        notes = self.root / 'docs/releases/v0.1.1.md'
        notes.unlink()
        with self.assertRaises(ValueError):
            metadata(self.root)
        notes.write_text(' \n')
        with self.assertRaises(ValueError):
            metadata(self.root)

    def make_artifacts(self):
        (self.root / 'dist').mkdir()
        (self.root / 'build').mkdir()
        assets = []
        for extension in ['dmg', 'zip']:
            path = self.root / 'dist' / f'RightClick-0.1.1-arm64.{extension}'
            path.write_bytes(extension.encode())
            assets.append({'name': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
        (self.root / 'dist/RightClick-0.1.1-arm64.sha256').write_text(
            ''.join(f"{item['sha256']}  {item['name']}\n" for item in assets))
        report = {'version': '0.1.1', 'architecture': 'arm64', 'artifacts': assets}
        (self.root / 'build/distribution-verification.json').write_text(json.dumps(report))

    def test_verified_assets_and_tampering(self):
        self.make_artifacts()
        validate_artifacts(self.root, '0.1.1')
        (self.root / 'dist/RightClick-0.1.1-arm64.zip').write_bytes(b'changed')
        with self.assertRaises(ValueError):
            validate_artifacts(self.root, '0.1.1')

    def test_wrong_build_report_rejected(self):
        self.make_artifacts()
        report = self.root / 'build/distribution-verification.json'
        content = json.loads(report.read_text())
        content['version'] = '0.1.0'
        report.write_text(json.dumps(content))
        with self.assertRaises(ValueError):
            validate_artifacts(self.root, '0.1.1')


if __name__ == '__main__':
    unittest.main()

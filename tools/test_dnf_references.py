"""Supplemental source packages must not alter runtime assets or accepted files."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from dnf_asset_store import digest
from sync_dnf_references import sync_references


def fixture(folder):
    data = b'original source note\n'
    entries = [{'path': 'references/source.txt', 'bytes': len(data),
                'sha256': hashlib.sha256(data).hexdigest()}]
    archive = folder / 'references-01.zip'
    with zipfile.ZipFile(archive, 'w') as z:
        z.writestr(entries[0]['path'], data)
        z.writestr('_manifests/references-01.zip.json', json.dumps(entries))
    return {'schema': 'dnflike_reference_store/1', 'version': 'references-test-v1',
            'base_asset_version': 'assets-test-v1',
            'packs': [{'name': archive.name, 'kind': 'references', 'bytes': archive.stat().st_size,
                       'sha256': digest(archive), 'files': 1, 'unpacked_bytes': len(data)}]}


class ReferenceSafety(unittest.TestCase):
    def test_reference_install_preserves_runtime_and_local_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = fixture(root)
            home = root / 'cache'
            runtime = home / 'assets-test-v1/runtime'
            runtime.mkdir(parents=True)
            stamp = runtime / '.asset_store_install.json'
            stamp.write_bytes(b'keep runtime version')
            result = sync_references(lock, home, root)
            self.assertEqual((result / 'source.txt').read_bytes(), b'original source note\n')
            self.assertEqual(stamp.read_bytes(), b'keep runtime version')
            (result / 'source.txt').write_bytes(b'local edit')
            with self.assertRaises(ValueError):
                sync_references(lock, home, root)
            self.assertEqual((result / 'source.txt').read_bytes(), b'local edit')

    def test_invalid_lock_paths_and_kinds_are_rejected_before_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for value in ['../escape', '..', 'x/y', 'C:other', None]:
                lock = fixture(root)
                lock['version'] = value
                with self.assertRaises(ValueError):
                    sync_references(lock, root / 'unused', root)
            lock = fixture(root)
            lock['packs'][0]['kind'] = 'runtime'
            with self.assertRaises(ValueError):
                sync_references(lock, root / 'unused', root)
            self.assertFalse((root / 'unused').exists())

    def test_corrupted_package_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = fixture(root)
            (root / 'references-01.zip').write_bytes(b'corrupt')
            with self.assertRaises(ValueError):
                sync_references(lock, root / 'cache', root)


if __name__ == '__main__':
    unittest.main()

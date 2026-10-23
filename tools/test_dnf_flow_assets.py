"""Verify native-pixel provenance and isolated cross-workspace loop installation."""
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from PIL import Image
from dnf_asset_store import ROOT, digest
from dnf_asset_reader import parse, decode
from export_dnf_map import Library
from sync_dnf_flow import sync_flow, installed_matches
from check_game_chinese import scan


class FlowAssets(unittest.TestCase):
    def test_combat_runtime_bundle_has_limited_roots_and_preserves_local_edits(self):
        import hashlib
        with tempfile.TemporaryDirectory(prefix='dnf-combat-pack-') as temp:
            base = Path(temp)
            archive = base/'combat.zip'
            def bundle(paths):
                records = [{'path': path, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()} for path, data in paths.items()]
                with zipfile.ZipFile(archive, 'w') as out:
                    for path, data in paths.items():out.writestr(path, data)
                    out.writestr('_manifests/combat.zip.json', json.dumps(records))
                return {'name': archive.name, 'kind': 'combat_runtime', 'bytes': archive.stat().st_size,
                        'sha256': digest(archive), 'files': len(records), 'unpacked_bytes': sum(r['bytes'] for r in records)}
            lock = {'schema': 'dnflike_loop_store/1', 'version': 'combat-v1', 'packs': [bundle({'combat_runtime/combat/manifest.json': b'{}', 'combat_runtime/content/combat_content.json': b'{"records":[]} ',
                                                                                              'combat_runtime/native_maps/lorien/map_export.json': b'{}'})]}
            project = base/'clone'
            sync_flow(lock, base/'cache', project, base)
            self.assertTrue(installed_matches(lock, project))
            self.assertTrue((project/'assets_local/native_maps/lorien/map_export.json').is_file())
            (project/'assets_local/combat/manifest.json').write_bytes(b'local generated changes')
            with self.assertRaisesRegex(ValueError, 'preserved'):sync_flow(lock, base/'cache', project, base)
            self.assertEqual((project/'assets_local/combat/manifest.json').read_bytes(), b'local generated changes')
            lock.update(version='combat-v2', packs=[bundle({'combat_runtime/content/private.json': b'forbidden scope'})])
            with self.assertRaisesRegex(ValueError, 'Unexpected runtime package root'):sync_flow(lock, base/'cache', project, base)
            self.assertFalse((project/'assets_local/content/private.json').exists())

    def test_chinese_gate_distinguishes_game_text_from_raw_sources(self):
        with tempfile.TemporaryDirectory(prefix='dnf-language-') as temp:
            base = Path(temp)
            game = base/'ui.gd'
            game.write_text('var text = "' + chr(0xac00) + '"\n', encoding='utf-8')
            raw = base/'assets_local'
            raw.mkdir()
            (raw/'source.json').write_text(chr(0x3131), encoding='utf-8')
            self.assertEqual(scan(base), [{'path': 'ui.gd', 'line': 1}])
            game.write_text('var text = "背包 负重 普通难度 X HP S"\n', encoding='utf-8')
            self.assertEqual(scan(base), [])

    def test_export_matches_original_pixels(self):
        root = ROOT/'game_dnf/assets_local/flow_v1'
        if not (root/'manifest.json').exists():self.skipTest('Build original flow assets first')
        manifest = json.loads((root/'manifest.json').read_text(encoding='utf-8'))
        from dnf_asset_store import cache_home
        lib = Library(cache_home()/manifest['source']['asset_version']/'library_v1', ROOT/'temp/flow_validation')
        try:
            self.assertEqual([1, 8], sorted(n['id'] for n in manifest['npcs']))
            self.assertEqual(1568, manifest['dungeon']['rooms']['map/elvengard/elvengard.map']['width'])
            for info in manifest['images'].values():
                row = lib.catalog.execute('select local_path from assets where sha256=?', (info['img_sha256'],)).fetchone()
                raw = (lib.root/row[0]).read_bytes()
                image, _ = decode(raw, parse(raw), info['frame'])
                delivered = Image.open(root/info['file']).convert('RGBA')
                self.assertEqual(image.size, delivered.size, info['file'])
                self.assertEqual(image.tobytes(), delivered.tobytes(), info['file'])
            self.assertEqual(digest(root/'msjh.ttf'), manifest['font']['sha256'])
        finally:lib.close()

    def test_installer_preserves_base_and_local_edits(self):
        with tempfile.TemporaryDirectory(prefix='dnf-loop-test-') as temp:
            base = Path(temp)
            archive = base/'flow.zip'
            content = b'original loop pixels'
            import hashlib
            info = {'path': 'flow_v1/img/frame.png', 'bytes': len(content), 'sha256': hashlib.sha256(content).hexdigest()}
            with zipfile.ZipFile(archive, 'w') as out:
                out.writestr(info['path'], content)
                out.writestr('_manifests/flow.zip.json', json.dumps([info]))
            entry = {'name': archive.name, 'kind': 'flow_v1', 'bytes': archive.stat().st_size,
                     'sha256': digest(archive), 'files': 1, 'unpacked_bytes': len(content)}
            lock = {'schema': 'dnflike_loop_store/1', 'version': 'isolated-v1', 'packs': [entry]}
            project = base/'clone'
            target = project/'assets_local'
            target.mkdir(parents=True)
            stamp = target/'.asset_store_install.json'
            stamp.write_text('base stamp untouched')
            sync_flow(lock, base/'cache', project, base)
            self.assertEqual((target/info['path']).read_bytes(), content)
            self.assertEqual(stamp.read_text(), 'base stamp untouched')
            self.assertTrue(installed_matches(lock, project))
            sync_flow(lock, base/'cache', project, base)
            (target/info['path']).write_bytes(b'local edit')
            self.assertFalse(installed_matches(lock, project))
            with self.assertRaisesRegex(ValueError, 'preserved'):
                sync_flow(lock, base/'cache', project, base)
            self.assertEqual((target/info['path']).read_bytes(), b'local edit')
            lock['version'] = '../escape'
            with self.assertRaises(ValueError):sync_flow(lock, base/'cache', project, base)


if __name__ == '__main__':unittest.main()

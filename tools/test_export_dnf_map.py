"""Checks for tools/export_dnf_map.py: pure parsing rules plus an optional library export."""
import json
from pathlib import Path
import tempfile
import unittest

import export_dnf_map as m
from dnf_asset_store import LOCK, ROOT, cache_home


class Rules(unittest.TestCase):
    def test_resolve_is_relative_and_case_insensitive(self):
        self.assertEqual(m.resolve('map/lorien/bn10.map', 'Tile/ForestOver.til'), 'map/lorien/tile/forestover.til')
        self.assertEqual(m.resolve('passiveobject/mapobject/obstacle/smalltreea0.obj', '../../../Map/Lorien/Animation/SmallTree1.ani'),
                         'map/lorien/animation/smalltree1.ani')
        with self.assertRaises(ValueError):
            m.resolve('a.map', '../../x.ani')

    def test_gate_template_needs_explicit_variant(self):
        self.assertEqual(m.fill_template('Map/PathGate/GranFlorisSideDoor%d%d.img', 5), 'Map/PathGate/GranFlorisSideDoor05.img')
        self.assertEqual(m.fill_template('Map/01tile00.img', None), 'Map/01tile00.img')
        with self.assertRaises(ValueError):
            m.fill_template('Map/PathGate/GranFlorisBush%d%d.img', None)

    def test_greed_mask_layout_and_unpaired_doors(self):
        diags = []
        cells = m.parse_greed('JJEE\r\n LLMM\r\n DDGG', 2, 3, 'lorien.dgn', diags)
        self.assertEqual(cells[(0, 0)]['doors'], ['right', 'down'])
        self.assertEqual(cells[(1, 1)]['doors'], ['left', 'down'])
        self.assertEqual(diags, [])
        diags = []
        m.parse_greed('BA', 2, 1, 'x.dgn', diags)
        self.assertEqual([d['code'] for d in diags], ['greed_unpaired'])
        diags = []
        cells = m.parse_greed('Z', 1, 1, 'x.dgn', diags)
        self.assertIsNone(cells[(0, 0)]['mask'])
        self.assertEqual(diags[0]['code'], 'greed_code')

    def test_special_objects_are_variable_length(self):
        values = [221, 526, 239, 0, 2, '[trap]', 2500, 1, 1, 7, -1, '[item]', 1, -1, 1, -1, -1,
                  221, 325, 343, 0, 1, '[trap]', 2110, 1, 2, 4, -1]
        diags = []
        records = m.special_records(values, 'bn11.map', diags)
        self.assertEqual([len(r) for r in records], [17, 11])
        self.assertEqual(diags, [])
        records = m.special_records(values[:-1], 'bn11.map', diags)
        self.assertEqual(len(records), 1)
        self.assertEqual(diags[0]['code'], 'special_object_layout')

    def test_uneven_groups_are_reported(self):
        diags = []
        self.assertEqual(m.groups([1, 2, 3, 4, 5], 2, '[x]', 'p', diags), [[1, 2], [3, 4]])
        self.assertEqual(diags[0]['level'], 'error')


class LibraryExport(unittest.TestCase):
    def test_lorien_export_is_traceable(self):
        lock = json.loads(LOCK.read_text(encoding='utf-8'))
        library = cache_home() / lock['version'] / 'library_v1'
        if not (library / 'pvf_config.sqlite').exists():
            self.skipTest('full library not synced')
        (ROOT / 'temp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'temp') as folder:
            result = m.run(library, 'dungeon/act1/lorien.dgn', Path(folder), [])
            dungeon = result['dungeon']
            self.assertEqual(result['source']['asset_version'], lock['version'])
            self.assertEqual(dungeon['size'], [2, 3])
            self.assertTrue(all(c['map_candidates'] for c in dungeon['cells']))
            self.assertFalse([d for d in result['diagnostics'] if d['level'] == 'error'])
            room = dungeon['rooms']['map/lorien/bn10.map']
            self.assertEqual(room['width'], 6 * 224)
            self.assertEqual(len(room['walk_grid']), 30)
            self.assertTrue(all(len(r) == 84 for r in room['walk_grid']))
            self.assertEqual(room['pathgate_pos']['up'], [376, 144])
            self.assertIn('[monster]', [s['tag'] for s in room['raw']])
            for key, info in result['images'].items():
                self.assertTrue((Path(folder) / info['file']).is_file(), key)
                self.assertEqual(len(info['img_sha256']), 64)
            boss = dungeon['gate_objects'][str(dungeon['pathgate_slots']['right_boss'])]
            self.assertTrue(any(p['raw_pair'] == [1, 5] for p in boss['parts']))


if __name__ == '__main__':
    unittest.main()

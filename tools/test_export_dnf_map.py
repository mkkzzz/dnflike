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
        self.assertEqual(m.fill_template('Map/PathGate/Act4/04ExitLeft%d%d.img', 10), 'Map/PathGate/Act4/04ExitLeft010.img')
        self.assertEqual(m.fill_template('Map/PathGate/Act4/04ExitLeft%d%d.img', 12), 'Map/PathGate/Act4/04ExitLeft012.img')
        self.assertEqual(m.fill_template('Map/01tile00.img', None), 'Map/01tile00.img')
        with self.assertRaises(ValueError):
            m.fill_template('Map/PathGate/GranFlorisBush%d%d.img', None)

    def test_empty_tile_normalizes_only_all_blocked_sentinel(self):
        diags = []
        passes, normalized = m.tile_pass([2] * 280, True, 'map/empty/tile/emptytile.til', diags)
        self.assertEqual(passes, [2] * 420)
        self.assertEqual(normalized, {'source_count': 280, 'value': 2})
        self.assertEqual([(row['level'], row['code']) for row in diags], [('info', 'empty_tile')])
        diags = []
        passes, normalized = m.tile_pass([2] * 279 + [0], True, 'map/empty/tile/emptytile.til', diags)
        self.assertIsNone(passes)
        self.assertIsNone(normalized)
        self.assertEqual([(row['level'], row['code']) for row in diags], [('error', 'tile_pass')])

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

    def test_map_greed_keeps_layout_and_ingress_paired(self):
        room = {'path': 'map/example.map',
                'raw': [{'tag': '[greed]', 'values': [[0, '', 'GG EE MM II']]}]}
        self.assertEqual(m.source_map_greed_pairs(room), [[6, 4], [12, 8]])
        room['raw'][0]['values'][0][2] = 'GG EE MM'
        with self.assertRaisesRegex(ValueError, 'Invalid MAP'):
            m.source_map_greed_pairs(room)

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

    def test_hellparty_special_object_is_preserved_opaque(self):
        values = [30507, 783, 289, 0, 1, '[hellparty]', 125, 25, 1, 63, 20, 2, '[/hellparty]']
        diags = []
        records = m.special_records(values, '60025.map', diags)
        self.assertEqual(records, [values])
        self.assertEqual([(d['level'], d['code']) for d in diags],
                         [('warning', 'opaque_special_object')])
        diags = []
        self.assertEqual(m.special_records(values[:-1], '60025.map', diags), [])
        self.assertEqual(diags[0]['code'], 'special_object_layout')

    def test_uneven_groups_are_reported(self):
        diags = []
        self.assertEqual(m.groups([1, 2, 3, 4, 5], 2, '[x]', 'p', diags), [[1, 2], [3, 4]])
        self.assertEqual(diags[0]['level'], 'error')

    def test_monster_optional_fields_do_not_shift_following_rows(self):
        prefix = [61262, 1, 0, 295, 227, 0, 1, 1, '[fixed]']
        boss = prefix + ['[NPC]', 1009, '[boss]']
        champion = prefix + ['[champion]', 1, 'option']
        normal = prefix + ['[normal]']
        diags = []
        self.assertEqual(m.monster_records(boss + champion + normal, 'p', diags),
                         [(boss, 1009), (champion, None), (normal, None)])
        self.assertFalse(diags)
        for broken in (boss[:-1], prefix + ['[NPC]', '[boss]'], champion[:-1]):
            diags = []
            self.assertEqual(m.monster_records(normal + broken, 'p', diags), [(normal, None)])
            self.assertEqual(diags[0]['code'], 'monster_layout')


class LibraryExport(unittest.TestCase):
    def test_moonlight_rooms_keep_the_boss_npc_link_and_original_stand_animations(self):
        from build_dnf_dungeon_route import resolve_selected_room, source_map_specifications

        lock = json.loads(LOCK.read_text(encoding='utf-8'))
        library = cache_home() / lock['version'] / 'library_v1'
        if not (library / 'pvf_config.sqlite').exists():
            self.skipTest('full library not synced')
        (ROOT / 'temp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'temp') as folder:
            result = m.run(library, 'dungeon/quest/training2.dgn', Path(folder), [])
            self.assertFalse([d for d in result['diagnostics'] if d['level'] == 'error'])
            dungeon = result['dungeon']
            self.assertEqual(dungeon['index'], 511)
            self.assertEqual(dungeon['start_map_raw'], [1, 0])
            self.assertEqual(dungeon['boss_map_raw'], [0, 0])
            self.assertEqual([(p['cell'], dungeon['rooms'][p['map']]['map_id']) for p in dungeon['placements']],
                             [([0, 0], 15270), ([1, 0], 15129)])
            pools = source_map_specifications(dungeon)
            self.assertEqual(pools['[map specification]'], {(1, 0): [15129]})
            self.assertEqual(pools['[boss map specification]'], {(0, 0): [15270]})
            self.assertEqual(resolve_selected_room(result, (1, 0), 15129, 'start')['id'], '1_0:15129training')
            self.assertEqual(resolve_selected_room(result, (0, 0), 15270, 'boss')['id'], '0_0:15270training')
            start, boss_room = (dungeon['rooms'][f'map/training2/{i}training.map'] for i in (15129, 15270))
            self.assertEqual([m['id'] for m in start['monsters']], [61301, 61300, 61300, 61301])
            self.assertTrue(all('npc_id' not in m for m in start['monsters']))
            boss, = boss_room['monsters']
            self.assertEqual((boss['id'], boss['npc_id'], boss['anchor']), (61262, 1009, [295, 227, 0]))
            self.assertEqual(boss['raw'][-3:], ['[NPC]', 1009, '[boss]'])
            self.assertEqual(boss['sprite']['ani'], 'monster/newmonsters/albert/animation/stay.ani')
            self.assertEqual(boss['sprite']['ani_sha256'], '5092a9df3e91721863b94ac3bfe10d529ca7c5cc720545d55dae2e8db0cfff5c')
            for entry in [boss, *start['monsters']]:
                self.assertTrue(all((Path(folder) / result['images'][frame['image']]['file']).is_file()
                                    for frame in entry['sprite']['frames']))
            self.assertEqual(dungeon['gate_objects']['5542']['parts'], [])
            self.assertEqual(dungeon['gate_objects']['5545']['parts'], [])

    def test_jungle_export_uses_verified_layout_and_ingress_pairs(self):
        export = json.loads((ROOT / 'game_dnf/assets_local/native_maps/jungle_v1/map_export.json').read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], 'aaa68a88b6cea80c7749fe4b5dabcea5aca6b290f27ebf1de01dc880a9457291')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['rooms']['map/jungle/s3201(1,3).map']['greed_pairs'], [[1, 1]])
        self.assertEqual(dungeon['rooms']['map/jungle/b3202(3,0).map']['greed_pairs'], [[4, 4]])
        self.assertEqual(len(dungeon['rooms']), 20)
        self.assertEqual(len(dungeon['placements']), 52)
        self.assertEqual(sum(len(cell['doors']) for cell in dungeon['cells']), 36)

    def test_cold_heart_boy_export_keeps_identical_boss_map_variants(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/theboywithcoldheart_v1/map_export.json').read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], 'dcf7202c45f573b15c34dcd576872ffca34370ed7ec049464543229b4b562a03')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['rooms']['map/coldboy/s5801.map']['greed_pairs'], [[4, 4]])
        self.assertEqual(dungeon['rooms']['map/coldboy/b5802.map']['greed_pairs'], [[1, 1]])
        self.assertEqual(dungeon['rooms']['map/coldboy/b5803.map']['greed_pairs'], [[1, 1]])
        self.assertEqual(dungeon['rooms']['map/coldboy/b5802.map']['sha256'],
                         dungeon['rooms']['map/coldboy/b5803.map']['sha256'])
        self.assertEqual([(p['cell'], p['map']) for p in dungeon['placements']], [
            ([0, 0], 'map/coldboy/b5802.map'),
            ([0, 0], 'map/coldboy/b5803.map'),
            ([1, 0], 'map/coldboy/s5801.map'),
        ])
        self.assertEqual(len(export['images']), 46)

    def test_ricu_ceiling_export_keeps_two_boss_cells_and_fixed_map_rows(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/ricuceiling_v1/map_export.json').read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], 'e4ca542dfdbb447d5b3382fcb506e47ba20348b455bb14d8fb816cd62247f01a')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['size'], [5, 4])
        self.assertEqual(dungeon['start_map_raw'], [1, 3])
        self.assertEqual(dungeon['boss_map_raw'], [2, 1, 3, 0])
        specifications = [s for s in dungeon['raw'] if s['tag'] == '[map specification]']
        self.assertEqual(len(specifications), 8)
        self.assertEqual(len(dungeon['rooms']), 12)
        self.assertEqual(len(dungeon['placements']), 15)
        self.assertEqual(len(export['images']), 94)
        self.assertEqual(dungeon['rooms']['map/ricuceiling/(2,1)ricuboss.map']['greed_pairs'], [[1, 1]])
        self.assertEqual(dungeon['rooms']['map/ricuceiling/(3,0)ricuboss.map']['greed_pairs'], [[8, 8]])
        for path in ('map/ricuceiling/(2,1)ricuboss.map', 'map/ricuceiling/(3,0)ricuboss.map'):
            room = dungeon['rooms'][path]
            role = next(span['values'][0][2] for span in room['raw'] if span['tag'] == '[type]')
            boss_rows = [row for row in room['monsters'] if row['raw'][-1] == '[boss]']
            self.assertEqual(role, '[boss]')
            self.assertEqual(len(boss_rows), 1)

    def test_white_land_export_keeps_two_boss_cells_and_shared_layouts(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/whiteland_v1/map_export.json').read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '096575dbf1ac14fab9681071a8ddc00189008977353d07c706006d0aa5e11f25')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['size'], [4, 4])
        self.assertEqual(dungeon['start_map_raw'], [1, 3])
        self.assertEqual(dungeon['boss_map_raw'], [0, 0, 3, 0])
        self.assertEqual(len(dungeon['rooms']), 12)
        self.assertEqual(len(dungeon['placements']), 20)
        self.assertEqual(len(export['images']), 62)
        for path in ('map/whiteland/boss(0,0).map', 'map/whiteland/boss(3,0).map'):
            room = dungeon['rooms'][path]
            role = next(span['values'][0][2] for span in room['raw'] if span['tag'] == '[type]')
            boss_rows = [row for row in room['monsters'] if row['raw'][-1] == '[boss]']
            self.assertEqual(role, '[boss]')
            self.assertEqual(len(boss_rows), 1)
        self.assertEqual(dungeon['rooms']['map/whiteland/normal1(0,1).map']['greed_pairs'], [[12, 12]])

    def test_bwanga_export_separates_ordinary_and_quest_boss_maps(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/bwanga_v1/map_export.json').read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '87a37cd9a924747b4a7ab422e4ac4788a26c9443716c5acafad572f96cac6021')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['size'], [10, 1])
        self.assertEqual(dungeon['start_map_raw'], [0, 0])
        self.assertEqual(dungeon['boss_map_raw'], [9, 0])
        self.assertEqual(len(dungeon['rooms']), 15)
        self.assertEqual(len(dungeon['placements']), 116)
        self.assertEqual(len(export['images']), 84)
        self.assertEqual(dungeon['rooms']['map/bwanga/(0,0)bwangastart.map']['greed_pairs'], [[1, 1]])
        self.assertEqual(dungeon['rooms']['map/bwanga/(1,0)bwanga.map']['greed_pairs'], [[5, 5], [4, 4]])
        self.assertEqual(dungeon['rooms']['map/bwanga/(1,0)maze0_bwanga.map']['map_id'], 16020)
        self.assertEqual(dungeon['rooms']['map/bwanga/(8,0)maze4_bwanga.map']['map_id'], 16024)
        boss_specs = [span['values'][2][2] for span in dungeon['raw']
                      if span['tag'] == '[boss map specification]']
        self.assertEqual(boss_specs, [16019, 16020, 16021, 16022, 16023, 16024, 16019])

    def test_outerwall_export_and_first_entry_use_native_map_pairs(self):
        from build_dnf_dungeon_route import build, cell_graph, resolve_selected_room

        lock = json.loads(LOCK.read_text(encoding='utf-8'))
        library = cache_home() / lock['version'] / 'library_v1'
        if not (library / 'pvf_config.sqlite').exists():
            self.skipTest('full library not synced')
        (ROOT / 'temp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'temp') as folder:
            result = m.run(library, 'dungeon/act3/outerwall.dgn', Path(folder), [])
        dungeon = result['dungeon']
        self.assertEqual(dungeon['sha256'], '4bc1517d37fdefdd4288ff0766a0bdc52d4c03248ca5e8d395e02354f05b08b8')
        self.assertFalse([d for d in result['diagnostics'] if d['level'] == 'error'])
        rooms = dungeon['rooms']
        self.assertEqual(rooms['map/outerwall/n3009.map']['greed_pairs'], [[12, 8]])
        cells = cell_graph(result)
        self.assertEqual(sum(bool(c['doors']) for c in cells.values()), 16)
        self.assertEqual(sum(len(c['doors']) for c in cells.values()), 30)
        self.assertNotIn('map/outerwall/n3006.map', cells[(5, 0)]['map_candidates'])
        self.assertNotIn('map/outerwall/n3010.map', cells[(0, 0)]['map_candidates'])
        for cell in [(0, 0), (0, 2)]:
            for map_id in (3001, 3002):
                self.assertEqual(rooms[resolve_selected_room(result, cell, map_id, 'start')['map']]['map_id'], map_id)
        for cell, ingress, normal, boss in [((5, 0), 'left', 3020, 3024), ((5, 2), 'up', 3021, 3022)]:
            self.assertEqual(rooms[resolve_selected_room(result, cell, normal, 'normal', ingress=ingress)['map']]['map_id'], normal)
            self.assertEqual(rooms[resolve_selected_room(result, cell, boss, 'boss', ingress=ingress)['map']]['map_id'], boss)
            with self.assertRaisesRegex(ValueError, 'not an eligible boss room'):
                resolve_selected_room(result, cell, normal, 'boss', ingress=ingress)
        with self.assertRaisesRegex(ValueError, 'outside source'):
            resolve_selected_room(result, (5, 2), 3007, 'normal', ingress='up')
        self.assertEqual(resolve_selected_room(result, (1, 0), 3013, 'normal', ingress='down')['id'], '1_0:n3009')
        self.assertEqual(resolve_selected_room(result, (0, 2), 3002, 'normal', ingress='right')['id'], '0_2:s3002')
        with self.assertRaisesRegex(ValueError, 'does not accept ingress'):
            resolve_selected_room(result, (1, 0), 3013, 'normal', ingress='left')
        rooms['map/outerwall/n3009.map'].pop('greed_pairs')
        self.assertEqual(resolve_selected_room(result, (1, 0), 3013, 'normal', ingress='down')['id'], '1_0:n3009')
        placements = {p['id']: rooms[p['map']]['map_id'] for p in dungeon['placements']}
        self.assertEqual(len(placements), 47)
        for start, second in [((0, 0), 3004), ((0, 2), 3003)]:
            for boss, final in [((5, 0), [3015, 3024]), ((5, 2), [3004, 3022])]:
                sample = build(result, start, boss)
                self.assertEqual([placements[room['placement']] for room in sample],
                                 [3001, second, 3008, 3009, 3010, 3011, *final])

    def test_gate_loop_refresh_matches_source_and_preserves_other_bytes(self):
        lock = json.loads(LOCK.read_text(encoding='utf-8'))
        library = cache_home() / lock['version'] / 'library_v1'
        if not (library / 'pvf_config.sqlite').exists():
            self.skipTest('full library not synced')
        source = ROOT / 'game_dnf/assets_local/flow_v1/skytower_v1/draconiantower/map_export.json'
        export = json.loads(source.read_bytes())
        light = next(p['sprite'] for gate in export['dungeon']['gate_objects'].values()
                     for p in gate['parts'] if p['role'] == 'light')

        def encode():
            return (json.dumps(export, ensure_ascii=False, indent=1) + '\n').replace('\n', '\r\n').encode('utf-8')

        (ROOT / 'temp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'temp') as folder:
            good, bad = Path(folder) / 'good.json', Path(folder) / 'bad.json'
            light['loop_flag'] = 1
            expected = encode()
            light['loop_flag'] = 0
            before = encode()
            good.write_bytes(before)
            light['ani_sha256'] = '0' * 64
            bad.write_bytes(encode())
            with self.assertRaisesRegex(ValueError, 'stale gate ANI'):
                m.refresh_gate_loops([good, bad], library)
            self.assertEqual(good.read_bytes(), before)
            self.assertEqual(m.refresh_gate_loops([good], library), {good: 1})
            self.assertEqual(good.read_bytes(), expected)
            self.assertEqual(m.refresh_gate_loops([good], library), {})

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

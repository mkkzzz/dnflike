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

    def test_maze_block_selection_prefers_ordinary_then_hell_base(self):
        def block(index, quest=None, escape=None, hell=None):
            return {'index': index, 'quest_connection': quest or [],
                    'escape_hell': escape or [], 'hell_dungeon': hell or []}

        quest = block(0, quest=[1, 3901, -1], escape=[1])
        ordinary = block(1)
        hell = block(2, hell=[1])
        selected, ordinary_rows, hell_rows, rule = m.select_maze_block([quest, ordinary, hell])
        self.assertEqual(selected['index'], 1)
        self.assertEqual([row['index'] for row in ordinary_rows], [1])
        self.assertEqual(hell_rows, [])
        self.assertEqual(rule, 'ordinary')

        selected, ordinary_rows, hell_rows, rule = m.select_maze_block([quest, hell])
        self.assertEqual(selected['index'], 2)
        self.assertEqual(ordinary_rows, [])
        self.assertEqual([row['index'] for row in hell_rows], [2])
        self.assertEqual(rule, 'hell_base')

        selected, ordinary_rows, hell_rows, rule = m.select_maze_block([quest])
        self.assertEqual(selected['index'], 0)
        self.assertEqual(ordinary_rows, [])
        self.assertEqual(hell_rows, [])
        self.assertEqual(rule, 'fallback')


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

    def test_ice_palace_export_keeps_shared_f_layout_and_fixed_specs(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/icepalace_v1/map_export.json').read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '13c7ece1b64c949af4870f9413334459c723812fea0d56ee6bf0347143e7dd16')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['size'], [3, 3])
        self.assertEqual(dungeon['start_map_raw'], [0, 1])
        self.assertEqual(dungeon['boss_map_raw'], [1, 1])
        self.assertEqual(len(dungeon['rooms']), 9)
        self.assertEqual(len(dungeon['placements']), 11)
        self.assertEqual(len(export['images']), 72)
        self.assertEqual(dungeon['rooms']['map/icepalace/(2,1)icepalacestart.map']['map_id'], 9100)
        self.assertEqual(dungeon['rooms']['map/icepalace/(2,1)icepalacestart.map']['greed_pairs'], [[10, 10]])
        self.assertEqual(dungeon['rooms']['map/icepalace/(1,1)icepalaceboss.map']['greed_pairs'], [[1, 1]])
        for path in ('map/icepalace/l2(1,0)icepalace.map', 'map/icepalace/l6(1,2)icepalace.map'):
            self.assertEqual(dungeon['rooms'][path]['greed_pairs'], [[5, 5]])
        specifications = [span['values'][2][2] for span in dungeon['raw']
                          if span['tag'] == '[map specification]']
        self.assertEqual(specifications, [9103, 9105, 9102, 9106, 9101, 9104, 9107])

    def test_gbl_branchofarad_export_separates_quest_boss_layouts(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/gbl_branchofarad_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '8666193f452687ae3eed7e27bf05d3b2b3721efa0952985eab4e6bb9fac357b8')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['size'], [4, 4])
        self.assertEqual(dungeon['start_map_raw'], [3, 1])
        self.assertEqual(dungeon['boss_map_raw'], [2, 2])
        self.assertEqual(len(dungeon['rooms']), 17)
        self.assertEqual(len(dungeon['placements']), 27)
        self.assertEqual(len(export['images']), 48)
        self.assertEqual(dungeon['rooms']['map/gbl1/g1(s)002.map']['greed_pairs'], [[2, 2]])
        self.assertEqual(dungeon['rooms']['map/gbl1/g1(b)002.map']['greed_pairs'], [[10, 10]])
        self.assertEqual(dungeon['rooms']['map/gbl1/maze(2,2).map']['greed_pairs'], [[10, 10]])
        self.assertEqual(dungeon['rooms']['map/gbl1/maze(3,3).map']['greed_pairs'], [[4, 4]])
        boss_specs = [span['values'][2][2] for span in dungeon['raw']
                      if span['tag'] == '[boss map specification]']
        self.assertEqual(boss_specs, [13059, 13058])

    def test_gbl_laboratory_export_keeps_single_maze_and_unique_boss_map(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/gbl_laboratory_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], 'ee701f2b6a72085033a4b8fe8430d1374e9ddd4dbd5c88dc88455fd00ee9e379')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['size'], [4, 4])
        self.assertEqual(dungeon['start_map_raw'], [0, 3])
        self.assertEqual(dungeon['boss_map_raw'], [3, 1])
        self.assertEqual(len(dungeon['rooms']), 12)
        self.assertEqual(len(dungeon['placements']), 20)
        self.assertEqual(len(export['images']), 114)
        self.assertEqual(dungeon['rooms']['map/gbl2/g2(s)001.map']['greed_pairs'], [[2, 2]])
        self.assertEqual(dungeon['rooms']['map/gbl2/g2(n)006.map']['greed_pairs'], [[4, 4]])
        self.assertEqual(dungeon['rooms']['map/gbl2/g2(b)001.map']['greed_pairs'], [[4, 4]])
        specifications = [span['values'][2][2] for span in dungeon['raw']
                          if span['tag'] == '[map specification]']
        self.assertEqual(specifications, [
            13017, 13018, 13019, 13020, 13016, 13021, 13025,
            13015, 13022, 13014, 13024, 13023,
        ])
        self.assertFalse([span for span in dungeon['raw']
                          if span['tag'] == '[boss map specification]'])

    def test_gbl_hatchery_export_keeps_ring_maze_and_reused_boss_cell(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/gbl_hatchery_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '266393055e4e3894218aa8f26b4ab35c1e7a416ec0b486b57cdfc1fe5b5b70ce')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['size'], [4, 4])
        self.assertEqual(dungeon['start_map_raw'], [3, 0])
        self.assertEqual(dungeon['boss_map_raw'], [2, 2])
        self.assertEqual(len(dungeon['rooms']), 13)
        self.assertEqual(len(dungeon['placements']), 19)
        self.assertEqual(len(export['images']), 46)
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(cells[(3, 0)]['map_candidates'], ['map/gbl3/g3(s)001.map'])
        self.assertEqual(cells[(2, 2)]['map_candidates'], [
            'map/gbl3/g3(b)001.map',
            'map/gbl3/g3(n)002.map',
            'map/gbl3/g3(n)010.map',
        ])
        self.assertEqual(dungeon['rooms']['map/gbl3/g3(s)001.map']['role_hint'], 'start')
        self.assertEqual(dungeon['rooms']['map/gbl3/g3(b)001.map']['role_hint'], 'boss')
        specifications = [span['values'][2][2] for span in dungeon['raw']
                          if span['tag'] == '[map specification]']
        self.assertEqual(specifications, [
            13031, 13028, 13027, 13030, 13029, 13032,
            13037, 13034, 13033, 13035, 13036,
        ])
        self.assertFalse([span for span in dungeon['raw']
                          if span['tag'] == '[boss map specification]'])

    def test_astray_thief_export_preserves_two_boss_cells_and_layoutless_quest_map(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/astraythief_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '72925d7c530658a4a7f9a4196fe5dccbef11d068c327c4f0d77dff85d40f81d8')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['size'], [5, 4])
        self.assertEqual(dungeon['start_map_raw'], [3, 0])
        self.assertEqual(dungeon['boss_map_raw'], [4, 3, 3, 2])
        self.assertEqual(len(dungeon['rooms']), 14)
        self.assertEqual(len(dungeon['placements']), 19)
        self.assertEqual(len(export['images']), 102)
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(cells[(3, 0)]['map_candidates'], [
            'map/astraythief/b6202.map',
            'map/astraythief/h6204.map',
            'map/astraythief/s6201.map',
        ])
        self.assertEqual(cells[(4, 3)]['map_candidates'], [
            'map/astraythief/b6202.map',
            'map/astraythief/h6204.map',
            'map/astraythief/s6201.map',
        ])
        self.assertEqual(cells[(3, 2)]['map_candidates'], [
            'map/astraythief/b6201.map',
            'map/astraythief/h6203.map',
        ])
        self.assertEqual(dungeon['rooms']['map/astraythief/s6201.map']['role_hint'], 'start')
        self.assertEqual(dungeon['rooms']['map/astraythief/b6201.map']['role_hint'], 'boss')
        self.assertEqual(dungeon['rooms']['map/astraythief/q6220.map']['greed_pairs'], [])
        layout_absent = [row for row in export['diagnostics'] if row['code'] == 'layout_absent']
        self.assertEqual([row['path'] for row in layout_absent], ['map/astraythief/q6220.map'])
        specifications = [span['values'][2][2] for span in dungeon['raw']
                          if span['tag'] == '[map specification]']
        self.assertEqual(specifications, [6203, 6202, 6205, 6206, 6207, 6208, 6209])
        self.assertFalse([span for span in dungeon['raw']
                          if span['tag'] == '[boss map specification]'])

    def test_aganzo_export_selects_the_only_ordinary_maze_block(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/aganzo_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '882dc960c67fc9378e11b20e2331ad628cf012f78cc581c6e2f463280461524e')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['maze_block_index'], 4)
        self.assertEqual(dungeon['size'], [5, 4])
        self.assertEqual(dungeon['start_map_raw'], [4, 1])
        self.assertEqual(dungeon['boss_map_raw'], [3, 3])
        self.assertEqual(len(dungeon['rooms']), 13)
        self.assertEqual(len(dungeon['placements']), 21)
        self.assertEqual(len(export['images']), 95)
        self.assertEqual([block['size'] for block in dungeon['maze_blocks']], [
            [2, 1], [2, 1], [5, 1], [5, 2], [5, 4], [5, 4],
        ])
        self.assertEqual([block['index'] for block in dungeon['maze_blocks']
                          if block['selected']], [4])
        ordinary = [block['index'] for block in dungeon['maze_blocks']
                    if not block['quest_connection'] and not block['escape_hell']
                    and not block['hell_dungeon']]
        self.assertEqual(ordinary, [4])
        selected = dungeon['maze_blocks'][4]
        self.assertEqual([row[2] for row in selected['map_specifications']],
                         [16005, 16003, 16002, 16001, 16006, 16007, 16008])
        self.assertEqual(selected['boss_map_specifications'], [[3, 3, 16009]])
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(sum(cell['code'] != 'AA' for cell in dungeon['cells']), 10)
        self.assertEqual(cells[(4, 1)]['map_candidates'], [
            'map/aganzo/(3.3)aganzoboss.map',
            'map/aganzo/(4,1)aganzostart.map',
        ])
        self.assertEqual(cells[(3, 3)]['map_candidates'], [
            'map/aganzo/(3.3)aganzoboss.map',
            'map/aganzo/(4,1)aganzostart.map',
        ])
        self.assertEqual(dungeon['rooms']['map/aganzo/(4,1)aganzostart.map']['role_hint'], 'start')
        self.assertEqual(dungeon['rooms']['map/aganzo/(3.3)aganzoboss.map']['role_hint'], 'boss')
        selected_diag = [row for row in export['diagnostics'] if row['code'] == 'maze_block_selected']
        self.assertEqual(len(selected_diag), 1)
        self.assertIn('selected maze block 4 of 6', selected_diag[0]['detail'])

    def test_kings_ruins_export_uses_six_fixed_single_cell_maps(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/kingsruins_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], 'f03c598f40d969f903f61266b0c33c38ab09c4e6cbf2ee92a60ebdf5118d1346')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['size'], [6, 1])
        self.assertEqual(dungeon['start_map_raw'], [5, 0])
        self.assertEqual(dungeon['boss_map_raw'], [0, 0])
        self.assertEqual(len(dungeon['rooms']), 6)
        self.assertEqual(len(dungeon['placements']), 18)
        self.assertEqual(len(export['images']), 45)
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(cells[(5, 0)]['map_candidates'], ['map/kingsruins/s4801.map'])
        self.assertEqual(cells[(0, 0)]['map_candidates'], ['map/kingsruins/b4801.map'])
        self.assertEqual(cells[(1, 0)]['map_candidates'], [
            'map/kingsruins/n4801.map',
            'map/kingsruins/n4802.map',
            'map/kingsruins/n4803.map',
            'map/kingsruins/n4804.map',
        ])
        self.assertEqual(dungeon['rooms']['map/kingsruins/s4801.map']['role_hint'], 'start')
        self.assertEqual(dungeon['rooms']['map/kingsruins/b4801.map']['role_hint'], 'boss')
        self.assertEqual(dungeon['rooms']['map/kingsruins/s4801.map']['greed_pairs'], [[4, 4]])
        self.assertEqual(dungeon['rooms']['map/kingsruins/n4801.map']['greed_pairs'], [[5, 5]])
        self.assertEqual(dungeon['rooms']['map/kingsruins/b4801.map']['greed_pairs'], [[1, 1]])
        specifications = [span['values'][2][2] for span in dungeon['raw']
                          if span['tag'] == '[map specification]']
        self.assertEqual(specifications, [4801, 4802, 4803, 4804, 4805, 4806])
        self.assertFalse([span for span in dungeon['raw']
                          if span['tag'] == '[boss map specification]'])
        self.assertFalse([row for row in export['diagnostics'] if row['level'] in ('error', 'warning')])

    def test_grozni_export_selects_ordinary_block_eight(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/grozni_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '6573a9ef1a05fb400c903b97b2ae89543504fb5cdf804d778c1bc26a289b5970')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['maze_block_index'], 8)
        self.assertEqual(dungeon['size'], [8, 3])
        self.assertEqual(dungeon['start_map_raw'], [7, 0])
        self.assertEqual(dungeon['boss_map_raw'], [0, 1])
        self.assertEqual(len(dungeon['rooms']), 32)
        self.assertEqual(len(dungeon['placements']), 69)
        self.assertEqual(len(export['images']), 87)
        self.assertEqual([block['size'] for block in dungeon['maze_blocks']], [
            [3, 3], [4, 2], [5, 2], [7, 3], [8, 3],
            [8, 3], [8, 3], [8, 3], [8, 3], [8, 3],
        ])
        self.assertEqual([block['index'] for block in dungeon['maze_blocks']
                          if block['selected']], [8])
        ordinary = [block['index'] for block in dungeon['maze_blocks']
                    if not block['quest_connection'] and not block['escape_hell']
                    and not block['hell_dungeon']]
        self.assertEqual(ordinary, [8])
        selected = dungeon['maze_blocks'][8]
        self.assertEqual([row[2] for row in selected['map_specifications']], [
            11202, 11221, 11212, 11209, 11204, 11202, 11215,
            11222, 11213, 11208, 11218, 11220, 11220, 11220,
        ])
        self.assertEqual(selected['boss_map_specifications'], [[0, 1, 11217]])
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(sum(bool(cell['doors']) for cell in dungeon['cells']), 15)
        self.assertEqual(sum(cell['code'] == 'AA' for cell in dungeon['cells']), 9)
        self.assertEqual(cells[(7, 0)]['map_candidates'], [
            'map/groznyoutside/grozny01.map',
            'map/groznyoutside/grozny06.map',
        ])
        self.assertEqual(cells[(0, 1)]['map_candidates'], [
            'map/groznyinside/grozny13-1.map',
            'map/groznyinside/grozny13.map',
        ])
        self.assertEqual(dungeon['rooms']['map/groznyoutside/grozny01.map']['role_hint'], 'start')
        self.assertEqual(dungeon['rooms']['map/groznyinside/grozny13.map']['role_hint'], 'boss')
        diagnostics = export['diagnostics']
        errors = [row for row in diagnostics if row['level'] == 'error']
        self.assertEqual([row['detail'] for row in errors], [
            'sprite/map/pathgate/town/cartelarad/ca_exitup010.img has no validated IMG in catalog',
            'sprite/map/pathgate/town/cartelarad/ca_exitup010.img has no validated IMG in catalog',
            'sprite/map/pathgate/town/cartelarad/ca_exitup08.img has no validated IMG in catalog',
            'sprite/map/pathgate/town/cartelarad/ca_exitup08.img has no validated IMG in catalog',
        ])
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'cell_without_map']), 9)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'object_unrendered']), 61)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'scroll_absent']), 96)
        selected_diag = [row for row in diagnostics if row['code'] == 'maze_block_selected']
        self.assertEqual(len(selected_diag), 1)
        self.assertIn('selected maze block 8 of 10', selected_diag[0]['detail'])

    def test_odesa_export_selects_non_quest_hell_base_block_four(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/odesa_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '1fed07147d1f2be9a4071572589b208a7e2c493410925df8f92d8655f7d5ed7b')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['index'], 60)
        self.assertEqual(dungeon['maze_block_index'], 4)
        self.assertEqual(dungeon['maze_block_selection'], 'hell_base')
        self.assertEqual(dungeon['size'], [7, 4])
        self.assertEqual(dungeon['start_map_raw'], [0, 0])
        self.assertEqual(dungeon['boss_map_raw'], [5, 3])
        self.assertEqual(len(dungeon['rooms']), 26)
        self.assertEqual(len(dungeon['placements']), 47)
        self.assertEqual(len(export['images']), 69)
        self.assertEqual([block['size'] for block in dungeon['maze_blocks']], [
            [4, 2], [5, 2], [7, 3], [6, 4], [7, 4],
        ])
        self.assertEqual([block['quest_connection'] for block in dungeon['maze_blocks']], [
            [0, 3901, -1], [0, 3903, -1], [0, 3904, 1], [0, 3906, 1], None,
        ])
        self.assertEqual([block['index'] for block in dungeon['maze_blocks']
                          if block['selected']], [4])
        ordinary = [block['index'] for block in dungeon['maze_blocks']
                    if not block['quest_connection'] and not block['escape_hell']
                    and not block['hell_dungeon']]
        hell_base = [block['index'] for block in dungeon['maze_blocks']
                     if not block['quest_connection'] and not block['escape_hell']
                     and block['hell_dungeon']]
        self.assertEqual(ordinary, [])
        self.assertEqual(hell_base, [4])
        selected = dungeon['maze_blocks'][4]
        self.assertEqual(len(selected['map_specifications']), 16)
        self.assertEqual(selected['boss_map_specifications'], [[5, 3, 11123]])
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(sum(bool(cell['doors']) for cell in dungeon['cells']), 13)
        self.assertEqual(sum(cell['code'] == 'AA' for cell in dungeon['cells']), 15)
        self.assertEqual(cells[(0, 0)]['map_candidates'], [
            'map/odesa2/odesa01.map',
            'map/odesa2/odesa17.map',
        ])
        self.assertEqual(cells[(5, 3)]['map_candidates'], [
            'map/odesa2/odesa08.map',
            'map/odesa2/odesa14-1.map',
            'map/odesa2/odesa14.map',
            'map/odesa2/odesa19.map',
        ])
        self.assertEqual(dungeon['rooms']['map/odesa2/odesa01.map']['role_hint'], 'start')
        self.assertEqual(dungeon['rooms']['map/odesa2/odesa19.map']['role_hint'], 'boss')
        diagnostics = export['diagnostics']
        errors = [row for row in diagnostics if row['level'] == 'error']
        self.assertEqual(errors, [
            {
                'level': 'error', 'code': 'image_missing',
                'path': 'passiveobject/mapobject/pathgate/town/cartelarad/ca_leftwall.obj',
                'detail': 'sprite/map/pathgate/town/cartelarad/ca_exitup010.img has no validated IMG in catalog',
            },
            {
                'level': 'error', 'code': 'image_missing',
                'path': 'passiveobject/mapobject/pathgate/town/cartelarad/ca_leftwall.obj',
                'detail': 'sprite/map/pathgate/town/cartelarad/ca_exitup010.img has no validated IMG in catalog',
            },
            {
                'level': 'error', 'code': 'image_missing',
                'path': 'passiveobject/mapobject/pathgate/town/cartelarad/ca_rightwall.obj',
                'detail': 'sprite/map/pathgate/town/cartelarad/ca_exitup08.img has no validated IMG in catalog',
            },
            {
                'level': 'error', 'code': 'image_missing',
                'path': 'passiveobject/mapobject/pathgate/town/cartelarad/ca_rightwall.obj',
                'detail': 'sprite/map/pathgate/town/cartelarad/ca_exitup08.img has no validated IMG in catalog',
            },
        ])
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'cell_without_map']), 15)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'object_unrendered']), 67)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'scroll_absent']), 78)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'unhandled_tags']), 26)
        selected_diag = [row for row in diagnostics if row['code'] == 'maze_block_selected']
        self.assertEqual(len(selected_diag), 1)
        self.assertIn('selected maze block 4 of 5', selected_diag[0]['detail'])
        self.assertIn('hell-base candidates=[4]', selected_diag[0]['detail'])

    def test_underfoot_export_uses_single_hell_base_layout(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/underfoot_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '01413357d13471901ca0dcceabc466ada9449f3f888eba97c00cd5dfd8687546')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['index'], 36)
        self.assertEqual(dungeon['maze_block_index'], 0)
        self.assertEqual(dungeon['maze_block_selection'], 'hell_base')
        self.assertEqual(len(dungeon['maze_blocks']), 1)
        self.assertEqual(dungeon['size'], [6, 3])
        self.assertEqual(dungeon['start_map_raw'], [0, 1])
        self.assertEqual(dungeon['boss_map_raw'], [5, 1])
        self.assertEqual(len(dungeon['rooms']), 15)
        self.assertEqual(len(dungeon['placements']), 23)
        self.assertEqual(len(export['images']), 111)
        selected = dungeon['maze_blocks'][0]
        self.assertEqual(len(selected['map_specifications']), 13)
        self.assertEqual(selected['boss_map_specifications'], [])
        self.assertEqual(sum(bool(cell['doors']) for cell in dungeon['cells']), 15)
        self.assertEqual(sum(cell['code'] == 'AA' for cell in dungeon['cells']), 3)
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(cells[(0, 1)]['map_candidates'], ['map/underfoot/s6601.map'])
        self.assertEqual(cells[(5, 1)]['map_candidates'], ['map/underfoot/b6615.map'])
        self.assertEqual(dungeon['rooms']['map/underfoot/s6601.map']['role_hint'], 'start')
        boss_room = dungeon['rooms']['map/underfoot/b6615.map']
        self.assertEqual(next(span['values'][0][2] for span in boss_room['raw']
                              if span['tag'] == '[type]'), '[boss]')
        self.assertEqual(sum(len(room['monsters']) for room in dungeon['rooms'].values()), 120)
        self.assertEqual(sum(len(room['objects']) for room in dungeon['rooms'].values()), 222)
        self.assertEqual(sum(1 for room in dungeon['rooms'].values()
                             for monster in room['monsters'] if monster['raw'][-1] == '[boss]'), 1)
        diagnostics = export['diagnostics']
        self.assertFalse([row for row in diagnostics if row['level'] == 'error'])
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'cell_without_map']), 3)
        self.assertFalse([row for row in diagnostics if row['code'] == 'object_unrendered'])
        self.assertFalse([row for row in diagnostics if row['code'] == 'maze_block_selected'])
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'unhandled_tags']), 15)

    def test_scasalair_export_keeps_two_start_cells_and_mask_pools(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/scasalair_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '33d86d36e372ad3d17ed062ce82a80710ec54395b19785c784a9419e760cb536')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['index'], 45)
        self.assertEqual(dungeon['maze_block_index'], 0)
        self.assertEqual(dungeon['maze_block_selection'], 'hell_base')
        self.assertEqual(dungeon['size'], [3, 4])
        self.assertEqual(dungeon['start_map_raw'], [1, 3, 0, 3])
        self.assertEqual(dungeon['boss_map_raw'], [0, 0])
        self.assertEqual(len(dungeon['rooms']), 16)
        self.assertEqual(len(dungeon['placements']), 21)
        self.assertEqual(len(export['images']), 74)
        self.assertEqual(len(dungeon['maze_blocks']), 2)
        base = dungeon['maze_blocks'][0]
        self.assertEqual(base['map_specifications'], [])
        self.assertEqual(base['boss_map_specifications'], [[0, 0, 9310]])
        self.assertEqual(base['quest_connection'], None)
        self.assertEqual(base['hell_dungeon'], [1])
        quest = dungeon['maze_blocks'][1]
        self.assertEqual(quest['quest_connection'], [0, 4571, 2])
        self.assertEqual(quest['escape_hell'], [1])
        self.assertEqual(sum(bool(cell['doors']) for cell in dungeon['cells']), 10)
        self.assertEqual(sum(cell['code'] == 'AA' for cell in dungeon['cells']), 2)
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(cells[(0, 3)]['map_candidates'], [
            'map/scasalair/e1(2,3).map',
            'map/scasalair/e2(start).map',
            'map/scasalair/start1(0,3).map',
            'map/scasalair/start2(1,3).map',
        ])
        self.assertEqual(cells[(1, 0)]['map_candidates'], [
            'map/scasalair/h2(1,0).map',
            'map/scasalair/qn2(1,2).map',
        ])
        self.assertEqual(cells[(0, 0)]['map_candidates'], [
            'map/scasalair/boss(0,0).map',
            'map/scasalair/qs1(0,2).map',
        ])
        self.assertEqual(sum(len(room['monsters']) for room in dungeon['rooms'].values()), 97)
        self.assertEqual(sum(len(room['objects']) for room in dungeon['rooms'].values()), 374)
        self.assertEqual(sum(1 for room in dungeon['rooms'].values()
                             for monster in room['monsters'] if monster['raw'][-1] == '[boss]'), 2)
        diagnostics = export['diagnostics']
        self.assertFalse([row for row in diagnostics if row['level'] == 'error'])
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'cell_without_map']), 2)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'object_unrendered']), 37)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'empty_tile']), 72)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'unhandled_tags']), 16)
        selected = [row for row in diagnostics if row['code'] == 'maze_block_selected']
        self.assertEqual(len(selected), 1)
        self.assertIn('selected maze block 0 of 2', selected[0]['detail'])

    def test_outergent_export_preserves_two_boss_branches(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/outergent_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '246884645ad85315f63f144f86b1347fa52b4d8cc5df29006bccd2ff6d3dfdb7')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['index'], 80)
        self.assertEqual(dungeon['maze_block_index'], 0)
        self.assertEqual(dungeon['maze_block_selection'], 'hell_base')
        self.assertEqual(dungeon['size'], [5, 5])
        self.assertEqual(dungeon['start_map_raw'], [2, 2])
        self.assertEqual(dungeon['boss_map_raw'], [0, 2, 4, 2])
        self.assertEqual(len(dungeon['rooms']), 17)
        self.assertEqual(len(dungeon['placements']), 29)
        self.assertEqual(len(export['images']), 53)
        self.assertEqual(len(dungeon['maze_blocks']), 1)
        block = dungeon['maze_blocks'][0]
        self.assertEqual(block['map_specifications'], [
            [0, 1, 10059], [1, 1, 10053], [3, 3, 10054], [4, 3, 10060],
        ])
        self.assertEqual(block['boss_map_specifications'], [])
        self.assertEqual(sum(bool(cell['doors']) for cell in dungeon['cells']), 15)
        self.assertEqual(sum(cell['code'] == 'AA' for cell in dungeon['cells']), 10)
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(cells[(2, 2)]['map_candidates'], ['map/outergent/01start(2,2).map'])
        self.assertEqual(cells[(0, 2)]['map_candidates'], [
            'map/outergent/boss1(0,2).map',
            'map/outergent/boss_not(0,2).map',
        ])
        self.assertEqual(cells[(4, 2)]['map_candidates'], [
            'map/outergent/boss2(4,2).map',
            'map/outergent/boss_not(4,2).map',
        ])
        self.assertEqual(sum(len(room['monsters']) for room in dungeon['rooms'].values()), 149)
        self.assertEqual(sum(len(room['objects']) for room in dungeon['rooms'].values()), 186)
        self.assertEqual(sum(1 for room in dungeon['rooms'].values()
                             for monster in room['monsters'] if monster['raw'][-1] == '[boss]'), 2)
        diagnostics = export['diagnostics']
        self.assertFalse([row for row in diagnostics if row['level'] == 'error'])
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'cell_without_map']), 10)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'object_unrendered']), 142)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'unhandled_tags']), 17)
        self.assertFalse([row for row in diagnostics if row['code'] == 'maze_block_selected'])

    def test_genteastgate_export_selects_hell_base_block_one(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/genteastgate_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '064337edb39b84d7a4dc7c7fbef089378ae64c6c1b61857224f2f9371d06d1a0')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['index'], 81)
        self.assertEqual(dungeon['maze_block_index'], 1)
        self.assertEqual(dungeon['maze_block_selection'], 'hell_base')
        self.assertEqual(dungeon['size'], [7, 3])
        self.assertEqual(dungeon['start_map_raw'], [6, 1, 0, 1])
        self.assertEqual(dungeon['boss_map_raw'], [5, 0, 1, 2])
        self.assertEqual(len(dungeon['rooms']), 19)
        self.assertEqual(len(dungeon['placements']), 71)
        self.assertEqual(len(export['images']), 47)
        self.assertEqual(len(dungeon['maze_blocks']), 2)
        self.assertEqual(dungeon['maze_blocks'][0]['quest_connection'], [0, 4212, -1])
        self.assertEqual(dungeon['maze_blocks'][0]['escape_hell'], [1])
        self.assertEqual(len(dungeon['maze_blocks'][1]['map_specifications']), 6)
        self.assertEqual(len(dungeon['maze_blocks'][1]['boss_map_specifications']), 2)
        self.assertEqual(sum(bool(cell['doors']) for cell in dungeon['cells']), 13)
        self.assertEqual(sum(cell['code'] == 'AA' for cell in dungeon['cells']), 8)
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(cells[(0, 1)]['map_candidates'], [
            'map/genteastgate/bonus2(2,0).map',
            'map/genteastgate/boss1(0,2).map',
            'map/genteastgate/start1(0,1).map',
        ])
        self.assertEqual(cells[(5, 0)]['map_candidates'], [
            'map/genteastgate/(4,0)maze1boss.map',
            'map/genteastgate/bonus1(4,2).map',
            'map/genteastgate/boss2(6,0).map',
            'map/genteastgate/start2(6,1).map',
        ])
        self.assertEqual(len(cells[(4, 1)]['map_candidates']), 9)
        self.assertEqual(sum(len(room['monsters']) for room in dungeon['rooms'].values()), 152)
        self.assertEqual(sum(len(room['objects']) for room in dungeon['rooms'].values()), 162)
        self.assertEqual(sum(1 for room in dungeon['rooms'].values()
                             for monster in room['monsters'] if monster['raw'][-1] == '[boss]'), 3)
        diagnostics = export['diagnostics']
        self.assertFalse([row for row in diagnostics if row['level'] == 'error'])
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'cell_without_map']), 8)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'object_unrendered']), 96)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'unhandled_tags']), 19)
        selected = [row for row in diagnostics if row['code'] == 'maze_block_selected']
        self.assertEqual(len(selected), 1)
        self.assertIn('selected maze block 1 of 2', selected[0]['detail'])

    def test_vilmark_export_keeps_six_fixed_rooms_and_item_groups(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/vilmark_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '4505427c9068da16427cd32547f070e9f912352d7d9f9cd00ae51dcd26fee45d')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['index'], 1500)
        self.assertEqual(dungeon['maze_block_index'], 0)
        self.assertEqual(dungeon['maze_block_selection'], 'hell_base')
        self.assertEqual(len(dungeon['maze_blocks']), 1)
        self.assertEqual(dungeon['size'], [6, 1])
        self.assertEqual(dungeon['start_map_raw'], [0, 0])
        self.assertEqual(dungeon['boss_map_raw'], [5, 0])
        self.assertEqual(len(dungeon['rooms']), 6)
        self.assertEqual(len(dungeon['placements']), 18)
        self.assertEqual(len(export['images']), 47)
        self.assertEqual(len(dungeon['cells']), 6)
        self.assertEqual(sum(len(cell['doors']) for cell in dungeon['cells']), 10)
        block = dungeon['maze_blocks'][0]
        self.assertEqual(block['map_specifications'], [
            [5, 0, 5206], [4, 0, 5205], [3, 0, 5204],
            [2, 0, 5203], [1, 0, 5202], [0, 0, 5201],
        ])
        self.assertEqual(block['boss_map_specifications'], [])
        self.assertEqual(block['hell_dungeon'], [1])
        self.assertEqual(block['seal_door_map_index'], [60038])
        self.assertEqual(block['seal_door_pos'], [4, 0])
        self.assertEqual(block['seal_door_appear_rate'], [10])
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(cells[(0, 0)]['map_candidates'], ['map/vilmark/s5201.map'])
        self.assertEqual(cells[(5, 0)]['map_candidates'], ['map/vilmark/b5201.map'])
        self.assertEqual(sum(len(room['monsters']) for room in dungeon['rooms'].values()), 37)
        self.assertEqual(sum(len(room['objects']) for room in dungeon['rooms'].values()), 209)
        self.assertEqual(sum(1 for room in dungeon['rooms'].values()
                             for monster in room['monsters'] if monster['raw'][-1] == '[boss]'), 1)
        diagnostics = export['diagnostics']
        self.assertFalse([row for row in diagnostics if row['level'] in ('error', 'warning')])
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'unhandled_tags']), 6)

    def test_leshphon_export_keeps_six_cells_and_event_action_objects(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/leshphon_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '523a5924b9faeae3da4e63c2cbac7f8f7fdb0bd27a7155d7b0b8388714365293')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['index'], 1506)
        self.assertEqual(dungeon['maze_block_index'], 0)
        self.assertEqual(dungeon['maze_block_selection'], 'hell_base')
        self.assertEqual(len(dungeon['maze_blocks']), 1)
        self.assertEqual(dungeon['size'], [2, 3])
        self.assertEqual(dungeon['start_map_raw'], [1, 0])
        self.assertEqual(dungeon['boss_map_raw'], [0, 2])
        self.assertEqual(len(dungeon['rooms']), 6)
        self.assertEqual(len(dungeon['placements']), 6)
        self.assertEqual(len(export['images']), 79)
        self.assertEqual(len(dungeon['cells']), 6)
        self.assertEqual(sum(len(cell['doors']) for cell in dungeon['cells']), 10)
        block = dungeon['maze_blocks'][0]
        self.assertEqual([row[2] for row in block['map_specifications']],
                         [15057, 15058, 15059, 15060, 15061])
        self.assertEqual([row[2] for row in block['boss_map_specifications']], [15062])
        self.assertEqual(block['hell_dungeon'], [1])
        self.assertEqual(block['seal_door_map_index'], [60053])
        self.assertEqual(block['seal_door_pos'], [0, 1])
        self.assertEqual(block['seal_door_appear_rate'], [10])
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(cells[(1, 0)]['map_candidates'], ['map/leshphon/(1,0)start.map'])
        self.assertEqual(cells[(0, 2)]['map_candidates'], ['map/leshphon/(0,2)boss.map'])
        self.assertEqual(sum(len(room['monsters']) for room in dungeon['rooms'].values()), 28)
        self.assertEqual(sum(len(room['objects']) for room in dungeon['rooms'].values()), 113)
        self.assertEqual(sum(1 for room in dungeon['rooms'].values()
                             for monster in room['monsters'] if monster['raw'][-1] == '[boss]'), 1)
        objects = [item for room in dungeon['rooms'].values() for item in room['objects']]
        self.assertEqual({item['source_tag'] for item in objects}, {'[passive object]'})
        self.assertEqual(len({item['obj'] for item in objects}), 15)
        self.assertEqual(sum(item['sprite'] is None for item in objects), 1)
        diagnostics = export['diagnostics']
        self.assertFalse([row for row in diagnostics if row['level'] == 'error'])
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'object_unrendered']), 1)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'scroll_absent']), 18)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'unhandled_tags']), 6)

    def test_noirpera_export_keeps_seven_fixed_rooms_and_no_objects(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/noirpera_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '123d44302169bc52aae44ac4220e220b9caae708a221984a5298c8c788aab56f')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['index'], 1502)
        self.assertEqual(dungeon['maze_block_index'], 0)
        self.assertEqual(dungeon['maze_block_selection'], 'hell_base')
        self.assertEqual(len(dungeon['maze_blocks']), 1)
        self.assertEqual(dungeon['size'], [5, 2])
        self.assertEqual(dungeon['start_map_raw'], [0, 0])
        self.assertEqual(dungeon['boss_map_raw'], [4, 0])
        self.assertEqual(len(dungeon['rooms']), 7)
        self.assertEqual(len(dungeon['placements']), 7)
        self.assertEqual(len(export['images']), 81)
        self.assertEqual(len(dungeon['cells']), 10)
        self.assertEqual(sum(len(cell['doors']) for cell in dungeon['cells']), 12)
        block = dungeon['maze_blocks'][0]
        self.assertEqual([row[2] for row in block['map_specifications']],
                         [7102, 7103, 7104, 7105, 7106])
        self.assertEqual(block['boss_map_specifications'], [])
        self.assertEqual(block['hell_dungeon'], [1])
        self.assertEqual(block['seal_door_map_index'], [60036])
        self.assertEqual(block['seal_door_pos'], [3, 0])
        self.assertEqual(block['seal_door_appear_rate'], [10])
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(cells[(0, 0)]['map_candidates'], ['map/noirpera/map1(0,0)_start.map'])
        self.assertEqual(cells[(4, 0)]['map_candidates'], ['map/noirpera/map7(4,0)_boss.map'])
        self.assertEqual(cells[(0, 1)]['map_candidates'], [])
        self.assertEqual(sum(len(room['monsters']) for room in dungeon['rooms'].values()), 47)
        self.assertEqual(sum(len(room['objects']) for room in dungeon['rooms'].values()), 0)
        self.assertEqual(sum(1 for room in dungeon['rooms'].values()
                             for monster in room['monsters'] if monster['raw'][-1] == '[boss]'), 1)
        diagnostics = export['diagnostics']
        self.assertFalse([row for row in diagnostics if row['level'] == 'error'])
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'cell_without_map']), 3)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'unhandled_tags']), 7)

    def test_screamingcave_export_selects_hell_base_and_keeps_quest_blocks(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/screamingcave_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], 'af64830f63d7142e1ba7794dcc5f0b5b8731f79fbda68d881b8778797306c05a')
        self.assertIn('E-PARSE', dungeon['cell_map_rule'])
        self.assertEqual(dungeon['index'], 1501)
        self.assertEqual(dungeon['maze_block_index'], 0)
        self.assertEqual(dungeon['maze_block_selection'], 'hell_base')
        self.assertEqual(len(dungeon['maze_blocks']), 3)
        self.assertEqual(dungeon['size'], [6, 1])
        self.assertEqual(dungeon['start_map_raw'], [5, 0])
        self.assertEqual(dungeon['boss_map_raw'], [0, 0])
        self.assertEqual(len(dungeon['rooms']), 9)
        self.assertEqual(len(dungeon['placements']), 18)
        self.assertEqual(len(export['images']), 102)
        self.assertEqual(len(dungeon['cells']), 6)
        self.assertEqual(sum(len(cell['doors']) for cell in dungeon['cells']), 10)
        selected = dungeon['maze_blocks'][0]
        self.assertEqual([row[2] for row in selected['map_specifications']],
                         [6805, 6804, 6803, 6802])
        self.assertEqual(selected['boss_map_specifications'], [])
        self.assertEqual(selected['hell_dungeon'], [1])
        self.assertEqual(selected['seal_door_map_index'], [60037])
        self.assertEqual(selected['seal_door_pos'], [1, 0])
        self.assertEqual(selected['seal_door_appear_rate'], [10])
        self.assertEqual(dungeon['maze_blocks'][1]['quest_connection'], [0, 4358, 2])
        self.assertEqual(dungeon['maze_blocks'][1]['escape_hell'], [1])
        self.assertEqual(dungeon['maze_blocks'][2]['quest_connection'], [0, 4378, 2])
        self.assertEqual(dungeon['maze_blocks'][2]['escape_hell'], [1])
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertEqual(cells[(5, 0)]['map_candidates'], ['map/screamingcave/s6801.map'])
        self.assertEqual(cells[(0, 0)]['map_candidates'], ['map/screamingcave/b6806.map'])
        self.assertEqual(len(cells[(1, 0)]['map_candidates']), 4)
        self.assertEqual(sum(len(room['monsters']) for room in dungeon['rooms'].values()), 80)
        self.assertEqual(sum(len(room['objects']) for room in dungeon['rooms'].values()), 45)
        self.assertEqual(sum(1 for room in dungeon['rooms'].values()
                             for monster in room['monsters'] if monster['raw'][-1] == '[boss]'), 2)
        objects = [item for room in dungeon['rooms'].values() for item in room['objects']]
        self.assertEqual({item['source_tag'] for item in objects},
                         {'[passive object]', '[special passive object]'})
        self.assertEqual(sum(item['sprite'] is None for item in objects), 12)
        special = next(span for span in dungeon['raw']
                       if span['tag'] == '[special passive object item]')
        self.assertEqual([row[2] for row in special['values']], [0, -1, 1, 3222, 10000])
        diagnostics = export['diagnostics']
        self.assertFalse([row for row in diagnostics if row['level'] == 'error'])
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'object_unrendered']), 12)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'unhandled_tags']), 9)
        selected_rows = [row for row in diagnostics if row['code'] == 'maze_block_selected']
        self.assertEqual(len(selected_rows), 1)
        self.assertIn('selected maze block 0 of 3', selected_rows[0]['detail'])

    def test_villageoftemptation_export_keeps_three_boss_candidates_and_dummy_maps(self):
        export = json.loads(
            (ROOT / 'game_dnf/assets_local/native_maps/villageoftemptation_v1/map_export.json')
            .read_text(encoding='utf-8'))
        dungeon = export['dungeon']
        self.assertEqual(dungeon['sha256'], '8a5c04698a9c51fa62c86e87a4cc33f1af1dd69643d64081adba4dafb03f2aa2')
        self.assertEqual(dungeon['index'], 51)
        self.assertEqual(dungeon['maze_block_index'], 0)
        self.assertEqual(dungeon['maze_block_selection'], 'hell_base')
        self.assertEqual(dungeon['size'], [5, 5])
        self.assertEqual(dungeon['start_map_raw'], [2, 4])
        self.assertEqual(dungeon['boss_map_raw'], [0, 0, 0, 1, 1, 0])
        self.assertEqual(len(dungeon['maze_blocks']), 1)
        self.assertEqual(len(dungeon['cells']), 25)
        self.assertEqual(len(dungeon['placements']), 46)
        self.assertEqual(len(dungeon['rooms']), 22)
        self.assertEqual(len(export['images']), 75)
        selected = dungeon['maze_blocks'][0]
        self.assertEqual([row[2] for row in selected['map_specifications']], [6410, 6402, 6415])
        self.assertEqual(selected['boss_map_specifications'], [])
        self.assertEqual(selected['hell_dungeon'], [1])
        self.assertEqual(selected['seal_door_map_index'], [60019])
        self.assertEqual(selected['seal_door_pos'], [3, 0])
        self.assertEqual(selected['seal_door_appear_rate'], [1])
        cells = {(cell['x'], cell['y']): cell for cell in dungeon['cells']}
        self.assertTrue(cells[(2, 4)]['start_candidate'])
        self.assertEqual([(x, y) for (x, y), cell in cells.items() if cell['boss_candidate']],
                         [(0, 0), (1, 0), (0, 1)])
        self.assertIn('map/villigeoftemptation/s6401.map', cells[(2, 4)]['map_candidates'])
        self.assertEqual(len(cells[(2, 4)]['map_candidates']), 5)
        self.assertEqual(cells[(2, 3)]['map_candidates'],
                         ['map/villigeoftemptation/h6410.map',
                          'map/villigeoftemptation/n6402.map'])
        self.assertIn('map/villigeoftemptation/n6415.map', cells[(4, 1)]['map_candidates'])
        self.assertEqual(len(cells[(4, 1)]['map_candidates']), 5)
        self.assertEqual(len(cells[(0, 0)]['map_candidates']), 4)
        self.assertEqual(len(cells[(0, 1)]['map_candidates']), 5)
        self.assertEqual(len(cells[(1, 0)]['map_candidates']), 4)
        self.assertEqual(sum(not cell['map_candidates'] for cell in cells.values()), 9)
        self.assertEqual(sum(len(room['monsters']) for room in dungeon['rooms'].values()), 172)
        self.assertEqual(sum(len(room['objects']) for room in dungeon['rooms'].values()), 337)
        mobs = {monster['mob'] for room in dungeon['rooms'].values()
                for monster in room['monsters']}
        self.assertEqual(len(mobs), 9)
        self.assertEqual(sum(1 for room in dungeon['rooms'].values()
                             for monster in room['monsters'] if monster['raw'][-1] == '[boss]'), 6)
        objects = [item for room in dungeon['rooms'].values() for item in room['objects']]
        self.assertEqual({item['source_tag'] for item in objects},
                         {'[passive object]', '[special passive object]'})
        self.assertEqual(len({item['obj'] for item in objects}), 15)
        self.assertEqual(sum('breakableobject/' in item['obj'] for item in objects), 27)
        special = next(span for span in dungeon['raw']
                       if span['tag'] == '[special passive object item]')
        self.assertEqual([row[2] for row in special['values']],
                         [0, -1, 3, 1089, 1000, 1090, 1000, 3217, 3000])
        self.assertEqual(next(span for span in dungeon['raw']
                              if span['tag'] == '[champion]')['values'],
                         [[2, '06000000', 6], [2, '0c000000', 12],
                          [2, '12000000', 18], [2, '18000000', 24],
                          [2, '1a000000', 26]])
        self.assertEqual([token[2] for token in next(
            span for span in dungeon['raw'] if span['tag'] == '[event monster]')['values']],
            [1, 10000, 61728, 1, 300, 80, 1])
        roles = {}
        for path, room in dungeon['rooms'].items():
            for span in room['raw']:
                if span['tag'] == '[type]' and span['values']:
                    roles[room['map_id']] = span['values'][0][2]
                    break
        self.assertEqual({map_id: roles[map_id] for map_id in (6418, 6420, 6424)},
                         {6418: '[dummy]', 6420: '[dummy]', 6424: '[dummy]'})
        diagnostics = export['diagnostics']
        self.assertFalse([row for row in diagnostics if row['level'] == 'error'])
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'cell_without_map']), 9)
        self.assertEqual(len([row for row in diagnostics if row['code'] == 'unhandled_tags']), 22)
        selected_rows = [row for row in diagnostics if row['code'] == 'maze_block_selected']
        self.assertEqual(selected_rows, [])

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

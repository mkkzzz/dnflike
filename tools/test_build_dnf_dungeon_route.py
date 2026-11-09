"""Route generation preserves authored source maps and runtime gates."""
import json
import unittest

try:
    from .bake_dnf_bgm import source_dungeon_tracks
    from .build_dnf_dungeon_route import GAME, build, merge_route, pick_map, resolve_selected_room, source_map_specifications
except ImportError:
    from bake_dnf_bgm import source_dungeon_tracks
    from build_dnf_dungeon_route import GAME, build, merge_route, pick_map, resolve_selected_room, source_map_specifications


class DungeonRouteMergeTest(unittest.TestCase):
    def setUp(self):
        self.existing = {
            "name": "旧名称",
            "region": "granfloris",
            "map_export": "res://old.json",
            "rooms": [{"placement": "old"}],
            "requires": ["source.quest"],
            "min_level": 7,
            "hidden": True,
            "runtime_tag": "keep",
        }
        self.generated = {
            "name": "新名称",
            "region": "granfloris",
            "map_export": "res://new.json",
            "rooms": [{"placement": "new"}],
            "monster_level": 9,
            "source": {"path": "dungeon/new.dgn"},
        }

    def test_default_keeps_existing_route_and_runtime_fields(self):
        self.assertIs(
            merge_route(self.existing, self.generated, refresh=False),
            self.existing,
        )

    def test_refresh_updates_route_but_preserves_runtime_fields(self):
        merged = merge_route(self.existing, self.generated, refresh=True)
        self.assertEqual(merged["name"], "新名称")
        self.assertEqual(merged["map_export"], "res://new.json")
        self.assertEqual(merged["rooms"], [{"placement": "new"}])
        self.assertEqual(merged["requires"], ["source.quest"])
        self.assertEqual(merged["min_level"], 7)
        self.assertTrue(merged["hidden"])
        self.assertEqual(merged["runtime_tag"], "keep")

    def test_new_route_is_used_verbatim(self):
        merged = merge_route(None, self.generated, refresh=False)
        self.assertEqual(merged, self.generated)


class DungeonBossMapTest(unittest.TestCase):
    def test_boss_cell_prefers_source_spawn_over_filename(self):
        ordinary = 'map/example/(0,0)d1601.map'
        boss = 'map/example/(1,0)b1823.map'
        export = {'dungeon': {
            'cells': [
                {'x': 0, 'y': 0, 'start_candidate': True, 'map_candidates': [ordinary], 'doors': ['right']},
                {'x': 1, 'y': 0, 'boss_candidate': True, 'map_candidates': [ordinary, boss], 'doors': ['left']},
            ],
            'rooms': {
                ordinary: {'monsters': [{'raw': [14, 1, 0, 60, 120, 0, 1, 1, '[fixed]']}]},
                boss: {'monsters': [{'raw': [71, 1, 0, 1399, 332, 0, 2, 1, '[fixed]', '[boss]']}]},
            },
        }}
        self.assertEqual(build(export)[-1]['placement'], '1_0:(1,0)b1823')
        export['dungeon']['rooms'][ordinary] = export['dungeon']['rooms'][boss]
        self.assertIsNone(build(export), 'a cell with multiple source boss maps requires a known selection')
        export['dungeon']['rooms'][ordinary] = {'monsters': []}
        export['dungeon']['rooms'][boss] = {'monsters': []}
        self.assertIsNone(build(export), 'an ordinary map cannot be promoted to the final room')


class DungeonStartMapTest(unittest.TestCase):
    def test_start_map_uses_source_area_and_matching_cell(self):
        ordinary = 'map/example/(2,0)d1601.map'
        other_start = 'map/example/(2,4)s1616.map'
        exact_start = 'map/example/(2,0)s1601.map'
        cell = {'x': 2, 'y': 0, 'map_candidates': [ordinary, other_start, exact_start]}
        maps = {
            ordinary: {'start_area': None},
            other_start: {'start_area': [945, 224, 253, 201]},
            exact_start: {'start_area': [990, 217, 198, 208]},
        }
        self.assertEqual(pick_map(cell, 'start', maps), '(2,0)s1601')
        self.assertEqual(pick_map(cell, 'normal', maps), '(2,0)d1601')


class DungeonMusicTest(unittest.TestCase):
    def test_resolves_map_keys_through_audio_xml_and_rejects_unresolved_room(self):
        source_rooms = {
            'start.map': {'sound': ['M_OUTER_TEMPLE', 'R_AMB_WIND']},
            'boss.map': {'sound': ['M_BEHEMOTH_BOSS_01_1', 'R_AMB_WIND']},
        }
        export = {'dungeon': {
            'path': 'dungeon/act3/outerwall.dgn',
            'rooms': source_rooms,
            'placements': [{'id': 'start', 'map': 'start.map'}, {'id': 'end', 'map': 'boss.map'}],
        }}
        route = [{'placement': 'start'}, {'placement': 'end', 'boss': True}]
        music = {
            'M_OUTER_TEMPLE': 'music/outer_temple.ogg',
            'M_BEHEMOTH_BOSS_01_1': 'music/behemoth_b01_1.ogg',
        }
        self.assertEqual(source_dungeon_tracks(export, route, music), {
            'normal': 'music/outer_temple.ogg', 'boss': 'music/behemoth_b01_1.ogg',
        })
        source_rooms['boss.map']['sound'] = ['R_AMB_WIND']
        with self.assertRaisesRegex(ValueError, 'boss.map.*audio.xml'):
            source_dungeon_tracks(export, route, music)


class DungeonSpecifiedMapTest(unittest.TestCase):
    def test_unverified_map_pools_keep_the_existing_route(self):
        spec = json.loads((GAME / 'data/dungeons.json').read_bytes())['dungeons']['mirkwood_deep']
        export = json.loads((GAME / spec['map_export'].removeprefix('res://')).read_bytes())
        generated = build(export)
        self.assertEqual([r['placement'] for r in generated],
                         ['0_3:s401', '1_3:403', '1_2:407', '0_2:405', '0_1:409', '0_0:b413'])

    def test_palace_ordinary_route_preserves_specified_source_maps(self):
        spec = json.loads((GAME / 'data/dungeons.json').read_bytes())['dungeons']['palaceofload']
        export = json.loads((GAME / spec['map_export'].removeprefix('res://')).read_bytes())
        dungeon = export['dungeon']
        placements = {p['id']: p for p in dungeon['placements']}
        generated = build(export)
        ids = [dungeon['rooms'][placements[room['placement']]['map']]['map_id'] for room in generated]
        self.assertEqual(ids, [2407, 2413, 2412, 2411, 2410, 2409, 2408])
        self.assertEqual([r['placement'] for r in generated], [r['placement'] for r in spec['rooms']])
        escort = spec['quest_routes']['original.quest.4312']['rooms']
        self.assertEqual(dungeon['rooms'][placements[escort[0]['placement']]['map']]['map_id'], 2421)
        self.assertFalse(any('quest4312_' in r['placement'] for r in generated))


class DungeonSelectedMapTest(unittest.TestCase):
    def setUp(self):
        def span(tag, *values):
            return {'tag': tag, 'values': [[0, 'int', value] for value in values]}

        maps = {
            'start_a.map': {'map_id': 3001, 'start_area': [260, 181, 75, 234]},
            'start_b.map': {'map_id': 3002, 'start_area': [236, 213, 71, 208]},
            'normal.map': {'map_id': 3020},
            'boss.map': {'map_id': 3024, 'monsters': [{'raw': [265, '[boss]']}]},
            'layered.map': {'map_id': 3026},
        }
        self.export = {'dungeon': {
            'raw': [span('[maze info]'), span('[map specification]', 5, 0, 3019, 3020),
                    span('[map specification]', 5, 0, 3020, 3021),
                    span('[boss map specification]', 5, 0, 3024),
                    span('[layered map specification]', 5, 0, 3026),
                    span('[maze info]'), span('[quest connection]', 0, 23, 1),
                    span('[map specification]', 5, 0, 3025)],
            'cells': [{'x': 0, 'y': 0, 'start_candidate': True, 'map_candidates': ['start_a.map', 'start_b.map']},
                      {'x': 5, 'y': 0, 'boss_candidate': True, 'map_candidates': ['normal.map', 'boss.map', 'layered.map']}],
            'rooms': maps,
            'placements': [
                {'id': '0_0:start_a', 'cell': [0, 0], 'map': 'start_a.map'},
                {'id': '0_0:start_b', 'cell': [0, 0], 'map': 'start_b.map'},
                {'id': '5_0:normal', 'cell': [5, 0], 'map': 'normal.map'},
                {'id': '5_0:boss', 'cell': [5, 0], 'map': 'boss.map'},
                {'id': '5_0:quest23_boss', 'cell': [5, 0], 'map': 'boss.map', 'quest_maze': 'original.quest.23'},
                {'id': '5_0:layered', 'cell': [5, 0], 'map': 'layered.map'},
            ],
        }}

    def test_packet_map_keeps_both_start_candidates_and_distinguishes_same_cell_roles(self):
        for cell, map_id, role, expected in [
            ((0, 0), 3001, 'start', '0_0:start_a'), ((0, 0), 3002, 'start', '0_0:start_b'),
            ((5, 0), 3020, 'normal', '5_0:normal'), ((5, 0), 3024, 'boss', '5_0:boss'),
        ]:
            self.assertEqual(resolve_selected_room(self.export, cell, map_id, role)['id'], expected)
        for cell, map_id, role in [
            ((0, 0), 3024, 'boss'), ((5, 0), 3020, 'boss'), ((5, 0), 3024, 'normal'),
            ((0, 0), 3002, 'normal'), ((5, 0), 3025, 'normal'), ((False, 0), 3001, 'start'),
        ]:
            with self.subTest(cell=cell, map_id=map_id, role=role), self.assertRaises(ValueError):
                resolve_selected_room(self.export, cell, map_id, role)

    def test_map_pools_preserve_separate_roles_order_and_native_replacement(self):
        self.assertEqual(source_map_specifications(self.export['dungeon']), {
            '[map specification]': {(5, 0): [3020, 3021]},
            '[boss map specification]': {(5, 0): [3024]},
            '[layered map specification]': {(5, 0): [3026]},
        })
        self.assertEqual(resolve_selected_room(self.export, (5, 0), 3026, 'normal', layered=True)['id'], '5_0:layered')
        with self.assertRaisesRegex(ValueError, 'source layered room'):
            resolve_selected_room(self.export, (5, 0), 3020, 'normal', layered=True)


if __name__ == "__main__":
    unittest.main()

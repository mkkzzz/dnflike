"""Route generation preserves authored source maps and runtime gates."""
import json
import unittest

try:
    from .build_dnf_dungeon_route import GAME, build, merge_route, pick_map
except ImportError:
    from build_dnf_dungeon_route import GAME, build, merge_route, pick_map


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


if __name__ == "__main__":
    unittest.main()

"""Route generation must never erase authored runtime gates by accident."""
import unittest

try:
    from .build_dnf_dungeon_route import build, merge_route, pick_map
except ImportError:
    from build_dnf_dungeon_route import build, merge_route, pick_map


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


if __name__ == "__main__":
    unittest.main()

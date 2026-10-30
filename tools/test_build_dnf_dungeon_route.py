"""Route generation must never erase authored runtime gates by accident."""
import unittest

try:
    from .build_dnf_dungeon_route import merge_route
except ImportError:
    from build_dnf_dungeon_route import merge_route


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


if __name__ == "__main__":
    unittest.main()

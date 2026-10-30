"""Room reapplication must preserve runtime-only town configuration."""
import unittest

try:
    from .apply_dnf_town_rooms import merge_location
except ImportError:
    from apply_dnf_town_rooms import merge_location


class TownRoomMergeTest(unittest.TestCase):
    def test_existing_runtime_fields_survive_room_refresh(self):
        existing = {
            "name": "旧名",
            "dungeon_region": "skytower",
            "dungeon_entry": [1, 2, 3, 4],
            "npcs": {"lorian": [10, 20]},
            "labels": [["旧标签"]],
            "camera_y": 3,
        }
        merged = merge_location(
            existing,
            "westcoast",
            "西海岸",
            [100, 200],
            [[0, 0, 300, 12]],
            {},
        )
        self.assertEqual(merged["name"], "西海岸")
        self.assertEqual(merged["spawn"], [100, 200])
        self.assertEqual(merged["dungeon_region"], "skytower")
        self.assertEqual(merged["dungeon_entry"], [1, 2, 3, 4])
        self.assertEqual(merged["npcs"]["lorian"], [10, 20])
        self.assertEqual(merged["camera_y"], 3)

    def test_manifest_npcs_replace_stale_anchors(self):
        merged = merge_location(
            {"npcs": {"lorian": [1, 1]}},
            "westcoast",
            "西海岸",
            [100, 200],
            [[0, 0, 300, 12]],
            {"lorian": [1206, 206]},
        )
        self.assertEqual(merged["npcs"]["lorian"], [1206, 206])


if __name__ == "__main__":
    unittest.main()

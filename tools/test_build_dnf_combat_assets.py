"""Staging and publish checks for combat asset builds."""
import tempfile
import unittest
from pathlib import Path

try:
    from .build_dnf_combat_assets import publish_tree
except ImportError:
    from build_dnf_combat_assets import publish_tree


class CombatAssetPublishTest(unittest.TestCase):
    def test_publish_replaces_previous_tree_after_stage_is_complete(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            target = root / "combat"
            stage = root / "stage"
            backups = root / "backups"
            target.mkdir()
            (target / "old.txt").write_text("old", encoding="utf-8")
            (target / "audio").mkdir()
            (target / "audio" / "hit.ogg").write_bytes(b"old-audio")
            (target / "audio" / "hit.ogg.import").write_text("uid=old", encoding="utf-8")
            stage.mkdir()
            (stage / "new.txt").write_text("new", encoding="utf-8")
            (stage / "audio").mkdir()
            (stage / "audio" / "hit.ogg").write_bytes(b"pcm")

            retained = publish_tree(stage, target, backup_parent=backups)

            self.assertIsNone(retained)
            self.assertFalse((target / "old.txt").exists())
            self.assertEqual((target / "new.txt").read_text(encoding="utf-8"), "new")
            self.assertEqual((target / "audio" / "hit.ogg").read_bytes(), b"pcm")
            self.assertEqual(
                (target / "audio" / "hit.ogg.import").read_text(encoding="utf-8"),
                "uid=old",
            )
            self.assertFalse(any(backups.iterdir()))


if __name__ == "__main__":
    unittest.main()

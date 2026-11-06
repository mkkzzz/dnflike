"""Staging and publish checks for combat asset builds."""
import tempfile
import unittest
import copy
from unittest.mock import patch
from pathlib import Path

try:
    from .build_dnf_combat_assets import publish_tree, animation_flags, refresh_animation_metadata, effect_bank, Atlas
    from .export_dnf_map import Library as MapLibrary
except ImportError:
    from build_dnf_combat_assets import publish_tree, animation_flags, refresh_animation_metadata, effect_bank, Atlas
    from export_dnf_map import Library as MapLibrary


class NativeAnimationMetadataTest(unittest.TestCase):
    def test_loop_and_other_global_flag_are_distinct(self):
        self.assertFalse(animation_flags({})['loop'])
        self.assertFalse(animation_flags({'global_items': {'1': 1}})['loop'])
        self.assertTrue(animation_flags({'global_items': {'0': 1, '1': 0}})['loop'])
        self.assertFalse(animation_flags({'global_items': {'0': 0, '1': 1}})['loop'])

    def test_both_exporters_consume_native_loop_tag(self):
        for flags in ({'0': 1, '1': 0}, {'0': 0, '1': 1}, {}):
            ani = {'frames': [], 'duration_ms': 0, 'global_items': flags}
            class Source:
                def animation(self, path):return ani
            with patch.object(Atlas, 'save', return_value={'texture': 'unchanged.png'}):
                bank = effect_bank(Source(), 'a', 'a.ani', [])
            self.assertEqual(bank['global_items'], flags)
            self.assertEqual(bank['loop'], bool(flags.get('0', 0)))
            library = object.__new__(MapLibrary)
            library.animation = lambda path: {'meta': ani, 'sha256': 'pinned'}
            self.assertEqual(library.sprite('a.ani', 'test')['loop_flag'], flags.get('0', 0))

    def test_metadata_refresh_preserves_frames_atlas_and_source(self):
        class Source:
            sources = {'a.ani': 'pinned'}
            def animation(self, path):
                return {'global_items': {'0': 1, '18': [1, 2]}}
        bank = {'source': 'a.ani', 'frames': [{'delay_ms': 70}],
                'atlas': {'texture': 'unchanged.png'}, 'duration_ms': 70}
        manifest = {'sources': {'a.ani': 'pinned'}, 'effects': {'a': bank}}
        original = copy.deepcopy(manifest)
        result = refresh_animation_metadata(Source(), manifest)
        self.assertEqual(manifest, original)
        updated = result['effects']['a']
        self.assertEqual({k: updated[k] for k in bank}, bank)
        self.assertEqual(updated['global_items'], {'0': 1, '18': [1, 2]})
        self.assertTrue(updated['loop'])
        self.assertEqual(refresh_animation_metadata(Source(), result), result)
        Source.sources = {'a.ani': 'different'}
        with self.assertRaisesRegex(ValueError, 'source hash differs'):
            refresh_animation_metadata(Source(), manifest)
        self.assertEqual(manifest, original)


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

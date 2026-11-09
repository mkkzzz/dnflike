"""Staging and publish checks for combat asset builds."""
import tempfile
import unittest
import copy
import json
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


class NativeSpiritSummonAssetsTest(unittest.TestCase):
    def test_original_cast_proxy_and_normal_attack_banks_are_bound(self):
        root = Path(__file__).resolve().parents[1] / 'game_dnf'
        assets = root / 'assets_local'
        manifest = json.loads((assets/'combat/manifest.json').read_text(encoding='utf-8'))
        pack = json.loads((assets/'content/combat_content.json').read_text(encoding='utf-8'))
        records = pack['records']
        proxy = 'passiveobject/common/summonmonster.obj'
        summons = manifest['native_spirit_summons']
        self.assertEqual(summons, records[proxy]['native_spirit_summons'])
        self.assertEqual(pack['indexes']['passive_objects']['48024'], proxy)
        for caster, mob, extra, z, frames, duration in (
            ('bossfather', 'darkspirit', 3, 0, 9, 800), ('bosspope', 'lightspirit', 4, 40, 10, 900),
        ):
            with self.subTest(caster=caster):
                caster_path = f'monster/zealot/{caster}.mob'
                spec = summons[caster_path]
                self.assertEqual(spec['mob'], f'monster/spirit/{mob}.mob')
                self.assertEqual((spec['extra'], spec['birth_z'], spec['proxy_id']), (extra, z, 48024))
                self.assertEqual(spec['cast_ani'], records[caster_path]['decoded']['etc_motions'][2])
                self.assertEqual([layer['order'] for layer in spec['cast_layers']], [-100, 100, 200])
                self.assertTrue(all(layer['bank'] in manifest['effects'] for layer in spec['cast_layers']))
                bank = manifest['effects'][spec['proxy_bank']]
                self.assertEqual((bank['source'], bank['duration_ms']), (spec['proxy_ani'], duration))
                self.assertEqual(len(bank['frames']), frames)
                self.assertIsNone(bank['frames'][0].get('delay_ms'))
                self.assertEqual([frame['delay_ms'] for frame in bank['frames'][1:]], [100] * (frames - 1))
                self.assertFalse(bank['loop'])
                self.assertTrue((root/bank['atlas']['texture'].removeprefix('res://')).is_file())
                for path, percent in ((caster_path, 80), (spec['mob'], 60)):
                    policy = records[path]['native_attack_selection']
                    self.assertEqual((policy['initial_ms'], policy['delay_ms'], policy['delay_spread_ms']),
                                     (3000, 1200, 240))
                    slot, = policy['slots']
                    self.assertEqual((slot['slot'], slot['standing_percent']), (0, percent))
        self.assertEqual([len(manifest['audio'][key]) for key in ('BELIEVER_PRAY', 'R_CLAWC_HIT', 'FG_HIT_01')],
                         [2, 2, 1])


if __name__ == "__main__":
    unittest.main()

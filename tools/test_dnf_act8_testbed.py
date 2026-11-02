"""Static checks for the isolated act8/newmonsters testbed."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'assets_local/act8_testbed'


class Act8TestbedDataTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.content = json.loads((OUT / 'content.json').read_text(encoding='utf-8'))
        cls.assets = json.loads((OUT / 'combat_manifest.json').read_text(encoding='utf-8'))
        cls.summary = json.loads((OUT / 'build_summary.json').read_text(encoding='utf-8'))
        cls.catalog = json.loads((GAME / 'data/monster_catalog.json').read_text(encoding='utf-8'))['monsters']

    def test_route_and_action_bindings_are_complete(self):
        self.assertEqual(self.summary['rooms'], 10)
        self.assertEqual(self.summary['mob_count'], 9)
        records = self.content['records']
        for mob_path in self.summary['route_mobs']:
            mob = records[mob_path]['decoded']
            attack_actions = mob.get('attack_actions', [])
            attack_infos = mob.get('attack_infos', [])
            self.assertTrue(attack_actions, mob_path)
            self.assertEqual(len(attack_actions), len(attack_infos), mob_path)
            for act_path, atk_path in zip(attack_actions, attack_infos):
                act = records[act_path]['decoded']
                ani_path = act.get('base_ani', '')
                self.assertTrue(ani_path.endswith('.ani'), act_path)
                self.assertIn(ani_path, records)
                if atk_path:
                    self.assertIn(atk_path, records)

    def test_catalog_keeps_original_action_order(self):
        biker = next(item for item in self.catalog.values() if item['path'].endswith('/chainbiker2.mob'))
        actions = [Path(path).stem for path in biker['actions']['attack']]
        self.assertEqual(actions, ['turning', 'dash_ready', 'dash_go', 'move', 'move_up', 'move_down'])

    def test_missing_haze_images_are_explicit_and_not_faked(self):
        self.assertEqual(self.summary['atlas_status'], 'logic_only_missing_source_image')
        self.assertEqual(len(self.summary['missing_atlas_kinds']), 9)
        for key in self.summary['missing_atlas_kinds']:
            self.assertFalse(self.assets['monsters'].get(key))
            self.assertFalse((OUT / 'combat' / f'mob_{key}.png').exists())


if __name__ == '__main__':
    unittest.main()

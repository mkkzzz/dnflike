"""Generated skill catalog must retain source names and executable-tree metadata."""
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'game_dnf/data/skill_catalog.json'
DESCRIPTIONS = ROOT / 'game_dnf/items/skill_descriptions.gd'


class SkillCatalogTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads(CATALOG.read_text(encoding='utf-8'))
        cls.skills = cls.data['skills']

    def test_all_swordman_skills_have_source_localization(self):
        self.assertEqual(self.data['schema'], 'dnf_skill_catalog/3')
        self.assertEqual(len(self.skills), 175)
        self.assertTrue(all(skill['name'] and not skill['name'].startswith('未开放') for skill in self.skills))
        for skill in self.skills:
            name = skill['localization']['name']
            if name['table']:
                self.assertEqual(name['table'], 'skill/skill.kor.str')
                self.assertIsInstance(name['line'], int)
            else:
                self.assertEqual(name['key'], '')

    def test_runtime_ids_are_unique_and_match_generated_descriptions(self):
        runtime = [skill for skill in self.skills if skill['local_id']]
        ids = [skill['local_id'] for skill in runtime]
        tree_ids = {
            int(node['id'])
            for branch in self.data['trees']['sp']
            for node in branch['nodes']
        }
        self.assertEqual(len(ids), len(self.skills))
        self.assertEqual(len(ids), 175)
        self.assertEqual(len(ids), len(set(ids)))
        text = DESCRIPTIONS.read_text(encoding='utf-8')
        for skill in runtime:
            self.assertIn('"%s"' % skill['local_id'], text)
            self.assertIn(skill['name'], text)

    def test_original_job_trees_keep_measured_coordinates(self):
        trees = {branch['source_branch']: branch for branch in self.data['trees']['sp']}
        self.assertEqual(
            {name: len(branch['nodes']) for name, branch in trees.items()},
            {'none': 17, 'weaponmaster': 34, 'soulbringer': 33, 'berserker': 29, 'asura': 33},
        )
        xs = {0, 47, 94, 141, 188, 235, 282, 329, 376, 423, 470}
        ys = {0, 67, 134, 201, 268, 335, 402, 469, 536, 603, 670}
        catalog_ids = {skill['id'] for skill in self.skills}
        for branch in trees.values():
            self.assertFalse(branch['missing_edges'])
            for node in branch['nodes']:
                self.assertIn(node['id'], catalog_ids)
                self.assertIn(node['x'], xs)
                self.assertIn(node['y'], ys)

    def test_next_skill_and_skl_prerequisites_form_tree_edges(self):
        trees = {branch['source_branch']: branch for branch in self.data['trees']['sp']}
        edges = {
            name: {(edge['from'], edge['to']) for edge in branch['edges']}
            for name, branch in trees.items()
        }
        self.assertEqual(edges['none'], set())
        self.assertTrue({(1, 3), (8, 72), (68, 72), (9, 73)} <= edges['weaponmaster'])
        self.assertTrue({(76, 24), (24, 81), (24, 79), (81, 85)} <= edges['berserker'])
        self.assertTrue({(25, 41), (41, 36), (75, 82), (82, 87)} <= edges['soulbringer'])
        self.assertTrue({(47, 2), (52, 57), (52, 62), (52, 88)} <= edges['asura'])


class SkillPanelSourceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from tools import build_dnf_skill_panel as build
        cls.build = build
        try:
            cls.source = build.B.Source(None)
        except FileNotFoundError as error:
            raise unittest.SkipTest(str(error))
        cls.manifest = json.loads((ROOT / 'game_dnf/assets_local/skill_panel/manifest.json').read_text(encoding='utf-8'))

    def test_runtime_parts_match_the_owning_original_ui_references(self):
        from PIL import Image
        parts = self.manifest['parts']
        for key in ['dim', 'title', 'sp_icon', 'detail_art', 'detail_separator', 'tree_footer']:
            with self.subTest(key=key):
                part = parts[key]
                reference = part['ui_reference']
                values = self.build.ui_control(self.source, reference['path'], reference['control'])
                self.assertEqual(values[7], part['frame'])
                self.assertEqual(values[2:4], reference['position'])
                image, _ = self.source.frame(values[5], part['frame'])
                exported = Image.open(ROOT / 'game_dnf/assets_local/skill_panel' / part['file']).convert('RGBA')
                self.assertEqual(exported.size, image.size)
                self.assertEqual(exported.tobytes(), image.convert('RGBA').tobytes())
        self.assertEqual(parts['dim']['frame'], 14)
        self.assertEqual(self.source.lib.raw(self.build.SKILL_WINDOW_UI)[1], self.manifest['source']['tree_sources'][self.build.SKILL_WINDOW_UI])
        self.assertEqual(self.source.sources['sprite/' + self.build.PANEL_BANK.lower()], self.manifest['source']['bank_sha256'])

    def test_detail_board_preserves_the_thirteen_pixel_source_top_edge(self):
        from PIL import Image
        part = self.manifest['parts']['detail_board']
        board = Image.open(ROOT / 'game_dnf/assets_local/skill_panel' / part['file']).convert('RGBA')
        top_left, _ = self.source.frame(self.build.WINDOW_BANK, 213)
        self.assertEqual(top_left.size, (12, 13))
        self.assertEqual(board.crop((0, 0, 12, 13)).tobytes(), top_left.convert('RGBA').tobytes())
        self.assertEqual(self.manifest['ui_layout']['detail_body']['size'], [179, 260])

    def test_rank_buttons_are_plus_minus_not_reset_or_lock(self):
        from PIL import Image
        for name, first in [('plus', 59), ('minus', 62)]:
            for offset, suffix in enumerate(['', '_hover', '_pressed']):
                part = self.manifest['parts'][name + suffix]
                self.assertEqual(part['frame'], first + offset)
                source, _ = self.source.frame(self.build.PANEL_BANK, first + offset)
                exported = Image.open(ROOT / 'game_dnf/assets_local/skill_panel' / part['file']).convert('RGBA')
                self.assertEqual(exported.size, (18, 18))
                self.assertEqual(exported.tobytes(), source.convert('RGBA').tobytes())


if __name__ == '__main__':
    unittest.main()

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
        body = self.manifest['ui_layout']['detail_body']
        source = self.build.ui_control_node(self.source, body['ui_path'], body['control'])
        self.assertEqual(source['values'][0], '[hyperlinklabel]')
        self.assertEqual(body['position'], source['values'][2:4])
        self.assertEqual(body['size'], source['values'][6:8])
        options = dict(child['values'] for child in source['children'] if child['tag'] == '[int option]')
        self.assertEqual(body['line_height'], options['line height'])
        self.assertEqual(body['display_marginwidth'], options['display marginwidth'])
        self.assertEqual(self.manifest['ui_layout']['popup']['body_content_size'][0],
                         body['size'][0] + options['display marginwidth'])

    def test_detail_scroll_uses_original_arrow_track_and_thumb_pixels(self):
        from PIL import Image
        part = self.manifest['parts']['detail_scroll']
        self.assertEqual(part['frames'], {
            'decrement': [16], 'decrement_highlight': [17], 'decrement_pressed': [18],
            'increment': [22], 'increment_highlight': [23], 'increment_pressed': [24],
            'scroll': [28], 'grabber': [184, 185, 186], 'grabber_highlight': [187, 188, 189],
        })
        self.assertEqual(part['thumb_caps'], [7, 7])
        self.assertEqual(part['bank'], self.build.WINDOW_BANK)
        self.assertEqual(part['ui_reference'], {'path': self.build.SKILL_EXPLAIN_UI, 'control': '4013'})
        with Image.open(ROOT / 'game_dnf/assets_local/skill_panel' / part['file']) as file:
            atlas = file.convert('RGBA')
        for state, frames in part['frames'].items():
            with self.subTest(state=state):
                x, y, w, h = part['regions'][state]
                self.assertEqual(w, 15)
                expected = Image.new('RGBA', (w, h))
                row = 0
                for index in frames:
                    image, meta = self.source.frame(part['bank'], index)
                    box = image.getbbox()
                    expected.paste(image.crop(box), (5 + meta['x'] + box[0], row + meta['y'] + box[1]))
                    row += image.height
                self.assertEqual(atlas.crop((x, y, x + w, y + h)).tobytes(), expected.tobytes())
        self.assertEqual(self.source.sources['sprite/' + part['bank'].lower()], part['bank_sha256'])

    def test_sp_digits_preserve_source_frames(self):
        from PIL import Image
        part = self.manifest['parts']['sp_digits']
        reference = part['ui_reference']
        node = self.build.ui_control_node(self.source, reference['path'], reference['control'])
        values = node['values']
        self.assertEqual((values[0], values[5], values[2:4], values[6:]),
                         ('[numberset]', part['bank'], reference['position'], reference['parameters']))
        self.assertIn({'tag': '[parent]', 'values': [reference['parent']]},
                      [{'tag': child['tag'], 'values': child['values']} for child in node['children']])
        parent = self.build.ui_control(self.source, reference['path'], reference['parent'])
        _, parent_meta = self.source.frame(parent[5], parent[7])
        self.assertEqual(part['max_digits'], values[8])
        self.assertEqual(values[10], 1)
        with Image.open(ROOT / 'game_dnf/assets_local/skill_panel' / part['file']) as exported:
            atlas = exported.convert('RGBA')
        self.assertEqual(len(part['regions']), 10)
        self.assertEqual(part['frames'], list(range(1, 11)))
        for digit, (frame, (x, y, width, height)) in enumerate(zip(part['frames'], part['regions'])):
            image, meta = self.source.frame(part['bank'], frame)
            self.assertEqual((width, height), image.size)
            self.assertEqual(atlas.crop((x, y, x + width, y + height)).tobytes(), image.convert('RGBA').tobytes())
            self.assertEqual(part['digit_advances'][digit], meta['cw'] + values[9])
            self.assertEqual(part['glyph_offsets'][digit], [meta['x'] - parent_meta['x'], meta['y'] - parent_meta['y']])
        self.assertEqual(self.source.sources['sprite/' + part['bank'].lower()], part['bank_sha256'])

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

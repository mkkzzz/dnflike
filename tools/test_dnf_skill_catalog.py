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
        self.assertEqual(len(ids), 16)
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


if __name__ == '__main__':
    unittest.main()

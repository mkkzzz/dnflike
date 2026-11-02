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
        self.assertEqual(self.data['schema'], 'dnf_skill_catalog/2')
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


if __name__ == '__main__':
    unittest.main()

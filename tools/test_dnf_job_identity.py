"""Published CHR identity evidence vs actual runtime registry and SKL columns."""
import copy
import json
import unittest
from pathlib import Path
from check_dnf_numbers import validate
ROOT=Path(__file__).resolve().parents[1]
def read(path):return json.loads((ROOT/path).read_text(encoding='utf-8'))
class JobIdentityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence=read('docs/reports/ws2/2026-11/source_job_identity.json')
        cls.numbers=read('game_dnf/data/numbers.json')
        cls.pack=read('game_dnf/assets_local/content/combat_content.json')
    def test_chr_identity_has_matching_archived_bytes(self):
        e=self.evidence
        record=self.pack['records'][e['source']['chr']['path']]
        self.assertEqual(record['source']['sha256'],e['source']['chr']['sha256'])
        self.assertEqual(record['decoded']['growtype_name_refs'],[ref for row in e['name_order'] for ref in row['references']])
        self.assertEqual([x['source_index'] for x in e['name_order']],list(range(6)))
        self.assertIsNone(e['name_order'][5]['local_id']) # archived placeholder is not a supported SP branch
    def test_runtime_and_panel_have_same_supported_identities(self):
        self.assertEqual(self.numbers['growtype_index'],self.evidence['runtime_identity'])
        panel=read('game_dnf/data/skill_catalog.json')
        self.assertEqual(set(self.numbers['growtype_index']),{b['job'] for b in panel['trees']['sp']})
        self.assertEqual(self.numbers['growtype_index']['soulbringer'],2)
        self.assertEqual(self.numbers['growtype_index']['asura'],4)
    def test_exclusive_skill_columns_agree(self):
        for job,path in [('soulbringer','ghostpowerup'),('asura','armormasteryplatewave')]:
            record=self.pack['records']['skill/swordman/'+path+'.skl']['decoded']
            caps=record['growtype_max_level']
            self.assertEqual([i for i,v in enumerate(caps) if v>0],[self.numbers['growtype_index'][job]])
            probe=self.evidence['exclusive_skill_probes'][job]
            self.assertEqual(probe['growtype_max_level'],caps)
            self.assertEqual(probe['sha256'],self.pack['records'][probe['path']]['source']['sha256'])
    def test_unknown_growth_is_not_filled_with_invented_coefficients(self):
        self.assertNotIn('soulbringer',self.numbers['growtypes'])
        self.assertNotIn('asura',self.numbers['growtypes'])
        self.assertIn('[growtype 3]',self.evidence['growth_fields_uninterpreted'])
        self.assertIn('[growtype 5]',self.evidence['growth_fields_uninterpreted'])
    def test_registry_validator_rejects_bad_columns(self):
        self.assertEqual(validate(self.numbers),[])
        for value in [True,-1,0.5,'2',0,1.0,{},None]:
            with self.subTest(value=value):
                bad=copy.deepcopy(self.numbers);bad['growtype_index']['soulbringer']=value
                self.assertTrue(validate(bad))
        bad=copy.deepcopy(self.numbers);del bad['growtype_index']['weaponmaster']
        self.assertTrue(validate(bad))
if __name__=='__main__':unittest.main()

import copy
import unittest
from check_dnf_services import load,validate
class Rules(unittest.TestCase):
    def test_baseline(self):self.assertEqual(validate(*load()),[])
    def test_reject_invalid_rules(self):
        for mutate in [lambda c:c.update(buyback_limit=0),lambda c:c.update(durability_max=-1),lambda c:c['wear'].update(weapon_hits=0),lambda c:c['items']['potion'].update(sell=-1),lambda c:c['items']['iron_sword'].update(repair_point=0),lambda c:c['items']['iron_sword'].update(disassemble={'potion':1}),lambda c:c['items']['iron_sword'].update(disassemble={'scrap_iron':-1}),lambda c:c['items'].pop('potion')]:
            cfg,catalog,gear=load();mutate(cfg)
            with self.subTest(cfg=cfg):self.assertTrue(validate(cfg,catalog,gear))
if __name__=='__main__':unittest.main()

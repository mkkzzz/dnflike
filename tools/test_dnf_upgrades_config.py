import copy
import unittest
from check_dnf_upgrades import inputs, validate


class UpgradeConfigTests(unittest.TestCase):
    def test_current_rules(self):
        self.assertEqual(validate(*inputs()), [])

    def test_reject_invalid_rules(self):
        cfg, catalog, numbers = inputs()
        variants = [
            ('chance', lambda c: c['reinforcement']['steps'][0].update(chance=101)),
            ('boolean', lambda c: c['reinforcement']['steps'][0].update(gold=True)),
            ('failure', lambda c: c['reinforcement']['steps'][0].update(failure_level=1)),
            ('not_material', lambda c: c['reinforcement']['steps'][0].update(materials={'potion': 1})),
            ('unknown_material', lambda c: c['reinforcement']['steps'][0].update(materials={'missing': 1})),
            ('negative', lambda c: c['reinforcement']['steps'][0].update(materials={'scrap_iron': -1})),
            ('overflow', lambda c: c['reinforcement'].update(steps=c['reinforcement']['steps'] * 4)),
            ('slot', lambda c: c['reinforcement']['bonuses'].update(missing={'strength': 1})),
            ('stat', lambda c: c['reinforcement']['bonuses']['coat'].update(missing=1)),
            ('enchant_slot', lambda c: c['enchants']['strength'].update(slots=['missing'])),
            ('enchant_mod', lambda c: c['enchants']['strength'].update(modifier={'stat': 'strength', 'op': 'mul', 'value': 2})),
            ('malformed', lambda c: c.update(enchants=[])),
        ]
        for label, change in variants:
            with self.subTest(label=label):
                bad = copy.deepcopy(cfg)
                change(bad)
                self.assertTrue(validate(bad, catalog, numbers))


if __name__ == '__main__':
    unittest.main()

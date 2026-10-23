import copy
import unittest
from check_dnf_recovery import inputs, validate


class RecoveryConfigTests(unittest.TestCase):
    def test_current(self):
        self.assertEqual(validate(*inputs()), [])

    def test_reject_bad_contracts(self):
        cfg, catalog = inputs()
        variants = [
            ('clock', lambda c: c['consumables']['potion'].update(cooldown_ms=-1)),
            ('group_clock', lambda c: c['consumables']['potion'].update(group_cooldown_ms=True)),
            ('group', lambda c: c['consumables']['potion'].update(group='')),
            ('level', lambda c: c['consumables']['potion'].update(level=0)),
            ('effect', lambda c: c['consumables']['potion'].update(effect={'kind': 'heal', 'amount': -1})),
            ('effect_kind', lambda c: c['consumables']['potion'].update(effect={'kind': 'missing', 'amount': 1})),
            ('catalog', lambda c: c['consumables'].update(iron_sword=c['consumables']['potion'])),
            ('fee', lambda c: c['revival'].update(gold=-1)),
            ('limit', lambda c: c['revival'].update(limit=101)),
            ('hp', lambda c: c['revival'].update(hp_percent=0)),
            ('mp', lambda c: c['revival'].update(mp_percent=101)),
            ('invuln', lambda c: c['revival'].update(invulnerable_ms=30001)),
            ('object', lambda c: c.update(revival=[])),
        ]
        for label, change in variants:
            with self.subTest(label=label):
                bad = copy.deepcopy(cfg)
                change(bad)
                self.assertTrue(validate(bad, catalog))


if __name__ == '__main__':
    unittest.main()

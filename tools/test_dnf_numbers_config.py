"""Configuration mistakes must be rejected before opening or changing a character save."""
import json
import unittest

from check_dnf_numbers import DEFAULT, validate


class NumericConfigTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(DEFAULT.read_text(encoding='utf-8'))

    def test_current_config_is_executable(self):
        self.assertEqual(validate(self.data), [])

    def test_zero_denominator_is_rejected(self):
        self.data['formula']['main_stat_divisor'] = 0
        self.assertTrue(validate(self.data))

    def test_missing_required_stat_is_rejected(self):
        del self.data['base']['independent_attack']
        self.assertTrue(validate(self.data))

    def test_negative_xp_requirement_is_rejected(self):
        self.data['progression']['xp_per_level'][0] = -1
        self.assertTrue(validate(self.data))

    def test_unknown_effect_stat_is_rejected(self):
        self.data['effects']['strength_potion']['modifiers'][0]['stat'] = 'strenght'
        self.assertTrue(validate(self.data))

    def test_invalid_slot_is_rejected(self):
        self.data['equipment']['iron_sword']['slot'] = 'unknown'
        self.assertTrue(validate(self.data))

    def test_unknown_on_hit_effect_is_rejected(self):
        self.data['skills']['rage_slash']['on_hit'][0]['id'] = 'unknown'
        self.assertTrue(validate(self.data))

    def test_finite_only(self):
        self.data['base']['strength'] = float('nan')
        self.assertTrue(validate(self.data))

    def test_reversed_hit_bounds_are_rejected(self):
        self.data['formula'].update(hit_min=0.9, hit_max=0.1)
        self.assertTrue(validate(self.data))


if __name__ == '__main__':
    unittest.main()

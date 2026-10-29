"""Reward grammar checks need neither a PVF installation nor runtime assets."""
import unittest

from build_dnf_progression_data import reward_rows, clean


class RewardGrammar(unittest.TestCase):
    def test_source_comments_do_not_leak_into_player_body(self):
        self.assertEqual(clean('前往洛伦\\n\n//091216 ???\n  // source note'), '前往洛兰')

    def test_dialogue_paragraphs_are_preserved(self):
        self.assertEqual(clean('第一段\r\n\r\n第二段'), '第一段\n\n第二段')

    def test_fixed_gold_and_duplicate_items(self):
        self.assertEqual(reward_rows([0, 50, 1106, 2, 1106, 3]),
                         (50, {'original_1106': 5}, []))

    def test_class_branches_do_not_become_unconditional(self):
        gold, items, branches = reward_rows([27800, '[job]', 0, -1, 1, 24116, 1])
        self.assertEqual((gold, items), (0, {'original_24116': 1}))
        self.assertEqual(branches, [{'item': 'original_27800', 'amount': 1,
                                    'jobs': [0], 'grow_types': [-1]}])

    def test_malformed_and_unsupported_rows_fail(self):
        for values in ([1106], [1106, 0], [1106, 1.5], [-1, 1],
                       [1106, '[job]', 0, -1], [0, '[job]', 0, -1, 1],
                       [1106, '[unknown]', 0, -1, 1], [True, 1]):
            with self.subTest(values=values), self.assertRaises(ValueError):
                reward_rows(values)

    def test_empty_reward_is_valid(self):
        self.assertEqual(reward_rows([]), (0, {}, []))


if __name__ == '__main__':
    unittest.main()

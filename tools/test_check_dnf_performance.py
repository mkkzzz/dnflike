"""Mutation fixtures prove that the performance guard rejects former bugs."""
import tempfile
import unittest
from pathlib import Path

from check_dnf_performance import check


class PerformanceGuardTest(unittest.TestCase):
    def inspect(self, source, path='ui/flow/panel.gd'):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            file = root / path
            file.parent.mkdir(parents=True)
            file.write_text(source, encoding='utf-8')
            return check(root)

    def test_previous_direct_and_nested_reads_fail(self):
        for expression in ['Numbers.config()', 'game.session.Numbers . config ()']:
            with self.subTest(expression=expression):
                self.assertEqual(len(self.inspect('func draw():\n\tvar cfg = '+expression)), 1)

    def test_preload_alias_is_not_an_escape(self):
        source = 'const Stats := preload("res://stats/api/numbers.gd")\nfunc draw():\n\tStats.config()'
        self.assertEqual(len(self.inspect(source)), 1)

    def test_internal_reader_cannot_use_old_copy_api(self):
        self.assertEqual(len(self.inspect('func valid():\n\tvar cfg = config()', 'stats/api/numbers.gd')), 1)

    def test_explicit_snapshot_and_inline_copy_fail_at_runtime(self):
        for expression in ['Numbers.config_snapshot()', 'Numbers.shared_config().duplicate(true)']:
            self.assertEqual(len(self.inspect('func draw():\n\t'+expression)), 1)

    def test_shared_reads_and_small_owned_copies_pass(self):
        self.assertEqual(self.inspect('func draw():\n\tNumbers.shared_config()\n\tprofile.duplicate(true)\n\tServices.config()'), [])

    def test_snapshot_implementation_and_test_consumers_pass(self):
        self.assertEqual(self.inspect('static func config_snapshot():\n\treturn shared_config().duplicate(true)', 'stats/api/numbers.gd'), [])
        self.assertEqual(self.inspect('var cfg = Numbers.config_snapshot()', 'tests/stats/test.gd'), [])

    def test_comments_and_string_examples_are_not_code(self):
        source = '# Numbers.config()\nvar tip="Numbers.config_snapshot()"\nvar example="""\nNumbers.config()\n"""'
        self.assertEqual(self.inspect(source), [])

    def test_skill_click_cannot_rebuild_window(self):
        for function in ['select_skill', 'change', '_refresh_progress']:
            self.assertEqual(len(self.inspect(f'func {function}():\n\tgame.show_overlay("numbers")', 'ui/flow/skill_panel.gd')), 1)
        self.assertEqual(self.inspect('func job_change():\n\tgame.show_overlay("numbers")', 'ui/flow/skill_panel.gd'), [])


if __name__ == '__main__':
    unittest.main()

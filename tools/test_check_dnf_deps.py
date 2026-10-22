"""Unit tests for tools/check_dnf_deps.py using a throwaway project tree."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from check_dnf_deps import check


def tree(files: dict[str, str]) -> Path:
    root = Path(tempfile.mkdtemp())
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')
    return root


class DepsTest(unittest.TestCase):
    def test_kernel_downward_api_dependency_passes(self):
        root = tree({'combat/world/w.gd': 'const C = preload("res://content/api/content_db.gd")\n'
                                          'const B = preload("res://core/box6.gd")\n'})
        self.assertEqual(check(root), [])

    def test_kernel_upward_dependency_fails(self):
        root = tree({'combat/world/w.gd': 'const V = preload("res://view/fx.gd")\n',
                     'core/a.gd': 'const C = preload("res://combat/api/x.gd")\n'})
        problems = check(root)
        self.assertEqual(len(problems), 2)
        self.assertTrue(all('lower kernel' in p for p in problems))

    def test_bypassing_kernel_api_fails_from_any_module(self):
        root = tree({'view/fx.gd': 'const W = preload("res://combat/world/world.gd")\n',
                     'flow/root.gd': 'const D = preload("res://content/db.gd")\n'})
        problems = check(root)
        self.assertEqual(len(problems), 2)
        self.assertTrue(all('bypasses' in p for p in problems))

    def test_kernel_legacy_reach_fails_except_bridge(self):
        root = tree({'combat/world/w.gd': 'const M = preload("res://scripts/main.gd")\n',
                     'combat/api/combat_session.gd': 'const SCENE := "res://scenes/main.tscn"\n'})
        problems = check(root)
        self.assertEqual(len(problems), 1)
        self.assertIn('legacy scripts/', problems[0])

    def test_modules_above_kernel_organise_freely(self):
        root = tree({'flow/root.gd': 'const S = preload("res://save/store.gd")\n'
                                     'const U = preload("res://ui/flow/skin.gd")\n'
                                     'extends "res://scripts/main.gd"\n',
                     'town/t.gd': 'const A = preload("res://scripts/native_actor.gd")\n'})
        self.assertEqual(check(root), [])

    def test_exempt_sources_and_comments(self):
        root = tree({'debug/t.gd': 'const W = preload("res://combat/world/world.gd")\n',
                     'core/a.gd': '# see res://view/api/x.gd\n'})
        self.assertEqual(check(root), [])


if __name__ == '__main__':
    unittest.main()

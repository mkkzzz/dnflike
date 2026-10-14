#!/usr/bin/env python3
"""Offline acceptance for V6 delivered assets; no Godot build or game modifications."""
from __future__ import annotations

import json
import unittest

import numpy as np
from PIL import Image

from bake_seq_v6 import OUT, encode_light, straight_pm, validate
from preview_v6 import render


class SequenceV6Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((OUT / 'manifest.json').read_text(encoding='utf-8'))

    def test_complete_unfrozen_moves(self):
        self.assertFalse(self.manifest['hitstop_baked'])
        self.assertTrue(self.manifest['actor_includes_weapon'])
        for name, length in (('attack1', 30), ('attack2', 32), ('attack3', 41), ('quick_draw', 36)):
            for prefix in ('actor', 'slash_back', 'slash_front'):
                clip = self.manifest['clips'][f'{prefix}/{name}']
                self.assertEqual(clip['duration_ticks'], length)
                self.assertEqual(clip['clock'], 'action')
                self.assertEqual(clip['start_tick'], 0)

    def test_alpha_add_preserves_low_light(self):
        light = np.array([[[0.08, 0.13, 0.20], [0, 0, 0]]], np.float32)
        pixels = np.asarray(encode_light(light), np.float32) / 255
        recovered = pixels[..., :3] * pixels[..., 3:]
        np.testing.assert_allclose(recovered, light, atol=0.002)

    def test_normal_has_no_double_alpha(self):
        pm = np.array([[[0.12, 0.08, 0.04, 0.2]]], np.float32)
        pixels = np.asarray(straight_pm(pm), np.float32) / 255
        np.testing.assert_allclose(pixels[..., :3] * pixels[..., 3:], pm[..., :3], atol=0.002)

    def test_landmarks_stay_on_the_painted_weapon(self):
        seen = set()
        for name, clip in self.manifest['clips'].items():
            if not name.startswith('actor/'):
                continue
            for frame in clip['frames']:
                if frame['file'] in seen:
                    continue
                seen.add(frame['file'])
                alpha = np.asarray(Image.open(OUT / frame['file']))[..., 3]
                for key in ('grip', 'guard', 'tip'):
                    point = np.round(np.array(frame[key]) + clip['anchor']).astype(int)
                    x, y = point
                    patch = alpha[max(0, y - 4):y + 5, max(0, x - 4):x + 5]
                    self.assertTrue(patch.size and patch.max() > 64, f'{frame["file"]} {key} misses painted pixels')

    def test_all_assets_bounds_and_timelines(self):
        self.assertTrue(validate(self.manifest)['passed'])

    def test_real_contact_and_exactly_one_hitstop(self):
        for names in (['attack1', 'attack2', 'attack3'], ['quick_draw']):
            hit_frames, _, hits = render(names, self.manifest, naked=False)
            dry_frames, _, _ = render(names, self.manifest, naked=True)
            self.assertEqual({h['move'] for h in hits}, set(names))
            self.assertEqual(len(hit_frames) - len(dry_frames), sum(h['freeze_ticks'] for h in hits))
            for hit in hits:
                point, guard, tip = (np.array(hit[k]) for k in ('contact', 'guard', 'tip'))
                delta = tip - guard
                k = np.dot(point - guard, delta) / np.dot(delta, delta)
                self.assertGreaterEqual(k, -0.001)
                self.assertLessEqual(k, 1.001)
                self.assertLess(np.linalg.norm(point - (guard + delta * k)), 0.03)
                a, b = self.manifest['moves'][hit['move']]['active']
                self.assertTrue(a <= hit['action_tick'] < b)


if __name__ == '__main__':
    unittest.main(verbosity=2)

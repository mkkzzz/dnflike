"""Checkpoint and cutting-side regressions; these do not approve animation art."""
import json
import unittest
from pathlib import Path
from explore.swordsman_layer_trial import cutting_edge_basis, sha
from explore.swordsman_base_batch import prepare_group

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT/'art/animations/players/swordsman/v7/exports/base_batch_c4'

def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


class BaseBatchCheckpointTests(unittest.TestCase):
    def marks(self):
        return {'guard': [0, 0], 'tip': [10, 0], 'cutting_edge': [5, 2], 'spine': [5, -2]}

    def test_reversed_texture_side_flips_only_transverse_axis(self):
        basis, review = cutting_edge_basis(([.6, 0], [0, -1]), self.marks(), [0, 1])
        self.assertEqual(basis, ([.6, 0], [0, 1]))
        self.assertTrue(review['transverse_axis_reflected'])
        self.assertEqual(review['cutting_alignment'], 1)

    def test_opposite_texture_cutting_side_is_bound(self):
        marks = self.marks()
        marks['cutting_edge'], marks['spine'] = marks['spine'], marks['cutting_edge']
        basis, review = cutting_edge_basis(([1, 0], [0, 1]), marks, [0, 1])
        self.assertEqual(basis, ([1, 0], [0, -1]))
        self.assertEqual(review['texture_cutting_side'], -1)

    def test_missing_actual_edge_or_ambiguous_direction_is_rejected(self):
        marks = self.marks()
        del marks['spine']
        with self.assertRaisesRegex(ValueError, 'landmarks'):
            cutting_edge_basis(([1, 0], [0, 1]), marks, [0, 1])
        with self.assertRaisesRegex(ValueError, 'ambiguous'):
            cutting_edge_basis(([1, 0], [0, 1]), self.marks(), [1, 0])

    def test_index_matches_actual_subpackages_and_keeps_integration_closed(self):
        index = read(PACKAGE/'manifest.json')
        actual = {p.parent.name for p in PACKAGE.glob('*/manifest.json')}
        self.assertEqual(set(index['clips']), actual)
        self.assertTrue(index['checkpoint_only'])
        self.assertFalse(index['complete'])
        self.assertFalse(index['integration_allowed'])
        for name, entry in index['clips'].items():
            path = PACKAGE/entry['manifest']
            m = read(path)
            self.assertEqual(entry['manifest_sha256'], sha(path))
            self.assertEqual(m['canvas'], [1024, 1080])
            self.assertEqual(m['anchor'], [448, 840])
            self.assertFalse(m['artwork_approved'])
            self.assertFalse(m['integration_allowed'])
            self.assertEqual(sum(f['duration_ticks'] for f in m['frames']), m['duration_ticks'])
            for frame in m['frames']:
                self.assertEqual(set(frame['profiles']), {'katana', 'greatsword', 'shortsword'})
                for profile in frame['profiles'].values():
                    self.assertGreaterEqual(profile['edge_review']['cutting_alignment'], .2)
                    self.assertLessEqual(profile['source_sampling_scale'], 1)
                    edge, spine = profile['cutting_edge'], profile['spine']
                    normal = profile['edge_review']['authored_cutting_direction']
                    self.assertGreater(sum((a-b)*n for a, b, n in zip(edge, spine, normal)), 0)

    def test_pending_source_annotations_cannot_export(self):
        for group in ['hit', 'death']:
            with self.subTest(group=group), self.assertRaisesRegex(ValueError, 'Review the true jaw/hair'):
                prepare_group(group)

    def test_idle_reuse_does_not_claim_four_unique_drawings(self):
        m = read(PACKAGE/'idle/manifest.json')
        self.assertEqual(len(m['frames']), 4)
        self.assertEqual(len({f['source_pose'] for f in m['frames']}), 3)
        self.assertEqual(m['frames'][0]['source_pose'], m['frames'][2]['source_pose'])
        self.assertEqual(m['frames'][0]['body_sha256'], m['frames'][2]['body_sha256'])


if __name__ == '__main__':
    unittest.main()

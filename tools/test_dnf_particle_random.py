"""Source binding for the native random arithmetic fixture (no client required)."""
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeRandomEvidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.matrix = json.loads((ROOT/'game_dnf/tests/fixtures/native_particle_random.json').read_text(encoding='utf8'))

    def test_verified_function_and_evaluator_are_pinned(self):
        matrix = self.matrix
        self.assertEqual(matrix['engine_sha256'],'187ad34ab6bfff040d9b12bb145bdda0bba29f82aaa41183280b0ae42e914b84')
        self.assertEqual(matrix['function_sha256'],'9542000f45d4ebbe85cb84a2cf4fe9880d581b422df545d0d8c2b81d139745c3')
        source = b''.join((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')
                          for name in ['audit_dnf_particle_random.py','audit_dnf_particle_axis.py'])
        self.assertEqual(matrix['evaluator_sha256'],hashlib.sha256(source).hexdigest())

    def test_clock_and_pointer_branches_have_matching_sequence_coverage(self):
        rows = self.matrix['cases']
        self.assertEqual(len(rows),50)
        for begin in range(0,50,5):
            group = rows[begin:begin+5]
            self.assertEqual([r['clock'] for r in group],[0,1,1000,0xffffffff,42])
            for previous,current in zip(group,group[1:]):self.assertEqual(previous['state'],current['seed'])
            for row in group:
                self.assertEqual(row['global_form'],begin>=25)
                self.assertTrue(0<=row['value']<=0x7fffffff)
                self.assertTrue(0<=row['state']<=0xffffffff)
                self.assertEqual(len(row['trace_sha256']),64)
        self.assertEqual(rows[0]['value'],rows[25]['value'])  # zero clock adds nothing
        self.assertNotEqual(rows[1]['value'],rows[26]['value'])  # subsequent clock changes the stream

    def test_original_local_seed_zero_sequence(self):
        self.assertEqual([r['value'] for r in self.matrix['cases'][:5]],
                         [1012484,1716955679,1792309082,229610924,1639479903])


if __name__=='__main__':unittest.main()

"""Validate the archived native arithmetic matrix without requiring a client PE.

The actual GDScript comparisons run in the formal loop's headless motion test.
Regenerate the matrix with audit_dnf_particle_axis.py and the pinned client.
"""
import hashlib
import json
from pathlib import Path
import unittest

from audit_dnf_particle_axis import cases, bits, real, signed

ROOT = Path(__file__).resolve().parents[1]


class NativeAxisEvidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.matrix = json.loads((ROOT/'game_dnf/tests/fixtures/native_particle_axis.json').read_text(encoding='utf8'))

    def test_matrix_is_bound_to_native_function_and_evaluator(self):
        matrix = self.matrix
        self.assertEqual(matrix['engine_sha256'],'187ad34ab6bfff040d9b12bb145bdda0bba29f82aaa41183280b0ae42e914b84')
        self.assertEqual(matrix['function_sha256'],'3da27e4b3fb4b3568ff860e334d1d3df94406018a885432ff64048e131402880')
        tool = (ROOT/'tools/audit_dnf_particle_axis.py').read_bytes().replace(b'\r\n',b'\n')
        self.assertEqual(matrix['evaluator_sha256'],hashlib.sha256(tool).hexdigest())
        self.assertEqual([row['input'] for row in matrix['cases']],cases())
        for row in matrix['cases']:
            self.assertEqual(row['bits'],f"{bits(row['value']):08x}")
            self.assertGreater(row['steps'],10)
            self.assertLess(row['steps'],1000)
            self.assertEqual(len(row['trace_sha256']),64)

    def test_original_branch_observations_cover_both_legs_and_term_zero(self):
        branches = {address:set() for address in ['0xe4f2f3','0xe4f342','0xe4f46e','0xe4f4d7','0xe4f5bf','0xe4f74f']}
        for row in self.matrix['cases']:
            for address,taken in row['branches']:
                if address in branches:branches[address].add(taken)
            if row['input']['move']==0:self.assertEqual(row['value'],0.0)
        for address,seen in branches.items():self.assertEqual(seen,{True,False},address)

    def test_integer_wrap_is_distinct_from_unbounded_speed_times_time(self):
        row = self.matrix['cases'][-1]
        self.assertEqual(signed(50000*100000),705032704)
        self.assertEqual(row['value'],real(bits(real(bits(705032704.0))*real(bits(0.001)))))
        self.assertNotAlmostEqual(row['value'],5000000.0)


if __name__ == '__main__':
    unittest.main()

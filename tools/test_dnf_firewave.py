"""Archived firewave source proof; optional live replay and source mutation."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_firewave import replay, verify
from audit_dnf_native_strings import ENGINE_SHA

p = argparse.ArgumentParser(add_help=False)
p.add_argument('--client', type=Path); p.add_argument('--decoder-dir', type=Path)
args, remaining = p.parse_known_args()
if args.decoder_dir: sys.path.insert(0, str(args.decoder_dir.resolve()))
ROOT = Path(__file__).resolve().parents[1]


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e = json.loads((ROOT/'docs/reports/ws2/2026-11/native_firewave.json').read_text(encoding='utf8'))

    def test_source_identity_and_tools(self):
        self.assertEqual(self.e['engine_sha256'], ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'], '8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name, digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)
        self.assertEqual(self.e['factory'], [dict(id=20024,index=17,case='0xa1f610'),dict(id=20025,index=18,case='0xa1f64c')])

    def test_boundary_matrix(self):
        self.assertEqual(len(self.e['runs']),38)
        for row in self.e['runs']: verify(row)
        for a, b in zip(self.e['runs'][::2],self.e['runs'][1::2]):
            # Volatile values at entry to cdecl services are not semantic inputs.
            meaningful=lambda row:[{k:v for k,v in e.items() if k!='this' or e['kind']!='cast_fixture'} for e in row['events']]
            self.assertEqual(meaningful(a),meaningful(b))

    def test_end_bit_and_two_damage_columns_are_executed(self):
        lines=[line for b in self.e['blocks'] for line in b['instructions']]
        self.assertIn('00A66133 test byte ptr [eax + 0x1ec], 8',lines)
        self.assertIn('00A66148 call eax',lines)
        self.assertEqual({e['args'][0] for r in self.e['runs'] for e in r['events'] if e['kind']=='fixed_resolver_fixture'},{0,1})

    def test_old_single_object_assumption_is_rejected(self):
        row=copy.deepcopy(next(r for r in self.e['runs'] if any(e['kind']=='spawn_fixture' for e in r['events'])))
        next(e for e in row['events'] if e['kind']=='spawn_fixture')['args'][3]+=1
        with self.assertRaisesRegex(ValueError,'position'):verify(row)


@unittest.skipUnless(args.client,'optional original source replay')
class Live(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from audit_dnf_particle_axis import AxisEvaluator
        cls.s=AxisEvaluator(args.client.read_bytes())

    def test_end_flag_mutation_prevents_actual_delete(self):
        original,_=replay(self.s,object_id=20025,phase='update',ended=True)
        verify(original)
        changed=copy.copy(self.s);raw=bytearray(changed.raw)
        pc=0xA66133
        i=next(changed.decoder.disasm(changed.source_bytes(pc,15),pc,count=1))
        self.assertEqual(i.operands[-1].imm,8)
        section=next(s for s in changed.sections if s['rva']<=pc-0x400000<s['rva']+s['bytes'])
        raw[section['offset']+pc-0x400000-section['rva']+i.size-1]=4
        changed.raw=bytes(raw)
        row,_=replay(changed,object_id=20025,phase='update',ended=True)
        self.assertFalse(any(e['kind']=='delete_fixture' for e in row['events']))
        with self.assertRaisesRegex(ValueError,'removal'):verify(row)

    def test_fixed_result_flows_through_source_conversion(self):
        for object_id in (20024,20025):
            for value in (1170,2257,-9):
                row,_=replay(self.s,object_id=object_id,skill_value=value,poison=True)
                verify(row)
                self.assertEqual(next(e['value'] for e in row['events'] if e['kind']=='secure_float_write_fixture'),float(value))


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

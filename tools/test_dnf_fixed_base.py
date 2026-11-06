"""Fixed-attack base service evidence and optional original-byte mutations."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

from audit_dnf_fixed_base import replay, verify, OWNER
from audit_dnf_native_strings import ENGINE_SHA

p=argparse.ArgumentParser(add_help=False)
p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]


class Archive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e=json.loads((ROOT/'docs/reports/ws2/2026-11/native_fixed_base.json').read_text(encoding='utf8'))

    def test_identity_and_source_tools(self):
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'],'8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        self.assertEqual(self.e['owner_vtable_slot'],{'address':'0x16f9b6c','raw':'9073d000'})
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)

    def test_all_routes_and_caller_saved_registers(self):
        runs=self.e['runs'];self.assertEqual(len(runs),58)
        for r in runs:verify(r)
        for a,b in zip(runs[::2],runs[1::2]):
            self.assertEqual(a['value'],b['value'])
            self.assertEqual([{k:v for k,v in e.items() if k!='this'} for e in a['events']],
                             [{k:v for k,v in e.items() if k!='this'} for e in b['events']])
        self.assertEqual(runs[0]['value'],1541)
        self.assertEqual(runs[-2]['value'],-77)

    def test_level_boundary_and_unused_input(self):
        runs=self.e['runs']
        valid=next(r for r in runs if r['fixture']['level']==100 and r['fixture']['count']==101)
        excluded=next(r for r in runs if r['fixture']['level']==100 and r['fixture']['count']==100)
        self.assertNotEqual(valid['value'],0);self.assertEqual(excluded['value'],0)
        self.assertEqual(next(r['value'] for r in runs if r['fixture']['unused_parameter']==123456),runs[0]['value'])
        self.assertEqual(next(r['value'] for r in runs if r['fixture']['owner_fallback']),runs[0]['value'])
        zero=next(r for r in runs if r['fixture']['level']==0)
        self.assertEqual(sum(e['kind']=='diagnostic_fixture' for e in zero['events']),1)

    def test_mode_selectors_and_distinct_info_kind(self):
        runs=self.e['runs']
        selected=[r for r in runs if r['fixture']['table_mode']!=r['fixture']['mode']]
        self.assertEqual(len(selected),4)
        special=next(r for r in runs if r['fixture']['mode']==4 and r['fixture']['info_kind']==2)
        queries=[e['argument'] for e in special['events'] if e['kind']=='native_owner_info']
        self.assertEqual(queries,[3,2,3,2])
        reads={e['this'] for e in special['events'] if e['kind']=='secure_read'}
        self.assertIn(hex(OWNER+0x8AC+2*0x8D0+0x888),reads)
        self.assertIn(hex(OWNER+0x8AC+3*0x8D0+0x8A0),reads)
        self.assertIn(hex(OWNER+0x8AC+2*0x8D0+0x8AC),reads)

    def test_source_operations_and_non_equivalent_simplification(self):
        lines=[line for block in self.e['blocks'] for line in block['instructions']]
        for line in ('0075EC49 jae 0x75ebee','0075ECA0 dec edi','0042CDC9 add ebx, dword ptr [ebp + 8]',
                     '013CD6A5 cvttsd2si eax, qword ptr [esp]','00D07396 imul eax, eax, 0x8d0'):
            self.assertIn(line,lines)
        changed=copy.deepcopy(self.e['runs'][0]);changed['value']=1217
        with self.assertRaisesRegex(ValueError,'arithmetic'):verify(changed)


@unittest.skipUnless(args.client,'optional original-source replay')
class Live(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from audit_dnf_particle_axis import AxisEvaluator
        cls.s=AxisEvaluator(args.client.read_bytes())

    def changed(self,address,expected,replacement):
        self.assertEqual(self.s.source_bytes(address,len(expected)),expected)
        source=copy.copy(self.s);data=bytearray(source.raw)
        sec=next(s for s in source.sections if s['rva']<=address-0x400000<s['rva']+s['bytes'])
        offset=sec['offset']+address-0x400000-sec['rva'];data[offset:offset+len(replacement)]=replacement
        source.raw=bytes(data);return source

    def test_strict_level_limit_mutation(self):
        original,_=replay(self.s,level=101);self.assertEqual(original['value'],0)
        source=self.changed(0x75EC49,b'\x73',b'\x77')
        changed,_=replay(source,level=101);self.assertNotEqual(changed['value'],0)
        with self.assertRaisesRegex(ValueError,'arithmetic'):verify(changed)

    def test_final_addition_mutation(self):
        source=self.changed(0x42CDC9,b'\x03',b'\x2b')
        changed,_=replay(source);self.assertEqual(changed['value'],1525)
        with self.assertRaisesRegex(ValueError,'arithmetic'):verify(changed)

    def test_special_multiplier_info_kind_mutation(self):
        source=self.changed(0x75EDA3,b'\x03',b'\x02')
        original,_=replay(self.s,mode=4,table_mode=4,info_kind=2);verify(original)
        changed,_=replay(source,mode=4,table_mode=4,info_kind=2)
        self.assertNotEqual(changed['value'],original['value'])
        with self.assertRaisesRegex(ValueError,'arithmetic'):verify(changed)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

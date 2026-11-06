"""Original linked-skill modifier arithmetic and selection regressions."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

from audit_dnf_skill_modifier import replay,verify,fbits
from audit_dnf_native_strings import ENGINE_SHA

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]


class Archive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads((ROOT/'docs/reports/ws2/2026-11/native_skill_modifier.json').read_text(encoding='utf8'))

    def test_source_tools_and_constant(self):
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'],'8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)
        self.assertEqual(self.e['constant'],{'address':'0x1559c80','raw':'0ad7233c'})
        self.assertEqual(self.e['owner_lookup'],{'vtable':'0x16f972c','slot':'0x804','target':'0x8406c0'})

    def test_matrix_and_abi_poison(self):
        rows=self.e['runs'];self.assertEqual(len(rows),84)
        for row in rows:verify(row)
        for a,b in zip(rows[::2],rows[1::2]):
            self.assertFalse(a['fixture']['poison']);self.assertTrue(b['fixture']['poison'])
            for key in ('bits','events','preserved','stack','percent_bits'):self.assertEqual(a[key],b[key])

    def test_phase_filters(self):
        # Same add/sub/percentage records, rank 3: phase 0=percentage only,
        # phase 1=add/sub only, phase 2=both in record order, phase 3=neither.
        rows=self.e['runs'][0:8:2]
        self.assertEqual([r['fixture']['phase'] for r in rows],[0,1,2,3])
        self.assertEqual([r['bits'] for r in rows],[fbits(v) for v in (115,103,118.45,100)])

    def test_lookup_gates_and_fallback(self):
        for row in self.e['runs']:
            f=row['fixture']
            if f['rank']<=0 or f['mode'] in (4,5,9) or f['skill_mode'] in (4,5) or f['linked_id']==-1 or not f['found'] or not(f['owner_arg'] or f['fallback_owner']):
                self.assertEqual(row['bits'],fbits(f['value']))
        fallback=next(r for r in self.e['runs'] if not r['fixture']['owner_arg'] and r['fixture']['fallback_owner'])
        self.assertEqual(fallback['bits'],fbits(118.45))

    def test_record_order_and_binary32_store(self):
        rows=self.e['runs']
        before=next(r for r in rows if len(r['fixture']['records'])==4)
        after=next(r for r in rows if r['fixture']['records']==[[1,0,2,5],[1,0,0,3]])
        self.assertEqual(before['bits'],fbits(125.35));self.assertEqual(after['bits'],fbits(124))
        rounded=next(r for r in rows if r['fixture']['value']==16777216)
        self.assertEqual(rounded['bits'],fbits(16777216));self.assertNotEqual(rounded['bits'],fbits(16777218))
        # Two separate calls in phases 1 then 0 cannot generally be replaced
        # with phase 2, even before considering the interposed 907D40 service.
        first,second=rows[-4],rows[-2]
        self.assertEqual(first['value'],second['fixture']['value'])
        self.assertEqual(second['bits'],fbits(125.35));self.assertNotEqual(second['bits'],after['bits'])

    def test_original_entries_and_initialization_write(self):
        lines=[line for block in self.e['blocks'] for line in block['instructions']]
        for line in ('00906250 push ebp','009064B2 add dword ptr [ebp + 8], 0x28',
                     '009063DC subss xmm1, xmm0','014F1E8D movss xmm0, dword ptr [0x1559c80]',
                     '00905E50 jle 0x905e77','004F9A29 lea ecx, [ecx + eax*4 + 0x590]'):
            self.assertIn(line,lines)
        for row in self.e['runs']:
            writes=[e for e in row['events'] if e['kind']=='secure_write_fixture']
            self.assertEqual(writes,[{'target':'0x1195a10','kind':'secure_write_fixture','this':'0x1a5ffa4','bits':fbits(.01)}])


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

    def test_original_cases_reproduce_archive(self):
        archived=json.loads((ROOT/'docs/reports/ws2/2026-11/native_skill_modifier.json').read_text(encoding='utf8'))
        for expected in archived['runs']:
            actual,_=replay(self.s,**expected['fixture']);verify(actual)
            self.assertEqual(json.loads(json.dumps(actual)),expected)

    def test_subtraction_changed_to_addition(self):
        row,_=replay(self.changed(0x9063DE,b'\x5c',b'\x58'))
        with self.assertRaisesRegex(ValueError,'arithmetic'):verify(row)

    def test_wrong_additive_phase(self):
        row,_=replay(self.changed(0x9062E9,b'\x01',b'\x00'),phase=0)
        with self.assertRaisesRegex(ValueError,'arithmetic'):verify(row)

    def test_zero_rank_wrongly_selected(self):
        row,_=replay(self.changed(0x905E50,b'\x7e',b'\x7c'),rank=0)
        with self.assertRaisesRegex(ValueError,'selection'):verify(row)

    def test_wrong_percent_source(self):
        row,_=replay(self.changed(0x1559C80,fbits(.01).to_bytes(4,'little'),fbits(.1).to_bytes(4,'little')))
        with self.assertRaisesRegex(ValueError,'initialization'):verify(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

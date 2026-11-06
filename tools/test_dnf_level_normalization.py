"""Native normalization evidence, tree miss cases and original-byte mutations."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

from audit_dnf_level_normalization import replay, verify, table_value
from audit_dnf_native_strings import ENGINE_SHA, recover_string

p=argparse.ArgumentParser(add_help=False)
p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]


class Archive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e=json.loads((ROOT/'docs/reports/ws2/2026-11/native_level_normalization.json').read_text(encoding='utf8'))

    def test_identity_and_tools(self):
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'],'8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)

    def test_dispatch_provenance(self):
        self.assertEqual([(x['mode'],x['scale'],x['map']) for x in self.e['vtable_slots']],
                         [(0,'0x759c30','0xe49010'),(1,'0x759c30','0xe49010'),
                          (2,'0x759c30','0xe49010'),(3,'0x42c7d0','0x42c780')])
        labels=self.e['diagnostic_labels']
        self.assertEqual([x['text'] for x in labels],['CNTownModule::Proc','CNMainGameModule::Proc'])
        for x in labels:
            raw=bytes.fromhex(x['raw']);self.assertEqual(recover_string(raw,0,2)[0],x['text'])
            self.assertEqual(hashlib.sha256(raw).hexdigest(),x['sha256'])
        lines=[line for b in self.e['static_provenance'] for line in b['instructions']]
        for line in ('0075B70E call 0x1102a70','0075B71F mov dword ptr [esi + 0xb4], eax',
                     '01102AAB mov dword ptr [esi], 0x1829e54','01102F3F push 0x1829efc',
                     '00759BAB mov dword ptr [esi], 0x15b105c','0110B966 push 0x182a858'):
            self.assertIn(line,lines)

    def test_routes_and_caller_saved_poison(self):
        runs=self.e['runs'];self.assertEqual(len(runs),92)
        for row in runs:verify(row)
        for a,b in zip(runs[::2],runs[1::2]):
            self.assertEqual(a['value'],b['value'])
            self.assertEqual([{k:v for k,v in e.items() if k!='this'} for e in a['events']],
                             [{k:v for k,v in e.items() if k!='this'} for e in b['events']])

    def test_scale_clamp_and_gate(self):
        runs=[r for r in self.e['runs'] if r['fixture']['operation']=='scale' and not r['fixture']['poison']]
        self.assertEqual(runs[0]['value'],table_value(39,13))
        for level in (60,61,100):
            self.assertEqual(next(r['value'] for r in runs if r['fixture']['level']==level),table_value(59,13))
        for r in runs:
            f=r['fixture']
            if not f['enabled'] or f['missing'] or f['mode']!=3 or f['level'] in (-1,0) or f['count']==0:
                self.assertEqual(r['value'],1)
        self.assertEqual(next(r['value'] for r in runs if r['fixture']['owner_arg']==2),runs[0]['value'])
        bad=copy.deepcopy(runs[0]);bad['value']=1
        with self.assertRaisesRegex(ValueError,'result'):verify(bad)

    def test_mapping_is_lookup_not_identity_or_nearest(self):
        runs=[r for r in self.e['runs'] if r['fixture']['operation']=='map']
        for level,value in ((9,-1),(10,8),(11,-1),(39,-1),(40,25),(41,-1),(79,-1),(80,60),(81,-1)):
            row=next(r for r in runs if r['fixture']['level']==level)
            self.assertEqual(row['value'],value)
        for r in runs:
            if r['fixture']['empty_map']:self.assertEqual(r['value'],-1)
        lines=[line for b in self.e['blocks'] for line in b['instructions']]
        for line in ('0093583E dec eax','009358D1 mov eax, dword ptr [ecx + 0x10]',
                     '00FCA948 jae 0xfca94f','00924C72 jb 0x924c8b'):
            self.assertIn(line,lines)


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

    def test_enabled_gate_mutation(self):
        original,_=replay(self.s);verify(original)
        source=self.changed(0x42C801,b'\x74',b'\x75')
        row,_=replay(source);self.assertEqual(row['value'],1)
        with self.assertRaisesRegex(ValueError,'result'):verify(row)

    def test_minimum_becomes_maximum_mutation(self):
        source=self.changed(0x935837,b'\x7c',b'\x7f')
        row,_=replay(source);self.assertEqual(row['value'],table_value(59,13))
        with self.assertRaisesRegex(ValueError,'result'):verify(row)

    def test_map_returns_key_instead_of_value_mutation(self):
        original,_=replay(self.s,operation='map');verify(original);self.assertEqual(original['value'],25)
        source=self.changed(0x9358D3,b'\x10',b'\x0c')
        row,_=replay(source,operation='map');self.assertEqual(row['value'],40)
        with self.assertRaisesRegex(ValueError,'result'):verify(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

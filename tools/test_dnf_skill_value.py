"""Skill table body evidence, ABI poison and original-byte counterfactuals."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

from audit_dnf_skill_value import replay, verify, TABLE
from audit_dnf_native_strings import ENGINE_SHA

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]


class Archive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads((ROOT/'docs/reports/ws2/2026-11/native_skill_value.json').read_text(encoding='utf8'))

    def test_source_and_tool_identity(self):
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'],'8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)

    def test_matrix_and_abi_poison(self):
        runs=self.e['runs'];self.assertEqual(len(runs),50)
        for row in runs:verify(row)
        for a,b in zip(runs[::2],runs[1::2]):
            self.assertFalse(a['fixture']['poison']);self.assertTrue(b['fixture']['poison'])
            for key in ('value','bits','events','preserved','stack'):self.assertEqual(a[key],b[key])

    def test_unequal_columns_and_invalid_ranks(self):
        runs=self.e['runs'];self.assertEqual(self.e['table_fixture'],[list(v) for v in TABLE])
        for col,rank in ((0,0),(0,-1),(0,4),(1,5),(2,2),(3,1),(-1,1)):
            row=next(r for r in runs if r['fixture']['column']==col and r['fixture']['rank']==rank)
            self.assertEqual(row['value'],0.0)
            self.assertFalse(any(e['kind']=='modifier_fixture' for e in row['events']))
        row=next(r for r in runs if r['fixture']['column']==1 and r['fixture']['rank']==4)
        self.assertEqual(row['value'],9.0)

    def test_noncommuting_modifiers(self):
        row=next(r for r in self.e['runs'] if r['fixture']['modifiers'] and r['fixture']['column']==0)
        self.assertEqual(row['value'],291.75)
        bad=copy.deepcopy(row)
        mods=[e for e in bad['events'] if e['kind']=='modifier_fixture'];mods[2]['args'][-1]=1
        with self.assertRaisesRegex(ValueError,'order/arguments'):verify(bad)

    def test_explicit_partial_entry_and_native_selector(self):
        self.assertIn('908794',self.e['boundaries'][0]);self.assertIn('NOT full',self.e['boundaries'][0])
        lines=[line for block in self.e['blocks'] for line in block['instructions']]
        for line in ('00908807 dec edx','0090895A cmp esi, 0xe','00905E03 cmp dword ptr [ebp + 8], -1'):
            self.assertIn(line,lines)
        self.assertFalse(any(line.startswith('00908770 ') for line in lines))


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

    def test_original_source_replays_archived_cases(self):
        archived=json.loads((ROOT/'docs/reports/ws2/2026-11/native_skill_value.json').read_text(encoding='utf8'))
        for expected in archived['runs']:
            actual,_=replay(self.s,**expected['fixture']);verify(actual);self.assertEqual(json.loads(json.dumps(actual)),expected)

    def test_wrong_rank_origin(self):
        row,_=replay(self.changed(0x908807,b'\x4a',b'\x42'))
        with self.assertRaisesRegex(ValueError,'Modifier count|value'):verify(row)

    def test_wrong_modifier_phase(self):
        row,_=replay(self.changed(0x908910,b'\x00',b'\x01'),modifiers=True)
        with self.assertRaisesRegex(ValueError,'order/arguments'):verify(row)

    def test_wrong_normalization_sentinel(self):
        row,_=replay(self.changed(0x90895C,b'\x0e',b'\x0d'),level_b=20)
        with self.assertRaisesRegex(ValueError,'Normalization gate'):verify(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

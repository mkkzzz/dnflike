"""DGN revision filename routing evidence and native-byte counterfactuals."""
import argparse
import collections
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

from audit_dnf_revision_dispatch import replay, verify, OBJECT
from audit_dnf_native_strings import ENGINE_SHA, recover_string

p=argparse.ArgumentParser(add_help=False)
p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]


class Archive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e=json.loads((ROOT/'docs/reports/ws2/2026-11/native_revision_dispatch.json').read_text(encoding='utf8'))

    def test_source_and_dependency_identity(self):
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'],'8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)
        dep=self.e['table_evidence']
        self.assertEqual(hashlib.sha256((ROOT/dep['path']).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),dep['sha256'])
        self.assertEqual(recover_string(bytes.fromhex(self.e['tag']['raw']),0,2)[0],'[revision table]')

    def test_dispatch_and_clobber_matrix(self):
        runs=self.e['runs'];self.assertEqual(len(runs),20)
        for row in runs:verify(row)
        for a,b in zip(runs[::2],runs[1::2]):
            for key in ('registration','parsed','copied','events'):
                self.assertEqual(a[key],b[key])

    def test_dgn_inventory_and_conditional_table_matches(self):
        records=self.e['inventory'];self.assertEqual(len(records),328)
        self.assertEqual(len({r['path'] for r in records}),328)
        self.assertEqual(sum(not r['fields'] for r in records),216)
        references=collections.Counter(f['value'].lower() for r in records for f in r['fields'])
        self.assertEqual(sum(references.values()),112)
        self.assertEqual(references,{
            'dungeon/towers/table/towerofdespair.tbl':100,
            'dungeon/warroom/table/towerofbloodyfight.tbl':5,
            'dungeon/event/dual/table/dual_raid.tbl':3,
            'dungeon/towers/table/towerofillusion.tbl':1,
            'dungeon/towers/table/towerofdeath.tbl':1,
            'dungeon/towers/table/towerofbloodyfight.tbl':1,
            'dungeon/southerndale/table/southerndale.tbl':1})
        self.assertFalse(next(r for r in records if r['path']=='dungeon/act1/lorien.dgn')['fields'])
        tables=self.e['table_evidence']['tables']
        self.assertEqual(sum(n for path,n in references.items() if tables[path]['loaded']),6)
        self.assertEqual(sum(n for path,n in references.items() if not tables[path]['loaded']),106)

    def test_missing_empty_inline_and_heap_paths(self):
        runs=self.e['runs']
        for row in runs:
            loads=[e for e in row['events'] if e['kind']=='load_boundary']
            if not row['filename']:self.assertEqual(loads,[])
            elif row['filename']=='a.tbl':self.assertEqual(loads[0]['filename_pointer'],hex(OBJECT+0x4F4))
            else:self.assertNotEqual(loads[0]['filename_pointer'],hex(OBJECT+0x4F4))
        row=copy.deepcopy(next(r for r in runs if r['filename']=='a.tbl'))
        next(e for e in row['events'] if e['kind']=='load_boundary')['this']=hex(OBJECT)
        with self.assertRaisesRegex(ValueError,'load object'):verify(row)

    def test_original_record_and_dispatch_offsets(self):
        lines=[line for b in self.e['blocks'] for line in b['instructions']]
        for line in ('012F9DFF mov dword ptr [ebp - 0x590], 0x85d',
                     '012FA732 add eax, 0x72c','007E3BF4 lea ecx, [edi + 0x4f0]',
                     '007DE9FE lea ecx, [ebx + 0x44]'):
            self.assertIn(line,lines)
        static=[line for b in self.e['static_provenance'] for line in b['instructions']]
        self.assertIn('007E1E34 lea eax, [ebp - 0x834]',static)
        self.assertIn('007E1E43 call 0x12f3aa0',static)


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

    def test_parser_writes_wrong_field(self):
        source=self.changed(0x12FA733,b'\x2c\x07\x00\x00',b'\x30\x07\x00\x00')
        row,_=replay(source,'a.tbl')
        with self.assertRaisesRegex(ValueError,'field/copy|destination'):verify(row)

    def test_copy_gate_reversed(self):
        source=self.changed(0x7E3BE8,b'\x74',b'\x75')
        row,_=replay(source,'a.tbl')
        self.assertEqual(row['copied'],'')
        with self.assertRaisesRegex(ValueError,'field/copy'):verify(row)

    def test_load_gate_reversed(self):
        source=self.changed(0x7DE9E4,b'\x74',b'\x75')
        row,_=replay(source,'a.tbl')
        self.assertEqual(row['copied'],'a.tbl')
        with self.assertRaisesRegex(ValueError,'load gate'):verify(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

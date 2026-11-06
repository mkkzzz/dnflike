"""Normalization file loader evidence and original instruction counterfactuals."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

from audit_dnf_revision_table import replay, verify
from audit_dnf_native_strings import ENGINE_SHA

p=argparse.ArgumentParser(add_help=False)
p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]


def small_tokens():
    return ([{'type':5,'value':'[Revision Table]'},{'type':5,'value':'[type]'},
            {'type':7,'value':'monster'},{'type':5,'value':'[/type]'}]+
            [{'type':2,'value':v} for v in range(1,15)]+[{'type':5,'value':'[/Revision Table]'}])


class Archive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e=json.loads((ROOT/'docs/reports/ws2/2026-11/native_revision_table.json').read_text(encoding='utf8'))
        cls.inputs={r['name']:r for r in cls.e['inputs']}

    def test_source_identity_and_tools(self):
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'],'8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)

    def test_original_tables_and_poison_routes(self):
        runs=self.e['runs'];self.assertEqual(len(runs),21)
        self.assertEqual(sum('sha256' in x for x in self.e['inputs']),7)
        for r in runs:verify(r,self.inputs[r['input']]['tokens'])
        for a,b in zip(runs[:-1:2],runs[1:-1:2]):
            for key in ('return_bool','enabled','banks','appends','cursor'):
                self.assertEqual(a[key],b[key],(a['input'],key))
        expected_lengths={'dungeon/towers/table/towerofillusion.tbl':[200,200,200],
                          'dungeon/towers/table/towerofdeath.tbl':[200,200,200],
                          'dungeon/towers/table/towerofbloodyfight.tbl':[200,200,200],
                          'dungeon/event/dual/table/dual_raid.tbl':[200,0,0]}
        for name,lengths in expected_lengths.items():
            row=next(r for r in runs if r['input']==name and r['opened'])
            self.assertEqual(list(map(len,row['banks'])),lengths)

    def test_missing_type_is_not_silently_repaired(self):
        name='dungeon/southerndale/table/southerndale.tbl'
        self.assertEqual(self.inputs[name]['sha256'],'72ddd47535cdcff3f6222d863da4a4e258e44227c438025a7564148f76935ca9')
        self.assertEqual(self.inputs[name]['tokens'][1],{'type':7,'value':'character'})
        for r in self.e['runs']:
            if r['input']==name:
                self.assertFalse(r['return_bool']);self.assertEqual(r['enabled'],0)
                self.assertEqual(r['banks'],[[],[],[]])

    def test_empty_and_missing_files_are_distinct(self):
        empty=next(r for r in self.e['runs'] if r['input']=='synthetic_empty_file')
        self.assertEqual((empty['return_bool'],empty['enabled'],empty['banks']),(True,1,[[],[],[]]))
        missing=self.e['runs'][-1]
        self.assertEqual((missing['return_bool'],missing['enabled'],missing['cursor']),(False,0,0))
        invalid=next(r for r in self.e['runs'] if r['input']=='synthetic_unknown_group')
        self.assertEqual((invalid['return_bool'],invalid['enabled']),(False,0))

    def test_shared_groups_and_column_width(self):
        row=next(r for r in self.e['runs'] if r['input']=='synthetic_shared_groups')
        self.assertEqual([a['bank'] for a in row['appends']],[2,0,2,0])
        self.assertEqual(row['banks'][0],row['banks'][2]);self.assertEqual(row['banks'][1],[])
        lines=[line for b in self.e['blocks'] for line in b['instructions']]
        for line in ('00936043 cmp esi, 0xe','007649BB add dword ptr [edi + 8], 0xa8',
                     '00936174 mov byte ptr [edx + 0x50], 1','00401CA4 cmovb edi, eax',
                     '01218B58 cvtsi2ss xmm0, eax','013CC490 repz ret '):
            self.assertIn(line,lines)
        changed=copy.deepcopy(row);changed['banks'][0][0][-1]=0
        with self.assertRaisesRegex(ValueError,'values'):verify(changed,self.inputs[row['input']]['tokens'])


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

    def test_group_two_changed_to_one(self):
        tokens=small_tokens();row,_=replay(self.s,tokens,poison=True);verify(row,tokens)
        source=self.changed(0x935EF7,b'\x02',b'\x01')
        row,_=replay(source,tokens,poison=True)
        self.assertEqual([len(b) for b in row['banks']],[0,1,0])
        with self.assertRaisesRegex(ValueError,'values'):verify(row,tokens)

    def test_fourteen_columns_changed_to_thirteen(self):
        tokens=small_tokens();source=self.changed(0x936045,b'\x0e',b'\x0d')
        row,_=replay(source,tokens)
        with self.assertRaisesRegex(ValueError,'values'):verify(row,tokens)

    def test_enable_flag_mutation(self):
        tokens=small_tokens();source=self.changed(0x936177,b'\x01',b'\x00')
        row,_=replay(source,tokens)
        self.assertTrue(row['return_bool']);self.assertEqual(row['enabled'],0)
        with self.assertRaisesRegex(ValueError,'enable'):verify(row,tokens)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

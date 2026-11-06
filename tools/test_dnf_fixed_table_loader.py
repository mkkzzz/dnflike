"""Archived native table routing and optional protected-byte counterfactuals."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

from audit_dnf_fixed_table_loader import replay, verify, ROUTES
from audit_dnf_ice_particle_bindings import decode_immediate
from audit_dnf_native_strings import ENGINE_SHA, recover_string

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path)
p.add_argument('--decoder-dir',type=Path);args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]


class Archive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e=json.loads((ROOT/'docs/reports/ws2/2026-11/native_fixed_table_loader.json').read_text(encoding='utf8'))

    def test_identity_tools_and_original_tags(self):
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'],'8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)
        for o in self.e['operands']:
            self.assertEqual(recover_string(bytes.fromhex(o['string_raw']),0,2)[0],ROUTES[o['mode']]['tag'])
        self.assertEqual(self.e['source_table']['sha256'],'61fe2583df5a6cbf0f33ab8a084d18aca760732441b332128dfcff98c1de0ba4')

    def test_all_paths_and_register_poisoning(self):
        self.assertEqual(len(self.e['runs']),10)
        for r in self.e['runs']:verify(r)
        for mode in ROUTES:
            full=[r for r in self.e['runs'] if r['mode']==mode and len(r['input_values'])==700]
            self.assertEqual(len(full),2)
            self.assertEqual(full[0]['columns'],full[1]['columns'])
            self.assertEqual(full[0]['appends'],full[1]['appends'])
            self.assertNotEqual(full[0]['poison'],full[1]['poison'])

    def test_original_data_mapping_and_no_added_row(self):
        tables=self.e['source_table']['fields']
        for mode,r in ROUTES.items():
            full=next(x for x in self.e['runs'] if x['mode']==mode and len(x['input_values'])==700)
            self.assertEqual(full['input_values'],tables[r['tag']])
            self.assertEqual([len(c['values']) for c in full['columns']],[100]*7)
            self.assertEqual(full['columns'][0]['values'],list(range(1,101)))
            self.assertEqual(full['columns'][1]['values'][0],63 if mode=='dungeon' else 33)
            self.assertEqual(full['columns'][1]['values'][-1],1000 if mode=='dungeon' else 682)
        partial=next(x for x in self.e['runs'] if len(x['input_values'])==3)
        self.assertEqual([c['values'] for c in partial['columns']],[[1],[99],[98],[0],[0],[0],[0]])

    def test_native_append_and_token_reader_included(self):
        lines={line for block in self.e['blocks'] for line in block['instructions']}
        for line in ('00441525 add dword ptr [edi + 8], 0xc','01218A90 cmp eax, 2',
                     '01218AA6 mov byte ptr [ecx], 1','01218AF0 mov byte ptr [eax], 0'):
            self.assertIn(line,lines)
        changed=copy.deepcopy(self.e['runs'][0]);changed['columns'][1]['values'][0]=59
        with self.assertRaisesRegex(ValueError,'transposition'):verify(changed)


@unittest.skipUnless(args.client,'optional original-source replay')
class Live(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from audit_dnf_particle_axis import AxisEvaluator
        cls.s=AxisEvaluator(args.client.read_bytes())

    def changed(self,address,raw):
        source=copy.copy(self.s);data=bytearray(source.raw)
        sec=next(s for s in source.sections if s['rva']<=address-0x400000<s['rva']+s['bytes'])
        at=sec['offset']+address-0x400000-sec['rva'];data[at:at+len(raw)]=raw;source.raw=bytes(data)
        return source

    def immediate(self,address,value):
        rotated=((value<<4)|(value>>28))&0xffffffff
        x=(~((rotated+1)&0xffffffff)^0x3C6AAEDE)^0x1F9BF630
        operand=(x+1+0x30201078-address)&0xffffffff
        changed=self.changed(address+4,operand.to_bytes(4,'little'))
        self.assertEqual(decode_immediate(changed,address),value)
        return changed

    def test_protected_array_bank_stride_mutation(self):
        self.assertEqual(decode_immediate(self.s,0x635B15),140)
        changed=self.immediate(0x635B15,0)
        row,_,_=replay(changed,'pvp',list(range(14)))
        with self.assertRaisesRegex(ValueError,'wrong global vectors'):verify(row)

    def test_protected_column_address_mutation(self):
        self.assertEqual(decode_immediate(self.s,0x219D290),0x1A6698C)
        changed=self.immediate(0x219D290,0x1A669A0)
        row,_,_=replay(changed,'dungeon',list(range(14)),poison=True)
        with self.assertRaisesRegex(ValueError,'append order'):verify(row)

    def test_token_acceptance_branch_mutation(self):
        self.assertEqual(self.s.source_bytes(0x1218A93,1),b'\x75')
        original,_,_=replay(self.s,'pvp',list(range(14)),poison=True);verify(original)
        changed=self.changed(0x1218A93,b'\x74')
        row,_,_=replay(changed,'pvp',list(range(14)))
        self.assertEqual(row['token_cursor'],0)
        with self.assertRaisesRegex(ValueError,'Incomplete'):verify(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

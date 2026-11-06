"""Original context source order, slot selection and sequential state arithmetic."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_skill_context_modifier import replay,verify,DEFAULT_ROWS
from audit_dnf_native_strings import ENGINE_SHA

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_skill_context_modifier.json'


class Archive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))
        cls.cases={r['case']:r for r in cls.e['runs']}

    def test_source_identity(self):
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'],'8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)

    def test_full_path_matrix_and_clobber(self):
        self.assertEqual(len(self.e['runs']),222)
        for r in self.e['runs']:verify(r)
        for a,b in zip(self.e['runs'][::2],self.e['runs'][1::2]):
            self.assertFalse(a['fixture']['poison']);self.assertTrue(b['fixture']['poison'])
            for k in ('value','binary32_bits','events','stack','preserved'):self.assertEqual(a[k],b[k])

    def test_state_rows_are_sequential_not_equipment_aggregation(self):
        self.assertEqual([self.cases[f'state:phase:{p}']['value'] for p in (0,1,2,3)],[132,110,142.60000610351562,100])
        cancelled=next(r for r in self.e['runs'] if r['fixture']['special_rows']==[[11,20,0,1,20,1,10],[11,20,0,1,20,1,-10]])
        self.assertEqual(cancelled['value'],99)
        rounded=next(r for r in self.e['runs'] if r['fixture']['value']==16777216)
        self.assertEqual(rounded['value'],16777216)

    def test_slot_bank_selection_uses_separate_manager_field(self):
        for index in (0,9,10,11,21,22,25):
            for mode in (0,14,15,16):
                self.assertEqual(self.cases[f'slot:{index}:{mode}']['value'],192 if 10<=index<=21 and mode in (14,15,16) else 140)
        self.assertEqual(self.cases['slot:special_bank']['value'],140)
        self.assertEqual(self.cases['slot:shadow']['value'],100)
        self.assertEqual(self.cases['slot:special_shadow']['value'],140)
        self.assertEqual(self.cases['slot:disabled']['value'],100)

    def test_source_order_and_state_tree(self):
        row=self.cases['all:2'];calls=[e for e in row['events'] if e['kind']=='native_modifier']
        self.assertEqual([e['container'] for e in calls],['equipment','equipment','equipment','null','special','level','status:0','status:2'])
        tree=self.cases['tree:inorder'];calls=[e for e in tree['events'] if e['kind']=='native_modifier']
        self.assertEqual([e['container'] for e in calls],['status:0','status:2','status:3','status:4'])
        self.assertEqual(tree['value'],114.0999984741211)
        self.assertEqual(self.cases['tree:empty_payload']['value'],100)

    def test_null_owner_and_profile_initialization(self):
        for name in ('empty','cold','null','null_cold'):
            self.assertEqual(self.cases[name]['value'],100)
        for name in ('null','null_cold'):
            self.assertFalse(any(e['kind']=='native_slot_query' for e in self.cases[name]['events']))
        self.assertEqual(self.cases['level:empty']['value'],100)

    def test_original_getters_and_entry_are_present(self):
        lines=[l for b in self.e['blocks'] for l in b['instructions']]
        for line in ('00907D40 push ebp','009080B9 ret 0x18','00904800 push ebp',
                     '009049E4 ret 0x1c','0080EEA0 lea eax, [ecx + 0x3858]',
                     '00485870 lea eax, [ecx + 0xac]','0083E580 mov al, byte ptr [ecx + 0x551d]',
                     '00843466 lea edi, [esi + 0x37b8]','0084346E lea edi, [esi + 0x3010]'):
            self.assertIn(line,lines)
        self.assertEqual(self.e['owner_vtable'],{'0x38':'0x8312d0','0x738':'0xd09590','0x798':'0x844850'})


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

    def test_all_original_paths_match_archive(self):
        for archived in json.loads(ARCHIVE.read_text(encoding='utf8'))['runs']:
            row,_=replay(self.s,**archived['fixture']);verify(row);row['case']=archived['case']
            self.assertEqual(json.loads(json.dumps(row)),archived)

    def test_percent_factor_multiply_becomes_addition(self):
        s=self.changed(0x90496A,b'\x59',b'\x58')
        row,_=replay(s,entry='state')
        with self.assertRaisesRegex(ValueError,'calculation'):verify(row)

    def test_state_loop_stops_after_first_row(self):
        s=self.changed(0x9049D6,b'\x82',b'\x83')
        row,_=replay(s,entry='state')
        with self.assertRaisesRegex(ValueError,'calculation'):verify(row)

    def test_special_owner_branch_is_skipped(self):
        s=self.changed(0x907EB3,b'\x74',b'\xeb')
        row,_=replay(s,special_rows=DEFAULT_ROWS)
        with self.assertRaisesRegex(ValueError,'calculation'):verify(row)

    def test_manager_mode_14_loses_alternate_bank(self):
        s=self.changed(0x750982,b'\x0e',b'\x0d')
        row,_=replay(s,load_mode=14,slots=[(11,0,True,True,False,False),(11,1,True,True,True,False)])
        with self.assertRaisesRegex(ValueError,'calculation'):verify(row)

    def test_active_level_branch_is_skipped(self):
        s=self.changed(0x907EEF,b'\x84',b'\x85')
        row,_=replay(s,level_rows=DEFAULT_ROWS)
        with self.assertRaisesRegex(ValueError,'calculation'):verify(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

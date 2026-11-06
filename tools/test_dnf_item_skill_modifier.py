"""Native item/status skill modifier aggregation and applicability regression."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_item_skill_modifier import replay,verify,fbits
from audit_dnf_native_strings import ENGINE_SHA

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]


class Archive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads((ROOT/'docs/reports/ws2/2026-11/native_item_skill_modifier.json').read_text(encoding='utf8'))

    def test_source_and_tool_identity(self):
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'],'8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)

    def test_source_matrix_and_caller_clobber(self):
        rows=self.e['runs'];self.assertEqual(len(rows),168)
        for row in rows:verify(row)
        for a,b in zip(rows[::2],rows[1::2]):
            self.assertFalse(a['fixture']['poison']);self.assertTrue(b['fixture']['poison'])
            for key in ('value','binary32_bits','events','stack','preserved'):self.assertEqual(a[key],b[key])

    def test_percentage_sum_before_fixed_addition(self):
        rows=self.e['runs'][:8:2]
        self.assertEqual([r['fixture']['phase'] for r in rows],[0,1,2,3])
        self.assertEqual([r['value'] for r in rows],[130,110,140,100])
        self.assertEqual(self.e['runs'][154]['value'],100)  # +10% and -10% cancel before scaling
        self.assertEqual(self.e['runs'][152]['value'],140)  # reversing entry order preserves sums

    def test_owner_and_row_filters(self):
        for row in self.e['runs']:
            f=row['fixture']
            if not f['has_owner'] or not f['has_modifier'] or f['category'] in (0,257) or f['column']==1 or f['skill_id']==21:
                self.assertEqual(row['value'],f['value'])
        lines=[l for b in self.e['blocks'] for l in b['instructions']]
        self.assertIn('00D09590 lea eax, [ecx + 0x3c08]',lines)
        self.assertIn('009045ED cmp dword ptr [edi + esi], 0xb',lines)

    def test_mode_groups_and_null_module(self):
        for row in self.e['runs']:
            f=row['fixture'];banks=f['banks']
            if len(banks[0])!=1 or banks[1] or banks[0][0][:4]!=[11,20,0,1] or banks[0][0][5:]!=[1,10]:continue
            rule=banks[0][0][4]
            if rule==18:self.assertEqual(row['value'],110 if f['mode'] in (4,5,7,9) else 100)
            if rule==19:self.assertEqual(row['value'],110 if f['mode']==2 or f['mode']==3 and f['has_module'] else 100)
        self.assertEqual(self.e['vtables']['modes']['3']['slot_28'],'0xe4f970')
        self.assertEqual(self.e['vtables']['modes']['1']['slot_28'],'0x43de80')

    def test_x87_return_is_not_already_binary32(self):
        row=next(r for r in self.e['runs'] if r['fixture']['value']==16777216)
        self.assertEqual(row['value'],16777217)
        self.assertEqual(row['binary32_bits'],fbits(16777216))
        self.assertNotEqual(row['value'],16777216)

    def test_both_vector_offsets_and_integer_wrap(self):
        lines=[l for b in self.e['blocks'] for l in b['instructions']]
        self.assertIn('00904575 mov esi, dword ptr [ebx + 0x4a4]',lines)
        self.assertIn('00904694 mov esi, dword ptr [ebx + 0x4cc]',lines)
        self.assertIn('009047E6 fild dword ptr [ebp - 4]',lines)
        row=next(r for r in self.e['runs'] if r['fixture']['banks'][0] and r['fixture']['banks'][0][0][-1]==2147483647)
        self.assertEqual(row['value'],-2147483548)

    def test_original_slot_loop_calls_both_sources_and_stores_each_result(self):
        rows=self.e['runs'][-12::2]
        self.assertEqual([r['value'] for r in rows[:5]],[100,140,192,140,100])
        self.assertEqual(rows[5]['value'],347.4800109863281)
        for row in rows:
            self.assertEqual([e['slot'] for e in row['events'] if e['kind']=='slot_lookup_fixture'],list(range(26)))
            self.assertEqual(row['fp_depth'],0)


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

    def test_all_original_cases_match_archive(self):
        archived=json.loads((ROOT/'docs/reports/ws2/2026-11/native_item_skill_modifier.json').read_text(encoding='utf8'))
        for expected in archived['runs']:
            row,_=replay(self.s,**expected['fixture']);verify(row)
            self.assertEqual(json.loads(json.dumps(row)),expected)

    def test_second_vector_reads_first_bank(self):
        row,_=replay(self.changed(0x904696,b'\xcc\x04',b'\xa4\x04'))
        with self.assertRaisesRegex(ValueError,'aggregation'):verify(row)

    def test_wrong_owner_wildcard(self):
        row,_=replay(self.changed(0x9045F0,b'\x0b',b'\x0c'))
        with self.assertRaisesRegex(ValueError,'aggregation'):verify(row)

    def test_mode_group_18_loses_mode_7(self):
        row,_=replay(self.changed(0x75C0CA,b'\x07',b'\x06'),banks=([(11,20,0,1,18,1,10)],[]),mode=7)
        with self.assertRaisesRegex(ValueError,'aggregation'):verify(row)

    def test_percent_sum_changes_sign(self):
        row,_=replay(self.changed(0x90463E,b'\x01',b'\x29'))
        with self.assertRaisesRegex(ValueError,'aggregation'):verify(row)

    def test_slot_loop_drops_last_index(self):
        row,_=replay(self.changed(0x907E9E,b'\x1a',b'\x19'),slots=[(25,True,True,False)])
        with self.assertRaisesRegex(ValueError,'traversal'):verify(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

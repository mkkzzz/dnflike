"""Original property 53 arithmetic, native gate and enum/dispatch regression."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_property_fixed_attack import replay,verify,decode_property,verify_decode
from audit_dnf_fixed_base import replay as consume,verify as verify_consumer

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_property_fixed_attack.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def test_source_identity_and_tool_dependencies(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)
        self.assertEqual(self.e['constant_percent']['bits'],0x3C23D70A)
        self.assertEqual(self.e['vtables']['plain']['entry_slot'],'30a99700')
        self.assertEqual(self.e['vtables']['owner_gate']['gate_slot'],'e000a500')

    def test_original_string_enum_and_jump_table(self):
        self.assertEqual(len(self.e['decodes']),4)
        for row in self.e['decodes']:verify_decode(row)
        self.assertEqual(self.e['dispatch'],{'property':53,'index':43,'target':'0x97d22b'})

    def test_complete_dispatcher_and_caller_clobbers(self):
        self.assertEqual(len(self.e['runs']),92)
        for row in self.e['runs']:verify(row)
        for a,b in zip(self.e['runs'][::2],self.e['runs'][1::2]):
            self.assertEqual(a['state'],b['state']);self.assertEqual(a['row_states'],b['row_states'])
        instructions=[i for b in self.e['blocks'] for i in b['instructions']]
        self.assertIn('0097A930 push ebp',instructions);self.assertIn('0097D607 ret 4',instructions)

    def test_integer_truncation_and_shared_mode_fields(self):
        rows=[r for r in self.e['runs'] if r['fixture']['gate']=='plain' and len(r['fixture']['rows'])==1]
        self.assertTrue(rows)
        for row in rows:
            prop,op,amount=row['fixture']['rows'][0]
            if amount==3.9:self.assertEqual(row['state'][:2],[10,22])
            if amount==-3.9:self.assertEqual(row['state'][:2],[4,16])
            if amount==16777217.:self.assertEqual(row['state'][:2],[16777223,16777235])
            if row['fixture']['initial'][0]==2147483647:self.assertEqual(row['state'][:2],[-2147483648,-2147483647])
            self.assertEqual(row['state'][4],row['fixture']['initial'][4])

    def test_percentage_is_added_per_row_not_equipment_multiplication(self):
        rows=[r for r in self.e['runs'] if r['fixture']['gate']=='plain']
        cancel=next(r for r in rows if r['fixture']['rows']==[[53,1,10.],[53,1,-10.]])
        self.assertEqual(cancel['state'][2:4],[1.25,1.75])
        noncanonical=next(r for r in rows if r['fixture']['rows']==[[53,7,10.]])
        self.assertEqual(noncanonical['state'][2:4],[1.350000023841858,1.850000023841858])
        ordered=next(r for r in rows if r['fixture']['rows']==[[53,1,16777216.],[53,1,1.],[53,1,-16777216.]])
        self.assertEqual(ordered['state'][2:4],[1.265625,1.765625])
        tiny=next(r for r in rows if r['fixture']['initial'][2]==16777216)
        self.assertEqual(tiny['state'][2:4],[16777216.,16777216.])

    def test_original_gate_and_out_of_range_properties(self):
        for row in self.e['runs']:
            f=row['fixture']
            if f['gate']=='owner_gate' and f['owner_status']==1:
                self.assertFalse(row['updates']);self.assertFalse(row['indices']);self.assertEqual(row['state'],f['initial'])
            if f['rows'] and f['rows'][0][0]==77 and f['gate']=='plain':
                self.assertEqual(row['indices'],[1,1,1]);self.assertEqual(len(row['updates']),2)

    def test_outputs_feed_original_base_consumer(self):
        self.assertEqual(len(self.e['consumers']),20)
        for a in self.e['consumers']:
            row=a['run'];verify_consumer(row)
            special=row['fixture']['mode'] in (4,5)
            blocked=a['gate']=='owner_gate' and a['owner_status']>0
            self.assertEqual(row['value'],(2168 if special else 1535) if blocked else (2540 if special else 1903))


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

    def test_live_paths_match_archive_and_gate_uses_signed_positive(self):
        e=json.loads(ARCHIVE.read_text(encoding='utf8'))
        for archived in e['decodes']:
            row,_=decode_property(self.s,archived['word'],poison=archived['poison']);verify_decode(row);self.assertEqual(row,archived)
        for archived in e['runs']:
            row,_=replay(self.s,**archived['fixture']);verify(row);self.assertEqual(row,archived)
        for a in e['consumers']:
            row,_=consume(self.s,**a['run']['fixture']);verify_consumer(row);self.assertEqual(json.loads(json.dumps(row)),a['run'])
        for status in (2,256,-2):
            row,_=replay(self.s,[[53,0,3.9]],gate='owner_gate',owner_status=status,poison=True);verify(row)
            self.assertEqual(len(row['updates']),0 if status>0 else 2)

    def test_property_name_maps_to_wrong_enum(self):
        row,_=decode_property(self.changed(0x1250443,b'\x35',b'\x34'),'[separate attack]')
        with self.assertRaisesRegex(ValueError,'enum mismatch'):verify_decode(row)

    def bad(self,source,rows):
        row,_=replay(source,rows)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_percentage_addition_becomes_multiplication(self):
        self.bad(self.changed(0x4468CC,b'\x58',b'\x59'),[[53,1,10.]])

    def test_fixed_update_targets_alternate_field_twice(self):
        self.bad(self.changed(0x97D2DF,b'\x7c',b'\x88'),[[53,0,3.9]])

    def test_loop_stops_after_first_row(self):
        self.bad(self.changed(0x97D5F1,b'\x82',b'\x83'),[[53,0,3.9],[53,1,10.]])

    def test_gate_skips_active_plain_object(self):
        self.bad(self.changed(0x97A96B,b'\x01',b'\x00'),[[53,0,3.9]])

    def test_fixed_and_percentage_branches_reversed(self):
        self.bad(self.changed(0x97D258,b'\x74',b'\x75'),[[53,0,3.9]])


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

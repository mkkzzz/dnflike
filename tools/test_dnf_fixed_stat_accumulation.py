"""Native fixed-stat reset/accumulation regression, with optional live mutation checks."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_fixed_stat_accumulation import replay,verify
from audit_dnf_fixed_base import replay as consume,verify as verify_consumer

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_fixed_stat_accumulation.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def test_original_identity_and_tool_dependencies(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)
        self.assertEqual(self.e['tag'],'[separate rate]')
        self.assertEqual(self.e['constant_one']['bits'],0x3F800000)

    def test_complete_reset_and_per_item_accumulation(self):
        self.assertEqual(len(self.e['runs']),100)
        for row in self.e['runs']:verify(row)
        for clean,poison in zip(self.e['runs'][::2],self.e['runs'][1::2]):
            self.assertEqual(clean['states'],poison['states']);self.assertEqual(clean['reset'],poison['reset'])
        instructions=[i for b in self.e['blocks'] for i in b['instructions']]
        self.assertIn('00D02B70 push ebp',instructions)
        self.assertIn('00D034D5 ret ',instructions)

    def test_multiplicative_rates_and_distinct_final_add_mode(self):
        rows=[r for r in self.e['runs'] if len(r['fixture']['items'])==2 and r['fixture']['items'][0]['attack']==[31,18]]
        self.assertEqual(len(rows),24)
        for row in rows:
            f=row['fixture'];special=f['alternate'] and f['manager_mode'] in (8,13,15,16)
            self.assertEqual(row['states'][-1],[87,52,0.9900000095367432,1.,28 if special else 20])
        self.assertTrue(any(r['fixture']['alternate'] and r['fixture']['manager_mode']==14 and r['states'][-1][-1]==20 for r in rows))

    def test_numeric_rounding_wrapping_and_zero_multiplier(self):
        for row in self.e['runs']:
            items=row['fixture']['items']
            if items and items[0]['attack']==[2147483647,-2147483648]:
                self.assertEqual(row['states'][-1][:4],[-2147483648,2147483647,1.000000238418579,0.])
            if items and items[0]['attack']==[-5,3]:
                self.assertEqual(row['parsed'][0]['rate'],[-0.75,16777216.])

    def test_full_base_consumer_keeps_post_truncation_addition(self):
        self.assertEqual(len(self.e['consumers']),60)
        for application in self.e['consumers']:
            row=application['run'];verify_consumer(row)
            # Native base table fixture is 1217. The ordinary mode gives
            # trunc(f32(1217+87)*f32(f32(1.1)*f32(0.9))) + final = 1290 + final.
            # Native base multiplication remains in x87 until the truncation helper.
            before_final=1269 if row['fixture']['mode'] in (4,5) else 1290
            self.assertEqual(row['value'],before_final+application['state'][4])

    def test_absent_source_tag_is_not_claimed_as_equipment_coverage(self):
        self.assertEqual(self.e['inventory']['separate_rate_string_ids'],[])
        self.assertIn('synthetic rate fixtures',self.e['inventory']['meaning'])
        self.assertTrue(any('Their producers' in b for b in self.e['boundaries']))


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

    def test_original_paths_and_consumers_match_archive(self):
        e=json.loads(ARCHIVE.read_text(encoding='utf8'))
        for archived in e['runs']:
            row,_=replay(self.s,**archived['fixture']);verify(row);self.assertEqual(row,archived)
        for a in e['consumers']:
            row,_=consume(self.s,**a['run']['fixture']);verify_consumer(row)
            self.assertEqual(json.loads(json.dumps(row)),a['run'])

    def check_bad(self,source,**kwargs):
        row,_=replay(source,[{'attack':[26,14],'rate':[1.25,0.75],'final':[7,11]}],**kwargs)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_reset_one_constant_becomes_zero(self):
        self.check_bad(self.changed(0x15560BC,b'\x00\x00\x80\x3f',b'\x00\x00\x00\x00'))

    def test_default_multiplier_reads_alternate_source(self):
        self.check_bad(self.changed(0x77BE77,b'\x60',b'\x6c'))

    def test_multiplier_is_overwritten_instead_of_multiplied(self):
        row,_=replay(self.changed(0x77BEAF,b'\x59',b'\x10'),[
            {'attack':[1,2],'rate':[1.25,1.],'final':[7,11]},
            {'attack':[3,4],'rate':[1.25,1.],'final':[13,17]}])
        with self.assertRaisesRegex(ValueError,'accumulation'):verify(row)

    def test_manager_eight_branch_changes_to_seven(self):
        self.check_bad(self.changed(0x750D02,b'\x08',b'\x07'),manager_mode=8,alternate=True)

    def test_default_final_add_reads_alternate_field(self):
        self.check_bad(self.changed(0x77BF48,b'\x78',b'\x84'),manager_mode=3,alternate=True)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

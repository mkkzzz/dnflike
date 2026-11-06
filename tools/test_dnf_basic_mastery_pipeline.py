"""ATK parser/caller/base-rank pipeline and original-byte mutation negatives."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_basic_mastery import replay,verify
from audit_dnf_basic_mastery_pipeline import parse_bonus,verify_parser,rank_transition,verify_rank

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_basic_mastery_pipeline.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def test_source_and_dependency_fingerprints(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)
        self.assertEqual([r['start'] for r in self.e['static_provenance']],['0x509930','0x80a680','0x861dec'])

    def test_atk_field_presence_and_missing_default_boundary(self):
        sources={r['move']:r for r in self.e['attack_sources']}
        self.assertEqual({k:v['fields'] for k,v in sources.items()},
                         {'attack1':[[-15]],'attack2':[],'attack3':[[20]],'dash_attack':[[40]],'air_attack':[[10]]})
        self.assertEqual(sources['attack2']['status'],'missing_field_default_not_proven')
        self.assertNotIn('attack2',[r['move'] for r in self.e['consumers']])
        self.assertEqual(len({r['sha256'] for r in sources.values()}),5)

    def test_native_registration_dispatch_and_numeric_reader(self):
        self.assertEqual(len(self.e['parsers']),22)
        for row in self.e['parsers']:verify_parser(row)
        expected={-2.9:-2,3.9:3,16777217.:16777216}
        for row in self.e['parsers']:
            if type(row['fixture']['value'])==float and row['fixture']['value'] in expected:self.assertEqual(row['value'],expected[row['fixture']['value']])
            if type(row['fixture']['value'])==int and row['fixture']['value']==16777217:self.assertEqual(row['value'],16777217)

    def test_real_source_rows_feed_actual_caller(self):
        self.assertEqual(len(self.e['consumers']),40)
        for item in self.e['consumers']:
            verify_parser(item['parsed']);row=item['run'];verify(row)
            self.assertTrue(row['fixture']['caller']);self.assertTrue(row['fixture']['cached_skill'])
            self.assertEqual(row['fixture']['initial'],item['parsed']['value'])
            rank=row['fixture']['rank'];self.assertEqual(row['fixture']['values'],[24*(rank-1)]*3)
        samples={i['move']:i['run']['value'] for i in self.e['consumers'] if i['run']['fixture']['rank']==60}
        self.assertEqual(samples,{'attack1':105,'attack3':189,'dash_attack':238,'air_attack':165})

    def test_caller_short_circuits_and_source_instructions(self):
        self.assertEqual(len(self.e['callers']),24)
        for row in self.e['callers']:verify(row)
        instructions=[i for b in self.e['blocks'] for i in b['instructions']]
        for i in ('012D0456 lea ecx, [esi + 0x24]','00CA6EE0 lea ecx, [esi + 0x3094]',
                  '00CA6EF7 lea ecx, [esi + 0x2d4]','00CA6F00 call 0x83fa10','0083FB27 ret 8',
                  '008444F0 push ebp','008407E1 ret 4'):
            self.assertIn(i,instructions)

    def test_nonzero_setter_then_effective_rank_copy(self):
        self.assertEqual(len(self.e['ranks']),28)
        for row in self.e['ranks']:verify_rank(row)
        beyond=next(r for r in self.e['ranks'] if r['fixture']['rank']==101 and r['fixture']['exists'])
        self.assertEqual(beyond['after_setter'],[101,37]);self.assertEqual(beyond['after_base_copy'],[101,101])
        self.assertTrue(any('event producing rank' in s for s in self.e['boundaries']))

    def test_corrupt_outputs_are_rejected(self):
        row=copy.deepcopy(self.e['parsers'][0]);row['value']+=1
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_parser(row)
        row=copy.deepcopy(self.e['ranks'][0]);row['after_base_copy'][1]+=1
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_rank(row)


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

    def test_live_paths_match_archive(self):
        e=json.loads(ARCHIVE.read_text(encoding='utf8'))
        for old in e['parsers']:
            row,_=parse_bonus(self.s,**old['fixture']);verify_parser(row);self.assertEqual(row,old)
        for old in [x['run'] for x in e['consumers']]+e['callers']:
            row,_=replay(self.s,**old['fixture']);verify(row);self.assertEqual(row,old)
        for old in e['ranks']:
            row,_=rank_transition(self.s,**old['fixture']);verify_rank(row);self.assertEqual(row,old)
        for value in (float('nan'),2147483647.0):
            with self.assertRaisesRegex(ValueError,'integer-conversion domain'):parse_bonus(self.s,value)

    def test_wrong_tag_enum(self):
        source=self.changed(0x12CFA8E,b'\x4e',b'\x4d')
        with self.assertRaisesRegex(ValueError,'Unexpected parsed field|mapping mismatch'):
            row,_=parse_bonus(source,20);verify_parser(row)

    def test_wrong_atk_target(self):
        source=self.changed(0x12D0458,b'\x24',b'\x18')
        with self.assertRaisesRegex(ValueError,'Unexpected parsed field'):
            parse_bonus(source,20)

    def test_wrong_embedded_record_pointer(self):
        source=self.changed(0xCA6EF9,bytes.fromhex('d4020000'),bytes.fromhex('e0020000'))
        with self.assertRaisesRegex(ValueError,'Secure ABI'):
            replay(source,caller=True)

    def test_wrong_category_field(self):
        source=self.changed(0xCA6EE2,bytes.fromhex('94300000'),bytes.fromhex('98300000'))
        with self.assertRaisesRegex(ValueError,'Secure ABI'):
            replay(source,caller=True)

    def test_setter_targets_effective_rank_prematurely(self):
        source=self.changed(0x844963,bytes.fromhex('90050000'),bytes.fromhex('9c050000'))
        row,_=rank_transition(source,60)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_rank(row)

    def test_rebuild_reads_old_effective_rank(self):
        source=self.changed(0x861DB4,bytes.fromhex('90050000'),bytes.fromhex('9c050000'))
        row,_=rank_transition(source,60)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_rank(row)

    def test_native_rank_getter_reads_wrong_field(self):
        source=self.changed(0x844524,bytes.fromhex('9c050000'),bytes.fromhex('90050000'))
        with self.assertRaisesRegex(ValueError,'Secure ABI'):
            replay(source,caller=True,cached_skill=True)

    def test_cached_lookup_reads_wrong_slot(self):
        source=self.changed(0x840714,bytes.fromhex('14440000'),bytes.fromhex('18440000'))
        with self.assertRaisesRegex(ValueError,'uninitialized memory'):
            replay(source,caller=True,cached_skill=True)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

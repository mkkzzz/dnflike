"""Native basic mastery gates/column/arithmetic with branch mutation negatives."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_basic_mastery import replay,verify

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_basic_mastery.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def test_source_identity_and_dependencies(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)
        self.assertEqual(self.e['vtable']['slots'],{'0x7d0':'f0448400','0x804':'c0068400','0x878':'60eec900','0x87c':'40c08300'})
        self.assertEqual(self.e['constants'],{'0x156889c':'cdcccc3d','0x1556df8':'0000c842','0x1559c80':'0ad7233c'})

    def test_original_skill_rows_and_linked_text(self):
        s=self.e['skill_source'];self.assertEqual(s['skill_id'],174)
        self.assertEqual(s['sha256'],'d6287b7182bb5471a578b6225bcc369d82665163362801fa660e22973ebad0e4')
        self.assertEqual(s['fields']['[level info]'],[3]+[24*(r-1) for r in range(1,101) for _ in range(3)])
        self.assertEqual(s['fields']['[static data]'],[1])
        self.assertEqual(s['fields']['[growtype maximum level]'],[1]*6)
        self.assertEqual(s['text']['[explain]'][0]['key'],'basic_attack_up_explain')
        self.assertIn('前沖',s['text']['[explain]'][0]['text'])

    def test_all_paths_and_volatile_register_clobbers(self):
        self.assertEqual(len(self.e['runs']),88)
        for row in self.e['runs']:verify(row)
        for a,b in zip(self.e['runs'][::2],self.e['runs'][1::2]):
            self.assertEqual(a['value'],b['value']);self.assertEqual(a['calls'],b['calls'])
        ins=[i for b in self.e['blocks'] for i in b['instructions']]
        for line in ('0083FA10 push ebp','0083FB27 ret 8','0083FAFA ret 8','00C9EE60 push ebp','009095EB ret 8'):self.assertIn(line,ins)

    def test_attack_categories_select_distinct_columns(self):
        for category,column in ((8,0),(7,1),(15,2)):
            rows=[r for r in self.e['runs'] if r['fixture']['category']==category and r['fixture']['values']==[24.,48.,72.]]
            self.assertTrue(rows)
            for row in rows:
                values=[c for c in row['calls'] if c['service']=='value']
                if row['writes']:self.assertEqual(values[0]['args'][0],column)
        for row in self.e['runs']:
            if row['fixture']['category'] not in (8,7,15):self.assertFalse(row['writes'])

    def test_source_rank_rows_are_fixture_inputs_not_auto_level_proof(self):
        rows=[r for r in self.e['runs'] if r['fixture']['rank']==60]
        self.assertEqual(len(rows),2)
        self.assertEqual(rows[0]['value'],226)
        self.assertEqual(rows[0]['calls'][-1]['args'][1],60)
        self.assertTrue(any('automatic level' in b for b in self.e['boundaries']))

    def test_swordman_states_and_missing_inputs_block_writes(self):
        for row in self.e['runs']:
            f=row['fixture']
            if 1 in f['states'] or f['learned']<=0 or not f['skill_exists'] or not f['attack_exists']:self.assertFalse(row['writes'])
        blocked=next(r for r in self.e['runs'] if r['fixture']['states']==[1,1,1])
        self.assertEqual(blocked['state_calls'],[0])

    def test_archive_corruption_is_detected(self):
        row=copy.deepcopy(next(r for r in self.e['runs'] if r['writes']))
        row['value']+=1
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)


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

    def bad(self,source,**case):
        row,_=replay(source,**case)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_live_paths_equal_archive(self):
        for archived in json.loads(ARCHIVE.read_text(encoding='utf8'))['runs']:
            row,_=replay(self.s,**archived['fixture']);verify(row);self.assertEqual(row,archived)

    def test_wrong_category_gate(self):self.bad(self.changed(0x83C02A,b'\x08',b'\x09'))
    def test_wrong_column(self):self.bad(self.changed(0x83C058,b'\x01',b'\x02'),category=7)
    def test_percentage_branch_reversed(self):self.bad(self.changed(0x83FA8B,b'\x74',b'\x75'))
    def test_rate_multiplication_becomes_addition(self):self.bad(self.changed(0x83FADB,b'\x59',b'\x58'))
    def test_state_gate_reversed(self):self.bad(self.changed(0xC9EE7E,b'\x75',b'\x74'),states=(0,None,None))
    def test_wrong_tenth_scale(self):self.bad(self.changed(0x156889C,bytes.fromhex('cdcccc3d'),bytes.fromhex('cdcc4c3e')))


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

"""Byte/growth/bank synchronization evidence with original-byte negatives."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_basic_mastery_sync import read_byte,verify_byte,sync,verify_sync

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_basic_mastery_sync.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def test_source_and_tool_fingerprints(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        for n,d in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/n).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),d,n)

    def test_unsigned_byte_inputs(self):
        self.assertEqual(len(self.e['input']),16)
        for row in self.e['input']:verify_byte(row)
        self.assertEqual({r['writes'][0]['value'] for r in self.e['input']},{0,1,2,60,100,127,128,255})

    def test_growth_and_identity_conditions(self):
        self.assertEqual(len(self.e['events']),128)
        for row in self.e['events']:verify_sync(row)
        for row in self.e['events']:
            f=row['fixture']
            if f['old']==0 or f['new']<=f['old'] or f['profile_kind'] not in (0,6):self.assertEqual(row['writes'],[])

    def test_dual_bank_order_and_restore(self):
        rows=[r for r in self.e['events'] if r['fixture']['dual'] and r['fixture']['bank']==1 and r['writes']]
        self.assertTrue(rows)
        for row in rows:
            self.assertEqual(row['switches'],[0,1,1]);self.assertEqual(row['final_bank'],1)
            self.assertEqual([c['service'] for c in row['calls']],['set_base','rebuild','refresh']*2)
            self.assertEqual([w['bank'] for w in row['writes']],[0,1])

    def test_effective_rank_and_initial_load_not_overclaimed(self):
        for row in self.e['events']:self.assertEqual([pair[1] for pair in row['ranks']],[19,20])
        self.assertTrue(any('effective ranks deliberately remain sentinel' in b for b in self.e['boundaries']))
        self.assertTrue(any('Complete profile-field semantics' in b for b in self.e['boundaries']))
        self.assertTrue(any('First load with old value zero' in b for b in self.e['boundaries']))

    def test_corrupt_write_or_restore_rejected(self):
        row=copy.deepcopy(next(r for r in self.e['events'] if r['writes']));row['writes'][0]['value']+=1
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_sync(row)
        row=copy.deepcopy(next(r for r in self.e['events'] if r['fixture']['bank']==1 and r['switches']));row['final_bank']=0
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_sync(row)


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
        for old in e['input']:
            row,_=read_byte(self.s,**old['fixture']);verify_byte(row);self.assertEqual(row,old)
        for old in e['events']:
            row,_=sync(self.s,**old['fixture']);verify_sync(row);self.assertEqual(row,old)

    def test_signed_instead_of_unsigned_byte(self):
        s=self.changed(0x50B040,b'\xb6',b'\xbe');row,_=read_byte(s,255)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_byte(row)

    def test_equal_value_incorrectly_counts_as_growth(self):
        s=self.changed(0x509980,b'\x7f',b'\x7d');row,_=sync(s,old=60,new=60)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_sync(row)

    def test_zero_old_value_incorrectly_notifies(self):
        s=self.changed(0x509952,b'\x74',b'\x75');row,_=sync(s,old=0,new=60)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_sync(row)

    def test_kind_gate_wrong_value(self):
        s=self.changed(0x9197D0,b'\x06',b'\x05');row,_=sync(s,profile_kind=6)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_sync(row)

    def test_wrong_skill_id(self):
        s=self.changed(0x80A735,b'\xae',b'\xad')
        with self.assertRaisesRegex(ValueError,'Skill setter ABI'):sync(s)

    def test_dual_loop_updates_only_one_bank(self):
        s=self.changed(0x80A718,b'\x02',b'\x01');row,_=sync(s,dual=True)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_sync(row)

    def test_wrong_bank_restore_local(self):
        s=self.changed(0x80A71D,b'\xe4',b'\xe8');row,_=sync(s,dual=True,bank=1)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_sync(row)

    def test_setter_wrongly_writes_effective_rank(self):
        s=self.changed(0x844963,bytes.fromhex('90050000'),bytes.fromhex('9c050000'))
        with self.assertRaisesRegex(ValueError,'Unexpected rank write'):sync(s)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

"""Native second update path: change/decrease, profile write and zero boundary."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_basic_mastery_local_sync import replay,verify

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_basic_mastery_local_sync.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def test_source_and_dependency_fingerprints(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        for n,d in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/n).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),d,n)
        instructions=self.e['static_provenance'][0]['instructions']
        self.assertIn('0074D5AA push 0x7355a0',instructions);self.assertIn('0074D5AF push 0x25',instructions)

    def test_native_fragment_paths_and_inequality_gate(self):
        self.assertEqual(len(self.e['runs']),80)
        for row in self.e['runs']:verify(row)
        for row in self.e['runs']:
            f=row['fixture']
            if f['old']==f['new']:self.assertEqual(row['calls'],[]);self.assertEqual(row['writes'],[])
            elif f['new']>0:self.assertEqual(row['writes'][0],{'target':'profile','field':'0x24','value':f['new']})

    def test_decrease_and_zero_old_value_are_not_growth_only(self):
        rows=[r for r in self.e['runs'] if (r['fixture']['old'],r['fixture']['new']) in ((60,59),(0,1))]
        self.assertEqual(len(rows),16)
        for row in rows:self.assertTrue(any(w['field']=='0x590' for w in row['writes']))

    def test_dual_bank_restore_and_deletion_boundary(self):
        for row in self.e['runs']:
            f=row['fixture']
            if f['new']==0 and f['old']>0:
                self.assertEqual(row['stop'],'0x844892');self.assertEqual(len(row['writes']),1)
                self.assertEqual(row['ranks'],[[3,19],[4,20]])
                self.assertEqual(row['switches'],[0] if f['dual'] else [])
            elif f['dual'] and row['calls']:
                self.assertEqual(row['switches'],[0,1,f['bank']]);self.assertEqual(row['final_bank'],f['bank'])

    def test_prepared_frame_and_rebuild_boundaries_are_explicit(self):
        self.assertTrue(any('prepared-frame stack adjustment is explicit' in b for b in self.e['boundaries']))
        self.assertTrue(any('Effective ranks remain sentinel' in b for b in self.e['boundaries']))
        for row in self.e['runs']:self.assertEqual([r[1] for r in row['ranks']],[19,20])

    def test_corrupt_profile_write_rejected(self):
        row=copy.deepcopy(next(r for r in self.e['runs'] if r['writes']));row['writes'][0]['value']+=1
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

    def test_live_paths_match_archive(self):
        e=json.loads(ARCHIVE.read_text(encoding='utf8'))
        for old in e['runs']:
            row,_=replay(self.s,**old['fixture']);verify(row);self.assertEqual(row,old)

    def test_signed_byte_breaks_equal_high_value(self):
        s=self.changed(0x7357CA,b'\xb6',b'\xbe');row,_=replay(s,old=255,new=255)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_growth_only_gate_loses_decrease(self):
        s=self.changed(0x7357D7,b'\x84',b'\x8f');row,_=replay(s,old=60,new=59)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_profile_write_wrong_field(self):
        s=self.changed(0x735876,b'\x24',b'\x30')
        with self.assertRaisesRegex(ValueError,'Local secure ABI'):replay(s)

    def test_skill_id_wrong(self):
        s=self.changed(0x735A86,b'\xae',b'\xad')
        with self.assertRaisesRegex(ValueError,'Local skill setter ABI'):replay(s)

    def test_dual_loop_omits_second_bank(self):
        s=self.changed(0x735A5C,b'\x02',b'\x01');row,_=replay(s,dual=True)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_restore_reads_packet_byte_instead_of_saved_bank(self):
        s=self.changed(0x735A61,bytes.fromhex('c8fbffff'),bytes.fromhex('ccfbffff'));row,_=replay(s,dual=True,bank=1)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_zero_assignment_is_not_deletion(self):
        s=self.changed(0x84488C,bytes.fromhex('0f85'),bytes.fromhex('0f84'));row,_=replay(s,old=1,new=0)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_refresh_does_not_replace_rebuild(self):
        s=self.changed(0x16F9F04,bytes.fromhex('509ecd00'),bytes.fromhex('00d08400'));row,_=replay(s)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

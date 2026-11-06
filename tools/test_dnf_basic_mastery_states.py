"""State identity/byte predicates, including original-code mutation negatives."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_basic_mastery import replay,verify
from audit_dnf_basic_mastery_states import bindings,flag_primitives,verify_flags

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_basic_mastery_states.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def test_source_and_dependency_fingerprints(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)

    def test_original_skill_ids_pointer_fields_and_virtuals(self):
        expected=[(88,'waveeye','0x6a44','0x16ef3f4'),(82,'kalla','0x6514','0x16ec7ac'),(18,'ghoststep','0x67e8','0x16ec65c')]
        self.assertEqual([(r['skill_id'],r['name'],r['owner_offset'],r['vtable']) for r in self.e['bindings']],expected)
        for r in self.e['bindings']:self.assertEqual(r['slots'],{'0x58':'0x928b70','0x6c':'0x42d640','0x70':'0x42d650'})
        source=self.e['skill_sources'];self.assertEqual(source['lst'],'skill/swordmanskill.lst')
        self.assertEqual([(r['skill_id'],r['path']) for r in source['skills']],[(x[0],f'skill/swordman/{x[1]}.skl') for x in expected])
        self.assertEqual(len({r['sha256'] for r in source['skills']}),3)
        self.assertEqual(len(self.e['static_provenance']),5)

    def test_reset_setter_getter_and_activation_tail(self):
        self.assertEqual(len(self.e['primitives']),3)
        for row in self.e['primitives']:verify_flags(row)
        instructions=[i for b in self.e['blocks'] for i in b['instructions']]
        for line in ('0042D650 mov al, byte ptr [ecx + 0x40]','0042D646 mov byte ptr [ecx + 0x40], al',
                     '009287E8 mov word ptr [ecx + 0x40], ax','00929011 push 1'):
            self.assertIn(line,instructions)

    def test_native_state_gates_short_circuit_on_any_nonzero_byte(self):
        self.assertEqual(len(self.e['runs']),96)
        for row in self.e['runs']:
            verify(row);f=row['fixture']
            self.assertTrue(f['native_states'] and f['cached_skill'] and f['caller'])
            if any(v for v in f['states']):self.assertEqual(row['writes'],[])
        active=[r for r in self.e['runs'] if r['fixture']['states']==[0,0,255]]
        self.assertTrue(active)
        for r in active:self.assertEqual(r['state_calls'],[0,1,2])

    def test_inactive_existing_objects_allow_mastery(self):
        rows=[r for r in self.e['runs'] if r['fixture']['states']==[0,0,0] and r['fixture']['category']==8]
        self.assertEqual(len(rows),2)
        for r in rows:self.assertEqual(r['value'],226);self.assertEqual(len(r['writes']),1)

    def test_corrupt_outputs_rejected_and_boundaries_preserved(self):
        row=copy.deepcopy(self.e['primitives'][0]);row['events'][0]['al']=0
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_flags(row)
        row=copy.deepcopy(self.e['runs'][0]);row['state_calls']=[0]
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)
        self.assertTrue(any('expiration and cleanup remain unresolved' in s for s in self.e['boundaries']))


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
        e=json.loads(ARCHIVE.read_text(encoding='utf8'));self.assertEqual(bindings(self.s),e['bindings'])
        for old in e['primitives']:
            row,_=flag_primitives(self.s,**old['fixture']);verify_flags(row);self.assertEqual(row,old)
        for old in e['runs']:
            row,_=replay(self.s,**old['fixture']);verify(row);self.assertEqual(row,old)

    def test_getter_wrong_adjacent_flag(self):
        s=self.changed(0x42D652,b'\x40',b'\x41');row,_=flag_primitives(s,0)
        with self.assertRaisesRegex(ValueError,'flag mismatch'):verify_flags(row)

    def test_setter_wrong_adjacent_flag(self):
        s=self.changed(0x42D648,b'\x40',b'\x41');row,_=flag_primitives(s,0)
        with self.assertRaisesRegex(ValueError,'flag mismatch'):verify_flags(row)

    def test_reset_leaves_active_byte(self):
        s=self.changed(0x9287EB,b'\x40',b'\x42');row,_=flag_primitives(s,0)
        with self.assertRaisesRegex(ValueError,'reset mismatch'):verify_flags(row)

    def test_activation_tail_writes_inactive(self):
        s=self.changed(0x929012,b'\x01',b'\x00');row,_=flag_primitives(s,0)
        with self.assertRaisesRegex(ValueError,'activation mismatch'):verify_flags(row)

    def test_wrong_original_skill_id(self):
        s=self.changed(0xCD31EA,b'\x58',b'\x57')
        with self.assertRaisesRegex(ValueError,'binding mismatch'):bindings(s)

    def test_wrong_owner_pointer_store(self):
        s=self.changed(0xCA4E79,bytes.fromhex('e8670000'),bytes.fromhex('ec670000'))
        with self.assertRaisesRegex(ValueError,'binding mismatch'):bindings(s)

    def test_wrong_virtual_slot_target(self):
        s=self.changed(0x16EF464,bytes.fromhex('50d64200'),bytes.fromhex('40d64200'))
        with self.assertRaisesRegex(ValueError,'binding mismatch'):bindings(s)

    def test_eligibility_reads_entire_eax_instead_of_al(self):
        s=self.changed(0xC9EE7C,bytes.fromhex('84c0'),bytes.fromhex('85c0'))
        row,_=replay(s,caller=True,cached_skill=True,native_states=True,states=(0,0,0))
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

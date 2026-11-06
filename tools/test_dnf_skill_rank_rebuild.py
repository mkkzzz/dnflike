"""Original effective-rank rebuilding and ghostpowerup regression evidence."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_skill_rank_rebuild import replay,verify,ghost_bonus,verify_ghost,ghost_source

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_skill_rank_rebuild.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def test_fingerprints(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        for name,sha in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),sha,name)

    def test_generic_paths_to_return(self):
        self.assertEqual(len(self.e['runs']),58)
        for row in self.e['runs']:verify(row)

    def test_ordered_clamps_cannot_be_replaced_by_total_delta(self):
        rows=[r for r in self.e['runs'] if r['fixture']['rows'] in ([[11,174,50],[11,174,-50]],[[11,174,-50],[11,174,50]])]
        self.assertEqual([r['effective'] for r in rows],[50,50,60,60])

    def test_ghost_source_targets_and_native_paths(self):
        source=self.e['ghost_source']
        self.assertEqual(source['sha256'],'82c42036e33e71cf28b96b4aea94b3a3f3ae47f6ce4e9cb429feb8c6af09da17')
        self.assertEqual(source['static_data'],[5,25,36,41,84,75,82])
        self.assertEqual(len(self.e['ghost_runs']),36)
        for row in self.e['ghost_runs']:verify_ghost(row,source['static_data'])

    def test_compiler_reads_source_targets_and_drops_invented_bonus(self):
        from build_dnf_skill_runtime import build_skill_definition
        catalog=json.loads((ROOT/'game_dnf/data/skill_catalog.json').read_text(encoding='utf8'))
        skill=next(s for s in catalog['skills'] if s['key']=='ghostpowerup')
        pack=json.loads((ROOT/'game_dnf/assets_local/content/combat_content.json').read_text(encoding='utf8'))
        record=pack['records'][skill['path']];actual=build_skill_definition(skill,record)
        self.assertEqual(actual['skill_rank_bonus_ids'],self.e['ghost_source']['static_data'])
        self.assertNotIn('skill_level_bonus',actual);self.assertNotIn('skill_damage_bonus',actual)
        with self.assertRaisesRegex(ValueError,'source static'):build_skill_definition(skill,{'decoded':{}})
        altered=copy.deepcopy(record)
        if 'static_data' in altered['decoded'].get('dungeon',{}):altered['decoded']['dungeon']['static_data']=[84,5]
        else:altered['decoded']['static_data']=[84,5]
        self.assertEqual(build_skill_definition(skill,altered)['skill_rank_bonus_ids'],[84,5])
        runtime=json.loads((ROOT/'game_dnf/data/skill_runtime.json').read_text(encoding='utf8'))['skills']['ghostpowerup']
        self.assertEqual(runtime['skill_rank_bonus_ids'],actual['skill_rank_bonus_ids'])

    def test_boundaries_and_corrupt_rank_rejection(self):
        self.assertTrue(any('equipment acquisition services return empty' in x for x in self.e['boundaries']))
        self.assertTrue(any('905E90/908510' in x for x in self.e['boundaries']))
        row=copy.deepcopy(self.e['runs'][0]);row['effective']+=1
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)


@unittest.skipUnless(args.client,'optional original-source replay')
class Live(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from audit_dnf_particle_axis import AxisEvaluator
        cls.s=AxisEvaluator(args.client.read_bytes());cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def changed(self,address,expected,replacement):
        self.assertEqual(self.s.source_bytes(address,len(expected)),expected)
        source=copy.copy(self.s);data=bytearray(source.raw)
        sec=next(s for s in source.sections if s['rva']<=address-0x400000<s['rva']+s['bytes'])
        offset=sec['offset']+address-0x400000-sec['rva'];data[offset:offset+len(replacement)]=replacement
        source.raw=bytes(data);return source

    def test_live_generic_and_ghost_paths(self):
        for old in self.e['runs']:
            row,_=replay(self.s,**old['fixture']);verify(row);self.assertEqual(row,old)
        for old in self.e['ghost_runs']:
            row,_=ghost_bonus(self.s,self.e['ghost_source']['static_data'],**old['fixture']);verify_ghost(row,self.e['ghost_source']['static_data']);self.assertEqual(row,old)
        self.assertEqual(ghost_source(),self.e['ghost_source'])

    def test_global_upper_clamp_reversed(self):
        s=self.changed(0x861F3F,b'\x7c',b'\x7f');row,_=replay(s,bonus=3)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_list_lower_clamp_zero(self):
        s=self.changed(0x84530B,bytes.fromhex('01000000'),bytes(4));row,_=replay(s,rows=[[11,174,-100]])
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_list_upper_clamp_reversed(self):
        s=self.changed(0x845317,b'\x7c',b'\x7f');row,_=replay(s,rows=[[11,174,1]])
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_common_class_wildcard_changed(self):
        s=self.changed(0x84B5E3,b'\x0b',b'\x00');row,_=replay(s,rows=[[11,174,1]])
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_id_exclusion_lower_bound_changed(self):
        s=self.changed(0x9044AB,bytes.fromhex('c8000000'),bytes.fromhex('c9000000'));row,_=replay(s,skill_id=200,bonus=3)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_global_mode_flag_gate_reversed(self):
        s=self.changed(0x861EF8,b'\x75',b'\x74');row,_=replay(s,bonus=3,flag=1,mode15=True)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row)

    def test_ghost_unlearned_gate_removed(self):
        s=self.changed(0xCD9EEC,b'\x7e',b'\x7c');row,_=ghost_bonus(s,self.e['ghost_source']['static_data'],rank=0)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_ghost(row,self.e['ghost_source']['static_data'])

    def test_ghost_cap_equal_allowed(self):
        s=self.changed(0xCD9F07,b'\x7d',b'\x7f');row,_=ghost_bonus(s,self.e['ghost_source']['static_data'],rank=50)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_ghost(row,self.e['ghost_source']['static_data'])

    def test_ghost_decrement_instead_of_increment(self):
        s=self.changed(0xCD9F2F,b'\x42',b'\x4a');row,_=ghost_bonus(s,self.e['ghost_source']['static_data'])
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_ghost(row,self.e['ghost_source']['static_data'])


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

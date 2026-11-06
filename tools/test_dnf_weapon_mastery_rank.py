"""Skill-27 source columns and original effective-rank caller regressions."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_weapon_mastery_rank import replay,verify,skill_source

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_weapon_mastery_rank.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def test_fingerprints(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        for name,sha in self.e['tools_sha256'].items():self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),sha,name)

    def test_source_and_native_paths(self):
        s=self.e['skill_source'];self.assertEqual(s['sha256'],'b12c13d26fe706e443e5b2c05c3eab6fff34eec971eeb1621774061f1421fd13')
        self.assertEqual(s['static_data'],[12,13,14,15,4]);self.assertEqual(s['columns'],5);self.assertEqual(len(s['rows']),50)
        self.assertEqual(s['rows'][0],[3,3,3,3,2]);self.assertEqual(s['rows'][-1],[52,52,52,52,51])
        self.assertEqual(len(self.e['runs']),126)
        for row in self.e['runs']:verify(row,s['static_data'])

    def test_ceiling_is_precondition_not_final_clamp(self):
        rows=[r for r in self.e['runs'] if r['fixture']['passive']==1 and r['fixture']['rank']==49 and r['fixture']['values']==[3,3,3,3,2]]
        self.assertEqual(len(rows),2)
        for r in rows:self.assertEqual(r['levels'][1:],[[12,52],[13,52],[14,52],[15,52],[4,51]])

    def test_unlearned_and_disabled_do_not_write(self):
        for row in self.e['runs']:
            f=row['fixture']
            if f['passive']<=0 or f['rank']<=0 or f['rank']>=f['ceiling']:self.assertEqual(row['writes'],[])

    def test_builder_copies_original_columns_and_removes_learning_adapter(self):
        from build_dnf_skill_runtime import build_skill_definition
        c=json.loads((ROOT/'game_dnf/data/skill_catalog.json').read_text(encoding='utf8'))
        skill=next(s for s in c['skills'] if s['id']==27)
        pack=json.loads((ROOT/'game_dnf/assets_local/content/combat_content.json').read_text(encoding='utf8'))
        record=pack['records'][skill['path']];definition=build_skill_definition(skill,record)
        self.assertEqual(definition['skill_rank_bonus_ids'],self.e['skill_source']['static_data'])
        self.assertEqual(definition['skill_rank_bonus_rows'],self.e['skill_source']['rows'])
        for k in ('mastery_levels_per_rank','mastery_fields','mastery_bonus'):self.assertNotIn(k,definition)
        runtime=json.loads((ROOT/'game_dnf/data/skill_runtime.json').read_text(encoding='utf8'))['skills']['weapon_mastery_up']
        self.assertEqual(runtime['skill_rank_bonus_rows'],definition['skill_rank_bonus_rows'])
        for values in ([],[4,1,2,3,4],[5,1,2,3,4,5],[5,1,2,3,4,'5']):
            altered=copy.deepcopy(record);context=altered['decoded'].get('dungeon',altered['decoded']);context['level_info']=values
            with self.assertRaisesRegex(ValueError,'source level'):build_skill_definition(skill,altered)

    def test_boundaries_and_corruption(self):
        self.assertTrue(any('908770 protected values are ABI inputs' in b for b in self.e['boundaries']))
        row=copy.deepcopy(self.e['runs'][0]);row['levels'][1][1]+=1
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row,self.e['skill_source']['static_data'])


@unittest.skipUnless(args.client,'optional original-source replay')
class Live(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from audit_dnf_particle_axis import AxisEvaluator
        cls.s=AxisEvaluator(args.client.read_bytes());cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'));cls.ids=cls.e['skill_source']['static_data']

    def changed(self,address,expected,replacement):
        self.assertEqual(self.s.source_bytes(address,len(expected)),expected)
        s=copy.copy(self.s);raw=bytearray(s.raw);sec=next(q for q in s.sections if q['rva']<=address-0x400000<q['rva']+q['bytes'])
        offset=sec['offset']+address-0x400000-sec['rva'];raw[offset:offset+len(replacement)]=replacement;s.raw=bytes(raw);return s

    def test_live_source_paths(self):
        self.assertEqual(skill_source(),self.e['skill_source'])
        for old in self.e['runs']:
            row,_=replay(self.s,self.ids,**old['fixture']);verify(row,self.ids);self.assertEqual(row,old)

    def test_disabled_passive_gate_removed(self):
        s=self.changed(0xCD9F5E,bytes.fromhex('0f8e'),bytes.fromhex('0f8c'));row,_=replay(s,self.ids,passive=0)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row,self.ids)

    def test_unlearned_target_gate_removed(self):
        s=self.changed(0xCD9FE7,b'\x7e',b'\x7c');row,_=replay(s,self.ids,rank=0)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row,self.ids)

    def test_cap_equal_allowed(self):
        s=self.changed(0xCDA004,b'\x7d',b'\x7f');row,_=replay(s,self.ids,rank=50)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row,self.ids)

    def test_wrong_column_local(self):
        s=self.changed(0xCDA008,b'\xfc',b'\xf8')
        with self.assertRaisesRegex(ValueError,'value wrapper ABI'):replay(s,self.ids)

    def test_wrapper_passes_owner_instead_of_rank(self):
        s=self.changed(0x9095DE,b'\x51',b'\x50')
        with self.assertRaisesRegex(ValueError,'value wrapper ABI'):replay(s,self.ids)

    def test_subtract_instead_of_add(self):
        s=self.changed(0xCDA034,b'\x03',b'\x2b');row,_=replay(s,self.ids)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row,self.ids)

    def test_base_rank_write_instead_of_effective(self):
        s=self.changed(0xCDA03E,bytes.fromhex('9c05'),bytes.fromhex('9005'))
        with self.assertRaisesRegex(ValueError,'secure ABI'):replay(s,self.ids)

    def test_wrong_vector_stride_skips_targets(self):
        s=self.changed(0xCD9F8C,bytes.fromhex('d1fa'),bytes.fromhex('d3fa'));row,_=replay(s,self.ids)
        with self.assertRaisesRegex(ValueError,'mismatch'):verify(row,self.ids)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

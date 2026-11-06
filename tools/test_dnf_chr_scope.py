"""Native CHR scope dispatch and negative pointer-routing checks."""
import argparse,copy,hashlib,json,sys,unittest
from pathlib import Path
from audit_dnf_chr_scope import replay,verify
p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,rest=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_chr_scope.json'
class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf-8'))
    def test_fingerprints(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        for name,sha in self.e['tools_sha256'].items():self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),sha)
    def test_scope_sequences(self):
        self.assertEqual(len(self.e['cases']),18)
        for row in self.e['cases']:verify(row)
    def test_wrong_parent_is_rejected(self):
        row=copy.deepcopy(self.e['cases'][1]);row['states'][1]['selected_name']='0x530'
        with self.assertRaises(ValueError):verify(row)
    def test_distinct_nested_scopes(self):
        rows=self.e['cases'][1:7]
        self.assertEqual(len({r['states'][2]['slots'][0] for r in rows}),6)
        for row in rows:self.assertNotEqual(row['states'][2]['slots'][0],row['states'][3]['slots'][0])
    def test_boundaries(self):
        self.assertTrue(any('comparison is an explicit' in x for x in self.e['boundaries']))
        self.assertTrue(any('Growth formulas' in x for x in self.e['boundaries']))
    def test_published_pack_retains_each_job_awakening(self):
        pack=json.loads((ROOT/'game_dnf/assets_local/content/combat_content.json').read_text(encoding='utf-8'))
        record=pack['records']['character/swordman/swordman.chr']
        groups=record['decoded']['stat_groups']
        self.assertNotIn('awakening_1',groups)
        self.assertNotIn('awakening_name_refs',record['decoded'])
        for job,hp,mp,skills in [(2,50,20,[91,1]),(3,40,30,[89,1]),(4,55,15,[90,1]),(5,45,25,[92,1]),(6,55,15,[])]:
            for stage in (1,2):
                with self.subTest(job=job,stage=stage):
                    group=groups['growtype_'+str(job)]
                    result=group.get('awakenings',{}).get('awakening_'+str(stage),{})
                    self.assertEqual((result.get('hp_max'),result.get('mp_max'),result.get('awakening_skill')),(hp,mp,skills if stage==1 else []))
                    self.assertEqual(len(group.get('awakening_name_refs',[])),4)
@unittest.skipUnless(args.client,'optional read-only client replay')
class Live(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from audit_dnf_particle_axis import AxisEvaluator
        cls.source=AxisEvaluator(args.client.read_bytes())
    def changed(self,address,old,new):
        self.assertEqual(self.source.source_bytes(address,len(old)),old)
        source=copy.copy(self.source);raw=bytearray(source.raw)
        sec=next(s for s in source.sections if s['rva']<=address-0x400000<s['rva']+s['bytes'])
        off=sec['offset']+address-0x400000-sec['rva'];raw[off:off+len(new)]=new;source.raw=bytes(raw);return source
    def test_original_sequences(self):
        for expected in json.loads(ARCHIVE.read_text())['cases']:
            row,_=replay(self.source,expected['order'],expected['poison']);verify(row);self.assertEqual(row,expected)
    def test_wrong_job_awakening_base(self):
        source=self.changed(0x129c5e1,bytes.fromhex('900a0000'),bytes.fromhex('30090000'))
        row,_=replay(source,['[growtype 3]','[awakening 1]'])
        with self.assertRaises(ValueError):verify(row)
    def test_second_awakening_aliases_first(self):
        source=self.changed(0x129c792,b'\x57',b'\x00')
        row,_=replay(source,['[growtype 3]','[awakening 2]'])
        with self.assertRaises(ValueError):verify(row)
    def test_wrong_job_name_pointer(self):
        source=self.changed(0x129c5e7,bytes.fromhex('70050000'),bytes.fromhex('30050000'))
        row,_=replay(source,['[growtype 3]','[awakening name]'])
        with self.assertRaises(ValueError):verify(row)
if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+rest)

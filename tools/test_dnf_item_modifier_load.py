"""Original equipment skill-data decoding, source inventory and byte mutations."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_item_modifier_load import replay,verify,validate,CLASSES,MODES,CATEGORIES
from audit_dnf_item_skill_modifier import verify as verify_modifier
from audit_dnf_native_strings import ENGINE_SHA

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_item_modifier_load.json'


class Archive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def test_identity(self):
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'],'8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)

    def test_paths_and_caller_clobber(self):
        self.assertEqual(len(self.e['runs']),168)
        for row in self.e['runs']:verify(row)
        for a,b in zip(self.e['runs'][::2],self.e['runs'][1::2]):
            self.assertFalse(a['fixture']['poison']);self.assertTrue(b['fixture']['poison'])
            for key in ('records','events','classes','preserved','stack'):self.assertEqual(a[key],b[key])

    def test_native_registration_and_decoders(self):
        self.assertEqual(self.e['tag']['text'],'[skill data up]')
        self.assertEqual(self.e['tag']['enum'],0x1941)
        self.assertEqual(self.e['tag']['map'],'0x1d8b55c')
        provenance=[l for b in self.e['static_provenance'] for l in b['instructions']]
        self.assertIn('0126E750 mov dword ptr [ebp - 0x150], 0x1941',provenance)
        row=next(r for r in self.e['runs'] if r['case']=='field:0:[swordman]')
        events=[e for e in row['events'] if e['kind']=='native_registration']
        self.assertEqual({e['tag'] for e in events if e['map']=='0x1d79130'},set(MODES))
        self.assertEqual({e['tag'] for e in events if e['map']=='0x1d79170'},set(CATEGORIES))
        self.assertEqual(row['classes'],CLASSES)
        lines=[l for b in self.e['blocks'] for l in b['instructions']]
        self.assertIn('01270AD5 lea ecx, [esi + 0x4a0]',lines)
        self.assertIn('0121F6DB add dword ptr [esi + 8], 0x34',lines)
        self.assertIn('0121F587 mov dword ptr [ebp - 0x5c], ebx',lines)

    def test_unknown_class_is_wildcard_but_unknown_mode_is_17(self):
        runs={r['case']:r for r in self.e['runs']}
        self.assertEqual(runs['field:0:[theif]']['records'][0][0],11)
        self.assertEqual(runs['field:2:[all]]']['records'][0][4],17)
        self.assertEqual(runs['field:2:[all]']['records'][0][4],20)
        self.assertEqual(runs['field:2:[dungeon type]']['records'][0][4],19)
        self.assertEqual(runs['field:2:[pvp type]']['records'][0][4],18)

    def test_operator_and_float_truncation(self):
        runs={r['case']:r for r in self.e['runs']}
        self.assertEqual(runs['field:5:+']['records'][0][5],0)
        for op in ('-','%','*',''):self.assertEqual(runs[f'field:5:{op}']['records'][0][5],1)
        for category in CATEGORIES:
            row=runs[f'float:{category}']['records'][0]
            self.assertEqual(row[1],20);self.assertEqual(row[6],-10)
            self.assertEqual(row[2],-3 if category in ('[static]','[level]','[skill consume item]') else 0)
        self.assertEqual(len(runs['multi']['records']),22)

    def test_inventory_and_coverage_do_not_repair_malformed_fields(self):
        inv=self.e['inventory']
        self.assertEqual((inv['files_with_field'],inv['fields'],inv['aligned_supported_rows']),(13294,13788,55335))
        self.assertEqual(len(inv['unreplayed_fields']),14)
        self.assertEqual(inv['counts']['operator'],{'%':51069,'+':4265,'-':1})
        self.assertEqual(inv['counts']['types']['7,2,7,7,2,7,4'],3)
        for field in inv['unreplayed_fields']:
            self.assertNotEqual(len(field['values'])%7,0)
            with self.assertRaises(ValueError):validate(field['values'])
        for name,index in (('class',0),('mode',2),('category',3),('operator',5)):
            seen={s['values'][j+index] for s in inv['samples'] for j in range(0,len(s['values']),7)}
            self.assertEqual(seen,set(inv['counts'][name]))

    def test_source_records_feed_original_aggregator(self):
        by_case={r['case']:r for r in self.e['runs']}
        self.assertEqual(len(self.e['applications']),237)
        for app in self.e['applications']:
            row=app['run'];verify_modifier(row)
            self.assertEqual(row['fixture']['banks'],[by_case[app['case']]['records'],[]])
            self.assertEqual(row['fixture']['mode'],3)
            self.assertEqual(row['fixture']['value'],100)

    def test_fixture_rejects_unmodeled_input(self):
        for v in (['[all]'],['[all]',20,'[all]','[missing]',0,'+',1],
                  ['[all]',20,'[all]','[level]',0,'+',float('nan')]):
            with self.assertRaises(ValueError):validate(v)


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

    def test_all_source_paths_match_archive(self):
        e=json.loads(ARCHIVE.read_text(encoding='utf8'))
        for archived in e['runs']:
            row,_=replay(self.s,**archived['fixture']);verify(row);row['case']=archived['case']
            self.assertEqual(row,archived)

    def test_all_original_applications_match_archive(self):
        from audit_dnf_item_skill_modifier import replay as modify
        e=json.loads(ARCHIVE.read_text(encoding='utf8'))
        for application in e['applications']:
            archived=application['run'];row,_=modify(self.s,**archived['fixture']);verify_modifier(row)
            self.assertEqual(json.loads(json.dumps(row)),archived)

    def test_percentage_becomes_fixed_add(self):
        s=self.changed(0x121F5E6,b'\x1b\xc0',b'\x31\xc0')
        row,_=replay(s,['[swordman]',20,'[all]','[level]',3,'%',10])
        with self.assertRaisesRegex(ValueError,'records'):verify(row)

    def test_cooltime_becomes_mp(self):
        s=self.changed(0x121F504,b'\x02',b'\x03')
        row,_=replay(s,['[swordman]',20,'[all]','[cooltime]',3,'+',10])
        with self.assertRaisesRegex(ValueError,'records'):verify(row)

    def test_unknown_class_loses_wildcard(self):
        s=self.changed(0x1219156,b'\x0b',b'\x0c')
        row,_=replay(s,['[theif]',20,'[all]','[level]',3,'+',10])
        with self.assertRaisesRegex(ValueError,'records'):verify(row)

    def test_all_mode_becomes_dungeon_type(self):
        s=self.changed(0x121DF08,b'\x14',b'\x13')
        row,_=replay(s,['[swordman]',20,'[all]','[level]',3,'+',10])
        with self.assertRaisesRegex(ValueError,'records'):verify(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

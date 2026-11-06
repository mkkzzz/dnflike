"""Original archive cases versus compiler; optional live source replay."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_basic_mastery_pipeline import parse_bonus,verify_parser
from compile_dnf_content import decode_fields

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_atk_damage_bonus.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def test_source_and_compiler_dependencies(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        for n,d in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/n).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),d,n)

    def test_archive_field_census(self):
        self.assertEqual(self.e['census']['atk_files'],6089)
        self.assertEqual(self.e['census']['top_level_fields'],3281)
        self.assertEqual(self.e['census']['float_files'],42)
        self.assertEqual(self.e['census']['repeated_field_files'],5)
        self.assertEqual(len(self.e['cases']),47)
        self.assertEqual(len({r['path'] for r in self.e['cases']}),47)

    def test_all_saved_native_results_match_current_compiler(self):
        for item in self.e['cases']:
            with self.subTest(path=item['path']):
                fields=[{'tag':'[damage bonus]','values':[v],'offset':o} for v,o in zip(item['values'],item['offsets'])]
                original=copy.deepcopy(fields);decoded,_,_=decode_fields('atk',fields,item['path'])
                self.assertEqual(fields,original)
                self.assertIs(type(decoded['damage_bonus']),int)
                self.assertEqual(decoded['damage_bonus'],item['decoded'])
                for row in item['runs']:verify_parser(row);self.assertEqual(row['value'],decoded['damage_bonus'])

    def test_repeat_overwrite_and_negative_truncation_examples(self):
        cases={r['path']:r for r in self.e['cases']}
        short=cases['character/swordman/attackinfo/weaponcomboshort1.atk']
        self.assertEqual(short['values'],[20,0]);self.assertEqual(short['decoded'],0)
        self.assertEqual(short['runs'][0]['writes'],[{'offset':'0x24','value':20},{'offset':'0x24','value':0}])
        jump=cases['monster/newmonsters/event/seria/attackinfo/jumpattack.atk']
        self.assertEqual(jump['values'],[-97.5]);self.assertEqual(jump['decoded'],-97)

    def test_shipped_content_pack_uses_native_results_and_retains_raw_fields(self):
        pack=json.loads((ROOT/'game_dnf/assets_local/content/combat_content.json').read_text(encoding='utf8'))
        covered=[]
        for item in self.e['cases']:
            if item['path'] not in pack['records']:continue
            record=pack['records'][item['path']];covered.append(item['path'])
            self.assertEqual(record['source']['sha256'],item['sha256'])
            self.assertEqual(record['decoded']['damage_bonus'],item['decoded'])
            self.assertIs(type(record['decoded']['damage_bonus']),int)
            self.assertEqual([f['values'][0] for f in record['raw'] if f['tag']=='[damage bonus]'],item['values'])
        for path in ('character/swordman/attackinfo/weaponcomboshort1.atk','character/swordman/dsattackinfo/weaponcomboshort1.atk'):
            self.assertIn(path,covered)

    def test_invalid_values_rejected_and_missing_source_not_invented(self):
        for value in (None,'20',float('nan'),float('inf'),2147483648.,-2147483649):
            with self.assertRaisesRegex(ValueError,'verified signed integer domain'):
                decode_fields('atk',[{'tag':'[damage bonus]','values':[value],'offset':2}],'fixture.atk')
        self.assertEqual(decode_fields('atk',[],'empty.atk')[0],{})

    def test_corrupt_order_or_write_history_rejected(self):
        row=copy.deepcopy(next(c['runs'][0] for c in self.e['cases'] if len(c['values'])>1))
        row['writes'].pop()
        with self.assertRaisesRegex(ValueError,'mismatch'):verify_parser(row)


@unittest.skipUnless(args.client,'optional original-source replay')
class Live(unittest.TestCase):
    def test_original_parser_sequences_match_archive(self):
        from audit_dnf_particle_axis import AxisEvaluator
        source=AxisEvaluator(args.client.read_bytes())
        e=json.loads(ARCHIVE.read_text(encoding='utf8'))
        for item in e['cases']:
            for old in item['runs']:
                row,_=parse_bonus(source,**old['fixture']);verify_parser(row);self.assertEqual(row,old)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

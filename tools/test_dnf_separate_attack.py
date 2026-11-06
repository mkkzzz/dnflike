"""Original separate-attack mode mapping and shipped equipment regression."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_separate_attack import replay,verify
from audit_dnf_fixed_base import replay as consume,verify as verify_consumer
from dnf_equipment_stats import separate_attack,apply_separate_attack
from migrate_dnf_separate_attack import prepare

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'docs/reports/ws2/2026-11/native_separate_attack.json'


class Mapping(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads(ARCHIVE.read_text(encoding='utf8'))

    def test_source_identity_and_native_paths(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)
        self.assertEqual(len(self.e['runs']),16)
        for row in self.e['runs']:verify(row)
        for a,b in zip(self.e['runs'][::2],self.e['runs'][1::2]):
            self.assertEqual(a['parsed'],b['parsed']);self.assertEqual(a['accumulated'],b['accumulated'])
        self.assertEqual(self.e['tags'],{'0x185cdac':'[separate attack]','0x18627b4':'[separate rate]'})

    def test_consumer_selects_mode_not_damage_category(self):
        self.assertEqual(len(self.e['consumers']),18)
        for application in self.e['consumers']:
            row=application['run'];verify_consumer(row)
            # Synthetic table: bank0 column1 level40 is 1217. Neutral remaining
            # modifiers isolate the original first/second accumulator selection.
            selected=application['accumulated'][int(row['fixture']['mode'] in (4,5))]
            self.assertEqual(row['value'],1217+selected)

    def test_both_compilers_share_the_checked_mapping(self):
        from build_dnf_native_catalog import compile_item,LISTS
        fields={'[equipment type]':['[ring]'],'[icon]':['Item/test.img',0],'[field image]':['Item/test.img',0],
                '[separate attack]':[56,34]}
        _,gear,_,reasons=compile_item(24211,LISTS['equipment'],'equipment/test.equ','sha',fields,{'[name]':'测试戒指'})
        self.assertFalse(reasons)
        self.assertEqual(gear['stats']['independent_attack'],56)
        self.assertNotIn('magical_independent_attack',gear['stats'])
        self.assertEqual(gear['native_separate_attack'],{'default':56,'modes_4_5':34})
        text=(ROOT/'tools/build_dnf_progression_data.py').read_text(encoding='utf8')
        self.assertIn('apply_separate_attack(definition,',text)
        fields['[separate attack]']=[1,2,3,4]
        self.assertIn('separate_attack_grammar',compile_item(1,LISTS['equipment'],'equipment/test.equ','sha',fields,{'[name]':'测试'})[3])

    def test_shipped_definitions_match_retained_source_and_checksum(self):
        updates,affected,stale=prepare()
        self.assertFalse(stale);self.assertFalse(updates)
        self.assertEqual(len(affected),157)
        self.assertEqual(sum(r['file']=='numbers' for r in affected),2)
        for r in affected:self.assertEqual(r['mapping']['default'],r['values'][0])

    def test_signed_float_conversion_and_alternate_grammar(self):
        self.assertEqual(separate_attack([3.9,-2.9]),[3,-2])
        self.assertEqual(separate_attack([16777217.0,0]),[16777216,0])
        for values in ([1],[1,2,3,4],[True,2],[float('nan'),2],[2147483647.0,0]):
            with self.assertRaises(ValueError):separate_attack(values)
        gear={'stats':{'strength':4,'physical_independent_attack':26,'magical_independent_attack':14},'stat_ranges':{}}
        apply_separate_attack(gear,[26,14]);first=copy.deepcopy(gear);apply_separate_attack(gear,[26,14])
        self.assertEqual(gear,first);self.assertEqual(gear['stats'],{'strength':4,'independent_attack':26})


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

    def test_original_parser_accumulator_and_consumers(self):
        e=json.loads(ARCHIVE.read_text(encoding='utf8'))
        for archived in e['runs']:
            row,_=replay(self.s,**archived['fixture']);verify(row);self.assertEqual(row,archived)
        for a in e['consumers']:
            row,_=consume(self.s,**a['run']['fixture']);verify_consumer(row)
            self.assertEqual(json.loads(json.dumps(row)),a['run'])

    def test_first_accumulator_reads_second_field(self):
        row,_=replay(self.changed(0x77BDDB,b'\x48',b'\x54'),[26,14])
        with self.assertRaisesRegex(ValueError,'mapping'):verify(row)

    def test_integer_accumulation_changes_sign(self):
        # 77BE0B: add eax,[ebp-1C] -> sub eax,[ebp-1C].
        row,_=replay(self.changed(0x77BE0B,b'\x03',b'\x2b'),[26,14])
        with self.assertRaisesRegex(ValueError,'mapping'):verify(row)

    def test_mode_three_wrongly_uses_second_value(self):
        row,_=consume(self.changed(0x7528A4,b'\x04',b'\x03'),mode=3)
        with self.assertRaisesRegex(ValueError,'arithmetic'):verify_consumer(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

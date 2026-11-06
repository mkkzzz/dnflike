"""Native SKL modifier field routing, real inventory and byte counterfactuals."""
import argparse
import collections
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_skill_modifier_load import replay,verify,RECORD
from audit_dnf_native_strings import ENGINE_SHA

p=argparse.ArgumentParser(add_help=False);p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]


class Archive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.e=json.loads((ROOT/'docs/reports/ws2/2026-11/native_skill_modifier_load.json').read_text(encoding='utf8'))

    def test_source_and_tool_identity(self):
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'],'8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)

    def test_replay_matrix_and_clobber(self):
        runs=self.e['runs'];self.assertEqual(len(runs),752)
        for row in runs:verify(row)
        for a,b in zip(runs[::2],runs[1::2]):
            self.assertFalse(a['fixture']['poison']);self.assertTrue(b['fixture']['poison'])
            for key in ('parsed','runtime_records','runtime_feature','events','registrations'):self.assertEqual(a[key],b[key])

    def test_all_original_field_occurrences_have_replay(self):
        self.assertEqual(self.e['scanned_skl'],2009);self.assertEqual(len(self.e['inventory']),895)
        counts=collections.Counter();ops=collections.Counter();rows={r['case']:r for r in self.e['runs']}
        for item in self.e['inventory']:
            for f in item['fields']:
                counts[f['tag']]+=1
                if f['tag']=='[special level up]':
                    self.assertEqual(f['types'],[2,2,7,2]*(len(f['values'])//4))
                    self.assertEqual(f['values'],rows[f['case']]['fixture']['values'])
                    digest=hashlib.sha256(json.dumps(f['values'],separators=(',',':')).encode()).hexdigest()
                    self.assertEqual(f['case'],digest);ops.update(f['values'][2::4])
                else:self.assertEqual(f['types'],[2])
        self.assertEqual(counts,{'[feature skill index]':449,'[special level up]':606})
        self.assertEqual(ops,{'%':1294,'+':392,'-':41,'*':1})

    def test_unknown_operator_retains_native_constructor_default(self):
        item=next(i for i in self.e['inventory'] if i['path']=='skill/mage/sweetcandybarex.skl')
        field=next(f for f in item['fields'] if '*' in f['values'])
        row=next(r for r in self.e['runs'] if r['case']==field['case'])
        self.assertEqual(row['parsed'],[[1,0,0,0],[1,1,0,0]])

    def test_wave_fields_remain_distinct(self):
        inventory={i['path']:i for i in self.e['inventory']}
        for name,index in (('normalwave',140),('icewave',216),('firewave',212)):
            field=inventory[f'skill/swordman/{name}.skl']['fields'][0]
            self.assertEqual(field['values'],[index])
        fields=inventory['skill/swordman/normalwaveex.skl']['fields']
        self.assertEqual(len(fields),2);self.assertNotEqual(fields[0]['case'],fields[1]['case'])
        # Inventory is not effective mode selection; each source occurrence survives.
        self.assertEqual(fields[0]['values'],[-1,0,'%',8,-1,1,'+',8,-1,2,'%',8])
        self.assertEqual(fields[1]['values'],[-1,0,'%',0,-1,1,'+',0,-1,2,'%',0])

    def test_original_offsets_and_caller_record(self):
        lines=[l for b in self.e['blocks'] for l in b['instructions']]
        for line in ('012CE75D add ecx, 0x520','012CE901 lea ecx, [ebx + 0x540]',
                     '012CB501 add dword ptr [edi + 8], 0x28','00913CDA lea ecx, [esi + 0x518]',
                     '00913D30 lea ecx, [esi + 0x530]'):
            self.assertIn(line,lines)
        static=[l for b in self.e['static_provenance'] for l in b['instructions']]
        self.assertIn('009122F4 lea eax, [ebp - 0x7bc]',static)

    def test_actual_wave_fields_feed_native_modifier(self):
        from audit_dnf_skill_modifier import verify as verify_modifier
        self.assertEqual(self.e['wave_index']['entries'],{'140':'skill/swordman/normalwaveex.skl',
            '212':'skill/swordman/firewaveexp.skl','216':'skill/swordman/icewaveexp.skl'})
        rows={r['case']:r for r in self.e['runs']};apps=self.e['modifier_applications']
        self.assertEqual(len(apps),10)
        for app in apps:
            previous=100.0
            for phase,call in zip((1,0),app['calls']):
                verify_modifier(call);f=call['fixture']
                self.assertEqual(f['records'],rows[app['case']]['runtime_records'])
                self.assertEqual(f['phase'],phase);self.assertEqual(f['value'],previous);self.assertEqual(f['rank'],2)
                previous=call['value']
            self.assertEqual(app['value'],previous)
        ice={a['column']:a['value'] for a in apps if a['path'].endswith('/icewaveexp.skl')}
        fire={a['column']:a['value'] for a in apps if a['path'].endswith('/firewaveexp.skl')}
        self.assertEqual(ice,{1:106,3:130});self.assertEqual(fire,{0:120,1:120})


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

    def test_original_sample_covers_all_operators_flags_and_empty(self):
        for values in ([],[-1,0,'+',3,0,1,'-',2,-2,2,'%',8],[-1,0,'*',0]):
            for poison in (False,True):
                row,_=replay(self.s,values,poison=poison);verify(row)

    def test_wrong_feature_field(self):
        row,_=replay(self.changed(0x12CE75F,b'\x20\x05\x00\x00',b'\x24\x05\x00\x00'),[-1,0,'+',3])
        with self.assertRaisesRegex(ValueError,'feature'):verify(row)

    def test_wrong_category_flag(self):
        row,_=replay(self.changed(0x12CE80B,b'\x00',b'\x01'),[0,0,'+',3])
        with self.assertRaisesRegex(ValueError,'record'):verify(row)

    def test_wrong_minus_operator_enum(self):
        row,_=replay(self.changed(0x12CE89C,b'\x01\x00\x00\x00',b'\x02\x00\x00\x00'),[-1,0,'-',3])
        with self.assertRaisesRegex(ValueError,'record'):verify(row)

    def test_wrong_vector_stride(self):
        row,_=replay(self.changed(0x12CB504,b'\x28',b'\x24'),[-1,0,'+',3])
        with self.assertRaisesRegex(ValueError,'record'):verify(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

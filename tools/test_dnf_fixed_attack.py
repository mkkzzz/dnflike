"""Native fixed-attack arithmetic archive; optional original-source counterfactuals."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_fixed_attack import replay, verify, fbits
from audit_dnf_native_strings import ENGINE_SHA, recover_string

p=argparse.ArgumentParser(add_help=False)
p.add_argument('--client',type=Path);p.add_argument('--decoder-dir',type=Path)
args,remaining=p.parse_known_args()
if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
ROOT=Path(__file__).resolve().parents[1]


class Archive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e=json.loads((ROOT/'docs/reports/ws2/2026-11/native_fixed_attack.json').read_text(encoding='utf8'))

    def test_pinned_identity_tools_and_constants(self):
        self.assertEqual(self.e['engine_sha256'],ENGINE_SHA)
        self.assertEqual(self.e['input_source']['input_sha256'],'8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name,digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),digest,name)
        self.assertEqual([int.from_bytes(bytes.fromhex(v['raw']),'little') for v in self.e['constants']],[fbits(100),fbits(.01),fbits(1)])

    def test_matrix_and_register_clobbers(self):
        runs=self.e['runs'];self.assertEqual(len(runs),58)
        for r in runs:verify(r)
        for a,b in zip(runs[::2],runs[1::2]):
            self.assertEqual(a['value'],b['value'])
            self.assertEqual([{k:v for k,v in e.items() if k!='this'} for e in a['events']],
                             [{k:v for k,v in e.items() if k!='this'} for e in b['events']])
        self.assertEqual(runs[0]['value'],583)  # not algebraically simplified 584
        self.assertEqual(next(r['value'] for r in runs if r['fixture']['skill_value']==-125.5),-125)
        self.assertTrue(any(not r['fixture']['has_owner'] and r['value']==0 for r in runs))

    def test_original_truncation_and_optional_divisor(self):
        lines=[line for block in self.e['blocks'] for line in block['instructions']]
        self.assertIn('0090A933 cvttss2si eax, xmm0',lines)
        self.assertIn('0090A89C cmp eax, 0xffff0001',lines)
        self.assertIn('0090A8C6 divss xmm0, xmm1',lines)
        self.assertIn('0090A7FE jge 0x90a813',lines)

    def test_candidate_tables_are_not_a_claim_of_runtime_mapping(self):
        p=self.e['candidate_parameters']
        self.assertEqual(p['path'],'etc/etcparameter.etc')
        self.assertEqual(p['sha256'],'61fe2583df5a6cbf0f33ab8a084d18aca760732441b332128dfcff98c1de0ba4')
        self.assertIn('NOT proved',p['status'])
        self.assertEqual([len(f['values']) for f in p['fields']],[700,700])
        for field in p['fields']:self.assertEqual(field['values'][::7],list(range(1,101)))
        for tag in self.e['native_parameter_tags']:
            value,_=recover_string(bytes.fromhex(tag['raw']),0,2)
            self.assertEqual(value,tag['text'])

    def test_rejects_replacing_original_operation_order_with_simplified_formula(self):
        changed=copy.deepcopy(self.e['runs'][0]);changed['value']=584
        with self.assertRaisesRegex(ValueError,'arithmetic'):verify(changed)

    def test_object_pointer_and_mapped_level_are_distinct(self):
        rows=[r for r in self.e['runs'] if r['fixture']['normalization_object'] and not r['fixture']['poison']]
        self.assertEqual([r['fixture']['mapped_level'] for r in rows],[-1,0,20,40,60])
        for r in rows:
            mapping=next(e for e in r['events'] if e['kind']=='object_level_mapping_fixture')
            self.assertEqual(mapping['args'],[0x60510000])
            self.assertEqual(mapping['value'],r['fixture']['mapped_level'])


@unittest.skipUnless(args.client,'optional original source replay')
class Live(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from audit_dnf_particle_axis import AxisEvaluator
        cls.s=AxisEvaluator(args.client.read_bytes())

    def changed(self,address,raw):
        source=copy.copy(self.s);data=bytearray(source.raw)
        sec=next(s for s in source.sections if s['rva']<=address-0x400000<s['rva']+s['bytes'])
        offset=sec['offset']+address-0x400000-sec['rva'];data[offset:offset+len(raw)]=raw
        source.raw=bytes(data);return source

    def test_coefficient_mutation_changes_actual_source_result(self):
        source=self.changed(0x1559C80,fbits(.02).to_bytes(4,'little'))
        row,_=replay(source)
        self.assertNotEqual(row['value'],583)
        with self.assertRaisesRegex(ValueError,'arithmetic'):verify(row)

    def test_sentinel_mutation_takes_divisor_branch(self):
        source=self.changed(0x90A89D,b'\x02\x00\xff\xff')
        row,_=replay(source)
        self.assertGreater(row['value'],58000)
        with self.assertRaisesRegex(ValueError,'arithmetic'):verify(row)

    def test_live_override_routes_and_negative_truncation(self):
        for parameters in (dict(rank=10,rank_override=2,column=1),dict(normalization_object=0x60510000,mapped_level=20,normalization=1.5,lower_normalization=.75),dict(skill_value=-125.5)):
            row,_=replay(self.s,poison=True,**parameters);verify(row)


if __name__=='__main__':unittest.main(argv=[sys.argv[0]]+remaining)

"""Validate published ice binding evidence without a client or disassembler.

Live replay: audit_dnf_ice_particle_bindings.py <client> --decoder-dir <dir>.
Instruction evaluator tests: test_dnf_native_vm_probe.py --decoder-dir <dir>.
"""
import hashlib
import json
from pathlib import Path
import unittest

from audit_dnf_ice_particle_bindings import decode_immediate
from audit_dnf_native_strings import recover_string, ENGINE_SHA

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT/'docs/reports/ws2/2026-11/native_ice_particle_bindings.json'


class IceParticleEvidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads(EVIDENCE.read_text(encoding='utf8'))

    def test_source_and_tools_are_pinned(self):
        evidence = self.evidence
        self.assertEqual(evidence['engine_sha256'], ENGINE_SHA)
        self.assertTrue(evidence['input_source']['embedded'])
        self.assertEqual(evidence['input_source']['input_sha256'],
                         '8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name, expected in evidence['tools_sha256'].items():
            raw = (ROOT/'tools'/name).read_bytes().replace(b'\r\n', b'\n')
            self.assertEqual(hashlib.sha256(raw).hexdigest(), expected, name)

    def test_encoded_operands_and_strings_reproduce_from_original_bytes(self):
        for operand in self.evidence['operands']:
            address = int(operand['bytecode'], 16)
            raw = bytes.fromhex(operand['raw8'])
            class Source:
                def source_bytes(self, start, size):
                    offset = start-address
                    if offset < 0 or offset+size > len(raw):
                        raise ValueError('Outside archived operand')
                    return raw[offset:offset+size]
            self.assertEqual(decode_immediate(Source(), address), int(operand['decoded'], 16))
            if 'string_bytes' in operand:
                text, size = recover_string(bytes.fromhex(operand['string_bytes']), 0, 2)
                self.assertEqual(size+4, len(bytes.fromhex(operand['string_bytes'])))
                runs = [r for r in self.evidence['runs'] if r['bytecode_operand'] == operand['bytecode']]
                self.assertEqual(len(runs), 2)
                self.assertTrue(all(r['constructor']['filename'] == text for r in runs))

    def test_smoke_and_star_are_not_reversed_and_returns_survive_clobbers(self):
        expected = {'IceWaveParticleSmoke.ptl': '0x1a5f820',
                    'IceWaveParticle.ptl': '0x1a5f824', 'IceWaveParticleStar.ptl': '0x1a5f828'}
        for filename, address in expected.items():
            runs = [r for r in self.evidence['runs'] if r['constructor']['filename'].split('/')[-1] == filename]
            self.assertEqual(len(runs), 2)
            self.assertNotEqual(runs[0]['clobber_fixture'], runs[1]['clobber_fixture'])
            self.assertNotEqual(runs[0]['write']['value'], runs[1]['write']['value'])
            self.assertEqual(runs[0]['trace_sha256'], runs[1]['trace_sha256'])
            for run in runs:
                self.assertEqual(run['write']['address'], address)
                self.assertEqual(run['write']['value'], run['constructor']['return_identity_fixture'])
                self.assertEqual(run['constructor']['callee_stack_pop_bytes'], 8)
                self.assertGreater(run['steps'], 1000)
                self.assertLess(run['steps'], 5000)

    def test_abi_and_reader_instructions_are_archived_with_explicit_boundaries(self):
        instructions = [line for block in self.evidence['blocks'] for line in block['instructions']]
        for line in ('005FEF58 mov edi, ecx', '005FF053 mov eax, edi', '005FF066 ret 8',
                     '00A6FE41 mov ebx, dword ptr [0x1a5f820]',
                     '021A38C8 mov dword ptr [edx], eax', '022050E8 mov dword ptr [edx], eax'):
            self.assertIn(line, instructions)
        self.assertTrue(any('not a live allocation' in s for s in self.evidence['boundaries']))
        self.assertTrue(any('does not certify' in s for s in self.evidence['boundaries']))


if __name__ == '__main__':
    unittest.main()

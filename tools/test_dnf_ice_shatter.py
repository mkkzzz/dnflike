"""Published source evidence checks; optional live replay and counterfactuals.

--client <original DNF.exe> --decoder-dir <Capstone directory> enables source
execution in the Python interpreter. No native client instructions are executed.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

from audit_dnf_ice_shatter import verify, replay, fbits, sse_step
from audit_dnf_native_strings import ENGINE_SHA

parser = argparse.ArgumentParser(add_help=False)
parser.add_argument('--client', type=Path)
parser.add_argument('--decoder-dir', type=Path)
args, remaining = parser.parse_known_args()
if args.decoder_dir:
    sys.path.insert(0, str(args.decoder_dir.resolve()))
ROOT = Path(__file__).resolve().parents[1]


class ShatterEvidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads((ROOT/'docs/reports/ws2/2026-11/native_ice_shatter.json').read_text(encoding='utf8'))

    def test_pinned_source_tools_and_constants(self):
        e = self.evidence
        self.assertEqual(e['engine_sha256'], ENGINE_SHA)
        self.assertEqual(e['input_source']['input_sha256'], '8748e19abf6155ca5a20d13244eaca0b9442c3d7569e8e5002bddffeeb9366ac')
        for name, expected in e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/'tools'/name).read_bytes().replace(b'\r\n', b'\n')).hexdigest(), expected, name)
        data = {r['address']: int.from_bytes(bytes.fromhex(r['raw']), 'little') for r in e['source_data']}
        self.assertEqual(data['0x159ec04'], fbits(-1.5))
        self.assertEqual(data['0x157dd14'], 0xE50030)
        self.assertEqual(data['0x157dd4c'], 0xE4E170)

    def test_boundary_matrix_and_volatile_register_variants(self):
        runs = self.evidence['runs']
        self.assertEqual(len(runs), 34)
        for row in runs:
            verify(row)
            self.assertEqual(row['stop'], '0x2381a3d')
            self.assertLess(row['steps'], 24000)
        for a, b in zip(runs[::2], runs[1::2]):
            self.assertEqual(a['events'], b['events'])
            self.assertEqual(a['writes'], b['writes'])
        self.assertEqual({r['fixture']['frame'] for r in runs}, {-1, 0, 1, 2, 3, 4})
        self.assertEqual({r['fixture']['ordinal'] for r in runs}, set(range(8)))
        self.assertEqual({r['fixture']['count'] for r in runs}, {0, 1})
        self.assertEqual({r['fixture']['has_animation'] for r in runs}, {False, True})
        self.assertEqual({r['fixture']['fired'] for r in runs}, {0, 1})

    def test_guard_store_and_scale_call_are_source_instructions(self):
        lines = [line for b in self.evidence['blocks'] for line in b['instructions']]
        self.assertIn('02439C28 jl 0x2381a3d', lines)
        self.assertIn('0230E69E jne 0x2381a3d', lines)
        self.assertTrue(any(s.startswith('02304DA4 mov byte ptr ') and s.endswith(', 1') for s in lines))
        self.assertIn('023CF53E call 0x1086e20', lines)
        self.assertTrue(any('ABI fixtures' in s for s in self.evidence['boundaries']))

    def test_validator_rejects_old_assumptions(self):
        original = next(r for r in self.evidence['runs'] if r['fixture']['ordinal'] == 7)
        changed = copy.deepcopy(original)
        next(e for e in changed['events'] if e['kind'] == 'position')['xyz'][2] = 37
        with self.assertRaisesRegex(ValueError, 'height'):verify(changed)
        changed = copy.deepcopy(original)
        changed['events'].append(copy.deepcopy(next(e for e in changed['events'] if e['kind'] == 'scale_fixture')))
        with self.assertRaisesRegex(ValueError, 'scale'):verify(changed)
        changed = copy.deepcopy(original); changed['final_fired'] = 0
        with self.assertRaisesRegex(ValueError, 'flag'):verify(changed)


@unittest.skipUnless(args.client, 'optional original source replay')
class LiveShatter(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from audit_dnf_particle_axis import AxisEvaluator
        cls.source = AxisEvaluator(args.client.read_bytes())

    def changed_source(self, address, raw):
        source = copy.copy(self.source)
        data = bytearray(source.raw)
        sec = next(s for s in source.sections if s['rva'] <= address-0x400000 < s['rva']+s['bytes'])
        offset = sec['offset']+address-0x400000-sec['rva']
        data[offset:offset+len(raw)] = raw
        source.raw = bytes(data)
        return source

    def test_source_coefficient_mutation_changes_observed_height(self):
        row, _ = replay(self.source, ordinal=7)
        verify(row)
        source = self.changed_source(0x159EC04, fbits(1.5).to_bytes(4, 'little'))
        changed, _ = replay(source, ordinal=7)
        self.assertNotEqual(row['events'], changed['events'])
        with self.assertRaisesRegex(ValueError, 'height'):verify(changed)

    def test_frame_threshold_mutation_changes_actual_branch(self):
        i = next(self.source.decoder.disasm(self.source.source_bytes(0x2436259, 15), 0x2436259, count=1))
        self.assertEqual((i.mnemonic, i.operands[-1].imm), ('cmp', 3))
        changed = self.changed_source(i.address+i.size-4, b'\x04\x00\x00\x00')
        row, _ = replay(changed, frame=3)
        self.assertFalse(any(e['kind'] == 'generate_fixture' for e in row['events']))
        with self.assertRaisesRegex(ValueError, 'trigger'):verify(row)

    def test_sse_conversion_truncation_upper_lanes_and_flags(self):
        from dnf_native_vm_probe import CPU
        c = CPU(self.source)
        xmm = {'xmm0': 7 | (0xffffffff << 32) | (2 << 64) | (0x80000000 << 96)}
        flags = c.flags
        for pc in (0x240704E, 0x2407051, 0x2407059):
            i = next(self.source.decoder.disasm(self.source.source_bytes(pc, 15), pc, count=1))
            sse_step(c, xmm, i)
        self.assertEqual(c.reg['ecx'], 0xfffffff6)  # -10.5 truncates toward zero
        self.assertEqual(xmm['xmm0'] >> 32, fbits(-1) | (fbits(2) << 32) | (fbits(-2147483648) << 64))
        self.assertEqual(c.flags, flags)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]]+remaining)

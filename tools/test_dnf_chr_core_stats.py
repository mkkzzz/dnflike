"""Native six-field consumption, conditional scaling and state restoration."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

from audit_dnf_chr_core_stats import replay, verify, PREVIOUS

p = argparse.ArgumentParser(add_help=False)
p.add_argument('--client', type=Path)
p.add_argument('--decoder-dir', type=Path)
args, rest = p.parse_known_args()
if args.decoder_dir:
    sys.path.insert(0, str(args.decoder_dir.resolve()))
ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'docs/reports/ws2/2026-11/native_chr_core_stats.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e = json.loads(ARCHIVE.read_text(encoding='utf-8'))

    def test_dependency_fingerprints(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'], ENGINE_SHA)
        self.assertEqual(hashlib.sha256(PREVIOUS.read_bytes().replace(b'\r\n', b'\n')).hexdigest(), self.e['previous_evidence_sha256'])
        for name, digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT / 'tools' / name).read_bytes().replace(b'\r\n', b'\n')).hexdigest(), digest, name)

    def test_paths_and_cleanup(self):
        self.assertEqual(len(self.e['cases']), 44)
        self.assertEqual(len(self.e['source_input_cases']), 40)
        for row in self.e['cases'] + [r['result'] for r in self.e['source_input_cases']]:
            verify(row)

    def test_source_input_identity(self):
        previous = json.loads(PREVIOUS.read_text(encoding='utf-8'))['source_input_cases']
        for before, after in zip(previous, self.e['source_input_cases']):
            w = dict(before['result']['writes'])
            self.assertEqual(after['result']['fixture']['core'], [w[hex(0x4cb0 + i * 12)] for i in range(6)])
            self.assertEqual((before['level'], before['job']), (after['level'], after['job']))
            if after['level'] == 1:
                self.assertEqual(after['result']['writes'], [['0x8b8', 180], ['0x8d0', 140], ['0x8f4', 7], ['0x90c', 7], ['0x924', 4], ['0x93c', 4]])

    def test_scale_wrapper_zero_and_present_paths(self):
        saw_zero = saw_present = False
        for row in self.e['cases']:
            f = row['fixture']
            if f['scalar_present'] and f['scalar_key'] == 0:
                self.assertFalse(any(c[0] in ('scale', 'scaler_lookup') for c in row['calls']))
                self.assertEqual([v for _, v in row['writes'][:2]], [180, 140])
                saw_zero = True
            if f['scalar_present'] and f['scalar_key'] == 7 and f['factors'] == [1.25, .75]:
                self.assertEqual([v for _, v in row['writes'][:2]], [225, 105])
                saw_present = True
        self.assertTrue(saw_zero and saw_present)

    def test_restoration_preserves_original_precision_loss(self):
        rows = [r for r in self.e['cases'] if r['rates'] == [135]]
        self.assertTrue(rows)
        for row in rows:
            self.assertEqual(row['bank_tail']['0xc'], 16777216)
            self.assertEqual(row['bank_tail']['0x24'], (-16777216) & 0xffffffff)
            self.assertEqual(len(row['writes']), 10)
        for row in self.e['cases']:
            if row['rates'] == [100]:
                self.assertEqual(row['bank_tail']['0xc'], 99)
                self.assertEqual(len(row['writes']), 6)

    def test_wrong_order_or_rate_rejected(self):
        row = copy.deepcopy(self.e['cases'][0])
        row['writes'][2][1] += 1
        with self.assertRaises(ValueError):
            verify(row)
        row = copy.deepcopy(self.e['cases'][0])
        row['rates'][0] += 1
        with self.assertRaises(ValueError):
            verify(row)

    def test_boundaries_and_constants(self):
        self.assertTrue(any('current-HP/MP refill' in b for b in self.e['boundaries']))
        self.assertTrue(any('not real refresh outputs' in b for b in self.e['boundaries']))
        self.assertTrue(any('not guessed vitality/spirit' in b for b in self.e['boundaries']))
        self.assertEqual(self.e['constants'], [{'address': '0x16cf488', 'bytes': '00002041'},
            {'address': '0x16f9b6c', 'bytes': '9073d000'}])


@unittest.skipUnless(args.client, 'optional read-only original bytes')
class Live(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from audit_dnf_particle_axis import AxisEvaluator
        cls.source = AxisEvaluator(args.client.read_bytes())
        cls.e = json.loads(ARCHIVE.read_text(encoding='utf-8'))

    def changed(self, address, old, new):
        self.assertEqual(self.source.source_bytes(address, len(old)), old)
        source = copy.copy(self.source)
        raw = bytearray(source.raw)
        sec = next(s for s in source.sections if s['rva'] <= address - 0x400000 < s['rva'] + s['bytes'])
        off = sec['offset'] + address - 0x400000 - sec['rva']
        raw[off:off + len(new)] = new
        source.raw = bytes(raw)
        return source

    def test_original_replays(self):
        for expected in self.e['cases'] + [r['result'] for r in self.e['source_input_cases']]:
            row, _ = replay(self.source, **expected['fixture'])
            verify(row)
            self.assertEqual(row, expected)
        for c in self.e['constants']:
            self.assertEqual(self.source.source_bytes(int(c['address'], 16), 4).hex(), c['bytes'])

    def reject(self, source, **fixture):
        with self.assertRaises(ValueError):
            row, _ = replay(source, **fixture)
            verify(row)

    def test_wrong_hp_denominator(self):
        self.reject(self.changed(0x16cf488, bytes.fromhex('00002041'), bytes.fromhex('0000a041')))

    def test_multiplication_replaces_division(self):
        self.reject(self.changed(0x8559d6, b'\x5e', b'\x59'))

    def test_wrong_core_integer_divisor(self):
        self.reject(self.changed(0x855ae4, b'\x06', b'\x05'))

    def test_wrong_default_rate(self):
        self.reject(self.changed(0x85579b, b'\x64', b'\x65'), flag10=True)

    def test_wrong_bank_stride(self):
        self.reject(self.changed(0xd07398, b'\xd0', b'\xd4'))

    def test_wrong_mode_exception(self):
        self.reject(self.changed(0x8558ca, b'\x09', b'\x08'), query=True, mode_id=9, rate=135)

    def test_wrong_restore_gate(self):
        self.reject(self.changed(0x855c06, b'\x64', b'\x63'))

    def test_wrong_zero_key_branch(self):
        self.reject(self.changed(0x75bf09, b'\x74', b'\x75'), scalar_present=True, scalar_key=0, factors=(2., 3.))


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + rest)

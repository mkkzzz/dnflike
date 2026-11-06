"""Original CHR actor writes: numeric boundaries, source inputs and bad bytes."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

from audit_dnf_chr_writeback import replay, verify, class_pointer, verify_class_pointer, fixture_record

p = argparse.ArgumentParser(add_help=False)
p.add_argument('--client', type=Path)
p.add_argument('--decoder-dir', type=Path)
args, rest = p.parse_known_args()
if args.decoder_dir:
    sys.path.insert(0, str(args.decoder_dir.resolve()))
ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'docs/reports/ws2/2026-11/native_chr_writeback.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e = json.loads(ARCHIVE.read_text(encoding='utf-8'))

    def test_source_and_tool_fingerprints(self):
        from audit_dnf_native_strings import ENGINE_SHA
        from audit_dnf_chr_writeback import PREVIOUS
        self.assertEqual(self.e['engine_sha256'], ENGINE_SHA)
        self.assertEqual(hashlib.sha256(PREVIOUS.read_bytes().replace(b'\r\n', b'\n')).hexdigest(), self.e['previous_evidence_sha256'])
        for name, digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT / 'tools' / name).read_bytes().replace(b'\r\n', b'\n')).hexdigest(), digest, name)

    def test_all_paths(self):
        self.assertEqual(len(self.e['cases']), 58)
        for row in self.e['cases']:
            verify(row)
        self.assertEqual(len(self.e['source_input_cases']), 40)
        for row in self.e['source_input_cases']:
            verify(row['result'])
        self.assertEqual(len(self.e['class_pointer_cases']), 14)
        for row in self.e['class_pointer_cases']:
            verify_class_pointer(row)

    def test_original_input_link_not_final_growth_claim(self):
        from audit_dnf_chr_writeback import PREVIOUS
        previous = json.loads(PREVIOUS.read_text(encoding='utf-8'))['source_growth']['cases']
        for before, after in zip(previous, self.e['source_input_cases']):
            self.assertEqual(before['bytes'], after['result']['fixture']['record'])
            self.assertEqual(before['fixture']['level'], after['level'])
            self.assertEqual(before['fixture']['job'], after['job'])
        self.assertTrue(any('intervening 834644..834F14' in b for b in self.e['boundaries']))
        self.assertTrue(any('regen tick frequency' in b for b in self.e['boundaries']))

    def test_source_initial_record_destinations(self):
        for row in self.e['source_input_cases']:
            if row['level'] != 1:
                continue
            result = row['result']
            writes = dict(result['writes'])
            for offset, value in {'0x4cb0': 1800, '0x4cc8': 75, '0x8d0': 140,
                    '0x96c': 20, '0x978': 0xffffffec, '0xbdc': 10, '0xbf4': 850, '0xc0c': 850}.items():
                self.assertEqual(writes[offset], value)
            self.assertEqual(result['calls'][-1], ['refresh', '0x833f80'])

    def test_unsigned_and_signed_are_distinct(self):
        rows = [r for r in self.e['cases'] if r['fixture']['class_index'] == 0 and not r['fixture']['mode10']]
        saw_unsigned = saw_signed = False
        for row in rows:
            b = bytes.fromhex(row['fixture']['record'])
            output = dict(row['writes'])
            if int.from_bytes(b[4:8], 'little') == 0xffffffff:
                self.assertEqual(output['0x8d0'], 429496729)
                saw_unsigned = True
            if int.from_bytes(b[16:18], 'little') == 0xffff:
                self.assertEqual(output['0x954'], 0)  # -1 / 10 truncates toward zero
                saw_signed = True
        self.assertTrue(saw_unsigned and saw_signed)

    def test_class_branch_and_multiplier_reset(self):
        for row in self.e['cases']:
            f = row['fixture']
            raw = bytes.fromhex(f['record'])
            n = int.from_bytes(raw[64:66], 'little', signed=True)
            ordinary = -(abs(n) // 10) if n < 0 else n // 10
            expected = (-(abs(ordinary) // 5) if ordinary < 0 else ordinary // 5) if 0 <= f['class_index'] <= 10 else ordinary
            self.assertEqual(dict(row['writes'])['0xbdc'], expected & 0xffffffff)
            self.assertEqual(dict(row['writes'])['0xbe8'], 0x3f800000)
        self.assertEqual(self.e['constants'], [
            {'address': '0x15560bc', 'bytes': '0000803f'},
            {'address': '0x156889c', 'bytes': 'cdcccc3d'},
            {'address': '0x16f9e64', 'bytes': '9095d000'},
            {'address': '0x16f9e74', 'bytes': 'f0ea8300'}])

    def test_corrupt_write_rejected(self):
        row = copy.deepcopy(self.e['cases'][0])
        row['writes'][0][1] += 1
        with self.assertRaises(ValueError):
            verify(row)


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
        for expected in self.e['class_pointer_cases']:
            row, _ = class_pointer(self.source, expected['class_index'])
            self.assertEqual(row, expected)
        for constant in self.e['constants']:
            self.assertEqual(self.source.source_bytes(int(constant['address'], 16), 4).hex(), constant['bytes'])

    def reject(self, source, **kwargs):
        # A closed-world ABI rejection also detects an unexpected destination;
        # otherwise the independent oracle must reject the wrong result.
        with self.assertRaises(ValueError):
            row, _ = replay(source, **kwargs)
            verify(row)

    def test_wrong_unsigned_division(self):
        self.reject(self.changed(0x83eb1a, b'\x03', b'\x02'), record=fixture_record(1))

    def test_wrong_resistance_sign(self):
        self.reject(self.changed(0x83eb64, b'\xbf', b'\xb7'), record=fixture_record(3))

    def test_wrong_raw_attack_sign(self):
        self.reject(self.changed(0x1286cf9, b'\xb7', b'\xbf'), record=fixture_record(3))

    def test_wrong_class_boundary(self):
        self.reject(self.changed(0x83ece5, b'\x0a', b'\x0b'), record=fixture_record(2), class_index=10)

    def test_wrong_raw_copy_stride(self):
        self.reject(self.changed(0x1286dbe, b'\x0c', b'\x10'), record=fixture_record(1))

    def test_wrong_refresh_argument(self):
        self.reject(self.changed(0x83efc9, b'\x00', b'\x01'), record=fixture_record(1))


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + rest)

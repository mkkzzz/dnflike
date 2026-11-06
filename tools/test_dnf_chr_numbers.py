"""CHR numeric evidence, finite conversion boundaries and native-byte mutations."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

from audit_dnf_chr_numbers import FIELDS, scalar, growth, verify_scalar, verify_growth, stored_number

p = argparse.ArgumentParser(add_help=False)
p.add_argument('--client', type=Path)
p.add_argument('--decoder-dir', type=Path)
args, rest = p.parse_known_args()
if args.decoder_dir:
    sys.path.insert(0, str(args.decoder_dir.resolve()))
ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'docs/reports/ws2/2026-11/native_chr_numbers.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e = json.loads(ARCHIVE.read_text(encoding='utf-8'))

    def test_dependencies(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'], ENGINE_SHA)
        for name, digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT / 'tools' / name).read_bytes().replace(b'\r\n', b'\n')).hexdigest(), digest, name)

    def test_all_scalar_paths(self):
        self.assertEqual(len(self.e['scalar_cases']), 368)
        for row in self.e['scalar_cases']:
            verify_scalar(row)
        self.assertEqual({r['fixture']['tag'] for r in self.e['scalar_cases']}, set(FIELDS))
        self.assertEqual({r['fixture']['token_type'] for r in self.e['scalar_cases']}, {None, 3, 5})

    def test_archive_field_coverage(self):
        self.assertEqual(len(self.e['files']), 11)
        self.assertEqual({f['tag'] for r in self.e['files'] for f in r['fields']},
            set(FIELDS) - {'[fire resistance]', '[water resistance]', '[hp regen speed]'})
        covered = {(r['fixture']['tag'], type(r['fixture']['values'][0]), r['fixture']['values'][0]): r
            for r in self.e['scalar_cases'] if len(r['fixture']['values']) == 1 and r['fixture']['token_type'] is None}
        for file in self.e['files']:
            for field in file['fields']:
                row = covered[(field['tag'], type(field['value']), field['value'])]
                self.assertEqual(row['writes'][-1][2], field['stored_bits'])

    def test_sign_ties_width_and_float_precision(self):
        self.assertEqual(self.e['constants'], [
            {'address': '0x16cf488', 'bytes': '00002041', 'value': 10.0},
            {'address': '0x155a170', 'bytes': '00000000', 'value': 0.0},
            {'address': '0x1556144', 'bytes': '0000003f', 'value': 0.5}])
        for value, width, expected in [(7.5, 2, 75), (4.8, 2, 48), (4.2, 2, 42),
                (.049999997, 4, 1), (.05, 4, 1), (-.05, 4, 0xffffffff),
                (1.25, 2, 13), (-1.25, 2, 65523), (6553.6, 2, 0), (3276.8, 2, 32768)]:
            with self.subTest(value=value, width=width):
                self.assertEqual(stored_number(value, width), expected)

    def test_growth_selection_and_wrapping(self):
        self.assertEqual(len(self.e['growth_cases']), 72)
        for row in self.e['growth_cases'] + self.e['source_growth']['cases']:
            verify_growth(row)

    def test_original_source_initial_values(self):
        self.assertEqual(self.e['source_growth']['sha256'], '576c7f66296b6dc9882280654a8378a95de6c677388c0a3e9b0050bfbfddb679')
        rows = self.e['source_growth']['cases']
        self.assertEqual(len(rows), 40)
        for row in rows:
            f = row['fixture']
            b = bytes.fromhex(row['bytes'])
            if f['level'] == 1:
                self.assertEqual((int.from_bytes(b[:4], 'little'), int.from_bytes(b[4:8], 'little')),(1800, 1400))
                self.assertEqual(int.from_bytes(b[8:10], 'little'), 75)
            if f['level'] == 60 and f['job'] == 1:
                self.assertEqual((int.from_bytes(b[:4], 'little'), int.from_bytes(b[4:8], 'little')),(30450, 14050))
                self.assertEqual(int.from_bytes(b[8:10], 'little'), 2991)

    def test_corrupt_evidence_rejected(self):
        row = copy.deepcopy(self.e['scalar_cases'][0])
        row['writes'][0][2] += 1
        with self.assertRaises(ValueError):
            verify_scalar(row)
        row = copy.deepcopy(self.e['growth_cases'][0])
        row['selected'][0]['factor'] += 1
        with self.assertRaises(ValueError):
            verify_growth(row)

    def test_boundary_is_explicit(self):
        self.assertTrue(any('before mode multipliers' in b for b in self.e['boundaries']))
        self.assertTrue(any('No final HP/MP' in b for b in self.e['boundaries']))
        self.assertIn('zero fixtures', self.e['source_growth']['fixture_boundary'])


@unittest.skipUnless(args.client, 'optional read-only original client replay')
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
        for constant in self.e['constants']:
            self.assertEqual(self.source.source_bytes(int(constant['address'], 16), 4).hex(), constant['bytes'])
        for expected in self.e['scalar_cases']:
            row, _ = scalar(self.source, **expected['fixture'])
            verify_scalar(row)
            self.assertEqual(row, expected)
        for expected in self.e['growth_cases'] + self.e['source_growth']['cases']:
            row, _ = growth(self.source, **expected['fixture'])
            verify_growth(row)
            self.assertEqual(row, expected)

    def test_actual_archive_census(self):
        from audit_dnf_chr_numbers import census
        version, files, _ = census()
        self.assertEqual(version, self.e['asset_version'])
        self.assertEqual(files, self.e['files'])

    def test_wrong_scaling_constant(self):
        source = self.changed(0x16cf488, bytes.fromhex('00002041'), bytes.fromhex('0000803f'))
        row, _ = scalar(source, '[hp max]', [180])
        with self.assertRaises(ValueError):
            verify_scalar(row)

    def test_wrong_negative_rounding(self):
        source = self.changed(0x112acf1, b'\x5c', b'\x58')
        row, _ = scalar(source, '[physical attack]', [-1.25])
        with self.assertRaises(ValueError):
            verify_scalar(row)

    def test_wrong_scalar_destination(self):
        source = self.changed(0x129c9ec, b'\x08', b'\x0a')
        row, _ = scalar(source, '[physical attack]', [7.5])
        with self.assertRaises(ValueError):
            verify_scalar(row)

    def reject_growth(self, source, level, job):
        fixture = next(r['fixture'] for r in self.e['growth_cases'] if r['fixture']['level'] == level and r['fixture']['job'] == job)
        row, _ = growth(source, **fixture)
        with self.assertRaises(ValueError):
            verify_growth(row)

    def test_wrong_growth_boundary(self):
        self.reject_growth(self.changed(0x8344d4, b'\x12', b'\x14'), 19, 1)

    def test_wrong_growth_column(self):
        self.reject_growth(self.changed(0x834509, b'\x57', b'\x00'), 60, 3)

    def test_missing_extra_record(self):
        self.reject_growth(self.changed(0x8344ed, b'\x01', b'\x00'), 60, 3)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + rest)

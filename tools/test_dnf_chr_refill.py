"""Refill gate, native limits, conditional rates and retained caller defaults."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

from audit_dnf_chr_refill import replay, verify, fixture, request, limit, PREVIOUS

p = argparse.ArgumentParser(add_help=False)
p.add_argument('--client', type=Path)
p.add_argument('--decoder-dir', type=Path)
args, rest = p.parse_known_args()
if args.decoder_dir:
    sys.path.insert(0, str(args.decoder_dir.resolve()))
ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'docs/reports/ws2/2026-11/native_chr_refill.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e = json.loads(ARCHIVE.read_text(encoding='utf-8'))

    def test_dependencies(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'], ENGINE_SHA)
        self.assertEqual(hashlib.sha256(PREVIOUS.read_bytes().replace(b'\r\n', b'\n')).hexdigest(), self.e['previous_evidence_sha256'])
        for name, digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT / 'tools' / name).read_bytes().replace(b'\r\n', b'\n')).hexdigest(), digest, name)

    def test_full_paths(self):
        self.assertEqual(len(self.e['cases']), 92)
        for row in self.e['cases']:
            verify(row)

    def test_byte_gate_not_bool32(self):
        seen = set()
        for row in self.e['cases']:
            arg = row['fixture']['refill']['argument']
            active = bool(arg & 255)
            self.assertEqual(bool(row['refill']['events']), active)
            self.assertEqual(row['calls'][-1], ['refresh', 3 if active else 2])
            seen.add(arg)
        self.assertTrue({0, 1, 2, 255, 256, 257, 0xffffffff} <= seen)

    def test_null_special_object_skips_hp_only(self):
        matched = 0
        for row in self.e['cases']:
            r = row['fixture']['refill']
            if r['guard'] and r['type_match'] and not r['profile_present']:
                requests = [e for e in row['refill']['events'] if e[0] == 'set_request']
                self.assertEqual(len(requests), 1)
                self.assertEqual(requests[0][1], '0x812260')
                matched += 1
        self.assertEqual(matched, 4)

    def test_distinct_rates_and_argument_defaults(self):
        matched = 0
        for row in self.e['cases']:
            r = row['fixture']['refill']
            if r['guard'] and r['type_match'] and r['profile_present'] and r['profile_rate'] == 65 and row['rates'] == [37]:
                requests = [e for e in row['refill']['events'] if e[0] == 'set_request']
                self.assertEqual(requests, [['set_request', '0x812260', 54, [1]], ['set_request', '0x831620', 244, [0, 1]]])
                matched += 1
        self.assertGreater(matched, 0)

    def test_precision_truncation_and_product_wrap(self):
        self.assertEqual(limit(16777217, 1.), 16777216)
        self.assertEqual(request(-301, 1.25, 37), -139)
        self.assertEqual(request(301, 1.25, 65), 244)
        self.assertEqual(request(0x7fffffff, .5, 255), -10737418)
        with self.assertRaises(ValueError):
            limit(0x7fffffff, 2.)

    def test_changed_request_and_bank_are_rejected(self):
        for key in ('request', 'bank'):
            row = copy.deepcopy(next(r for r in self.e['cases'] if r['refill']['events']))
            if key == 'request':
                next(e for e in row['refill']['events'] if e[0] == 'set_request')[2] += 1
            else:
                row['bank_tail']['0xc'] += 1
            with self.assertRaises(ValueError):
                verify(row)

    def test_vtable_and_implementation_boundaries(self):
        self.assertEqual(self.e['vtable'], [{'offset': hex(o), 'target': hex(t)} for o, t in (
            (0x514, 0x812260), (0x51c, 0xd07af0), (0x2a0, 0x831620),
            (0x2a8, 0xd07a70), (0x48, 0x406920), (0x91c, 0x82eb50))])
        self.assertTrue(any('not proof of completed' in b for b in self.e['boundaries']))
        self.assertTrue(any('explicit fixture bank values' in b for b in self.e['boundaries']))


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
        for expected in self.e['cases']:
            row, _ = replay(self.source, **expected['fixture'])
            verify(row)
            self.assertEqual(row, expected)

    def reject(self, source, **kwargs):
        with self.assertRaises(ValueError):
            row, _ = replay(source, **kwargs)
            verify(row)

    def test_wrong_byte_gate(self):
        self.reject(self.changed(0x855cac, b'\x00', b'\x01'), refill=fixture())

    def test_wrong_mp_divisor(self):
        self.reject(self.changed(0x855cdd, b'\x05', b'\x06'), refill=fixture(), rate=65)

    def test_wrong_special_hp_rate_source(self):
        self.reject(self.changed(0x855d49, b'\xcb', b'\xcf'), refill=fixture(guard=True, type_match=True), eligible=True, rate=37)

    def test_wrong_null_profile_branch(self):
        self.reject(self.changed(0x855d1d, b'\x74', b'\x75'), refill=fixture(guard=True, type_match=True), eligible=True)

    def test_wrong_hp_bank_offset(self):
        self.reject(self.changed(0xd07a88, b'\x0c', b'\x24'), refill=fixture())

    def test_wrong_mp_multiplier_offset(self):
        self.reject(self.changed(0xd07b1b, b'\x30', b'\x18'), refill=fixture())

    def test_wrong_retained_default_argument(self):
        self.reject(self.changed(0x855cca, b'\x01', b'\x00'), refill=fixture())

    def test_wrong_profile_dispatch(self):
        self.reject(self.changed(0x82eb5c, b'\x74', b'\x75'), refill=fixture(guard=True, type_match=True), eligible=True)

    def test_wrong_guard_gate(self):
        self.reject(self.changed(0x855cf7, b'\x74', b'\x75'), refill=fixture(guard=True, type_match=True), eligible=True, rate=37)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + rest)

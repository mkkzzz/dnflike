"""Native input, unsigned byte routing and explicit protected-write boundary."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_stamina_input import run, verify, register, verify_registration

p = argparse.ArgumentParser(add_help=False)
p.add_argument('--client', type=Path)
p.add_argument('--decoder-dir', type=Path)
args, rest = p.parse_known_args()
if args.decoder_dir:
    sys.path.insert(0, str(args.decoder_dir.resolve()))
ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'docs/reports/ws2/2026-11/native_stamina_input.json'


class Evidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e = json.loads(ARCHIVE.read_text(encoding='utf-8'))

    def test_dependencies_and_vtable(self):
        from audit_dnf_native_strings import ENGINE_SHA
        self.assertEqual(self.e['engine_sha256'], ENGINE_SHA)
        for name, digest in self.e['tools_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT / 'tools' / name).read_bytes().replace(b'\r\n', b'\n')).hexdigest(), digest, name)
        self.assertEqual(self.e['vtable'], [{'offset': '0x750', 'target': '0x855770'},
            {'offset': '0x758', 'target': '0xd09700'}, {'offset': '0x75c', 'target': '0xd09720'}])

    def test_paths(self):
        self.assertEqual(len(self.e['cases']), 192)
        for row in self.e['cases']:
            verify(row)

    def test_native_registration(self):
        self.assertEqual(len(self.e['registrations']), 16)
        for row in self.e['registrations']:
            verify_registration(row)

    def test_unsigned_byte_and_absent_actor(self):
        seen = set()
        for row in self.e['cases']:
            f = row['fixture']
            if f['variant'] not in ('notice', 'guarded'):
                continue
            self.assertEqual(row['cursor'], '0x60100001')
            if not f['present']:
                self.assertFalse(row['events'])
            for event in row['events']:
                if event[0] == 'set_request' and f['value'] >= 128:
                    self.assertEqual(event, ['set_request', '0x4e60', '0x4e68', f['value']])
                    seen.add(event[-1])
        self.assertEqual(seen, {128, 255})

    def test_notice_and_recompute_are_separate(self):
        for row in self.e['cases']:
            f = row['fixture']
            if f['variant'] != 'notice':
                continue
            self.assertEqual(any(e[0] == 'notification' for e in row['events']), f['present'] and f['value'] == 100)
            self.assertEqual(any(e[0] == 'recompute_request' for e in row['events']), f['present'] and f['mode'] == 1)

    def test_guarded_prefix_and_reader_underflow(self):
        for row in self.e['cases']:
            f = row['fixture']
            if f['variant'] == 'guarded' and f['guarded']:
                self.assertEqual(row['events'], [['guard']] if f['present'] else [])
            if f['variant'] == 'reader' and f['remaining'] == 0:
                self.assertEqual((row['stop'], row['remaining'], row['read_byte']), ('0x11ae972', 0xffffffff, f['value']))

    def test_boundaries_do_not_claim_protected_write_or_refill(self):
        self.assertTrue(any('set_request is not proof' in b for b in self.e['boundaries']))
        self.assertTrue(any('nonzero refill path remains unproved' in b for b in self.e['boundaries']))
        self.assertTrue(any('undefined 16-bit' in b for b in self.e['boundaries']))
        self.assertEqual([x['start'] for x in self.e['static_unresolved']], ['0x20df6d0', '0x1ee8be2', '0x1eb401e'])

    def test_corrupt_request_rejected(self):
        row = copy.deepcopy(next(r for r in self.e['cases'] if any(e[0] == 'set_request' for e in r['events'])))
        next(e for e in row['events'] if e[0] == 'set_request')[-1] = 999
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
        for expected in self.e['cases']:
            row, _ = run(self.source, **expected['fixture'])
            verify(row)
            self.assertEqual(row, expected)
        for expected in self.e['registrations']:
            row, _ = register(self.source, **expected['fixture'])
            self.assertEqual(row, expected)
        for block in self.e['static_unresolved']:
            self.assertEqual(self.source.source_bytes(int(block['start'], 16), len(bytes.fromhex(block['bytes']))).hex(), block['bytes'])

    def reject(self, source, **fixture):
        with self.assertRaises(ValueError):
            row, _ = run(source, **fixture)
            verify(row)

    def test_signed_byte_regression(self):
        self.reject(self.changed(0x723541, b'\xb6', b'\xbe'), value=128)

    def test_wrong_notification_threshold(self):
        self.reject(self.changed(0x723575, b'\x64', b'\x63'), value=100)

    def test_wrong_mode_gate(self):
        self.reject(self.changed(0x72355d, b'\x01', b'\x02'), mode=1)

    def test_wrong_cursor_direction(self):
        self.reject(self.changed(0x11aea0d, b'\x40', b'\x48'), variant='reader', value=255)

    def test_wrong_remaining_count(self):
        self.reject(self.changed(0x11aea0f, b'\x01', b'\x02'), variant='reader', value=255, remaining=2)

    def test_wrong_setter_destination_prefix(self):
        self.reject(self.changed(0xd09708, b'\x60', b'\x64'))

    def test_wrong_guard_branch(self):
        self.reject(self.changed(0x72c2f9, b'\x75', b'\x74'), variant='guarded', guarded=True)

    def test_wrong_registration_key(self):
        with self.assertRaises(ValueError):
            register(self.changed(0x74d3aa, b'\x04', b'\x05'))


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + rest)

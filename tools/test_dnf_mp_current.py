"""Native MP body write gate, encoded timer fields and read-after-write fixture."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from audit_dnf_mp_current import run, verify, PREVIOUS

p = argparse.ArgumentParser(add_help=False)
p.add_argument('--client', type=Path)
p.add_argument('--decoder-dir', type=Path)
args, rest = p.parse_known_args()
if args.decoder_dir:
    sys.path.insert(0, str(args.decoder_dir.resolve()))
ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'docs/reports/ws2/2026-11/native_mp_current.json'


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

    def test_paths(self):
        self.assertEqual(len(self.e['cases']), 242)
        for row in self.e['cases']:
            verify(row)

    def test_refill_input_linkage_is_explicit(self):
        previous = json.loads(PREVIOUS.read_text(encoding='utf-8'))['cases']
        self.assertEqual(len(self.e['refill_input_cases']), 88)
        for case in self.e['refill_input_cases']:
            row = case['result']
            verify(row)
            request = next(e for e in previous[case['source_case']]['refill']['events'] if e[:2] == ['set_request', '0x812260'])
            self.assertEqual((row['fixture']['target'], row['fixture']['mark']), (request[2], request[3][0]))
            self.assertEqual((row['fixture']['current'], row['fixture']['flags']), (100, 3))

    def test_lower_equal_and_higher_values(self):
        selected = {r['fixture']['target']: r for r in self.e['cases'] if r['fixture']['variant'] == 'setter'
            and r['fixture']['flags'] == 3 and r['fixture']['mark'] == 1 and r['fixture']['current'] == 100
            and r['fixture']['clock_value'] == 70 and r['fixture']['offset'] == 29 and r['fixture']['duration'] == 100}
        for target in (99, 100, 101):
            row = selected[target]
            self.assertEqual(row['writes'], [] if target == 99 else [['0x2bf8', target], ['0x3110', 0xffffffff]])
            self.assertEqual(row['result'], 100 if target == 99 else target)

    def test_mark_low_byte_and_unclamped_body(self):
        for row in self.e['cases']:
            f = row['fixture']
            if f['variant'] != 'setter' or f['flags']:
                continue
            self.assertEqual(row['current'], f['target'] & 0xffffffff)
            self.assertEqual(row['dirty'], 0xffffffff if f['mark'] & 255 else 123)
        self.assertTrue(any(r['fixture']['target'] == -1 and r['writes'] for r in self.e['cases'] if r['fixture']['flags'] == 0))

    def test_boolean_result_is_al_only(self):
        rows = [r for r in self.e['cases'] if r['fixture']['variant'] == 'complete' and r['fixture']['clock_value'] == 0x7fffffff]
        self.assertEqual({r['result'] for r in rows}, {0x7fffff01, 0x80000000})

    def test_corrupt_write_or_decode_rejected(self):
        for kind in ('write', 'decode'):
            row = copy.deepcopy(next(r for r in self.e['cases'] if r['writes']))
            if kind == 'write':
                row['writes'][0][1] += 1
            else:
                row['decodes'][0] = 'wrong'
            with self.assertRaises(ValueError):
                verify(row)

    def test_vtable_and_boundaries(self):
        self.assertEqual(self.e['vtable'], [{'offset': hex(o), 'target': hex(t)} for o, t in (
            (0x460, 0xd073c0), (0x514, 0x812260), (0x518, 0xd07ac0))])
        self.assertTrue(any('no full setter return' in b for b in self.e['boundaries']))
        self.assertTrue(any('not bridged' in b for b in self.e['boundaries']))
        self.assertEqual([b['start'] for b in self.e['unresolved_blocks']], ['0x812260', '0x8122d8', '0x1ef4b5c'])


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
        for expected in self.e['cases'] + [r['result'] for r in self.e['refill_input_cases']]:
            row, _ = run(self.source, **expected['fixture'])
            verify(row)
            self.assertEqual(row, expected)
        for block in self.e['unresolved_blocks']:
            self.assertEqual(self.source.source_bytes(int(block['start'], 16), len(bytes.fromhex(block['bytes']))).hex(), block['bytes'])

    def reject(self, source, **fixture):
        with self.assertRaises(ValueError):
            row, _ = run(source, **fixture)
            verify(row)

    def test_equal_value_wrongly_rejected(self):
        self.reject(self.changed(0x812297, b'\x7c', b'\x7e'), target=100)

    def test_wrong_mp_destination(self):
        self.reject(self.changed(0x8122af, b'\x0c', b'\x00'), flags=0)

    def test_wrong_mark_argument(self):
        self.reject(self.changed(0x8122ba, b'\x0c', b'\x08'), flags=0, mark=0)

    def test_wrong_marker_sentinel(self):
        self.reject(self.changed(0x8122cf, b'\xff', b'\xfe'), flags=0)

    def test_wrong_second_timer_flag(self):
        self.reject(self.changed(0x11afbf7, b'\x02', b'\x01'), variant='elapsed', flags=1)

    def test_wrong_cached_timer_flag(self):
        self.reject(self.changed(0x11afc01, b'\x04', b'\x08'), variant='elapsed', flags=7, cached=55)

    def test_wrong_duration_boundary(self):
        self.reject(self.changed(0x11afd20, b'\x9d', b'\x9f'), variant='complete', flags=7, cached=100)

    def test_wrong_clock_table_stride(self):
        self.reject(self.changed(0x11e64b9, b'\x85', b'\xc5'), variant='elapsed')

    def test_clock_offset_subtracted(self):
        self.reject(self.changed(0x11afc4d, b'\x03', b'\x2b'), variant='elapsed')

    def test_wrong_current_state_pointer(self):
        self.reject(self.changed(0xd073c2, b'\xec', b'\xf0'), variant='current')


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + rest)

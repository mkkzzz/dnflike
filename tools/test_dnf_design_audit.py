"""Evidence safety checks: malformed streams, raw preservation, read-only input."""
import hashlib
from contextlib import closing
from pathlib import Path
import sqlite3
import struct
import tempfile
import unittest

from audit_dnf_design import Strings, connect_readonly, decode_tokens


def string_table(values):
    encoded = [s.encode('cp949') for s in values]
    offsets, cursor = [], 4 * (len(values) + 1)
    for value in encoded:
        offsets.append(cursor)
        cursor += len(value)
    offsets.append(cursor)
    return struct.pack('<I', len(values)) + struct.pack('<' + 'I' * len(offsets), *offsets) + b''.join(encoded)


def token(kind, number):
    return bytes([kind]) + struct.pack('<i', number)


class EvidenceSafety(unittest.TestCase):
    def test_duplicate_tags_and_localization_are_preserved(self):
        strings = Strings(string_table(['[cool time]', '[dungeon]', '[pvp]']))
        content = b'\xb0\xd0' + b''.join([
            token(5, 1), token(5, 0), token(2, 15000),
            token(5, 2), token(5, 0), token(2, 18000), token(9, 12), token(10, 42)])
        parsed = decode_tokens(content, strings)
        self.assertEqual([s['tag'] for s in parsed['tag_spans']],
                         ['[dungeon]', '[cool time]', '[pvp]', '[cool time]'])
        self.assertEqual(parsed['tokens'][-1]['raw_int'], 42)
        self.assertNotIn('value', parsed['tokens'][-1])
        self.assertEqual(parsed['unresolved_types'], {'9': 1, '10': 1})
        reconstructed = b'\xb0\xd0' + b''.join(bytes([t['type']]) + bytes.fromhex(t['raw_hex']) for t in parsed['tokens'])
        self.assertEqual(reconstructed, content)

    def test_bad_index_is_explicit(self):
        parsed = decode_tokens(b'\xb0\xd0' + token(5, -1), Strings(string_table(['[x]'])))
        self.assertIn('error', parsed['tokens'][0])
        self.assertEqual(parsed['tag_spans'], [])

    def test_invalid_alignment_and_table_bounds_are_rejected(self):
        strings = Strings(string_table(['[x]']))
        for content in [b'', b'\xb0\xd0\x02', b'XX' + token(2, 1)]:
            with self.assertRaises(ValueError):
                decode_tokens(content, strings)
        with self.assertRaises(ValueError):
            Strings(struct.pack('<3I', 9999, 0, 0))
        corrupt = Strings(struct.pack('<3I', 1, 0, 99999))
        with self.assertRaises(ValueError):
            corrupt.get(0)

    def test_database_is_never_opened_writable_or_created(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'source.sqlite'
            with closing(sqlite3.connect(path)) as db:
                db.execute('create table source(value integer)')
                db.commit()
            before = hashlib.sha256(path.read_bytes()).digest()
            db = connect_readonly(path)
            try:
                with self.assertRaises(sqlite3.OperationalError):
                    db.execute('insert into source values(1)')
            finally:
                db.close()
            self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), before)
            absent = Path(directory) / 'absent.sqlite'
            with self.assertRaises(sqlite3.OperationalError):
                connect_readonly(absent)
            self.assertFalse(absent.exists())


if __name__ == '__main__':
    unittest.main()

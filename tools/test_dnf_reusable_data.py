"""Guard archive-specific localization, reference boundaries and Chinese encodings."""
import hashlib
import struct
import unittest

from audit_dnf_design import Strings
from audit_dnf_reusable_data import TextResolver, parse_table, string_bytes


def strings(values, encoding):
    values = [value.encode(encoding) for value in values]
    cursor = 4 * (len(values) + 1)
    offsets = []
    for value in values:
        offsets.append(cursor)
        cursor += len(value)
    offsets.append(cursor)
    return Strings(struct.pack('<I', len(values)) + struct.pack('<' + 'I' * len(offsets), *offsets)
                   + b''.join(values))


def tokens(*values):
    return b'\xb0\xd0' + b''.join(struct.pack('<Bi', kind, value) for kind, value in values)


class FakeLibrary:
    def __init__(self, encoding='cp950'):
        self.strings = strings(['[name]', 'name_1', '古老的羊毛背心', '[condition message]'], encoding)
        self.files = {'a.str': 'name_1>林納斯大叔\r\r\n'.encode(encoding),
                      'b.str': 'name_1>賽麗亞\r\n'.encode(encoding)}

    def listing(self, _):
        return {11: 'a.str', 12: 'b.str'}

    def raw(self, path):
        raw = self.files[path]
        return raw, hashlib.sha256(raw).hexdigest()


class LocalizationEvidence(unittest.TestCase):
    def test_same_key_in_different_tables_is_not_global(self):
        resolver = TextResolver(FakeLibrary())
        fields = resolver.fields(tokens((5, 0), (9, 11), (10, 1), (5, 0), (9, 12), (10, 1)))
        self.assertEqual([x['text'] for x in fields['[name]']], ['林納斯大叔', '賽麗亞'])
        self.assertEqual([x['table'] for x in fields['[name]']], ['a.str', 'b.str'])

    def test_direct_big5_and_simplified_source_use_explicit_encoding(self):
        original = FakeLibrary()
        self.assertEqual(TextResolver(original).fields(tokens((5, 0), (7, 2)))['[name]'][0]['text'], '古老的羊毛背心')
        simplified = FakeLibrary('gb18030')
        simplified.files['a.str'] = 'name_1>铁匠林纳斯\r\n'.encode('gb18030')
        self.assertEqual(TextResolver(simplified, 'gb18030').fields(tokens((5, 0), (9, 11), (10, 1)))['[name]'][0]['text'], '铁匠林纳斯')

    def test_reference_must_be_adjacent_and_not_cross_field_boundary(self):
        resolver = TextResolver(FakeLibrary())
        self.assertEqual(resolver.fields(tokens((5, 0), (9, 11), (2, 0), (10, 1))), {})
        self.assertEqual(resolver.fields(tokens((5, 0), (9, 11), (5, 3), (10, 1))), {})

    def test_missing_link_is_explicit_and_duplicate_table_keys_are_reported(self):
        lib = FakeLibrary()
        lib.files['a.str'] = b'name_2>missing other key\n'
        record = TextResolver(lib).fields(tokens((5, 0), (9, 11), (10, 1)))['[name]'][0]
        self.assertTrue(record['missing'])
        self.assertEqual(record['key'], 'name_1')
        table, duplicates = parse_table('name_1>甲\r\r\n續行\r\nname_1>乙\r\n'.encode('cp950'))
        self.assertEqual(table['name_1']['text'], '甲\n續行')
        self.assertEqual(duplicates, ['name_1'])

    def test_bad_stream_and_string_bounds_fail_explicitly(self):
        lib = FakeLibrary()
        with self.assertRaises(ValueError):
            TextResolver(lib).fields(b'\xb0\xd0\x05')
        with self.assertRaises(ValueError):
            string_bytes(lib.strings, -1)
        with self.assertRaises(ValueError):
            TextResolver(lib).fields(tokens((5, 9999)))


if __name__ == '__main__':
    unittest.main()

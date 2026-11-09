"""CRC and explicit client-transform regressions; no private library needed."""
import hashlib
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

import dnf_pvf_archive as reader


def encrypt(raw, key):
    words = struct.unpack('<'+'I'*(len(raw)//4), raw)
    return struct.pack('<'+'I'*len(words), *[
        (((word << 6) | (word >> 26)) & 0xffffffff) ^ key ^ 0x81a79011 for word in words])


def fixture(transformed=False):
    content = struct.pack('<3I', 1, 8, 9)+b'x'
    padded = content+b'\0'*3
    name, name_hash = b'stringtable.bin', 12345
    crc = zlib.crc32(padded, name_hash) & 0xffffffff
    tree = struct.pack('<II', name_hash, len(name))+name+struct.pack('<III', len(content), crc, 0)
    tree = tree.ljust(2101248 if transformed else (len(tree)+3)&~3, b'\0')
    key = zlib.crc32(tree, 1) & 0xffffffff
    if transformed:
        tree = bytearray(tree)
        for block in range(1024):
            offset = 4096-20+2048*block
            for i, value in enumerate(reader.CLIENT_DIRECTORY_MASK):
                tree[offset+i] ^= value
    return struct.pack('<5I', 0, 48984, len(tree), key, 1)+encrypt(tree, key)+encrypt(padded, crc)


class ArchiveTest(unittest.TestCase):
    def test_standard_archive_and_payload_crc(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'fixture.pvf'
            raw = fixture()
            path.write_bytes(raw)
            archive = reader.Archive(path)
            self.assertEqual(archive.strings.get(0), 'x')
            archive.close()
            path.write_bytes(raw[:-1]+bytes([raw[-1] ^ 1]))
            with self.assertRaisesRegex(ValueError, 'File CRC mismatch'):
                reader.Archive(path, allow_known_client_transform=True)

    def test_transform_is_explicit_hash_scoped_and_crc_checked(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'fixture.pvf'
            raw = fixture(transformed=True)
            path.write_bytes(raw)
            for enabled in (False, True):
                with self.assertRaisesRegex(ValueError, 'Directory CRC mismatch'):
                    reader.Archive(path, allow_known_client_transform=enabled)
            with patch.object(reader, 'CLIENT_IMAGE_SHA', hashlib.sha256(raw).hexdigest()):
                archive = reader.Archive(path, allow_known_client_transform=True)
                self.assertEqual(archive.strings.get(0), 'x')
                self.assertTrue(archive.directory_transform)
                archive.close()
            self.assertEqual(path.read_bytes(), raw)
            broken = bytearray(raw)
            broken[500] ^= 1
            path.write_bytes(broken)
            with patch.object(reader, 'CLIENT_IMAGE_SHA', hashlib.sha256(broken).hexdigest()):
                with self.assertRaisesRegex(ValueError, 'Directory CRC mismatch'):
                    reader.Archive(path, allow_known_client_transform=True)


class IndexedArchiveTest(unittest.TestCase):
    def setUp(self):
        self.anchor = b'known independent plaintext anchor of distinct size'
        self.body = b'A' * 32 + b'tested'
        near_match = self.body[:-1] + b'!'
        key = bytes(range(len(self.anchor)))
        rows = [(0, self.anchor), (1, near_match), (1, self.body), (1, self.body)]
        data = bytearray(reader.INDEXED_HEADER.pack(48984, len(rows) << 13))
        contents = bytearray()
        for i, (flag, body) in enumerate(rows):
            data += reader.INDEXED_ENTRY.pack(i + 1, i + 2, i + 3, i + 4, flag, len(contents), len(body))
            contents += bytes(a ^ b for a, b in zip(body, key))
        self.archive = bytes(data + contents)

    def test_pinned_indexed_comparison_uses_whole_payload_and_retains_aliases(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'indexed.pvf'
            path.write_bytes(self.archive)
            entries = {'a.ani': self.body, 'missing.ani': self.body[:-1] + b'?'}
            with self.assertRaisesRegex(ValueError, 'Unrecognized indexed PVF SHA256'):
                reader.indexed_payload_mask(path, self.anchor, len(self.body))
            with patch.object(reader, 'INDEXED_CLIENT_SHA', hashlib.sha256(self.archive).hexdigest()):
                mask = reader.indexed_payload_mask(path, self.anchor, len(self.body))
                result = reader.compare_indexed_payloads(path, mask, entries)
            self.assertEqual(result['index_entries'], 4)
            self.assertEqual(result['without_exact_match'], ['missing.ani'])
            self.assertEqual(result['exact_content_matches']['a.ani']['sha256'], hashlib.sha256(self.body).hexdigest())
            self.assertEqual([r['index'] for r in result['exact_content_matches']['a.ani']['rows']], [2, 3])
            self.assertEqual(path.read_bytes(), self.archive)

    def test_rejects_noncontiguous_offsets_and_trailing_bytes(self):
        broken = bytearray(self.archive)
        struct.pack_into('<I', broken, reader.INDEXED_HEADER.size + 17, 1)
        with self.assertRaisesRegex(ValueError, 'Invalid indexed PVF entry'):
            reader._indexed_layout(broken)
        with self.assertRaisesRegex(ValueError, 'Indexed PVF payload end'):
            reader._indexed_layout(self.archive + b'\0')


if __name__ == '__main__':
    unittest.main()

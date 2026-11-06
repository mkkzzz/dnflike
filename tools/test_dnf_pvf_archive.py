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


if __name__ == '__main__':
    unittest.main()

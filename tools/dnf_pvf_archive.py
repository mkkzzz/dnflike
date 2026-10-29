"""Read-only standard GUID-header PVF reader with directory and file CRC checks.

Algorithm matches the already used config_library.py extraction: XOR then ROR6,
directory CRC seeded by file count, payload CRC seeded by filename hash. Refuse
nonstandard client headers and CRC mismatches instead of guessing or patching.
"""
from __future__ import annotations

import array
from pathlib import Path
import hashlib
import struct
import sys
import zlib

from audit_dnf_design import Strings
from dnf_pvf import parse_list


def decrypt(data: bytes, key: int) -> bytes:
    if len(data) % 4:
        raise ValueError('PVF block is not four-byte aligned')
    words = array.array('I', data)
    if words.itemsize != 4:
        raise ValueError('Platform unsigned int size is not four bytes')
    if sys.byteorder != 'little':
        words.byteswap()
    key ^= 0x81a79011
    result = array.array('I', ((((n ^ key) >> 6) | ((n ^ key) << 26)) & 0xffffffff for n in words))
    if sys.byteorder != 'little':
        result.byteswap()
    return result.tobytes()


class Archive:
    def __init__(self, path: Path):
        self.path = path.resolve()
        self.data = self.path.read_bytes()
        if len(self.data) < 20:
            raise ValueError('Truncated PVF header')
        guid = struct.unpack_from('<I', self.data)[0]
        if not 0 <= guid <= 256:
            raise ValueError('Nonstandard header; standard GUID reader not applicable')
        if 20 + guid > len(self.data):
            raise ValueError('Truncated GUID header')
        self.version, length, key, count = struct.unpack_from('<4I', self.data, 4 + guid)
        self.base = 20 + guid + length
        if self.base > len(self.data) or count > length // 20:
            raise ValueError('PVF directory outside archive')
        tree = decrypt(self.data[20 + guid:self.base], key)
        if zlib.crc32(tree, count) & 0xffffffff != key:
            raise ValueError('Directory CRC mismatch')
        self.entries = {}
        pos = 0
        for _ in range(count):
            if pos + 8 > len(tree):
                raise ValueError('Truncated tree record')
            name_hash, length = struct.unpack_from('<2I', tree, pos)
            pos += 8
            if not 0 < length <= 4096 or pos + length + 12 > len(tree):
                raise ValueError('Tree entry out of bounds')
            name = tree[pos:pos + length].decode('cp949').replace('\\', '/').lower()
            pos += length
            size, crc, offset = struct.unpack_from('<3I', tree, pos)
            pos += 12
            if self.base + offset + ((size + 3) & ~3) > len(self.data):
                raise ValueError('Payload out of bounds: ' + name)
            if name in self.entries:
                raise ValueError('Duplicate archive path: ' + name)
            self.entries[name] = (name_hash, size, crc, offset)
        raw = self.raw('stringtable.bin')
        if raw is None:
            raise ValueError('Missing stringtable.bin')
        self.strings = Strings(raw[0])

    def exists(self, path):
        return path.lower() in self.entries

    def raw(self, path):
        if not self.exists(path):
            return None
        name_hash, size, crc, offset = self.entries[path.lower()]
        data = decrypt(self.data[self.base + offset:self.base + offset + ((size + 3) & ~3)], crc)
        if zlib.crc32(data, name_hash) & 0xffffffff != crc:
            raise ValueError('File CRC mismatch: ' + path)
        data = data[:size]
        return data, hashlib.sha256(data).hexdigest()

    def listing(self, path):
        raw = self.raw(path)
        return parse_list(raw[0], self.strings) if raw else {}

    def scripts(self):
        for path in sorted(self.entries):
            if Path(path).suffix in ('.qst', '.equ', '.stk'):
                raw, sha = self.raw(path)
                yield path, raw, sha, True

    def close(self):
        self.data = b''

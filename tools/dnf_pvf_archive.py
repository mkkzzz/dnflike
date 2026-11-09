"""Read-only standard GUID-header PVF reader with directory and file CRC checks.

Algorithm matches the already used config_library.py extraction: XOR then ROR6,
directory CRC seeded by file count, payload CRC seeded by filename hash. Refuse
nonstandard client headers and CRC mismatches in the standard reader. An explicit option decodes the
identified ImagePacks2 client directory transform in memory, retaining ALL CRC
checks and leaving the source file unchanged.
The separate indexed audit supports only the two pinned nonstandard archives.
"""
from __future__ import annotations

import array
from collections import defaultdict
from pathlib import Path
import hashlib
import mmap
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


# Evidence: 2026-11-06 client/backup audit. Restricted to this exact archive;
# unknown layouts must fail instead of using a guessed deobfuscation fallback.
CLIENT_IMAGE_SHA = '3893d5d1506bcc332ca4b6438f6f884d128481641483bee9478cad8d0221fe01'
CLIENT_DIRECTORY_MASK = bytes.fromhex('e351a3418a09d5c468cf381b4c657f462bf281425d5267f4')

# These are separate indexed variants. Four opaque words identify an entry;
# their filename algorithm has not been recovered.
INDEXED_CLIENT_SHA = '3c0e8050082ddf922abe0fe9643f3550cf42ab14576caf2ba6b1aeb3881bcea4'
INDEXED_VIDEO_SHA = 'cfea184b6a26252e41fd419765eadd07fb748c5e0759f04d937d21cce7a99542'
INDEXED_HEADER = struct.Struct('<II')
INDEXED_ENTRY = struct.Struct('<IIIIBII')


def _indexed_entries(data, count):
    for i in range(count):
        entry = INDEXED_ENTRY.unpack_from(data, INDEXED_HEADER.size + INDEXED_ENTRY.size * i)
        yield i, entry


def _indexed_layout(data):
    if len(data) < INDEXED_HEADER.size:
        raise ValueError('Truncated indexed PVF header')
    version, encoded_count = INDEXED_HEADER.unpack_from(data)
    count = encoded_count >> 13
    base = INDEXED_HEADER.size + count * INDEXED_ENTRY.size
    if version != 48984 or encoded_count != count << 13 or not count or base > len(data):
        raise ValueError('Invalid indexed PVF header')
    end = 0
    order = 0
    for _, (_, _, _, identifier, flag, offset, length) in _indexed_entries(data, count):
        if identifier < order or flag not in (0, 1) or offset != end or base + offset + length > len(data):
            raise ValueError('Invalid indexed PVF entry')
        order = identifier
        end = offset + length
    if base + end != len(data):
        raise ValueError('Indexed PVF payload end differs')
    return version, count, base


def indexed_payload_mask(path, stringtable, prefix_length):
    """Derive the observed per-record XOR prefix from the root archive's unique anchor."""
    if not stringtable or not 0 <= prefix_length <= len(stringtable):
        raise ValueError('Indexed PVF payload exceeds verified prefix length')
    with Path(path).open('rb') as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as data:
        if hashlib.sha256(data).hexdigest() != INDEXED_CLIENT_SHA:
            raise ValueError('Unrecognized indexed PVF SHA256')
        _, count, base = _indexed_layout(data)
        anchors = [base + offset for _, (_, _, _, _, flag, offset, length) in _indexed_entries(data, count)
                   if flag == 0 and length == len(stringtable)]
        if len(anchors) != 1:
            raise ValueError('Indexed PVF stringtable anchor differs')
        anchor = anchors[0]
        return bytes(a ^ b for a, b in zip(data[anchor:anchor + prefix_length], stringtable[:prefix_length]))


def compare_indexed_payloads(path, mask, known_payloads):
    """Find full matches for CRC-verified named records using the known-plaintext mask.

    Filename lookup and the stringtable used to derive the mask are outside the comparison.
    """
    if 'stringtable.bin' in known_payloads or any(len(body) > len(mask) for body in known_payloads.values()):
        raise ValueError('Indexed PVF comparisons need an independent and complete payload prefix')
    with Path(path).open('rb') as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as data:
        digest = hashlib.sha256(data).hexdigest()
        if digest not in {INDEXED_CLIENT_SHA, INDEXED_VIDEO_SHA}:
            raise ValueError('Unrecognized indexed PVF SHA256')
        version, count, base = _indexed_layout(data)
        expected = {name: bytes(a ^ b for a, b in zip(body, mask)) for name, body in known_payloads.items()}
        by_prefix = defaultdict(list)
        for name, body in expected.items():
            by_prefix[len(body), body[:32]].append(name)
        matches = defaultdict(list)
        for index, entry in _indexed_entries(data, count):
            offset, length = entry[-2:]
            start = base + offset
            candidates = by_prefix.get((length, data[start:start + min(32, length)]), ())
            for name in candidates:
                if data[start:start + length] == expected[name]:
                    matches[name].append({'index': index, 'opaque_id': list(entry[:4]), 'flag': entry[4],
                                          'offset': start, 'bytes': length})
        found = {name: {'sha256': hashlib.sha256(known_payloads[name]).hexdigest(), 'rows': rows}
                 for name, rows in matches.items()}
        return {'sha256': digest, 'version': version, 'index_entries': count, 'payload_base': base,
                'known_plaintext_prefix_bytes': len(mask), 'exact_content_matches': found,
                'without_exact_match': sorted(known_payloads.keys() - matches.keys())}


class Archive:
    def __init__(self, path: Path, *, allow_known_client_transform=False):
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
        self.directory_transform = ''
        if zlib.crc32(tree, count) & 0xffffffff != key and allow_known_client_transform:
            if hashlib.sha256(self.data).hexdigest() == CLIENT_IMAGE_SHA:
                decoded = bytearray(tree)
                # Absolute file offsets 4096 + n*2048, 1024 blocks, 24 bytes
                # each; XOR mask shown here is after the normal ROR6 decrypt.
                for block in range(1024):
                    start = 4096 - (20 + guid) + block * 2048
                    for index, value in enumerate(CLIENT_DIRECTORY_MASK):
                        decoded[start + index] ^= value
                tree = bytes(decoded)
                self.directory_transform = 'known_imagepacks2_xor24_stride2048_blocks1024'
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

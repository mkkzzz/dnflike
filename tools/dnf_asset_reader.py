"""Strict native IMG reader for the selected local DNF validation assets.

Reference formats: https://github.com/HsOjo/PyDnfEx/ . Pixel conversion uses
Neople-style 1555 bit replication and RGBA V4 palettes. No client executables.
"""
from __future__ import annotations
from array import array
from functools import lru_cache
import io
import struct
import zlib
from PIL import Image


def parse(data: bytes) -> dict:
    if len(data) < 32 or not data.startswith((b'Neople Img File', b'Neople Image Fil')):
        raise ValueError('Unsupported IMG header')
    version, count = struct.unpack_from('<2I', data, 24)
    if version not in (1, 2, 4) or count > 100000:
        raise ValueError('Unsupported IMG version/count')
    pos, palette, frames = 32, None, []
    if version == 4:
        colors = struct.unpack_from('<I', data, pos)[0]
        pos += 4
        palette = data[pos:pos + colors * 4]
        pos += colors * 4
    for index in range(count):
        fmt = struct.unpack_from('<i', data, pos)[0]
        if fmt == 17:
            frames.append({'frame': index, 'link': struct.unpack_from('<i', data, pos + 4)[0]})
            pos += 8
            continue
        fmt, extra, w, h, size, x, y, cw, ch = struct.unpack_from('<9i', data, pos)
        if fmt not in (14, 15, 16) or extra not in (5, 6) or min(w, h, size) < 0:
            raise ValueError(f'Unsupported frame {index}: {fmt}/{extra}')
        if extra == 5 and version in (1, 2):
            size = w * h * (4 if fmt == 16 else 2)
        pos += 36
        fr = dict(frame=index, format=fmt, extra=extra, w=w, h=h, size=size,
                  x=x, y=y, cw=cw, ch=ch)
        if version == 1:
            fr['offset'] = pos
            pos += size
        frames.append(fr)
    if version == 2:
        start = 32 + struct.unpack_from('<I', data, 16)[0]
        if start < pos:
            raise ValueError('IMG index overlaps data')
        pos = start
    if version in (2, 4):
        for fr in frames:
            if 'link' not in fr:
                fr['offset'] = pos
                pos += fr['size']
    if pos > len(data):
        raise ValueError('IMG pixel payload exceeds file')
    return dict(version=version, frames=frames, palette=palette)


@lru_cache(maxsize=2)
def lookup(fmt: int):
    values = []
    for v in range(65536):
        if fmt == 14:
            r, g, b = (v >> 10) & 31, (v >> 5) & 31, v & 31
            values.append(bytes(((r << 3) | (r >> 2), (g << 3) | (g >> 2),
                                 (b << 3) | (b >> 2), (v >> 15) * 255)))
        else:
            values.append(bytes((((v >> 8) & 15) << 4, ((v >> 4) & 15) << 4,
                                 (v & 15) << 4, ((v >> 12) & 15) << 4)))
    return values


def decode(data: bytes, parsed: dict, index: int):
    frames = parsed['frames']
    fr, seen = frames[index], set()
    while 'link' in fr:
        if fr['link'] in seen or not 0 <= fr['link'] < len(frames):
            raise ValueError('Circular/out-of-range IMG link')
        seen.add(fr['link'])
        fr = frames[fr['link']]
    if not fr['w'] or not fr['h']:
        return Image.new('RGBA', (1, 1)), fr
    raw = data[fr['offset']:fr['offset'] + fr['size']]
    if fr['extra'] == 6:
        dec = zlib.decompressobj()
        raw = dec.decompress(raw, 100000001)
        if not dec.eof or dec.unconsumed_tail:
            raise ValueError('Incomplete/oversized IMG zlib payload')
    if parsed['palette'] and fr['extra'] == 6:
        palette = parsed['palette']
        if len(raw) != fr['w'] * fr['h']:
            raise ValueError('Palette pixel count mismatch')
        raw = b''.join(palette[x * 4:x * 4 + 4] for x in raw)
    elif fr['format'] in (14, 15):
        if len(raw) != fr['w'] * fr['h'] * 2:
            raise ValueError('16-bit pixel count mismatch')
        words = array('H')
        words.frombytes(raw)
        if __import__('sys').byteorder != 'little':
            words.byteswap()
        lut = lookup(fr['format'])
        raw = b''.join(lut[x] for x in words)
    else:
        if len(raw) != fr['w'] * fr['h'] * 4:
            raise ValueError('32-bit pixel count mismatch')
        return Image.frombytes('RGBA', (fr['w'], fr['h']), raw, 'raw', 'BGRA'), fr
    return Image.frombytes('RGBA', (fr['w'], fr['h']), raw), fr

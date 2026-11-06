"""Read-only CHR scalar writes and the bounded 834460 growth prefix.

Original PE bytes are data, never executed by the OS. Lexer, secure reads and
class/catalog lookup are explicit ABI inputs; final character stats are excluded.
"""
import argparse
from contextlib import closing
import hashlib
import json
import math
from pathlib import Path
import sys

from audit_dnf_firewave import extra_step
from audit_dnf_ice_shatter import fbits, real
from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_native_strings import ENGINE_SHA

FRAME, STACK, STAT = 0x6fffe000, 0x6fffdf00, 0x60100000
ACTOR, INFO, CATALOG, CLASS = 0x60200000, 0x60300000, 0x60400000, 0x60500000
# Independently transcribed native writes. Values remain source-field identities,
# not a guessed mapping to Strength, Intelligence or final gameplay units.
FIELDS = {
    '[hp max]': (0, 4), '[mp max]': (4, 4),
    '[physical attack]': (8, 2), '[physical defense]': (10, 2),
    '[magical attack]': (12, 2), '[magical defense]': (14, 2),
    '[fire resistance]': (16, 2), '[water resistance]': (18, 2),
    '[dark resistance]': (20, 2), '[light resistance]': (22, 2),
    '[inventory limit]': (58, 4), '[hp regen speed]': (62, 2),
    '[mp regen speed]': (64, 2), '[move speed]': (66, 4),
    '[attack speed]': (70, 2), '[cast speed]': (72, 2),
    '[hit recovery]': (74, 2), '[jump power]': (76, 2), '[weight]': (78, 4),
}
ACCUMULATED = [(0, 4), (4, 4)] + [(i, 2) for i in range(8, 58, 2)] + [
    (58, 4), (62, 2), (64, 2), (66, 4), (70, 2), (72, 2), (74, 2), (76, 2), (78, 4)]


def f32(v):
    return real(fbits(v))


def stored_number(value, width):
    """Independent finite-input oracle: binary32 multiply, sign-aware half add."""
    v = f32(f32(value) * 10.0)
    v = f32(v + (0.5 if v >= 0 else -0.5))
    if not math.isfinite(v) or not -2147483648 <= math.trunc(v) <= 2147483647:
        raise ValueError('Conversion outside audited finite domain')
    return math.trunc(v) & ((1 << (width * 8)) - 1)


def extension(c, xmm, fp, ins):
    """Only observed finite SSE/x87 moves and signed multiply forms."""
    def get(op):
        return xmm[ins.reg_name(op.reg)] if op.type == 1 and ins.reg_name(op.reg).startswith('xmm') else c.get(ins, op)
    if ins.mnemonic in ('addss', 'subss', 'comiss'):
        a, b = [real(get(o)) for o in ins.operands]
        if not all(map(math.isfinite, (a, b))):
            raise ValueError('Nonfinite arithmetic not modeled')
        if ins.mnemonic == 'comiss':
            c.flags = (c.flags & ~0x8d5) | (1 if a < b else 0x40 if a == b else 0)
        else:
            name = ins.reg_name(ins.operands[0].reg)
            xmm[name] = (xmm[name] & ~0xffffffff) | fbits(a + b if ins.mnemonic == 'addss' else a - b)
    elif ins.mnemonic == 'fld' and len(ins.operands) == 1 and ins.operands[0].size == 4:
        fp.append(real(c.get(ins, ins.operands[0])))
    elif ins.mnemonic == 'fstp' and len(ins.operands) == 1 and ins.operands[0].size == 4:
        c.put(ins, ins.operands[0], fbits(fp.pop()))
    elif ins.mnemonic in ('rep movsd', 'movsw', 'movsb'):
        width = {'rep movsd': 4, 'movsw': 2, 'movsb': 1}[ins.mnemonic]
        count = c.reg['ecx'] if ins.mnemonic.startswith('rep ') else 1
        if count > 128:
            raise ValueError('Copy budget')
        delta = -width if c.flags & 0x400 else width
        for _ in range(count):
            c.write(c.reg['edi'], width, c.read(c.reg['esi'], width))
            c.reg['edi'] += delta
            c.reg['esi'] += delta
        if ins.mnemonic.startswith('rep '):
            c.reg['ecx'] = 0
    elif ins.mnemonic == 'imul' and len(ins.operands) in (2, 3):
        dst = ins.operands[0]
        left, right = ins.operands if len(ins.operands) == 2 else ins.operands[1:]
        def signed_operand(o):
            bits = o.size * 8
            v = c.get(ins, o) & ((1 << bits) - 1)
            return v - (1 << bits) if v & (1 << (bits - 1)) else v
        value = signed_operand(left) * signed_operand(right)
        c.put(ins, dst, value)
        fits = -(1 << (dst.size * 8 - 1)) <= value < (1 << (dst.size * 8 - 1))
        c.flags = (c.flags & ~0x801) | (0 if fits else 0x801)
    else:
        extra_step(c, xmm, ins)
        return
    c.pc += ins.size


def step(c, source, xmm, fp, calls):
    result = c.run(c.pc, 1)
    if result[0] == 'budget':
        return
    ins = next(source.decoder.disasm(source.source_bytes(c.pc, 15), c.pc, count=1))
    if result[0] == 'call' and int(result[2], 16) in calls:
        c.push(c.pc + ins.size)
        c.pc = int(result[2], 16)
    elif result[0] == 'unsupported':
        extension(c, xmm, fp, ins)
    else:
        raise ValueError('Unmodeled execution: ' + str(result))


def scalar(source, tag, values, poison=False, token_type=None):
    from dnf_native_vm_probe import CPU
    key = tag.lower()
    if key not in FIELDS or not values:
        raise ValueError('Unsupported scalar fixture')
    c = CPU(source)
    for a in range(FRAME - 0x1000, FRAME + 0x100, 4):
        c.write(a, 4, 0)
    for a in range(STAT - 4, STAT + 0x5b):
        c.write(a, 1, 0xa5)
    c.reg.update(ebp=FRAME, esp=STACK, ebx=STAT, edi=0x60000000, esi=29)
    if poison:
        c.string_clobber = (0xbaadf00d, 0xbad0c0de, 0xa97)
    xmm = {f'xmm{i}': 0 for i in range(8)}
    fp, writes, readers, stops = [], [], [], []
    original_write = c.write
    def observe(a, n, v):
        original_write(a, n, v)
        if STAT - 4 <= a < STAT + 0x5b:
            writes.append([hex(a - STAT), n, v & ((1 << (n * 8)) - 1)])
    c.write = observe
    def finish(value):
        c.reg['eax'] = value & 0xffffffff
        c.pc = c.pop()
        c.reg['ecx'], c.reg['edx'], c.flags = (0xbaadf00d, 0xbad0c0de, 0xa97) if poison else (0, 0, 0x202)
        for name in xmm:
            xmm[name] = 0x123456789abcdef if poison else 0
    for value in values:
        actual_type = token_type if token_type is not None else 2 if type(value) == int else 4
        c.pc = 0x129c8e1
        for _ in range(2500):
            if c.pc in (0x129e5b1, 0x129eddd):
                stops.append(hex(c.pc))
                break
            if c.pc == 0x401dd0:
                a, b = (c.read(c.reg['esp'] + j, 4) for j in (4, 8))
                if a != FRAME - 0x230 or b not in c.strings:
                    raise ValueError('Comparison ABI')
                native_tag = {'[hp max]': '[HP MAX]', '[mp max]': '[MP MAX]',
                    '[hp regen speed]': '[HP regen speed]', '[mp regen speed]': '[MP regen speed]'}.get(key, key)
                finish(int(c.strings[b] == native_tag))
                continue
            if c.pc in (0x119a6f0, 0x119a800, 0x119a820, 0x119a860):
                if c.reg['ecx'] != 0x1d176c8:
                    raise ValueError('Lexer ABI')
                target = c.pc
                readers.append(hex(target))
                if target == 0x119a6f0:
                    finish(actual_type)
                elif target == 0x119a860:
                    fp.append(f32(value))
                    finish(0)
                else:
                    if type(value) != int or not -2147483648 <= value <= 2147483647:
                        raise ValueError('Integer lexer input')
                    finish(value)
                continue
            step(c, source, xmm, fp, {0x1194fc0, 0x401dd0, 0x1218bd0, 0x1218b30,
                0x119a6f0, 0x119a800, 0x119a820, 0x119a860, 0x112acd0})
        else:
            raise ValueError('Scalar instruction budget')
        if c.pc == 0x129eddd:
            break
    row = {'fixture': {'tag': tag, 'values': values, 'poison': poison, 'token_type': token_type},
        'writes': writes, 'readers': readers, 'stops': stops,
        'bytes': bytes(c.read(a, 1) for a in range(STAT - 4, STAT + 0x5b)).hex(),
        'abi': [c.reg[k] for k in ('ebx', 'esi', 'edi', 'ebp', 'esp')], 'fp_depth': len(fp),
        'steps': len(c.trace), 'trace_sha256': trace_hash(c.trace)}
    return row, c.trace


def verify_scalar(row):
    f = row['fixture']
    off, width = FIELDS[f['tag'].lower()]
    valid = f['token_type'] is None or f['token_type'] in (2, 3, 4)
    writes, readers = [], []
    for value in f['values']:
        kind = f['token_type'] if f['token_type'] is not None else 2 if type(value) == int else 4
        readers.append('0x119a6f0')
        if not valid:
            break
        readers.append(hex({2: 0x119a800, 3: 0x119a820, 4: 0x119a860}[kind]))
        writes.append([hex(off), width, stored_number(value, width)])
    expected = bytearray([0xa5] * 95)
    if writes:
        expected[off + 4:off + 4 + width] = writes[-1][2].to_bytes(width, 'little')
    stops = ['0x129e5b1'] * len(f['values']) if valid else ['0x129eddd']
    if (row['writes'], row['readers'], row['stops'], row['bytes']) != (writes, readers, stops, expected.hex()):
        raise ValueError('CHR scalar conversion/write mismatch')
    if row['abi'] != [STAT, 29, 0x60000000, FRAME, STACK] or row['fp_depth']:
        raise ValueError('CHR scalar ABI mismatch')


def growth(source, level, job, tables, extra, poison=False):
    """Execute 834460..834644, before later mode/modifier/final writes."""
    from dnf_native_vm_probe import CPU
    if not 1 <= level <= 100 or not 0 <= job <= 5 or len(tables) != 7 or len(bytes.fromhex(extra)) != 0x57:
        raise ValueError('Bounded growth fixture')
    c = CPU(source)
    for a in range(0x6fffc000, 0x70000000, 4):
        c.write(a, 4, 0)
    for index, raw in enumerate(tables):
        if len(bytes.fromhex(raw)) != 0x57:
            raise ValueError('CHR record size')
        for j, b in enumerate(bytes.fromhex(raw)):
            c.write(CATALOG + 0x24 + index * 0x57 + j, 1, b)
    for j, b in enumerate(bytes.fromhex(extra)):
        c.write(INFO + 0x32c + j, 1, b)
    c.reg.update(ecx=ACTOR, ebx=17, esi=29, edi=31, ebp=37)
    c.write(ACTOR, 4, 0x16f972c)
    c.write(ACTOR + 0x5664, 4, INFO)
    c.write(INFO + 0xc, 4, job)
    c.write(CLASS, 4, 0)
    c.write(0x1a5fa7c, 4, 0x60600000)  # prepared catalog service, not its constructor
    xmm = {f'xmm{i}': 0 for i in range(8)}
    fp, selected, services = [], [], []
    c.pc = 0x834460
    def finish(value, pop_bytes=0):
        c.reg['eax'] = value
        c.pc = c.pop()
        c.reg['esp'] += pop_bytes
        c.reg['ecx'], c.reg['edx'], c.flags = (0xbaadf00d, 0xbad0c0de, 0xa97) if poison else (0, 0, 0x202)
    for _ in range(6000):
        if c.pc == 0x834644:
            break
        if c.pc == 0x1195eb0:
            if c.reg['ecx'] != INFO + 0x18 or c.read(c.reg['esp'] + 4, 4) != INFO + 0x20:
                raise ValueError('Level secure ABI')
            out = c.read(c.reg['esp'] + 8, 4)
            c.write(out, 4, level)
            services.append('secure_info_18')
            finish(0, 8)
            continue
        if c.pc == 0x8344aa:
            if c.reg['ecx'] != ACTOR or c.reg['edx'] != int.from_bytes(source.source_bytes(0x16f972c + 0x738, 4), 'little'):
                raise ValueError('Class vtable ABI')
            services.append('class_virtual_738')
            c.reg['eax'] = CLASS
            c.reg['ecx'], c.reg['edx'], c.flags = (0xbaadf00d, 0xbad0c0de, 0xa97) if poison else (0, 0, 0x202)
            c.pc += 2
            continue
        if c.pc == 0x112af50:
            if c.reg['ecx'] != 0x60600000 or c.read(c.reg['esp'] + 4, 4) != 0:
                raise ValueError('Catalog lookup ABI')
            services.append('class_catalog_lookup')
            finish(CATALOG, 4)
            continue
        if c.pc == 0x834527:
            p = c.reg['edx']
            selected.append({'source': 'info_extra' if p == INFO + 0x32c else hex(p - CATALOG), 'factor': c.reg['ecx']})
        step(c, source, xmm, fp, {0x1195eb0, 0x112af50})
    else:
        raise ValueError('Growth instruction budget')
    frame = 0x6ffffffc
    return {'fixture': {'level': level, 'job': job, 'tables': tables, 'extra': extra, 'poison': poison},
        'selected': selected, 'services': services,
        'bytes': bytes(c.read(frame - 0x5c + j, 1) for j in range(0x57)).hex(),
        'stop': hex(c.pc), 'abi': [c.reg[k] for k in ('ebx', 'ebp', 'esp')],
        'steps': len(c.trace), 'trace_sha256': trace_hash(c.trace)}, c.trace


def verify_growth(row):
    f = row['fixture']
    expected = bytearray.fromhex(f['tables'][0])
    selection = [('0x7b', min(f['level'], 18) - 1, f['tables'][1])]
    if f['level'] > 18:
        selection.append((hex(0x7b + f['job'] * 0x57), f['level'] - 18, f['tables'][f['job'] + 1]))
    selection.append(('info_extra', 1, f['extra']))
    for _, factor, data in selection:
        data = bytes.fromhex(data)
        for off, width in ACCUMULATED:
            a = int.from_bytes(expected[off:off + width], 'little')
            b = int.from_bytes(data[off:off + width], 'little')
            v = (a + factor * b) & ((1 << (width * 8)) - 1)
            expected[off:off + width] = v.to_bytes(width, 'little')
    if row['bytes'] != expected.hex() or row['selected'] != [{'source': a, 'factor': b} for a, b, _ in selection]:
        raise ValueError('Growth record arithmetic/selection mismatch')
    if row['services'] != ['secure_info_18', 'class_virtual_738', 'class_catalog_lookup'] or row['stop'] != '0x834644' or row['abi'] != [ACTOR, 0x6ffffffc, 0x6fffff60]:
        raise ValueError('Growth boundary/ABI mismatch')


def census():
    from dnf_pvf import open_library, parse_script, canonical
    files, unique = [], {}
    with closing(open_library()) as lib:
        version = lib.asset_version
        for path, raw in lib.files('.chr'):
            fields = []
            scope = parent = None
            for field in parse_script(raw, lib.strings, 'chr')['fields']:
                tag = canonical(field['tag']).lower()
                if tag == '[initial value]' or tag.startswith('[growtype '):
                    scope = parent = tag
                elif tag in ('[awakening 1]', '[awakening 2]'):
                    scope = parent + '/' + tag
                if tag not in FIELDS:
                    continue
                values = field['values']
                if len(values) != 1 or type(values[0]) not in (int, float):
                    raise ValueError('Unexpected CHR scalar: ' + path)
                value = values[0]
                key = (tag, type(value).__name__, value)
                unique[key] = {'tag': tag, 'values': [value]}
                fields.append({'tag': tag, 'scope': scope, 'offset': field['offset'], 'value': value,
                    'stored_bits': stored_number(value, FIELDS[tag][1])})
            files.append({'path': path, 'sha256': hashlib.sha256(raw).hexdigest(), 'fields': fields})
    return version, sorted(files, key=lambda r: r['path']), list(unique.values())


def audit(source):
    if hashlib.sha256(source.raw).hexdigest() != ENGINE_SHA:
        raise ValueError('Unexpected engine')
    version, files, fixtures = census()
    present = {f['tag'] for f in fixtures}
    fixtures += [{'tag': tag, 'values': [-1.25]} for tag in FIELDS if tag not in present]
    # Half ties, adjacent binary32 values, sign, word wrapping, repeats and failure.
    for tag in ('[hp max]', '[physical attack]'):
        fixtures += [{'tag': tag, 'values': [v]} for v in (0.0, -0.0, .049999997, .05, .050000004, -.05, 1.25, -1.25, 3276.8, -3276.8, 6553.6)]
        fixtures.append({'tag': tag, 'values': [7.5, 4.2, -1.25]})
    fixtures += [{'tag': '[hp max]', 'values': [17], 'token_type': 3},
        {'tag': '[mp max]', 'values': [999], 'token_type': 5}]
    scalar_rows, growth_rows, traces = [], [], []
    for poison in (False, True):
        for fixture in fixtures:
            row, trace = scalar(source, **fixture, poison=poison)
            verify_scalar(row)
            scalar_rows.append(row)
            traces.append(trace)
    # Distinct nonzero records catch wrong group selection, field widths and
    # dropping the extra record; suffix bytes must stay from initial copy.
    tables = []
    for index in range(7):
        buf = bytearray([0xd0 + index] * 0x57)
        for j, (off, width) in enumerate(ACCUMULATED):
            value = (65520 + index * 13 + j) if width == 2 else (0xffffffe0 + index * 19 + j)
            buf[off:off + width] = (value & ((1 << (width * 8)) - 1)).to_bytes(width, 'little')
        tables.append(buf.hex())
    extra = bytes((j * 13 + 7) % 256 for j in range(0x57)).hex()
    for poison in (False, True):
        for level in (1, 17, 18, 19, 60, 100):
            for job in range(6):
                row, trace = growth(source, level, job, tables, extra, poison)
                verify_growth(row)
                growth_rows.append(row)
                traces.append(trace)
    swordman = next(f for f in files if f['path'] == 'character/swordman/swordman.chr')
    actual_tables = []
    for scope in ['[initial value]'] + [f'[growtype {i}]' for i in range(1, 7)]:
        buf = bytearray(0x57)
        for field in swordman['fields']:
            if field['scope'] != scope:
                continue
            # Use the matching observed native write, not a second packing rule.
            match = next(r for r in scalar_rows if r['fixture']['tag'] == field['tag']
                and r['fixture']['token_type'] is None
                and type(r['fixture']['values'][0]) == type(field['value'])
                and r['fixture']['values'] == [field['value']])
            offset, width, value = match['writes'][-1]
            off = int(offset, 16)
            buf[off:off + width] = value.to_bytes(width, 'little')
        actual_tables.append(buf.hex())
    source_rows = []
    for poison in (False, True):
        for level in (1, 18, 19, 60):
            for job in range(5):
                row, trace = growth(source, level, job, actual_tables, bytes(0x57).hex(), poison)
                verify_growth(row)
                source_rows.append(row)
                traces.append(trace)
    names = ('audit_dnf_chr_numbers.py', 'dnf_native_vm_probe.py', 'audit_dnf_firewave.py',
        'audit_dnf_ice_shatter.py', 'audit_dnf_ice_particle_bindings.py', 'audit_dnf_native_strings.py',
        'audit_dnf_particle_axis.py', 'dnf_pvf.py')
    return {'schema': 'dnf_chr_numbers/1', 'engine_sha256': ENGINE_SHA, 'input_source': source.source,
        'asset_version': version, 'tools_sha256': {n: hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n', b'\n')).hexdigest() for n in names},
        'files': files, 'scalar_cases': scalar_rows, 'growth_cases': growth_rows,
        'source_growth': {'path': swordman['path'], 'sha256': swordman['sha256'], 'cases': source_rows,
            'fixture_boundary': 'Audited scalar writes populate initial/growtype records; all unmodeled bytes and INFO extra are explicitly zero fixtures, not proven constructor/default behavior.'},
        'constants': [{'address': hex(a), 'bytes': source.source_bytes(a, 4).hex(),
            'value': real(int.from_bytes(source.source_bytes(a, 4), 'little'))}
            for a in (0x16cf488, 0x155a170, 0x1556144)],
        'blocks': source_blocks(source, traces),
        'boundaries': [
            'Scalar replay starts at 129C8E1 with a prepared selected record; scope routing was separately audited.',
            '1194FC0 is existing string-decoder modeling; 401DD0 uses an explicit comparison fixture. Audited tags use their known spellings; general string comparison semantics are not proved.',
            '1218BD0/1218B30 and 112ACD0 execute original instructions; lexer token types and returned numeric values are ABI inputs.',
            'Finite binary32 arithmetic assumes round-to-nearest; x87 only transfers exactly representable binary32 values. Exceptions, NaNs and alternate rounding modes are excluded.',
            '19 scalar tags are searched across all archive CHR files; 16 occur. Missing fire/water resistance and HP regen speed use explicit synthetic fixtures. Each distinct archive tag/type/value is replayed, not every full file load.',
            '834460 growth prefix copies 87 bytes and accumulates 82 bytes. INFO+18, class virtual and catalog lookup remain explicit service fixtures.',
            'Growth stops at 834644 before mode multipliers, profile modifiers, final field conversion and character-stat writes.',
            'INFO+0C selects the growth column; its complete producer and awakening/default grant lifecycle are not proved here.',
            'No final HP/MP/Strength/Intelligence formula or runtime progression change is claimed.']}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('client', type=Path)
    p.add_argument('--decoder-dir', type=Path)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if args.client.resolve() == args.output.resolve():
        raise ValueError('Cannot overwrite source')
    if args.decoder_dir:
        sys.path.insert(0, str(args.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    result = audit(AxisEvaluator(args.client.read_bytes()))
    args.output.write_text(json.dumps(result, indent=1) + '\n', encoding='utf-8')
    print('CHR_NUMBERS files', len(result['files']), 'scalars', len(result['scalar_cases']), 'growth', len(result['growth_cases']))


if __name__ == '__main__':
    main()

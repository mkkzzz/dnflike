"""Replay the native CHR record copy and actor-property writer, not final stats."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from audit_dnf_chr_numbers import ACCUMULATED, extension, f32
from audit_dnf_ice_shatter import fbits, real
from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_native_strings import ENGINE_SHA

ROOT = Path(__file__).resolve().parents[1]
PREVIOUS = ROOT / 'docs/reports/ws2/2026-11/native_chr_numbers.json'
ACTOR, RECORD, MODE = 0x60000000, 0x60100000, 0x60200000
VTABLE = 0x16f972c
# Packed fields promoted into consecutive 12-byte protected slots by 1286CC0.
SIGNED_WORDS = set(range(16, 58, 2)) | {62, 64, 74, 76}
RAW_FIELDS = [(off, width, width == 2 and off in SIGNED_WORDS) for off, width in ACCUMULATED] + [(82, 1, False), (83, 4, False)]
# Source offset, width, signed interpretation, actor destination after /10.
CONVERTED = [(4, 4, False, 0x8d0)] + [(16 + i * 2, 2, True, 0x954 + i * 12) for i in range(4)] + [
    (24 + i * 2, 2, True, 0xa14 + i * 12) for i in range(17)] + [
    (58, 4, True, 0xbac), (62, 2, True, 0xbc4), (64, 2, True, 0xbdc),
    (66, 4, False, 0xbf4), (70, 2, False, 0xc0c), (72, 2, False, 0xc24),
    (74, 2, True, 0xc3c), (76, 2, True, 0xc6c), (78, 4, True, 0xc9c)]


def signed(v, bits=32):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def trunc_div(v, divisor):
    return -(abs(v) // divisor) if v < 0 else v // divisor


def replay(source, record, class_index=0, mode10=False, eligible=True,
           actor_index=-1, bonus=37, poison=False, caller=False):
    from dnf_native_vm_probe import CPU
    raw = bytes.fromhex(record)
    if len(raw) != 87:
        raise ValueError('Expected 87-byte packed record')
    c = CPU(source)
    for a in range(0x6fffc000, 0x70000000, 4):
        c.write(a, 4, 0)
    for i, b in enumerate(raw):
        c.write(RECORD + i, 1, b)
    c.write(ACTOR, 4, VTABLE)
    c.write(ACTOR + 0x3c08, 4, class_index)
    c.write(ACTOR + 0x644, 4, actor_index)
    c.write(0x70000004, 4, RECORD)
    c.reg.update(ecx=ACTOR, ebx=17, esi=29, edi=31, ebp=37)
    c.pc = 0x83eaf0
    if caller:
        c.reg.update(ebx=ACTOR, ebp=0x6ffffe00, esp=0x6ffffd00)
        for i, b in enumerate(raw):
            c.write(0x6ffffe00 - 0x5c + i, 1, b)
        c.pc = 0x834f14
    xmm = {f'xmm{i}': 0 for i in range(8)}
    fp, writes, calls = [], [], []
    protected = {0x1ae9bfc: bonus & 0xffffffff}
    allowed = {ACTOR + 0x4cb0 + i * 12 for i in range(len(RAW_FIELDS))}
    # Resistance multipliers live after all resistance base values, likewise
    # abnormal-resistance multipliers; these are not interleaved pairs.
    multipliers = {0x8dc, 0xbb8, 0xbd0, 0xbe8, 0xc00, 0xc18, 0xc30, 0xc48, 0xc78, 0xca8}
    multipliers |= {0x984 + i * 12 for i in range(4)} | {0xae0 + i * 12 for i in range(17)}
    allowed |= {ACTOR + r[3] for r in CONVERTED} | {ACTOR + x for x in multipliers} | {ACTOR + 0xda4}
    def clobber():
        c.reg['ecx'], c.reg['edx'], c.flags = (0xbaadf00d, 0xbad0c0de, 0xa97) if poison else (0, 0, 0x202)
        for name in xmm:
            xmm[name] = 0x123456789abcdef if poison else 0
    def finish(v=0, pop_bytes=0):
        c.reg['eax'] = v & 0xffffffff
        c.pc = c.pop()
        c.reg['esp'] += pop_bytes
        clobber()
    for _ in range(12000):
        if c.pc == (0x834f24 if caller else 0xdeadbeef):
            break
        arg = lambda j: c.read(c.reg['esp'] + 4 + j * 4, 4)
        if c.pc in (0x1195a10, 0x1195eb0):
            this = c.reg['ecx']
            if c.pc == 0x1195a10:
                if this not in allowed or arg(1) != this + 8:
                    raise ValueError('Protected write ABI ' + hex(this))
                value = c.read(arg(0), 4)
                protected[this] = value
                writes.append([hex(this - ACTOR), value])
            else:
                if this not in (0x1ae9bfc, ACTOR + 0xda4) or arg(0) != this + 8:
                    raise ValueError('Protected read ABI')
                c.write(arg(1), 4, protected[this])
                calls.append(['read', hex(this)])
            finish(pop_bytes=8)
            continue
        if c.pc == 0x6fc760:
            calls.append(['mode_service'])
            finish(MODE)
            continue
        if c.pc == 0x752930:
            if c.reg['ecx'] != MODE or arg(0) != 10:
                raise ValueError('Mode query ABI')
            calls.append(['mode_query', 10])
            finish(int(mode10), 4)
            continue
        if c.pc in (0x83ef5c, 0x83efcc):
            predicate = c.pc == 0x83ef5c
            slot = 0x38 if predicate else 0x444
            target = int.from_bytes(source.source_bytes(VTABLE + slot, 4), 'little')
            if c.reg['ecx'] != ACTOR or c.reg['eax'] != target:
                raise ValueError('Actor virtual ABI')
            if not predicate and c.read(c.reg['esp'], 4) != 0:
                raise ValueError('Refresh argument ABI')
            calls.append(['eligible' if predicate else 'refresh', hex(target)])
            c.reg['eax'] = int(eligible) if predicate else 0
            if not predicate:
                c.reg['esp'] += 4
            clobber()
            c.pc += 2
            continue
        result = c.run(c.pc, 1)
        if result[0] in ('budget', 'returned'):
            continue
        ins = next(source.decoder.disasm(source.source_bytes(c.pc, 15), c.pc, count=1))
        if result[0] == 'call':
            target = int(result[2], 16)
            if target not in (0x83eaf0, 0x1286cc0, 0x1195a10, 0x1195eb0, 0x4041c0, 0x6fc760, 0x752930):
                raise ValueError('Unexpected call ' + str(result))
            c.push(c.pc + ins.size)
            c.pc = target
        elif result[0] == 'unsupported' and ins.mnemonic in ('mul', 'imul') and len(ins.operands) == 1:
            left, right = c.reg['eax'], c.get(ins, ins.operands[0])
            if ins.operands[0].size != 4:
                raise ValueError('Unmodeled multiply width')
            product = signed(left) * signed(right) if ins.mnemonic == 'imul' else left * right
            c.reg['eax'], c.reg['edx'] = product & 0xffffffff, (product >> 32) & 0xffffffff
            overflow = not -2147483648 <= product <= 2147483647 if ins.mnemonic == 'imul' else product > 0xffffffff
            c.flags = (c.flags & ~0x801) | (0x801 if overflow else 0)
            c.pc += ins.size
        elif result[0] == 'unsupported':
            extension(c, xmm, fp, ins)
        else:
            raise ValueError('Unexpected stop ' + str(result))
    else:
        raise ValueError('Writeback instruction budget')
    return {'fixture': {'record': record, 'class_index': class_index, 'mode10': mode10,
        'eligible': eligible, 'actor_index': actor_index, 'bonus': bonus, 'poison': poison, 'caller': caller},
        'writes': writes, 'calls': calls, 'stop': hex(c.pc),
        'abi': [c.reg[k] for k in ('ebx', 'esi', 'edi', 'ebp', 'esp')], 'fp_depth': len(fp),
        'steps': len(c.trace), 'trace_sha256': trace_hash(c.trace)}, c.trace


def verify(row):
    f = row['fixture']
    data = bytes.fromhex(f['record'])
    def get(off, width, is_signed=False):
        return int.from_bytes(data[off:off + width], 'little', signed=is_signed)
    writes = [[hex(0x4cb0 + i * 12), get(off, width, sign) & 0xffffffff] for i, (off, width, sign) in enumerate(RAW_FIELDS)]
    for off, width, sign, dest in CONVERTED:
        value = trunc_div(get(off, width, sign), 10)
        if off == 64 and 0 <= f['class_index'] <= 10:
            value = trunc_div(value, 5)
        multiplier = dest + (0x30 if 16 <= off < 24 else 0xcc if 24 <= off < 58 else 12)
        writes += [[hex(dest), value & 0xffffffff], [hex(multiplier), fbits(1.)]]
    tail = f32(real(get(83, 4)) * f32(.1))
    writes.append(['0xda4', fbits(tail)])
    calls = [['mode_service'], ['mode_query', 10]]
    if f['mode10']:
        calls.append(['eligible', '0x8312d0'])
        if f['eligible'] and not 0 <= f['actor_index'] <= 11:
            calls += [['read', '0x1ae9bfc'], ['read', hex(ACTOR + 0xda4)]]
            writes.append(['0xda4', fbits(f32(tail + f32(f['bonus'])))])
    calls.append(['refresh', '0x833f80'])
    if row['writes'] != writes or row['calls'] != calls:
        raise ValueError('Native writeback values/order/branch mismatch')
    expected_abi = [ACTOR, 29, 31, 0x6ffffe00, 0x6ffffd00] if f['caller'] else [17, 29, 31, 37, 0x70000008]
    if row['abi'] != expected_abi or row['fp_depth'] or row['stop'] != ('0x834f24' if f['caller'] else '0xdeadbeef'):
        raise ValueError('Writeback return/ABI mismatch')


def fixture_record(seed):
    b = bytearray(87)
    words = (0, 9, 10, 32767, 32768, 65535, 65527)
    dwords = (0, 9, 10, 2147483647, 2147483648, 0xffffffff, 0xfffffff7)
    for index, (off, width) in enumerate(ACCUMULATED):
        value = (words if width == 2 else dwords)[(index + seed) % 7]
        b[off:off + width] = value.to_bytes(width, 'little')
    b[82] = 255
    b[83:87] = fbits(-12.5 if seed % 2 else 37.5).to_bytes(4, 'little')
    return b.hex()


def class_pointer(source, class_index):
    from dnf_native_vm_probe import CPU
    c = CPU(source)
    c.reg['ecx'] = ACTOR
    c.write(ACTOR + 0x3c08, 4, class_index)
    stop = c.run(0xd09590, 10)
    row = {'class_index': class_index, 'address': hex(c.reg['eax']),
        'value': c.read(c.reg['eax'], 4), 'stop': list(stop), 'stack': hex(c.reg['esp']),
        'steps': len(c.trace), 'trace_sha256': trace_hash(c.trace)}
    verify_class_pointer(row)
    return row, c.trace


def verify_class_pointer(row):
    if row['address'] != hex(ACTOR + 0x3c08) or row['value'] != row['class_index'] & 0xffffffff or row['stop'] != ['returned'] or row['stack'] != '0x70000004':
        raise ValueError('Class pointer getter mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest() != ENGINE_SHA:
        raise ValueError('Unexpected engine')
    previous = json.loads(PREVIOUS.read_text(encoding='utf-8'))
    cases, traces = [], []
    fixtures = [{'record': fixture_record(i % 7), 'class_index': i} for i in (-1, *range(12), 15)]
    fixtures += [{'record': fixture_record(seed), 'class_index': 0} for seed in range(7)]
    fixtures += [{'record': fixture_record(0), 'mode10': True, 'eligible': eligible, 'actor_index': index,
        'bonus': -16777217} for eligible in (False, True) for index in (-1, 0, 11, 12)]
    for poison in (False, True):
        for fixture in fixtures:
            row, trace = replay(source, **fixture, poison=poison)
            verify(row)
            cases.append(row)
            traces.append(trace)
    source_cases = []
    for original in previous['source_growth']['cases']:
        row, trace = replay(source, original['bytes'], poison=original['fixture']['poison'], caller=True)
        verify(row)
        source_cases.append({'level': original['fixture']['level'], 'job': original['fixture']['job'], 'result': row})
        traces.append(trace)
    class_cases = []
    for index in (-1, *range(12), 15):
        row, trace = class_pointer(source, index)
        class_cases.append(row)
        traces.append(trace)
    names = ('audit_dnf_chr_writeback.py', 'audit_dnf_chr_numbers.py', 'dnf_native_vm_probe.py',
        'audit_dnf_firewave.py', 'audit_dnf_ice_shatter.py', 'audit_dnf_ice_particle_bindings.py',
        'audit_dnf_native_strings.py', 'audit_dnf_particle_axis.py')
    return {'schema': 'dnf_chr_writeback/1', 'engine_sha256': ENGINE_SHA, 'input_source': source.source,
        'tools_sha256': {n: hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n', b'\n')).hexdigest() for n in names},
        'previous_evidence_sha256': hashlib.sha256(PREVIOUS.read_bytes().replace(b'\r\n', b'\n')).hexdigest(),
        'cases': cases, 'source_input_cases': source_cases, 'class_pointer_cases': class_cases, 'blocks': source_blocks(source, traces),
        'constants': [{'address': hex(a), 'bytes': source.source_bytes(a, 4).hex()}
            for a in (0x15560bc, 0x156889c, VTABLE + 0x738, VTABLE + 0x748)],
        'boundaries': [
            '83EAF0 and 1286CC0 execute original instructions through return; protected storage uses explicit ABI fixtures.',
            'Source-input cases also execute 834F14 virtual dispatch and return to 834F24, with the prior record placed in a prepared stack frame.',
            'The prior growth prefix output is a test input: intervening 834644..834F14 modifiers are NOT executed or assumed identity.',
            '6FC760/752930 mode query, virtual 38 eligibility and virtual 444 refresh remain ABI fixtures; final refresh logic is not executed.',
            'Class index is the actor 3C08 field also exposed by D09590. Full class/profile initialization is not proved.',
            'Raw HP and four attack/defense fields are copied into protected record slots; this writer does not establish their final character stat mapping.',
            'Converted MP/regen/resistance/speed destinations are internal actor fields, not proof of final panel units, regen tick frequency or final damage.',
            'The packed byte at 52 and float at 53 retain unnamed identities; their CHR tag/producer is not established in this audit.',
            'No gameplay progression formula, timer or UI display changes are made by this evidence.']}


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
    print('CHR_WRITEBACK cases', len(result['cases']), 'source inputs', len(result['source_input_cases']))


if __name__ == '__main__':
    main()

"""Native rate-byte input and notification routing; protected setter is partial."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_native_strings import ENGINE_SHA

ACTOR, BUFFER, MODE, VTABLE = 0x60000000, 0x60100000, 0x60200000, 0x16f972c


def run(source, variant='notice', value=100, present=True, mode=1, guarded=False, poison=False, remaining=1):
    from dnf_native_vm_probe import CPU
    if variant not in ('notice', 'guarded', 'reader', 'getter'):
        raise ValueError('Unknown fixture')
    if variant != 'getter' and not 0 <= value <= 255:
        raise ValueError('Byte input required')
    c = CPU(source)
    for a in range(0x6fffc000, 0x70000000, 4):
        c.write(a, 4, 0)
    c.write(ACTOR, 4, VTABLE)
    c.write(0x1ab7cdc, 4, ACTOR if present else 0)
    c.write(BUFFER, 1, value)
    c.write(0x1b466d8, 4, BUFFER)
    c.write(0x1b466dc, 4, remaining)
    c.reg.update(ecx=ACTOR, ebx=17, esi=29, edi=31, ebp=37)
    c.pc = {'notice': 0x723520, 'guarded': 0x72c2d0, 'reader': 0x11aea00, 'getter': 0xd09720}[variant]
    out = 0x60300000
    c.write(out, 1, 0xa5)
    if variant == 'reader':
        c.write(0x70000004, 4, out)
        c.write(0x70000008, 4, 1)
    if poison:
        c.string_clobber = (0xbaadf00d, 0xbad0c0de, 0xa97)
    events = []
    def clobber():
        c.reg['ecx'], c.reg['edx'], c.flags = (0xbaadf00d, 0xbad0c0de, 0xa97) if poison else (0, 0, 0x202)
    def finish(v=0, size=0):
        c.reg['eax'] = v & 0xffffffff
        c.pc = c.pop()
        c.reg['esp'] += size
        clobber()
    for _ in range(3000):
        if c.pc == 0xdeadbeef or (variant == 'guarded' and c.pc in (0x72c322, 0x72c32f)) or c.pc == 0x11ae972:
            break
        arg = lambda j: c.read(c.reg['esp'] + 4 + j * 4, 4)
        if c.pc == 0xd09717:
            # Execute the real setter prefix, then model the unproved remainder's
            # return ABI only. No protected actor storage write is invented.
            pointer, key = c.read(c.reg['esp'], 4), c.read(c.reg['esp'] + 4, 4)
            events.append(['set_request', hex(c.reg['ecx'] - ACTOR), hex(key - ACTOR), c.read(pointer, 4)])
            frame = c.reg['ebp']
            c.pc, c.reg['ebp'], c.reg['esp'] = c.read(frame + 4, 4), c.read(frame, 4), frame + 12
            c.reg['eax'] = 0
            clobber()
            continue
        if c.pc == 0x855770:
            if c.reg['ecx'] != ACTOR or arg(0) != 1:
                raise ValueError('Recompute ABI')
            events.append(['recompute_request', 1])
            finish(size=4)
            continue
        if c.pc == 0x1195eb0:
            if variant != 'getter' or c.reg['ecx'] != ACTOR + 0x4e60 or arg(0) != ACTOR + 0x4e68:
                raise ValueError('Getter protected read ABI')
            c.write(arg(1), 4, value)
            events.append(['get', '0x4e60', value & 0xffffffff])
            finish(size=8)
            continue
        if c.pc == 0x6fc760:
            finish(MODE)
            continue
        if c.pc == 0x752850:
            if c.reg['ecx'] != MODE:
                raise ValueError('Mode ABI')
            events.append(['mode'])
            finish(mode)
            continue
        if c.pc == 0x92f9b0:
            events.append(['guard'])
            finish(int(guarded))
            continue
        if c.pc == 0x75bd70:
            message = arg(0)
            if message not in c.strings or [arg(i) for i in (1, 2, 3)] != [0xffffffff, 0, 0]:
                raise ValueError('Notification ABI')
            events.append(['notification', c.strings[message], -1, 0, 0])
            finish()
            continue
        result = c.run(c.pc, 1)
        if result[0] in ('budget', 'returned'):
            continue
        if result[0] == 'call':
            target = int(result[2], 16)
            if target not in (0x11aea00, 0x11ae960, 0xd09700, 0x855770, 0x6fc760, 0x752850, 0x92f9b0, 0x1194fc0, 0x75bd70, 0x1195eb0):
                raise ValueError('Unknown call ' + str(result))
            ins = next(source.decoder.disasm(source.source_bytes(c.pc, 15), c.pc, count=1))
            c.push(c.pc + ins.size)
            c.pc = target
        else:
            raise ValueError('Unmodeled stop ' + str(result))
    else:
        raise ValueError('Input instruction budget')
    return {'fixture': {'variant': variant, 'value': value, 'present': present, 'mode': mode, 'guarded': guarded, 'poison': poison, 'remaining': remaining},
        'events': events, 'cursor': hex(c.read(0x1b466d8, 4)), 'remaining': c.read(0x1b466dc, 4),
        'read_byte': c.read(out, 1) if variant == 'reader' else None,
        'return_value': c.reg['eax'] if variant == 'getter' else None,
        'stop': hex(c.pc), 'abi': [c.reg[k] for k in ('ebx', 'esi', 'edi', 'ebp', 'esp')],
        'steps': len(c.trace), 'trace_sha256': trace_hash(c.trace)}, c.trace


def verify(row):
    f = row['fixture']
    variant = f['variant']
    events = []
    if variant == 'getter':
        events.append(['get', '0x4e60', f['value'] & 0xffffffff])
        cursor, remaining, ret = BUFFER, f['remaining'], f['value'] & 0xffffffff
    else:
        cursor, remaining, ret = BUFFER + 1, (f['remaining'] - 1) & 0xffffffff, None
        if variant == 'guarded' and f['present']:
            events.append(['guard'])
        active = f['present'] and (variant == 'notice' or variant == 'guarded' and not f['guarded'])
        if active:
            events.append(['set_request', '0x4e60', '0x4e68', f['value']])
            if variant == 'notice':
                events.append(['mode'])
            if variant == 'guarded' or f['mode'] == 1:
                events.append(['recompute_request', 1])
            if variant == 'notice' and f['value'] == 100:
                events.append(['notification', 'STAMINA_RECOVER', -1, 0, 0])
    stop, abi = '0xdeadbeef', [17, 29, 31, 37, 0x70000004]
    if variant == 'guarded':
        stop = '0x72c322' if f['present'] and not f['guarded'] else '0x72c32f'
        abi = [0, 29, 31, 0x6ffffffc, 0x6ffffff0]
    if variant == 'reader' and f['remaining'] == 0:
        stop = '0x11ae972'
        abi = [17, 29, 31, 0x6ffffff0, 0x6ffffff0]
    if (row['events'], row['cursor'], row['remaining'], row['return_value']) != (events, hex(cursor), remaining, ret):
        raise ValueError('Input/routing mismatch')
    if row['read_byte'] != (f['value'] if variant == 'reader' else None) or row['stop'] != stop or row['abi'] != abi:
        raise ValueError(f"Input boundary/ABI mismatch: {f} {row['abi']} expected {abi}")


def register(source, variant='notice', context=0, allocated=True, poison=False):
    from dnf_native_vm_probe import CPU
    start, end = (0x74d3a3, 0x74d3b0) if variant == 'notice' else (0x74dde4, 0x74ddf4)
    c = CPU(source)
    for a in range(0x6fffc000, 0x70000000, 4):
        c.write(a, 4, 0)
    c.write(0x1a5f07c, 4, 1)  # registration map constructor already completed
    c.write(0x60400000, 4, 0xa5a5a5a5)
    c.write(0x60400004, 4, 0xa5a5a5a5)
    c.write(0x60500000, 4, 0xa5a5a5a5)
    c.reg.update(ebx=17, esi=29, edi=context, ebp=37)
    c.pc = start
    keys = []
    def finish(value, count=0):
        c.reg['eax'] = value
        c.pc = c.pop()
        c.reg['esp'] += count
        c.reg['ecx'], c.reg['edx'], c.flags = (0xbaadf00d, 0xbad0c0de, 0xa97) if poison else (0, 0, 0x202)
    for _ in range(300):
        if c.pc == end:
            break
        if c.pc == 0x13cbdca:
            if c.read(c.reg['esp'] + 4, 4) != 8:
                raise ValueError('Registration allocation ABI')
            finish(0x60400000 if allocated else 0)
            continue
        if c.pc == 0x462750:
            if c.reg['ecx'] != 0x1a5f068:
                raise ValueError('Registration map ABI')
            keys.append(c.read(c.read(c.reg['esp'] + 4, 4), 4))
            finish(0x60500000, 4)
            continue
        result = c.run(c.pc, 1)
        if result[0] == 'budget':
            continue
        if result[0] == 'call' and int(result[2], 16) in (0x744b30, 0x13cbdca, 0x462750):
            ins = next(source.decoder.disasm(source.source_bytes(c.pc, 15), c.pc, count=1))
            c.push(c.pc + ins.size)
            c.pc = int(result[2], 16)
            continue
        raise ValueError('Registration stop ' + str(result))
    else:
        raise ValueError('Registration budget')
    row = {'fixture': {'variant': variant, 'context': context, 'allocated': allocated, 'poison': poison},
        'keys': keys, 'record': [c.read(0x60400000 + i * 4, 4) for i in range(2)], 'entry': c.read(0x60500000, 4),
        'abi': [c.reg[k] for k in ('ebx', 'esi', 'edi', 'ebp', 'esp')], 'stop': hex(c.pc), 'seh': c.read(0x50000000, 4),
        'steps': len(c.trace), 'trace_sha256': trace_hash(c.trace)}
    verify_registration(row)
    return row, c.trace


def verify_registration(row):
    f = row['fixture']
    key, callback, end = (4, 0x723520, 0x74d3b0) if f['variant'] == 'notice' else (137, 0x72c2d0, 0x74ddf4)
    record = [callback, f['context']] if f['allocated'] else [0xa5a5a5a5] * 2
    if (row['keys'], row['record'], row['entry']) != ([key], record, 0x60400000 if f['allocated'] else 0):
        raise ValueError('Registration key/callback mismatch')
    if row['abi'] != [17, 29, f['context'], 37, 0x6ffffff4] or row['stop'] != hex(end) or row['seh'] != 0xffffffff:
        raise ValueError('Registration ABI mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest() != ENGINE_SHA:
        raise ValueError('Unexpected engine')
    rows, traces = [], []
    for poison in (False, True):
        fixtures = []
        for v in (0, 1, 99, 100, 101, 127, 128, 255):
            fixtures += [{'value': v, 'mode': m, 'present': present} for m in (0, 1, 9) for present in (False, True)]
            fixtures += [{'variant': 'guarded', 'value': v, 'present': present, 'guarded': guard} for present in (False, True) for guard in (False, True)]
        fixtures += [{'variant': 'reader', 'value': v, 'remaining': n} for v in (0, 128, 255) for n in (0, 1, 2)]
        fixtures += [{'variant': 'getter', 'value': v} for v in (0, 1, 99, 100, 255, -1, 0x80000000)]
        for fixture in fixtures:
            row, trace = run(source, **fixture, poison=poison)
            verify(row)
            rows.append(row)
            traces.append(trace)
    registrations = []
    for variant in ('notice', 'guarded'):
        for context in (0, 3):
            for allocated in (False, True):
                for poison in (False, True):
                    row, trace = register(source, variant, context, allocated, poison)
                    registrations.append(row)
                    traces.append(trace)
    names = ('audit_dnf_stamina_input.py', 'dnf_native_vm_probe.py', 'audit_dnf_ice_particle_bindings.py', 'audit_dnf_native_strings.py', 'audit_dnf_particle_axis.py')
    return {'schema': 'dnf_stamina_input/1', 'engine_sha256': ENGINE_SHA, 'input_source': source.source,
        'tools_sha256': {n: hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n', b'\n')).hexdigest() for n in names},
        'cases': rows, 'registrations': registrations, 'blocks': source_blocks(source, traces),
        'static_unresolved': [{'start': hex(a), 'bytes': source.source_bytes(a, n).hex(),
            'instructions': [f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in source.decoder.disasm(source.source_bytes(a, n), a)]}
            for a, n in ((0x20df6d0, 5), (0x1ee8be2, 8), (0x1eb401e, 8))],
        'vtable': [{'offset': hex(off), 'target': hex(int.from_bytes(source.source_bytes(VTABLE + off, 4), 'little'))} for off in (0x750, 0x758, 0x75c)],
        'boundaries': [
            'Original registration callsites and 744B30 publish callback/context under keys 4 and 137; allocation and map lookup are ABI fixtures with an already-initialized map.',
            '723520 executes through return. 72C2D0 stops at 72C322 or 72C32F before subsequent UI/character handling.',
            '11AEA00 and 11AE960 execute original byte copy, cursor advance and remaining-count decrement. Empty declared input stops at 11AE972 before diagnostics/cleanup.',
            'Synthetic packet bytes are prepared data, never a real network request. No input provenance or server restoration timer is inferred.',
            'D09700 executes only its prefix through D09717: the protected remainder is NOT executed and only its return ABI is modeled. set_request is not proof of a completed actor write.',
            'D09720 executes through return against an explicit protected-read value. It is not linked to a claimed setter write.',
            '855770 receives argument 1 as a checked ABI fixture. Its nonzero refill path remains unproved, unlike the separate zero-argument audit.',
            'Mode, guard and notification services remain ABI fixtures. The original encrypted notification identifier is decoded, not rendered or localized.',
            'The null-global setter exploration reached the protected write, but the populated-global detour encountered undefined 16-bit obfuscation forms; neither exploration is claimed as this executable evidence.',
            'No local stamina decay/recovery formula, death penalty, UI or gameplay implementation is added.']}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('client', type=Path)
    p.add_argument('--decoder-dir', type=Path)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    if a.client.resolve() == a.output.resolve():
        raise ValueError('Cannot overwrite source')
    if a.decoder_dir:
        sys.path.insert(0, str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    result = audit(AxisEvaluator(a.client.read_bytes()))
    a.output.write_text(json.dumps(result, indent=1) + '\n', encoding='utf-8')
    print('STAMINA_INPUT', len(result['cases']))


if __name__ == '__main__':
    main()

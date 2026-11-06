"""Bounded source replay of the ordinary ice shatter branch, never native execution.

The update prefix uses explicit position/base-update fixtures. Particle factories
return synthetic STL vectors (zero or one object), not real allocations. Source
branches, vector iteration, coordinates and DD6 writes execute as instructions.
Scene insertion, RNG, allocation, renderer and the rest of the controller are
outside this probe. This is local control-flow evidence, not a client recording.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys

from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_native_strings import ENGINE_SHA

ICE, ANI = 0x60000000, 0x60100000
EMITTERS = (0x60110000, 0x60111000, 0x60112000)
POST_SHATTER = 0x2381A3D


def signed(value):
    return value - 0x100000000 if value & 0x80000000 else value


def fbits(value):
    return int.from_bytes(struct.pack('<f', value), 'little')


def real(value):
    return struct.unpack('<f', (value & 0xffffffff).to_bytes(4, 'little'))[0]


def sse_step(cpu, xmm, instruction):
    """Five SSE forms used here; full lanes for CVTDQ2PS, finite scalar inputs.

    IEEE binary32 round-to-nearest conversion via struct. MXCSR exceptions and
    alternate rounding modes are not emulated. Unknown forms fail closed.
    """
    i = instruction
    dst, src = i.operands
    def is_xmm(o):
        return o.type == 1 and i.reg_name(o.reg).startswith('xmm')
    def get(o):
        return xmm[i.reg_name(o.reg)] if is_xmm(o) else cpu.get(i, o)
    def put(o, v):
        if is_xmm(o):
            xmm[i.reg_name(o.reg)] = v
        else:
            cpu.put(i, o, v & 0xffffffff)
    if i.mnemonic == 'movd':
        put(dst, get(src) & 0xffffffff)
    elif i.mnemonic == 'movss':
        upper = get(dst) & ~0xffffffff if is_xmm(dst) and is_xmm(src) else 0
        put(dst, upper | (get(src) & 0xffffffff))
    elif i.mnemonic == 'cvtdq2ps':
        value = get(src)
        put(dst, sum(fbits(signed(value >> (32*j) & 0xffffffff)) << (32*j) for j in range(4)))
    elif i.mnemonic == 'mulss':
        left, right = get(dst), get(src)
        if not all(math.isfinite(real(v)) for v in (left, right)):
            raise ValueError('Non-finite SSE input outside fixture')
        put(dst, (left & ~0xffffffff) | fbits(real(left)*real(right)))
    elif i.mnemonic == 'cvttss2si':
        value = real(get(src))
        if not math.isfinite(value) or not -2147483648 <= math.trunc(value) <= 2147483647:
            raise ValueError('SSE integer conversion outside fixture')
        put(dst, math.trunc(value))
    else:
        raise ValueError(f'Unsupported SSE: {i.mnemonic} {i.op_str}')


def replay(source, *, frame=3, ordinal=0, fired=0, has_animation=True,
           count=1, xyz=(320, 400, 0), scale=1.5, poison=False):
    if count not in (0, 1):
        raise ValueError('Factory fixture supports zero/one object only')
    from dnf_native_vm_probe import CPU
    c = CPU(source)
    # Only state fields actually consumed on this selected ordinary-ice path.
    for offset, width, value in ((0, 4, 0x15FA33C), (0x254, 4, 20002+ordinal % 6),
            (0xB8, 4, 0x60150000), (0xC0, 4, ANI if has_animation else 0),
            (0xDCC, 4, ordinal), (0xDD0, 4, 1), (0xDD4, 1, 1),
            (0xDD6, 1, fired), (0xDD8, 4, fbits(scale)), (0xDDC, 1, 1), (0xDDE, 1, 0)):
        c.write(ICE+offset, width, value)
    c.write(ANI+0x144, 4, frame)
    c.write(28032880, 1, 1)  # profiling label already initialized
    c.write(0x1AF4584, 1, 0)  # profiling disabled; execute its actual constructor
    for j, emitter in enumerate(EMITTERS):
        c.write(0x1A5F820+j*4, 4, emitter)
        c.write(emitter, 4, 0x157DCEC)  # original 5FEF64 vtable
    events, writes, reads = [], [], []
    old_write, old_read = c.write, c.read
    def observe_write(a, n, v):
        old_write(a, n, v)
        if ICE <= a < ICE+0x1000:
            writes.append({'pc': hex(c.pc), 'offset': hex(a-ICE), 'width': n, 'value': v})
    def observe_read(a, n):
        v = old_read(a, n)
        if ICE <= a < ICE+0x1000 or ANI <= a < ANI+0x200 or 0x1A5F820 <= a <= 0x1A5F828:
            reads.append({'pc': hex(c.pc), 'address': hex(a), 'width': n, 'value': v})
        return v
    c.write, c.read = observe_write, observe_read
    xmm = {f'xmm{j}': 0 for j in range(8)}
    generated = 0
    c.pc = 0xA6EF60
    # Single-step to stop at the actual join, before unrelated death/AI logic.
    # No branch direction or program counter inside the branch is prescribed.
    for _ in range(24000):
        if c.pc == POST_SHATTER:
            break
        result = c.run(c.pc, 1)
        if result[0] == 'budget':
            continue
        i = next(source.decoder.disasm(source.source_bytes(c.pc, 15), c.pc, count=1))
        next_pc = c.pc+i.size
        if result[0] == 'unsupported' and i.mnemonic in ('movd', 'movss', 'cvtdq2ps', 'mulss', 'cvttss2si'):
            sse_step(c, xmm, i)
            c.pc = next_pc
            continue
        if result[0] != 'call':
            raise ValueError(f'Unexpected stop: {result}')
        target = int(result[2], 16)
        head = next(source.decoder.disasm(source.source_bytes(target, 15), target, count=1))
        # Source stack trampolines, setters, vector begin/end/increment and the
        # disabled profiler constructor execute through the integer interpreter.
        if ((head.mnemonic == 'add' and head.op_str.startswith('dword ptr [esp],'))
                or target == next_pc+1 or target in (0x1183720, 0xE50030, 0xB09680, 0x110F7C0, 0xBF2520)):
            c.push(next_pc)
            c.pc = target
            if target == 0xE50030:
                events.append({'kind': 'position', 'pc': hex(i.address), 'emitter': hex(c.reg['ecx']),
                               'xyz': [signed(c.read(c.reg['esp']+4+j*4, 4)) for j in range(3)]})
            continue
        arg = lambda j: c.read(c.reg['esp']+j*4, 4)
        this = c.reg['ecx']
        pop_bytes, returned = 0, 0
        if target == 0x7F9E20:
            events.append({'kind': 'base_update_fixture', 'pc': hex(i.address)})
        elif target in (0x406480, 0x406490, 0x4064A0):
            returned = xyz[(target-0x406480)//16] & 0xffffffff
        elif target == 0x7F7940:
            events.append({'kind': 'position_accept_fixture', 'pc': hex(i.address),
                           'xyz': [signed(arg(j)) for j in range(3)]})
            returned, pop_bytes = 1, 12
        elif target == 0x57DB30:
            events.append({'kind': 'reset', 'pc': hex(i.address), 'emitter': hex(this), 'age': arg(0)})
            pop_bytes = 4
        elif target == 0xE4E170:
            vector = arg(0)
            proxy = 0x60120000+generated*0x100
            particle = 0x60130000+generated*0x1000
            generated += 1
            for off, val in ((0, proxy), (4, proxy+16), (8, proxy+16+count*4), (12, proxy+16+count*4)):
                c.write(vector+off, 4, val)
            c.write(proxy, 4, vector)
            c.write(proxy+16, 4, particle)
            c.write(particle, 4, 0x15568C4)  # source free ANI constructor 406CC7
            c.write(particle+0xC0, 4, particle+0x400)
            events.append({'kind': 'generate_fixture', 'pc': hex(i.address), 'emitter': hex(this),
                           'count': count, 'vector': hex(vector)})
            returned, pop_bytes = vector, 4
        elif target == 0x8A6290:
            events.append({'kind': 'scene_insert_fixture', 'pc': hex(i.address),
                           'scene': hex(this), 'args': [hex(arg(j)) for j in range(5)]})
            pop_bytes = 20  # source 8A633B RET 14h
        elif target == 0x7F0800:
            returned = c.read(this+0xC0, 4)  # renderer getter is an explicit fixture
        elif target == 0x1086E20:
            events.append({'kind': 'scale_fixture', 'pc': hex(i.address),
                           'animation': hex(this), 'scale': real(arg(0))})
            pop_bytes = 4
        elif target == 0x13CADD7:
            events.append({'kind': 'free_fixture', 'pc': hex(i.address), 'pointer': hex(arg(0))})
        else:
            raise ValueError(f'Unmodeled native call {target:#x} at {i.address:#x}')
        c.reg['eax'] = returned
        c.reg['esp'] += pop_bytes
        c.reg['ecx'], c.reg['edx'], c.flags = (0xBAADF00D, 0xBAD0C0DE, 0xA97) if poison else (0, 0, 0x202)
        c.pc = next_pc
    else:
        raise ValueError('Ice branch instruction budget exceeded')
    row = {'fixture': {'frame': frame, 'ordinal': ordinal, 'fired': fired, 'has_animation': has_animation,
                      'count': count, 'xyz': list(xyz), 'scale': scale, 'poison': poison},
           'events': events, 'writes': writes, 'reads': reads,
           'stop': hex(c.pc), 'final_fired': c.read(ICE+0xDD6, 1),
           'branches': c.branches, 'steps': len(c.trace), 'trace_sha256': trace_hash(c.trace)}
    return row, c.trace


def verify(row):
    f = row['fixture']
    active = not f['fired'] and f['has_animation'] and f['frame'] >= 3
    positions = [e for e in row['events'] if e['kind'] == 'position']
    generations = [e for e in row['events'] if e['kind'] == 'generate_fixture']
    resets = [e for e in row['events'] if e['kind'] == 'reset']
    scales = [e for e in row['events'] if e['kind'] == 'scale_fixture']
    insertions = [e for e in row['events'] if e['kind'] == 'scene_insert_fixture']
    expected = ['0x60111000', '0x60112000'] if active else []
    if [e['emitter'] for e in generations] != expected or [e['emitter'] for e in positions] != expected:
        raise ValueError('Wrong shatter trigger or template order')
    if [e['emitter'] for e in resets] != expected or any(e['age'] != 0 for e in resets):
        raise ValueError('Wrong emitter reset')
    xyz = list(f['xyz']); xyz[2] += 20-math.trunc(real(fbits(f['ordinal']*-1.5)))
    if any(e['xyz'] != xyz for e in positions):
        raise ValueError('Wrong ordinal-dependent height')
    if len(scales) != (f['count'] if active else 0) or any(e['scale'] != real(fbits(f['scale'])) for e in scales):
        raise ValueError('Only shards inherit ice image scale')
    if len(insertions) != len(expected) or any(e['args'][:3] != [hex(ICE), '0x2', '0x0'] or e['args'][4] != '0x0' for e in insertions):
        raise ValueError('Wrong scene insertion ABI')
    if row['final_fired'] != (1 if active else f['fired']):
        raise ValueError('Wrong one-shot flag')
    flag_writes = [w for w in row['writes'] if w['offset'] == '0xdd6']
    if flag_writes != ([{'pc': '0x2304da4', 'offset': '0xdd6', 'width': 1, 'value': 1}] if active else []):
        raise ValueError('Missing source one-shot store')


def audit(source):
    runs, traces = [], []
    fixtures = [dict(frame=f) for f in (-1, 0, 1, 2, 3, 4)]
    fixtures += [dict(fired=1), dict(has_animation=False), dict(count=0)]
    fixtures += [dict(ordinal=j, xyz=(-320, 410, 17), scale=1.5+j*.075) for j in range(8)]
    for fixture in fixtures:
        for poison in (False, True):
            row, trace = replay(source, **fixture, poison=poison)
            verify(row)
            runs.append(row); traces.append(trace)
    # Constructor identity and callee-pop evidence for fixture boundaries.
    traces.append([f'{i.address:08X} {i.mnemonic} {i.op_str}'
        for start, size in ((0x5FEF64, 6), (0x406CC7, 6), (0x57DB30, 31),
                            (0x8A6337, 7), (0x1086E20, 80))
        for i in source.decoder.disasm(source.source_bytes(start, size), start)])
    tools = ('audit_dnf_ice_shatter.py', 'dnf_native_vm_probe.py', 'audit_dnf_ice_particle_bindings.py',
             'audit_dnf_particle_axis.py', 'audit_dnf_native_strings.py')
    return {'schema': 'dnf_ice_shatter/1', 'engine_sha256': ENGINE_SHA, 'input_source': source.source,
            'method': __doc__.strip(), 'tools_sha256': {name: hashlib.sha256(Path(__file__).with_name(name)
                .read_bytes().replace(b'\r\n', b'\n')).hexdigest() for name in tools},
            'boundaries': ['Ordinary-ice update after synthetic base update; child-spawn prefix already complete (DD4/DDC=1, DDE=0).',
                           'Source vtables, frame field and DD6 guard; XYZ getters and accepted position request are fixtures.',
                           'Factories return synthetic zero/one-element vectors; source vector iteration is interpreted.',
                           'Reset/factory/scene/ANI-getter/scale/free calls are ABI fixtures; no native allocation, RNG or renderer execution.',
                           'Two volatile-register/flag clobber variants; stop at source join 2381A3D, not whole update return.',
                           'SSE finite binary32 nearest rounding; MXCSR exceptions/alternate modes not modeled.'],
            'source_data': [{'address': hex(a), 'raw': source.source_bytes(a, 4).hex()}
                            for a in (0x159EC04, 0x157DCEC+0x28, 0x157DCEC+0xC,
                                      0x157DCEC+0x60, 0x15568C4+0x130)],
            'runs': runs, 'blocks': source_blocks(source, traces)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('client', type=Path)
    parser.add_argument('--decoder-dir', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.client.resolve() == args.output.resolve():
        raise ValueError('Output cannot overwrite source')
    if args.decoder_dir:
        sys.path.insert(0, str(args.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    evidence = audit(AxisEvaluator(args.client.read_bytes()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=1)+'\n', encoding='utf8', newline='\n')
    print(f"[ICE_SHATTER] {len(evidence['runs'])} source traces: frame>=3, shards then stars, DD6 one-shot")


if __name__ == '__main__':
    main()

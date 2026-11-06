"""Bounded Python replay of ordinary FireWaveBig initialization and lifecycle.

Never executes the client. Original branches, vtables and call arguments run in
the integer interpreter; engine services are explicit ABI fixtures. In particular
90A950 returns an injected value: this does NOT prove its character-stat formula.
The EX explosion has a different controller and is outside this probe.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_ice_shatter import fbits, real, signed, sse_step
from audit_dnf_native_strings import ENGINE_SHA

OBJ, OWNER, ANI = 0x60000000, 0x60100000, 0x60150000
VTABLES = {20024: 0x1600DB4, 20025: 0x16012A4}
SERVICES = {0x7F4670, 0x1195A10, 0x90A950, 0x8444F0, 0x8406C0,
            0x13CC98F, 0x7F7D60, 0x7EF760, 0x406480, 0x406490, 0x4064A0,
            0x86D500, 0x7EF780, 0x7FA200, 0xD07BC0, 0x7F9E20}
LEAVES = {0x61DAB0, 0x1183720, 0x11833D0, 0x4063E0, 0x7F0800, 0x13CC480, 0x13CC488}


def extra_step(c, xmm, i):
    """Only the extra finite-input SSE and stack forms observed on these paths."""
    if i.mnemonic in ('movd', 'movss', 'cvtdq2ps', 'mulss', 'cvttss2si'):
        sse_step(c, xmm, i)
    elif i.mnemonic == 'cvtsi2ss':
        dst, src = i.operands
        if dst.type != 1 or src.size != 4:
            raise ValueError('Unmodeled CVTSI2SS form')
        name = i.reg_name(dst.reg)
        xmm[name] = (xmm[name] & ~0xffffffff) | fbits(signed(c.get(i, src)))
    elif i.mnemonic == 'xorps' and all(o.type == 1 for o in i.operands):
        a, b = [i.reg_name(o.reg) for o in i.operands]
        xmm[a] ^= xmm[b]
    elif i.mnemonic == 'pushal':
        values = [c.reg[k] for k in ('eax', 'ecx', 'edx', 'ebx', 'esp', 'ebp', 'esi', 'edi')]
        for value in values:
            c.push(value)
    elif i.mnemonic == 'popal':
        for name in ('edi', 'esi', 'ebp', 'skip', 'ebx', 'edx', 'ecx', 'eax'):
            value = c.pop()
            if name != 'skip':
                c.reg[name] = value
    elif i.mnemonic == 'repz ret':
        c.pc = c.pop()
        return
    else:
        raise ValueError(f'Unmodeled instruction {i.address:#x}: {i.mnemonic} {i.op_str}')
    c.pc += i.size


def replay(source, *, object_id=20024, phase='init', ended=False, facing=1,
           xyz=(320, 400, 0), authority=True, alive=True, initialized=True,
           owner_value=0, skill_value=584, rank=1, poison=False):
    from dnf_native_vm_probe import CPU
    if object_id not in VTABLES or phase not in ('init', 'update') or facing not in (0, 1):
        raise ValueError('Only ordinary firewave objects / native direction 0 or 1')
    c = CPU(source)
    # CPU's call diagnostic inspects two stack words even for no-arg calls.
    for address in range(0x6FFFFE00, 0x70000000, 4):
        c.write(address, 4, 0)
    # The fixtures zero the synthetic object; unmodeled object/owner state is
    # not claimed as a reconstruction of the complete native constructors.
    for address in range(OBJ, OBJ+0x1000, 4):
        c.write(address, 4, 0)
    for off, width, value in ((0, 4, VTABLES[object_id]), (0x254, 4, object_id),
            (0xD64, 4, object_id), (0xC0, 4, ANI), (0x880, 4, OWNER),
            (0x178, 1, int(alive)), (0xF4, 4, 0x60130000), (0xF8, 4, 0x60130004)):
        c.write(OBJ+off, width, value)
    if phase == 'update':
        c.write(OBJ+(0xDCC if object_id == 20024 else 0xDD4), 1, int(initialized))
    c.write(0x70000004, 4, OWNER)
    c.write(OWNER, 4, 0x16F972C)
    c.write(0x60130000, 4, 0x60140000)  # etc ANI index 0
    c.write(ANI+0x144, 4, 0)
    c.write(ANI+0x1EC, 1, 8 if ended else 0)
    c.write(0x1ABBB60, 1, 1); c.write(0x1ABBBB0, 1, 1)  # profile labels initialized
    c.write(0x1AF4584, 1, 0)  # disabled profiler, actual constructor/destructor
    events, reads, writes = [], [], []
    read, write = c.read, c.write
    def observe_read(a, n):
        value = read(a, n)
        if OBJ <= a < OBJ+0x1000 or ANI <= a < ANI+0x200:
            reads.append({'pc': hex(c.pc), 'address': hex(a), 'width': n, 'value': value})
        return value
    def observe_write(a, n, value):
        write(a, n, value)
        if OBJ <= a < OBJ+0x1000:
            writes.append({'pc': hex(c.pc), 'offset': hex(a-OBJ), 'width': n, 'value': value})
    c.read, c.write = observe_read, observe_write
    xmm = {f'xmm{j}': 0 for j in range(8)}
    c.pc = int.from_bytes(source.source_bytes(VTABLES[object_id]+(0x43C if phase == 'init' else 0x1F0), 4), 'little')
    for _ in range(30000):
        if c.pc in SERVICES:
            target, this = c.pc, c.reg['ecx']
            arg = lambda j: c.read(c.reg['esp']+4+j*4, 4)
            event = {'kind': '', 'target': hex(target), 'this': hex(this)}
            returned, pop_bytes = 0, 0
            if target == 0x7F7D60:
                event.update(kind='base_init_fixture', owner=hex(arg(0)))
                c.write(this+0x880, 4, arg(0)); pop_bytes = 4
            elif target == 0x13CC98F:
                event.update(kind='cast_fixture', args=[hex(arg(j)) for j in range(5)])
                returned = OWNER
            elif target in (0x8406C0, 0x8444F0):
                event.update(kind='skill_lookup' if target == 0x8406C0 else 'skill_rank', skill_id=arg(0))
                returned, pop_bytes = (0x60120000 if target == 0x8406C0 else rank), 4
            elif target == 0x90A950:
                event.update(kind='fixed_resolver_fixture', args=[arg(j) for j in range(5)], result=skill_value)
                returned, pop_bytes = skill_value & 0xffffffff, 20
            elif target == 0x1195A10:
                value = c.read(arg(0), 4)
                event.update(kind='secure_float_write_fixture', bits=value, value=real(value))
                c.write(this, 4, value); pop_bytes = 8  # plain synthetic storage, not encryption
            elif target == 0x7F4670:
                event.update(kind='attach_ani', args=[arg(j) for j in range(11)])
                pop_bytes = 44
            elif target == 0x7F9E20:
                event.update(kind='base_update_fixture')
            elif target == 0xD07BC0:
                event.update(kind='owner_3094_fixture', value=owner_value); returned = owner_value
            elif target == 0x7EF780:
                event.update(kind='authority_fixture', value=authority); returned = int(authority)
            elif target == 0x7EF760:
                event.update(kind='direction_fixture', value=facing); returned = facing
            elif target in (0x406480, 0x406490, 0x4064A0):
                returned = xyz[(target-0x406480)//16] & 0xffffffff
                event.update(kind='coordinate_fixture', value=signed(returned))
            elif target == 0x86D500:
                event.update(kind='spawn_fixture', args=[arg(j) for j in range(13)])
                returned = 0x60160000  # cdecl, caller cleans 13 arguments
            elif target == 0x7FA200:
                event.update(kind='delete_fixture', args=[arg(0)])
                pop_bytes = 4
            events.append(event)
            c.reg['eax'] = returned
            c.pc = c.pop(); c.reg['esp'] += pop_bytes
            c.reg['ecx'], c.reg['edx'], c.flags = (0xBAADF00D, 0xBAD0C0DE, 0xA97) if poison else (0, 0, 0x202)
            continue
        result = c.run(c.pc, 1)
        if result[0] == 'returned':
            break
        if result[0] == 'budget':
            continue
        i = next(source.decoder.disasm(source.source_bytes(c.pc, 15), c.pc, count=1))
        if result[0] == 'unsupported':
            extra_step(c, xmm, i)
            continue
        if result[0] != 'call':
            raise ValueError(f'Unexpected stop {result}')
        target = int(result[2], 16)
        head = next(source.decoder.disasm(source.source_bytes(target, 15), target, count=1))
        if (target in SERVICES | LEAVES or target == c.pc+i.size+1
                or head.mnemonic == 'add' and head.op_str.startswith('dword ptr [esp],')):
            c.push(c.pc+i.size); c.pc = target
        else:
            raise ValueError(f'Unmodeled call {target:#x} at {c.pc:#x}')
    else:
        raise ValueError('Firewave instruction budget exceeded')
    return {'fixture': dict(object_id=object_id, phase=phase, ended=ended, facing=facing,
                xyz=list(xyz), authority=authority, alive=alive, initialized=initialized,
                owner_value=owner_value, skill_value=skill_value, rank=rank, poison=poison),
            'events': events, 'reads': reads, 'writes': writes, 'stop': list(result),
            'stack': hex(c.reg['esp']), 'branches': c.branches,
            'steps': len(c.trace), 'trace_sha256': trace_hash(c.trace)}, c.trace


def verify(row):
    f = row['fixture']; events = row['events']
    pick = lambda kind: [e for e in events if e['kind'] == kind]
    if row['stop'] != ['returned'] or row['stack'] != ('0x70000008' if f['phase'] == 'init' else '0x70000004'):
        raise ValueError('Incomplete source return / ABI cleanup')
    if f['phase'] == 'init':
        if [e['skill_id'] for e in pick('skill_lookup')+pick('skill_rank')] != [22, 22]:
            raise ValueError('Wrong native skill ID')
        resolved = pick('fixed_resolver_fixture')
        # The packed second argument is constant on these paths, NOT the
        # injected rank. Keep it raw until the resolver contract is decoded.
        if len(resolved) != 1 or resolved[0]['args'] != [f['object_id']-20024, 0xFFFF0001, 0, fbits(1), 0xFFFFFFFF]:
            raise ValueError('Wrong fixed column/resolver arguments')
        written = pick('secure_float_write_fixture')
        if len(written) != 1 or written[0]['this'] != hex(OBJ+0x990) or written[0]['bits'] != fbits(f['skill_value']):
            raise ValueError('Wrong fixed attack component')
        if [e['args'] for e in pick('attach_ani')] != [[0xFFFFFFFF, 0x60140000, 0, 0, 0, 0, 0, 0, 0, 1, fbits(1)]]:
            raise ValueError('Wrong rear ANI attachment')
    else:
        active = f['alive'] and f['ended'] and (f['object_id'] == 20024 or f['initialized'])
        expected_spawn = active and f['object_id'] == 20024 and f['authority']
        spawns = pick('spawn_fixture')
        if len(spawns) != int(expected_spawn):
            raise ValueError('Wrong explosion trigger/authority')
        if spawns:
            xyz = list(f['xyz']); xyz[0] += 360 if f['facing'] else -360
            expected = [OWNER, 20025, 0]+[v & 0xffffffff for v in xyz]+[f['facing'], 0, 0, 0, 0, 0, 0]
            if spawns[0]['args'] != expected:
                raise ValueError('Wrong explosion ID/position/direction')
        if [e['args'] for e in pick('delete_fixture')] != ([[0]] if active else []):
            raise ValueError('Wrong animation-end removal')


def audit(source):
    runs, traces = [], []
    for object_id in VTABLES:
        fixtures = [dict(phase='init', rank=rank, skill_value=value) for rank, value in ((1, 584), (10, 2257))]
        fixtures += [dict(phase='update', ended=end, facing=direction, xyz=(-320, 410, 17))
                     for end in (False, True) for direction in (0, 1)]
        fixtures += [dict(phase='update', ended=True, authority=False),
                     dict(phase='update', ended=True, alive=False),
                     dict(phase='update', ended=False, owner_value=22)]
        if object_id == 20025:
            fixtures.append(dict(phase='update', ended=True, initialized=False))
        for fixture in fixtures:
            for poison in (False, True):
                row, trace = replay(source, object_id=object_id, poison=poison, **fixture)
                verify(row); runs.append(row); traces.append(trace)
    # Factory switch and constructor writes pin the IDs independently of names.
    factory = []
    for object_id in VTABLES:
        index = source.source_bytes(0xA2A188+object_id-20002, 1)[0]
        case = int.from_bytes(source.source_bytes(0xA2A03C+index*4, 4), 'little')
        factory.append({'id': object_id, 'index': index, 'case': hex(case)})
    for start, size in ((0xA1EF56, 31), (0xA1F610, 124), (0x9EE111, 6),
                        (0x9EE21B, 6), (0x7F486E, 3)):
        traces.append([f'{i.address:08X} {i.mnemonic} {i.op_str}'
                       for i in source.decoder.disasm(source.source_bytes(start, size), start)])
    names = ('audit_dnf_firewave.py', 'audit_dnf_ice_shatter.py', 'dnf_native_vm_probe.py',
             'audit_dnf_ice_particle_bindings.py', 'audit_dnf_particle_axis.py', 'audit_dnf_native_strings.py')
    return {'schema': 'dnf_firewave/1', 'engine_sha256': ENGINE_SHA, 'input_source': source.source,
            'method': __doc__.strip(), 'factory': factory,
            'tools_sha256': {n: hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n', b'\n')).hexdigest() for n in names},
            'boundaries': ['Synthetic zeroed object / owner / one etc-ANI; original constructor is not replayed.',
                'Base update, authority, XYZ, owner secure field 3094 and RTTI cast are ABI fixtures.',
                '90A950 returns injected integers; character stats, encryption, network, collision and rendering are not executed.',
                'Source chooses fixed column, attachment, successor and removal; source end bit is injected, not an emulated animator.',
                'Ordinary IDs 20024/20025 only; EX 20101 has an independent branch. Global ordering/ground validity remain unproven.'],
            'source_data': [{'address': hex(a), 'raw': source.source_bytes(a, n).hex()}
                for a, n in ((0xA2A188+22, 2), (0xA2A03C+17*4, 8))]+
                [{'address': hex(v+off), 'raw': source.source_bytes(v+off, 4).hex()}
                 for v in VTABLES.values() for off in (0x43C, 0x1F0)],
            'runs': runs, 'blocks': source_blocks(source, traces)}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('client', type=Path); p.add_argument('--decoder-dir', type=Path)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if args.output.resolve() == args.client.resolve():
        raise ValueError('Output cannot overwrite source')
    if args.decoder_dir:
        sys.path.insert(0, str(args.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    evidence = audit(AxisEvaluator(args.client.read_bytes()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=1)+'\n', encoding='utf8', newline='\n')
    print(f"[FIREWAVE] {len(evidence['runs'])} source traces verified")


if __name__ == '__main__':
    main()

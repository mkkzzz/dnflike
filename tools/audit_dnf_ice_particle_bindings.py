"""Reproduce bounded protected-code evidence for three ice particle bindings.

Reads the pinned PE as data; never starts the client or invokes native code.
Splices independently identified bytecode operands into a source-derived VM
frame. String decoding and constructor returns are explicit ABI fixtures.
This proves local operand/return-store chains under those boundaries, not
successful initialization of a live client or particle gameplay triggers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from audit_dnf_native_strings import ENGINE_SHA, recover_string

MASK = 0xFFFFFFFF
HANDLER = 0x21D7D21
BINDINGS = [
    (0x775C8D, 0x15B5100, 0x215BE2D, 0x1A5F820, 'IceWaveParticleSmoke.ptl'),
    (0x219215A, 0x15B5078, 0x21632F9, 0x1A5F824, 'IceWaveParticle.ptl'),
    (0x21F4ECB, 0x15B4FE8, 0x2207FFE, 0x1A5F828, 'IceWaveParticleStar.ptl'),
]
PREFIX = 'PassiveObject/Character/Swordman/Particle/'


def decode_immediate(source, address):
    """Pinned image relocation delta=0; handler 21D7D21 -> 21FAE27."""
    operand = struct.unpack('<I', source.source_bytes(address+4, 4))[0]
    value = (address+operand-1-0x30201078) & MASK
    value ^= 0x1F9BF630
    value = ((~value & MASK) ^ 0x3C6AAEDE)-1
    value &= MASK
    return ((value >> 4) | (value << 28)) & MASK


class BoundaryReached(Exception):
    pass


def vm_frame(source):
    from dnf_native_vm_probe import CPU
    cpu = CPU(source)
    original_write = cpu.write

    def capture(address, size, value):
        original_write(address, size, value)
        if cpu.pc == 0x21FAE38 and size == 4 and value == 0x15B6418:
            raise BoundaryReached()

    cpu.write = capture
    try:
        result = cpu.run(0x7711D0, 12000)
    except BoundaryReached:
        pass
    else:
        raise ValueError(f'VM frame prefix stopped before boundary: {result}')
    finally:
        cpu.write = original_write
    # Remove the already pushed _nosound operand. Preserve the explicit owner=0
    # fixture beneath it. We do not claim this is the full resource loader path.
    cpu.reg['esp'] += 4
    if cpu.read(cpu.reg['esp'], 4) != 0:
        raise ValueError('Unexpected fixture argument beneath immediate')
    prefix = cpu.trace[:]
    cpu.trace.clear()
    cpu.events.clear()
    cpu.branches.clear()
    return cpu, prefix


def trace_binding(source, operand_address, handle, clobber):
    cpu, prefix = vm_frame(source)
    cpu.string_clobber = clobber
    cpu.reg['esi'] = operand_address
    result = cpu.run(HANDLER, 5000)
    if result[:2] != ('native_entry', '0x5fef30'):
        raise ValueError(f'Constructor boundary not reached: {result}')
    args = result[2]
    path = cpu.strings.get(args[0])
    if not path or args[1] != 0:
        raise ValueError(f'Unexpected particle constructor arguments: {args}')
    boundary = {'entry': '0x5fef30', 'filename': path, 'owner_fixture': args[1],
                'this_at_spliced_entry': hex(cpu.reg['ecx']),
                'return_pc': hex(cpu.read(cpu.reg['esp'], 4)),
                'return_identity_fixture': hex(handle), 'callee_stack_pop_bytes': 8}
    # Constructor 5FEF58 retains ECX in EDI; 5FF053 returns EDI in EAX;
    # 5FF066 is RET 8. Its allocation/loading body is deliberately not run.
    cpu.reg['eax'] = handle
    cpu.reg['ecx'], cpu.reg['edx'], cpu.flags = clobber
    continuation = cpu.pop()
    cpu.reg['esp'] += 8
    original_write = cpu.write
    observed = []

    def capture(address, size, value):
        original_write(address, size, value)
        if address in (0x1A5F820, 0x1A5F824, 0x1A5F828):
            observed.append({'pc': hex(cpu.pc), 'address': hex(address),
                             'size': size, 'value': hex(value)})
            raise BoundaryReached()

    cpu.write = capture
    try:
        result = cpu.run(continuation, 5000)
    except BoundaryReached:
        pass
    else:
        raise ValueError(f'Global write boundary not reached: {result}')
    if len(observed) != 1 or observed[0]['size'] != 4 or observed[0]['value'] != hex(handle):
        raise ValueError(f'Constructor return identity not retained: {observed}')
    return {'bytecode_operand': hex(operand_address), 'constructor': boundary,
            'clobber_fixture': [hex(v) for v in clobber], 'write': observed[0],
            'steps': len(cpu.trace), 'trace_sha256': trace_hash(cpu.trace),
            'conditional_branches': cpu.branches}, prefix, cpu.trace


def trace_hash(trace):
    return hashlib.sha256(('\n'.join(trace)+'\n').encode()).hexdigest()


def source_blocks(source, traces):
    # Archive every decoded instruction used, coalescing contiguous addresses.
    addresses = sorted({int(line[:8], 16) for trace in traces for line in trace})
    ranges = []
    for address in addresses:
        instruction = next(source.decoder.disasm(source.source_bytes(address, 15), address, count=1))
        end = address+instruction.size
        if ranges and address == ranges[-1][1]:
            ranges[-1][1] = end
        else:
            ranges.append([address, end])
    blocks = []
    for start, end in ranges:
        raw = source.source_bytes(start, end-start)
        instructions = list(source.decoder.disasm(raw, start))
        if sum(i.size for i in instructions) != len(raw):
            raise ValueError('Incomplete instruction span')
        blocks.append({'start': hex(start), 'end_exclusive': hex(end),
                       'sha256': hashlib.sha256(raw).hexdigest(),
                       'instructions': [f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in instructions]})
    return blocks


def audit(source):
    traces, runs, operands = [], [], []
    for index, (string_code, string_va, global_code, global_va, filename) in enumerate(BINDINGS):
        for code, expected in ((string_code, string_va), (global_code, global_va)):
            actual = decode_immediate(source, code)
            if actual != expected:
                raise ValueError(f'Immediate mismatch at {code:#x}: {actual:#x}')
            operands.append({'bytecode': hex(code), 'raw8': source.source_bytes(code, 8).hex(),
                             'decoded': hex(actual)})
        text, size = recover_string(source.source_bytes(string_va, 1024), 0, 2)
        if text != PREFIX+filename:
            raise ValueError('Decoded source filename differs')
        operands[-2]['string_bytes'] = source.source_bytes(string_va, 4+size).hex()
        for variant, clobber in enumerate(((0, 0, 0x202), (0xBAADF00D, 0xBAD0C0DE, 0xA97))):
            row, prefix, trace = trace_binding(source, string_code, 0x61500000+index*0x1000+variant*0x100, clobber)
            if row['constructor']['filename'] != PREFIX+filename or row['write']['address'] != hex(global_va):
                raise ValueError(f'Observed binding differs from pinned expected mapping: {row}')
            runs.append(row)
            traces.extend((prefix, trace))
    constructor_trace = [f'{i.address:08X} {i.mnemonic} {i.op_str}' for start, end in
                         ((0x5FEF58, 0x5FEF5D), (0x5FF036, 0x5FF069),
                          (0xA6FE41, 0xA6FEB4), (0xA6FF1D, 0xA6FF3E))
                         for i in source.decoder.disasm(source.source_bytes(start, end-start), start)]
    traces.append(constructor_trace)
    tools = {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes().replace(b'\r\n', b'\n')).hexdigest()
             for name in ('audit_dnf_ice_particle_bindings.py', 'dnf_native_vm_probe.py',
                          'audit_dnf_native_strings.py', 'audit_dnf_particle_axis.py')}
    return {'schema': 'dnf_ice_particle_bindings/1', 'engine_sha256': ENGINE_SHA,
            'input_source': source.source,
            'method': __doc__.strip(), 'tools_sha256': tools,
            'boundaries': ['Source-derived VM frame at 0x7711D0, spliced at immediate handler 0x21D7D21.',
                           'Owner=0 and first constructor this=0 are splice fixtures, not a live allocation.',
                           'String wrapper replaced by pinned decoder; constructor body replaced by return identity and RET 8.',
                           'Two different constructor identities and volatile-register/flag fixtures per path.',
                           'Stops at first targeted global write; does not certify full initialization or trigger behavior.'],
            'prefix_steps': len(prefix), 'prefix_trace_sha256': trace_hash(prefix),
            'operands': operands, 'runs': runs, 'blocks': source_blocks(source, traces)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('client', type=Path)
    parser.add_argument('--decoder-dir', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.client.resolve() == args.output.resolve():
        raise ValueError('Output cannot replace source client')
    if args.decoder_dir:
        sys.path.insert(0, str(args.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    evidence = audit(AxisEvaluator(args.client.read_bytes()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=1)+'\n', encoding='utf8', newline='\n')
    print('[ICE_PARTICLE_BINDINGS] smoke=1A5F820 shard=1A5F824 star=1A5F828; 6 bounded traces passed')


if __name__ == '__main__':
    main()

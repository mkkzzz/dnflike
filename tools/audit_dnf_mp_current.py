"""Native current-MP setter body, timer predicates and current-value getter.

The setter's protected prologue/epilogue are excluded explicitly. The body starts
with prepared actor/frame registers; its timer helpers and getters run fully.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from audit_dnf_chr_writeback import signed
from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_native_strings import ENGINE_SHA

ACTOR, TIMER, CURRENT, DIRTY = 0x60000000, 0x60003598, 0x60002bf8, 0x60003110
VTABLE, FRAME, CLOCK = 0x16f972c, 0x6ffffffc, 0x1bcaae0
PREVIOUS = Path(__file__).resolve().parents[1] / 'docs/reports/ws2/2026-11/native_chr_refill.json'


def run(source, variant='setter', current=100, target=99, mark=1, flags=3,
        duration=100, cached=99, clock_index=2, clock_value=70, offset=29, poison=False):
    from dnf_native_vm_probe import CPU
    if variant not in ('setter', 'elapsed', 'complete', 'current') or clock_index not in range(16):
        raise ValueError('Unknown fixture/domain')
    c = CPU(source)
    for a in range(0x6fffc000, 0x70000000, 4):
        c.write(a, 4, 0)
    c.reg.update(ecx=ACTOR, ebx=17, esi=29, edi=31, ebp=37)
    c.write(ACTOR, 4, VTABLE)
    values = {8: clock_index, 12: flags, 16: offset, 20: cached, 24: duration}
    decoded = {}
    for off, value in values.items():
        token = 0x10000000 + off
        c.write(TIMER + off, 4, token)
        decoded[token] = (hex(off), value & 0xffffffff)
    # Every clock entry has a distinct token. Wrong indexing cannot silently read
    # an uninitialized zero or the selected fixture's value.
    for index in range(16):
        token = 0x20000000 + index
        c.write(CLOCK + index * 4, 4, token)
        decoded[token] = ('clock:' + str(index), (clock_value if index == clock_index else 10000 + index) & 0xffffffff)
    protected = {CURRENT: current & 0xffffffff, DIRTY: 123}
    c.pc = {'setter': 0x812268, 'elapsed': 0x11afbd0, 'complete': 0x11afcf0, 'current': 0xd07ac0}[variant]
    if variant == 'setter':
        c.reg.update(esi=ACTOR, ebp=FRAME, esp=FRAME - 8)
        c.write(FRAME + 8, 4, target)
        c.write(FRAME + 12, 4, mark)
    elif variant in ('elapsed', 'complete'):
        c.reg['ecx'] = TIMER
    decodes, writes, reads = [], [], []
    body_abi, body_stop = None, None
    def finish(value=0, pop_bytes=0):
        c.reg['eax'] = value & 0xffffffff
        c.pc = c.pop()
        c.reg['esp'] += pop_bytes
        c.reg['ecx'], c.reg['edx'], c.flags = (0xbaadf00d, 0xbad0c0de, 0xa97) if poison else (0, 0, 0x202)
    for _ in range(3000):
        if c.pc == 0xdeadbeef:
            break
        if c.pc == 0x8122d8:
            if variant != 'setter' or body_stop is not None:
                raise ValueError('Unexpected body boundary')
            body_stop = hex(c.pc)
            body_abi = [c.reg[k] for k in ('ebx', 'esi', 'edi', 'ebp', 'esp')]
            # Independent second phase: actual native current-MP getter reads the
            # same protected-store fixture after the body. No protected epilogue
            # or complete setter return is implied by this prepared entry.
            c.reg.update(ecx=ACTOR, ebx=17, esi=29, edi=31, ebp=37, esp=0x70000000)
            c.write(0x70000000, 4, 0xdeadbeef)
            c.pc = 0xd07ac0
            continue
        arg = lambda j: c.read(c.reg['esp'] + 4 + j * 4, 4)
        if c.pc == 0x1195b90:
            token = c.read(arg(0), 4)
            if token not in decoded:
                raise ValueError('Unknown encoded timer/clock input')
            label, value = decoded[token]
            decodes.append(label)
            c.write(arg(1), 4, value)
            finish()
            continue
        if c.pc in (0x1195eb0, 0x1195a10):
            this = c.reg['ecx']
            if this not in protected:
                raise ValueError('Unexpected protected state address')
            if c.pc == 0x1195eb0:
                if arg(0) != this + 8:
                    raise ValueError('Protected read key')
                reads.append(hex(this - ACTOR))
                c.write(arg(1), 4, protected[this])
            else:
                if arg(1) != this + 8:
                    raise ValueError('Protected write key')
                protected[this] = c.read(arg(0), 4)
                writes.append([hex(this - ACTOR), protected[this]])
            finish(pop_bytes=8)
            continue
        result = c.run(c.pc, 1)
        if result[0] in ('budget', 'returned'):
            continue
        if result[0] == 'call' and int(result[2], 16) in (
                0x11afa40, 0x11afcf0, 0x11afbd0, 0x11e64b0, 0x1195b90,
                0xd073c0, 0xd07ac0, 0x1195eb0, 0x1195a10):
            ins = next(source.decoder.disasm(source.source_bytes(c.pc, 15), c.pc, count=1))
            c.push(c.pc + ins.size)
            c.pc = int(result[2], 16)
            continue
        raise ValueError('Unmodeled current-MP instruction ' + str(result))
    else:
        raise ValueError('Current-MP instruction budget')
    return {'fixture': {'variant': variant, 'current': current, 'target': target, 'mark': mark,
        'flags': flags, 'duration': duration, 'cached': cached, 'clock_index': clock_index,
        'clock_value': clock_value, 'offset': offset, 'poison': poison},
        'decodes': decodes, 'writes': writes, 'reads': reads,
        'current': protected[CURRENT], 'dirty': protected[DIRTY], 'result': c.reg['eax'],
        'body_stop': body_stop, 'body_abi': body_abi, 'stop': hex(c.pc),
        'abi': [c.reg[k] for k in ('ebx', 'esi', 'edi', 'ebp', 'esp')],
        'steps': len(c.trace), 'trace_sha256': trace_hash(c.trace)}, c.trace


def elapsed(f):
    if f['flags'] & 3 != 3:
        return 0
    return (f['cached'] if f['flags'] & 4 else f['clock_value'] + f['offset']) & 0xffffffff


def elapsed_decodes(f):
    if f['flags'] & 3 != 3:
        return ['0xc']
    return ['0xc', '0x14'] if f['flags'] & 4 else ['0xc', '0x8', '0x10', 'clock:' + str(f['clock_index'])]


def verify(row):
    f = row['fixture']
    complete = signed(elapsed(f)) >= signed(f['duration'] & 0xffffffff)
    current, dirty, writes, reads, decodes = f['current'] & 0xffffffff, 123, [], [], []
    body_stop, body_abi = None, None
    if f['variant'] == 'setter':
        decodes = ['0xc']
        guarded = bool(f['flags'] & 1)
        if guarded:
            decodes += ['0x18'] + elapsed_decodes(f)
            if not complete:
                reads.append('0x2bf8')
        if not (guarded and not complete and signed(f['target'] & 0xffffffff) < signed(current)):
            current = f['target'] & 0xffffffff
            writes.append(['0x2bf8', current])
            if f['mark'] & 255:
                dirty = 0xffffffff
                writes.append(['0x3110', dirty])
        reads.append('0x2bf8')
        body_stop, body_abi = '0x8122d8', [f['target'] & 0xffffffff, ACTOR, 31, FRAME, FRAME - 8]
        result = current
    elif f['variant'] == 'elapsed':
        result, decodes = elapsed(f), elapsed_decodes(f)
    elif f['variant'] == 'complete':
        # Native SETGE writes AL only; callers test AL, while the upper EAX
        # bytes still contain the elapsed result.
        result = (elapsed(f) & 0xffffff00) | int(complete)
        decodes = ['0x18'] + elapsed_decodes(f)
    else:
        result, reads = current, ['0x2bf8']
    if (row['current'], row['dirty'], row['result'], row['writes'], row['reads'], row['decodes']) != (current, dirty, result, writes, reads, decodes):
        raise ValueError('Current-MP/timer result mismatch')
    if row['body_stop'] != body_stop or row['body_abi'] != body_abi:
        raise ValueError('Prepared setter body boundary mismatch')
    if row['stop'] != '0xdeadbeef' or row['abi'] != [17, 29, 31, 37, 0x70000004]:
        raise ValueError('Native getter/timer return ABI mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest() != ENGINE_SHA:
        raise ValueError('Unexpected engine')
    fixtures = [{'flags': flags, 'target': target, 'mark': mark}
        for flags in range(8) for target in (99, 100, 101) for mark in (0, 1)]
    fixtures += [{'flags': 0, 'mark': mark} for mark in (256, 257, 0xffffffff)]
    fixtures += [{'flags': 3, 'clock_value': v, 'offset': 0} for v in (99, 100, 101)]
    fixtures += [{'flags': 7, 'cached': v} for v in (99, 100, 101)]
    fixtures += [{'flags': 3, 'clock_index': i, 'clock_value': 101, 'offset': -2} for i in (0, 15)]
    fixtures += [{'flags': 0, 'target': v} for v in (-1, 0, 0x7fffffff, 0x80000000)]
    fixtures += [{'flags': 1, 'current': a, 'target': b} for a, b in ((0, -1), (-1, 0), (0x7fffffff, 0x80000000))]
    fixtures += [{'flags': 3, 'clock_value': v, 'offset': off, 'duration': d}
        for v, off, d in ((0x7fffffff, 1, 100), (-1, 1, 0), (0, -1, -1), (99, 0, -1))]
    fixtures += [{'variant': variant, 'flags': flags, 'duration': d}
        for variant in ('elapsed', 'complete') for flags in (0, 1, 2, 3, 4, 7, 255) for d in (0, 99, 100)]
    fixtures += [{'variant': 'current', 'current': v} for v in (0, -1, 54, 0x7fffffff, 0x80000000)]
    fixtures += [{'variant': 'complete', 'flags': 3, 'clock_value': v, 'offset': off, 'duration': d}
        for v, off, d in ((0x7fffffff, 0, 100), (-1, 0, -1), (0x7fffffff, 1, 100), (0x123400, 0, 0x123400))]
    rows, traces = [], []
    for poison in (False, True):
        for f in fixtures:
            row, trace = run(source, **f, poison=poison)
            verify(row)
            rows.append(row)
            traces.append(trace)
    source_cases = []
    previous = json.loads(PREVIOUS.read_text(encoding='utf-8'))
    for index, old in enumerate(previous['cases']):
        requests = [e for e in old['refill']['events'] if e[:2] == ['set_request', '0x812260']]
        for request in requests:
            row, trace = run(source, target=request[2], mark=request[3][0], poison=old['fixture']['poison'])
            verify(row)
            source_cases.append({'source_case': index, 'result': row})
            traces.append(trace)
    names = ('audit_dnf_mp_current.py', 'audit_dnf_chr_writeback.py', 'dnf_native_vm_probe.py',
        'audit_dnf_ice_particle_bindings.py', 'audit_dnf_native_strings.py', 'audit_dnf_particle_axis.py')
    return {'schema': 'dnf_mp_current/1', 'engine_sha256': ENGINE_SHA, 'input_source': source.source,
        'tools_sha256': {n: hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n', b'\n')).hexdigest() for n in names},
        'previous_evidence_sha256': hashlib.sha256(PREVIOUS.read_bytes().replace(b'\r\n', b'\n')).hexdigest(),
        'cases': rows, 'refill_input_cases': source_cases, 'blocks': source_blocks(source, traces),
        'unresolved_blocks': [{'start': hex(a), 'bytes': source.source_bytes(a, n).hex(),
            'instructions': [f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in source.decoder.disasm(source.source_bytes(a, n), a)]}
            for a, n in ((0x812260, 8), (0x8122d8, 5), (0x1ef4b5c, 8))],
        'vtable': [{'offset': hex(o), 'target': hex(int.from_bytes(source.source_bytes(VTABLE + o, 4), 'little'))}
            for o in (0x460, 0x514, 0x518)],
        'boundaries': [
            'Setter executes only 812268 through 8122D8 with prepared ESI/frame/stack. Protected entry 812260 and tail 8122D8 are not emulated; no full setter return is claimed.',
            '11AFA40, 11AFCF0, 11AFBD0 and 11E64B0 execute native instructions, including flags, signed comparison, selected clock table entry and wrapped addition.',
            '11AFCF0 returns its predicate in AL only. Its upper EAX bytes retain the elapsed value; the setter tests AL, not full EAX.',
            '1195B90 encoded-value decoding and 1195EB0/1195A10 protected reads/writes are explicit checked ABI storage fixtures, not the native cryptographic implementation.',
            'After the body boundary, a separate prepared invocation of D07AC0 and D073C0 executes the real current-value getter against the same protected-store fixture.',
            'Prior refill requests are fed as target/mark inputs to the prepared body, with explicit current=100 and timer fixture state. The protected prologue gap is not bridged by this input linkage.',
            'The decoded timer flag producers, chosen clock channel, units, update cadence, actor lifecycle and mode meaning remain unproved.',
            'Actor+3110 receives -1 when the low byte of the mark argument is nonzero and writing was allowed; downstream meaning is unresolved.',
            'This body has no maximum or zero clamp on permitted input; protected surrounding code and other callers are excluded, so this is not a whole-game unclamped-value claim.',
            'No local MP restoration timer, resource consumption rule, HP setter behavior or gameplay adaptation is added.']}


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
    print('MP_CURRENT', len(result['cases']))


if __name__ == '__main__':
    main()

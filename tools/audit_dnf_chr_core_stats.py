"""Read-only 855770 core-field consumer; refresh/reset services remain fixtures."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

from audit_dnf_chr_numbers import extension, f32
from audit_dnf_chr_writeback import signed, trunc_div
from audit_dnf_ice_shatter import fbits, real
from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_native_strings import ENGINE_SHA

ROOT = Path(__file__).resolve().parents[1]
PREVIOUS = ROOT / 'docs/reports/ws2/2026-11/native_chr_writeback.json'
ACTOR, MODE, SCALER, SCALER_VT = 0x60000000, 0x60100000, 0x60200000, 0x60300000
VTABLE, BANK = 0x16f972c, ACTOR + 0x8ac + 3 * 0x8d0
FRAME = 0x6ffffffc
CORE_DEST = (0x8b8, 0x8d0, 0x8f4, 0x90c, 0x924, 0x93c)
SNAPSHOT = {0xc: 16777217, 0x18: fbits(1.375), 0x24: -16777217 & 0xffffffff, 0x30: fbits(-2.125)}
CHANGED = {0xc: 99, 0x18: fbits(2.75), 0x24: 101, 0x30: fbits(3.5)}


def replay(source, core=(1800, 1400, 75, 75, 45, 45), rate=100, query=False,
           mode_id=0, flag10=False, flag13=False, scalar_present=False,
           scalar_key=7, factors=(1.25, .75), eligible=False, kind=0, poison=False):
    from dnf_native_vm_probe import CPU
    if len(core) != 6 or len(factors) != 2:
        raise ValueError('Fixture shape')
    c = CPU(source)
    for a in range(0x6fffc000, 0x70000000, 4):
        c.write(a, 4, 0)
    c.reg.update(ecx=ACTOR, ebx=17, esi=29, edi=31, ebp=37)
    c.write(ACTOR, 4, VTABLE)
    c.write(ACTOR + 0x3658, 4, kind)
    c.write(SCALER, 4, SCALER_VT)
    c.write(SCALER_VT + 0x40, 4, 0)  # explicit external virtual service marker
    protected = {ACTOR + 0x4cb0 + i * 12: v & 0xffffffff for i, v in enumerate(core)}
    protected[ACTOR + 0x4e60] = rate & 0xffffffff
    protected[BANK] = scalar_key & 0xffffffff
    for off, v in {0x60: 61, 0x6c: 62, 0x90: 91, 0x9c: 92, **SNAPSHOT}.items():
        protected[BANK + off] = v
    locals_ = {FRAME - 0x4c, FRAME - 0x64, FRAME - 0x58}
    xmm = {f'xmm{i}': 0 for i in range(8)}
    fp, writes, calls, rates = [], [], [], []
    refreshes = 0
    c.pc = 0x855770
    def clobber():
        c.reg['ecx'], c.reg['edx'], c.flags = (0xbaadf00d, 0xbad0c0de, 0xa97) if poison else (0, 0, 0x202)
        for name in xmm:
            xmm[name] = 0x123456789abcdef if poison else 0
    def finish(value=0, pop_bytes=0):
        c.reg['eax'] = value & 0xffffffff
        c.pc = c.pop()
        c.reg['esp'] += pop_bytes
        clobber()
    def virtual(value, pop_bytes=0):
        c.reg['eax'] = value & 0xffffffff
        c.reg['esp'] += pop_bytes
        clobber()
        c.pc += 2
    for _ in range(16000):
        if c.pc == 0xdeadbeef:
            break
        arg = lambda j: c.read(c.reg['esp'] + 4 + j * 4, 4)
        if c.pc == 0x8549f0:
            if c.reg['ecx'] != ACTOR:
                raise ValueError('Reset ABI')
            calls.append(['reset'])
            finish()
            continue
        if c.pc in (0x1197630, 0x1195dc0):
            this = c.reg['ecx']
            if this not in locals_:
                raise ValueError('Temporary protected value ABI')
            if c.pc == 0x1197630:
                protected[this] = 0
            else:
                del protected[this]
            finish()
            continue
        if c.pc in (0x1195eb0, 0x1195a10):
            this = c.reg['ecx']
            if c.pc == 0x1195eb0:
                if this not in protected or arg(0) != this + 8:
                    raise ValueError('Protected read ABI ' + hex(this))
                c.write(arg(1), 4, protected[this])
            else:
                if arg(1) != this + 8 or this not in locals_ | {ACTOR + x for x in CORE_DEST} | {BANK + x for x in SNAPSHOT}:
                    raise ValueError('Protected write ABI ' + hex(this))
                protected[this] = c.read(arg(0), 4)
                if this not in locals_:
                    writes.append([hex(this - ACTOR), protected[this]])
            finish(pop_bytes=8)
            continue
        if c.pc == 0x6fc760:
            finish(MODE)
            continue
        if c.pc in (0x752ab0, 0x752850, 0x752930, 0x7527d0):
            if c.reg['ecx'] != MODE:
                raise ValueError('Mode service ABI')
            if c.pc == 0x752ab0:
                if arg(0) != 0xffffffff:
                    raise ValueError('Mode -1 ABI')
                calls.append(['query', -1])
                finish(int(query), 4)
            elif c.pc == 0x752850:
                calls.append(['mode_id'])
                finish(mode_id)
            elif c.pc == 0x752930:
                key = arg(0)
                if key not in (10, 13):
                    raise ValueError('Unknown mode flag')
                calls.append(['flag', key])
                finish(int(flag10 if key == 10 else flag13), 4)
            else:
                calls.append(['scaler_lookup'])
                finish(SCALER if scalar_present else 0)
            continue
        if c.pc == 0x75bf37:
            actual = [c.read(c.reg['esp'] + j * 4, 4) for j in range(3)]
            if c.reg['ecx'] != SCALER or c.reg['edx'] != 0 or actual not in ([scalar_key, 2, ACTOR], [scalar_key, 12, ACTOR]):
                raise ValueError('Scaler virtual ABI')
            selector = actual[1]
            calls.append(['scale', selector, scalar_key])
            fp.append(f32(factors[0 if selector == 2 else 1]))
            virtual(0, 12)
            continue
        if c.pc in (0x8557b0, 0x855c02):
            if c.reg['ecx'] != ACTOR or c.read(c.reg['esp'], 4) != 0:
                raise ValueError('Refresh ABI')
            # Register holding the actual virtual target differs at the two sites.
            target = c.reg['edx'] if c.pc == 0x8557b0 else c.reg['eax']
            if target != int.from_bytes(source.source_bytes(VTABLE + 0x444, 4), 'little'):
                raise ValueError('Refresh target')
            refreshes += 1
            calls.append(['refresh', refreshes])
            if refreshes == 2:
                # Explicit second-service output makes the subsequent restoration
                # observable; this is not an emulation of the refresh function.
                for off, v in CHANGED.items():
                    protected[BANK + off] = v
            virtual(0, 4)
            continue
        if c.pc == 0x855bc9:
            if c.reg['ecx'] != ACTOR or c.reg['eax'] != int.from_bytes(source.source_bytes(VTABLE + 0x38, 4), 'little'):
                raise ValueError('Eligibility ABI')
            calls.append(['eligible'])
            virtual(int(eligible))
            continue
        if c.pc == 0x11b3780:
            if arg(0) != ACTOR + 0x8ac:
                raise ValueError('Conditional callback ABI')
            calls.append(['callback_bank0'])
            finish()
            continue
        if c.pc == 0x855907:
            rates.append(signed(c.reg['edi']))
        result = c.run(c.pc, 1)
        if result[0] in ('budget', 'returned'):
            continue
        ins = next(source.decoder.disasm(source.source_bytes(c.pc, 15), c.pc, count=1))
        if result[0] == 'call':
            target = int(result[2], 16)
            if target not in (0x8549f0, 0xd07390, 0x1195eb0, 0x1195a10, 0x1197630, 0x1195dc0,
                0x6fc760, 0x752ab0, 0x752850, 0x752930, 0x7527d0, 0x75bf00, 0x11b3780):
                raise ValueError('Unexpected call ' + str(result))
            c.push(c.pc + ins.size)
            c.pc = target
        elif result[0] == 'unsupported' and ins.mnemonic == 'fld1':
            fp.append(1.)
            c.pc += ins.size
        elif result[0] == 'unsupported' and ins.mnemonic == 'divss':
            dst, src = ins.operands
            name = ins.reg_name(dst.reg)
            divisor = real(c.get(ins, src))
            if divisor == 0:
                raise ValueError('Zero divisor outside finite audit')
            xmm[name] = (xmm[name] & ~0xffffffff) | fbits(real(xmm[name]) / divisor)
            c.pc += ins.size
        elif result[0] == 'unsupported' and ins.mnemonic == 'imul' and len(ins.operands) == 1:
            product = signed(c.reg['eax']) * signed(c.get(ins, ins.operands[0]))
            c.reg['eax'], c.reg['edx'] = product & 0xffffffff, (product >> 32) & 0xffffffff
            c.flags = (c.flags & ~0x801) | (0 if -2147483648 <= product <= 2147483647 else 0x801)
            c.pc += ins.size
        elif result[0] == 'unsupported':
            extension(c, xmm, fp, ins)
        else:
            raise ValueError('Unexpected stop ' + str(result))
    else:
        raise ValueError('Core consumer instruction budget')
    return {'fixture': {'core': list(core), 'rate': rate, 'query': query, 'mode_id': mode_id,
        'flag10': flag10, 'flag13': flag13, 'scalar_present': scalar_present, 'scalar_key': scalar_key,
        'factors': list(factors), 'eligible': eligible, 'kind': kind, 'poison': poison},
        'writes': writes, 'calls': calls, 'rates': rates, 'bank_tail': {hex(o): protected[BANK + o] for o in SNAPSHOT},
        'abi': [c.reg[k] for k in ('ebx', 'esi', 'edi', 'ebp', 'esp')], 'fp_depth': len(fp),
        'temporary_count': sum(a in protected for a in locals_), 'seh': c.read(0x50000000, 4),
        'stop': hex(c.pc), 'steps': len(c.trace), 'trace_sha256': trace_hash(c.trace)}, c.trace


def verify(row):
    f = row['fixture']
    calls = [['reset'], ['refresh', 1], ['query', -1]]
    use_default = False
    if f['query']:
        calls.append(['mode_id'])
        use_default = f['mode_id'] != 9
    if not use_default:
        calls.append(['flag', 10])
        use_default = f['flag10']
        if not use_default:
            calls.append(['flag', 13])
            use_default = f['flag13']
    rate = 100 if use_default else f['rate']
    factors = [1., 1.]
    for i, selector in enumerate((2, 12)):
        if f['scalar_key']:
            calls.append(['scaler_lookup'])
            if f['scalar_present']:
                calls += [['scaler_lookup'], ['scale', selector, f['scalar_key']]]
                factors[i] = f32(f['factors'][i])
    values = [math.trunc(f32(f32(factors[i] / 10.) * f32(signed(f['core'][i] & 0xffffffff)))) for i in range(2)]
    values += [trunc_div(signed((v * rate) & 0xffffffff), 1000) for v in f['core'][2:]]
    writes = [[hex(off), v & 0xffffffff] for off, v in zip(CORE_DEST, values)]
    calls.append(['eligible'])
    if f['eligible'] and f['kind'] in (3, 8):
        calls.append(['callback_bank0'])
    calls.append(['refresh', 2])
    final = CHANGED.copy()
    if rate != 100:
        final = SNAPSHOT.copy()
        for off in (0xc, 0x24):
            final[off] = math.trunc(f32(signed(final[off]))) & 0xffffffff
        writes += [[hex(BANK + off - ACTOR), final[off]] for off in SNAPSHOT]
    if (row['writes'], row['calls'], row['rates'], row['bank_tail']) != (writes, calls, [rate], {hex(k): v for k, v in final.items()}):
        raise ValueError('Core consumer arithmetic/routing/restoration mismatch')
    if row['abi'] != [17, 29, 31, 37, 0x70000008] or row['fp_depth'] or row['temporary_count'] or row['seh'] != 0xffffffff or row['stop'] != '0xdeadbeef':
        raise ValueError('Core consumer return/cleanup mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest() != ENGINE_SHA:
        raise ValueError('Unexpected engine')
    fixtures = [{'rate': r} for r in (0, 1, 50, 100, 135, -21, 0x7fffffff)]
    fixtures += [{'rate': 135, 'query': q, 'mode_id': mode, 'flag10': a, 'flag13': b}
        for q, mode, a, b in [(True, 0, False, False), (True, 9, False, False), (False, 0, True, False), (False, 0, False, True), (True, 9, True, True)]]
    fixtures += [{'scalar_present': present, 'scalar_key': key, 'factors': factors}
        for present, key, factors in [(False, 0, (2., 3.)), (True, 0, (2., 3.)), (True, 7, (1.25, .75)), (True, 7, (-.25, 0.)), (True, 7, (1.33333337, .99999994))]]
    fixtures += [{'eligible': e, 'kind': k, 'rate': 135} for e, k in [(False, 3), (True, 0), (True, 3), (True, 8)]]
    fixtures += [{'core': [0xfffffff7, 16777217, 65535, 32768, 9999, -9999], 'rate': 135}]
    cases, traces = [], []
    for poison in (False, True):
        for fixture in fixtures:
            row, trace = replay(source, **fixture, poison=poison)
            verify(row)
            cases.append(row)
            traces.append(trace)
    previous = json.loads(PREVIOUS.read_text(encoding='utf-8'))
    source_cases = []
    for old in previous['source_input_cases']:
        w = dict(old['result']['writes'])
        core = [w[hex(0x4cb0 + i * 12)] for i in range(6)]
        row, trace = replay(source, core=core, poison=old['result']['fixture']['poison'])
        verify(row)
        source_cases.append({'level': old['level'], 'job': old['job'], 'result': row})
        traces.append(trace)
    names = ('audit_dnf_chr_core_stats.py', 'audit_dnf_chr_writeback.py', 'audit_dnf_chr_numbers.py',
        'dnf_native_vm_probe.py', 'audit_dnf_firewave.py', 'audit_dnf_ice_shatter.py',
        'audit_dnf_ice_particle_bindings.py', 'audit_dnf_native_strings.py', 'audit_dnf_particle_axis.py')
    return {'schema': 'dnf_chr_core_stats/1', 'engine_sha256': ENGINE_SHA, 'input_source': source.source,
        'tools_sha256': {n: hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n', b'\n')).hexdigest() for n in names},
        'previous_evidence_sha256': hashlib.sha256(PREVIOUS.read_bytes().replace(b'\r\n', b'\n')).hexdigest(),
        'cases': cases, 'source_input_cases': source_cases, 'blocks': source_blocks(source, traces),
        'constants': [{'address': hex(a), 'bytes': source.source_bytes(a, 4).hex()}
            for a in (0x16cf488, VTABLE + 0x440)],
        'boundaries': [
            '855770 executes from entry to return with its byte argument fixed at 0; the current-HP/MP refill branch for nonzero arguments is excluded.',
            'D07390 bank selection and 75BF00 scaler dispatch execute native instructions; mode services and scaler virtual results are explicit ABI fixtures.',
            '8549F0 reset, virtual 444 refresh, virtual 38 predicate and 11B3780 callback remain fixtures, not proven implementations.',
            'Second refresh injects changed bank fields solely to observe the native restoration branch; these are not real refresh outputs.',
            'Protected storage constructors/read/write/destructors use checked ABI fixtures, including three local temporary lifetimes.',
            'Prior source records are data inputs only; intervening growth modifiers and full character initialization are not proved.',
            'Actor 4E60 rate producer and mode meanings are unresolved. HP/MP factors are mode-scaler results, not guessed vitality/spirit formulas.',
            'Six destination fields are identified by offsets; final panel labels, later modifiers and gameplay equations remain unresolved.']}


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
    print('CHR_CORE_STATS', len(result['cases']), 'cases', len(result['source_input_cases']), 'source inputs')


if __name__ == '__main__':
    main()

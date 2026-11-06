"""Native nonzero-byte 855770 branch and actual HP/MP limit getters."""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import sys

from audit_dnf_chr_core_stats import replay, verify as verify_core, VTABLE, SNAPSHOT
from audit_dnf_chr_numbers import f32
from audit_dnf_chr_writeback import signed, trunc_div
from audit_dnf_ice_shatter import fbits
from audit_dnf_ice_particle_bindings import source_blocks
from audit_dnf_native_strings import ENGINE_SHA

ROOT = Path(__file__).resolve().parents[1]
PREVIOUS = ROOT / 'docs/reports/ws2/2026-11/native_chr_core_stats.json'


def fixture(**kwargs):
    out = {'argument': 1, 'bank': [301, 1.25, 197, .75], 'guard': False,
        'type_match': False, 'profile_present': True, 'profile_rate': 65, 'actor_id': 17}
    out.update(kwargs)
    return out


def limit(base, factor):
    # Native CVTSI2SS, MULSS, CVTTSS2SI within the finite conversion domain.
    value = f32(f32(signed(base & 0xffffffff)) * f32(factor))
    if not -2147483648 <= value < 2147483648:
        raise ValueError('Outside audited finite conversion domain')
    return math.trunc(value)


def request(base, factor, rate):
    return trunc_div(signed((limit(base, factor) * rate) & 0xffffffff), 100)


def verify(row):
    f = row['fixture']
    r = f['refill']
    prefix = copy.deepcopy(row)
    del prefix['fixture']['refill']
    del prefix['refill']
    active = bool(r['argument'] & 255)
    if active:
        if prefix['calls'][-1] != ['refresh', 3]:
            raise ValueError('Missing third refresh')
        prefix['calls'].pop()
        prefix['bank_tail'] = row['refill']['bank_before']
    elif row['refill']['bank_before'] is not None:
        raise ValueError('Unexpected refill snapshot')
    verify_core(prefix)
    events = []
    if active:
        rate = row['rates'][0]
        hp, hf, mp, mf = r['bank']
        events = [['limit_get', '0xd07af0', [1]],
            ['set_request', '0x812260', request(mp, mf, rate), [1]], ['guard']]
        if r['guard']:
            events.append(['type_predicate', r['actor_id'] & 0xffffffff])
        special = r['guard'] and r['type_match']
        if special:
            events.append(['profile_eligible', f['eligible']])
            if not f['eligible']:
                events.append(['profile_fallback'])
        if not special or r['profile_present']:
            hp_rate = r['profile_rate'] if special else rate
            events += [['limit_get', '0xd07a70', [0, 1]],
                ['set_request', '0x831620', request(hp, hf, hp_rate), [0, 1]]]
        bank = {hex(o): v for o, v in zip(SNAPSHOT, (hp & 0xffffffff, fbits(hf), mp & 0xffffffff, fbits(mf)))}
        if row['bank_tail'] != bank:
            raise ValueError('Third refresh bank not consumed')
    if row['refill']['events'] != events:
        raise ValueError('Refill routing/arithmetic/default arguments mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest() != ENGINE_SHA:
        raise ValueError('Unexpected engine')
    rows, traces = [], []
    fixtures = [{'refill': fixture(argument=a), 'rate': 65} for a in (0, 1, 2, 255, 256, 257, 0xffffffff)]
    fixtures += [{'refill': fixture(guard=g, type_match=t, profile_present=p), 'eligible': e, 'rate': 37}
        for g in (False, True) for t in (False, True) for p in (False, True) for e in (False, True)]
    fixtures += [{'refill': fixture(profile_rate=r, guard=True, type_match=True), 'rate': 37, 'eligible': True}
        for r in (0, 1, 100, 135, -21, 0x7fffffff)]
    fixtures += [{'refill': fixture(), 'rate': r} for r in (0, 1, 99, 100, 101, 255, -21, 0x7fffffff)]
    fixtures += [{'refill': fixture(), 'rate': 37, 'query': q, 'mode_id': m, 'flag10': a, 'flag13': b}
        for q, m, a, b in ((True, 0, False, False), (True, 9, False, False), (False, 0, True, False), (False, 0, False, True))]
    fixtures += [{'refill': fixture(bank=b), 'rate': r} for b, r in (
        ([16777217, 1., -16777217, 1.], 100),
        ([-301, 1.25, -197, .75], 37),
        ([100, -.33333334, 200, 1.33333337], 65),
        ([2147483520, 1., -0x80000000, 1.], 1),
        ([0x7fffffff, .5, 16777217, .5], 255))]
    for poison in (False, True):
        for f in fixtures:
            row, trace = replay(source, **f, poison=poison)
            verify(row)
            rows.append(row)
            traces.append(trace)
    previous = json.loads(PREVIOUS.read_text(encoding='utf-8'))
    names = tuple(previous['tools_sha256']) + ('audit_dnf_chr_refill.py',)
    return {'schema': 'dnf_chr_refill/1', 'engine_sha256': ENGINE_SHA, 'input_source': source.source,
        'tools_sha256': {n: hashlib.sha256((ROOT / 'tools' / n).read_bytes().replace(b'\r\n', b'\n')).hexdigest() for n in names},
        'previous_evidence_sha256': hashlib.sha256(PREVIOUS.read_bytes().replace(b'\r\n', b'\n')).hexdigest(),
        'cases': rows, 'blocks': source_blocks(source, traces),
        'vtable': [{'offset': hex(o), 'target': hex(int.from_bytes(source.source_bytes(VTABLE + o, 4), 'little'))}
            for o in (0x514, 0x51c, 0x2a0, 0x2a8, 0x48, 0x91c)],
        'boundaries': [
            '855770 executes from full entry to return, including original byte-argument gate and nonzero refill branch.',
            'D07AF0 and D07A70 execute actual bank-3 protected reads, binary32 integer conversion/multiplication, truncation and return. Their RET preserves caller-pushed default arguments for the later setters.',
            '406920 executes actual actor+98 read. 82EB50 executes original eligibility dispatch and actor+5664/profile+1EE0 pointer read; its 842070 fallback remains an ABI fixture.',
            '812260 and 831620 are checked setter ABI fixtures. Requests are not proof of completed current-value writes, clamp rules, death handling or notification side effects.',
            '92F9B0 and 92E060 predicates have explicit fixture results. Their gameplay meanings are not inferred.',
            'Third refresh outputs are explicit fixture bank values, distinct from both the earlier snapshot and second-refresh output. Full refresh/reset implementation is still unproved.',
            'Arithmetic uses finite binary32 values and in-range CVTTSS2SI results; alternate MXCSR rounding, unmasked exceptions and invalid conversions are outside this audit. Subsequent signed 32-bit product wrap is covered.',
            'Protection read/write/local lifetime services, mode/scaler services and conditional callbacks retain the prior core audit fixture boundaries.',
            'Special HP rate comes from returned object+2D0. Object lifecycle and source configuration are unresolved; null object skips HP request after the MP request has already occurred.',
            'No source server recovery timer, death penalty, final HP/MP formula or local gameplay implementation is added.']}


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
    print('CHR_REFILL', len(result['cases']))


if __name__ == '__main__':
    main()

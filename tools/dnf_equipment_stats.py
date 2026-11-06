"""Verified ordinary EQU fields; alternate reinforcement grammar stays separate."""
import math
import struct


def separate_attack(values):
    """126F633: two signed integers (float tokens truncate after binary32 read).

    77BDD9 adds these to +87C/+888. 75EB80 chooses +888 in stable modes
    4/5 and +87C otherwise. They are NOT physical/magical channels.
    Four-value reinforcement records are outside this ordinary-field grammar.
    """
    if len(values)!=2:raise ValueError('separate_attack_grammar')
    out=[]
    for v in values:
        if type(v) not in (int,float) or not math.isfinite(v) or not -2147483648<=v<2147483648:
            raise ValueError('separate_attack_grammar')
        if type(v)==float:v=struct.unpack('<f',struct.pack('<f',v))[0]
        if not -2147483648<=v<2147483648:raise ValueError('separate_attack_grammar')
        out.append(math.trunc(v))
    return out


def apply_separate_attack(definition,values):
    normal,special=separate_attack(values)
    stats=definition.setdefault('stats',{});ranges=definition.setdefault('stat_ranges',{})
    for key in ('physical_independent_attack','magical_independent_attack'):
        stats.pop(key,None);ranges.pop(key,None)
    stats['independent_attack']=normal;ranges['independent_attack']=[normal,normal]
    # The game currently runs offline PVE. Retain the other native mode value
    # without applying it to magic attacks or pretending PVP is implemented.
    definition['native_separate_attack']={'default':normal,'modes_4_5':special}

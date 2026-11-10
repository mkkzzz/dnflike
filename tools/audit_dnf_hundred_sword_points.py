"""Replay the original Hundred Sword waypoint and field hit direction readers.

The readers run in the bounded Python interpreter with position and facing
getter fixtures. This replay does not create swords, simulate their motion,
or run the original client.
"""
import argparse
from pathlib import Path
from struct import unpack
import sys

from audit_dnf_ice_shatter import signed
from audit_dnf_firewave import extra_step

ENTRY = 0x24DE6DC
ORDER_TABLE = 0x16EBBD8
OWNER, OUT, VTABLE, GETTERS, SWORDS = range(0x60000000, 0x60500000, 0x100000)
STACK, RETURN = 0x70000000, 0xDEADBEEF
FIELD_VTABLE = 0x162CF04


def replay(source, ordinal, origin, positions, ground_slots=()):
    from dnf_native_vm_probe import CPU

    cpu = CPU(source)
    for address in range(STACK - 0x180, STACK + 0x30, 4):
        cpu.write(address, 4, 0)
    for index, value in enumerate((RETURN, OUT, OUT+4, OUT+8, ordinal)):
        cpu.write(STACK+index*4, 4, value)
    for index, value in enumerate(origin):
        cpu.write(OWNER+0x68AC+index*4, 4, value)
    sentinel = (181, -71, 29)
    for index, value in enumerate(sentinel):
        cpu.write(OUT+index*4, 4, value)
        cpu.write(VTABLE+0xA4+index*4, 4, GETTERS+index)
    for index, point in enumerate(positions):
        sword = SWORDS+0x400*index
        cpu.write(OWNER+0x68C4+index*4, 4, sword if point is not None else 0)
        if point is None:
            continue
        cpu.write(sword, 4, VTABLE)
        cpu.write(sword+0x224, 1, int(index in ground_slots))
        for axis, value in enumerate(point):
            cpu.write(sword+0x44+axis*4, 4, value)
    cpu.reg['ecx'] = OWNER
    cpu.pc = ENTRY
    for _ in range(12000):
        if cpu.pc == RETURN:
            return tuple(signed(cpu.read(OUT+axis*4, 4)) for axis in range(3))
        if GETTERS <= cpu.pc < GETTERS+3:
            axis = cpu.pc-GETTERS
            cpu.reg['eax'] = cpu.read(cpu.reg['ecx']+0x44+axis*4, 4)
            cpu.pc = cpu.pop()
            continue
        instruction = next(source.decoder.disasm(source.source_bytes(cpu.pc, 15), cpu.pc, count=1))
        if instruction.mnemonic == 'call':
            target = cpu.get(instruction, instruction.operands[0])
            cpu.push(cpu.pc+instruction.size)
            cpu.pc = target
            continue
        result = cpu.run(cpu.pc, 1)
        if result[0] == 'unsupported' and instruction.mnemonic in ('pushal', 'popal'):
            extra_step(cpu, {}, instruction)
            continue
        if result[0] != 'budget':
            raise ValueError(f'Waypoint probe stopped: {result}')
    raise ValueError('Waypoint instruction budget exhausted')


def replay_field_direction(source, origin_x, target_x, facing):
    from dnf_native_vm_probe import CPU

    cpu = CPU(source)
    for actor in (OWNER, SWORDS):
        cpu.write(actor, 4, FIELD_VTABLE)
    cpu.write(OWNER+0x3F0, 4, 4)  # ATK [inner]
    cpu.write(STACK, 4, RETURN)
    cpu.write(STACK+4, 4, SWORDS)
    cpu.reg.update(ecx=OWNER, esp=STACK)
    entry = cpu.read(FIELD_VTABLE+0x3E4, 4)
    if entry != 0x867370:
        raise ValueError('Unexpected Hundred Sword field hit direction entry')
    cpu.pc = entry
    for _ in range(100):
        if cpu.pc == RETURN:
            return cpu.reg['eax']
        if cpu.pc in (0x406480, 0x7EF760):
            x = origin_x if cpu.reg['ecx'] == OWNER else target_x
            cpu.reg['eax'] = (x & 0xFFFFFFFF) if cpu.pc == 0x406480 else facing
            cpu.pc = cpu.pop()
            continue
        instruction = next(source.decoder.disasm(source.source_bytes(cpu.pc, 15), cpu.pc, count=1))
        if instruction.mnemonic == 'call':
            target = cpu.get(instruction, instruction.operands[0])
            cpu.push(cpu.pc+instruction.size)
            cpu.pc = target
            continue
        result = cpu.run(cpu.pc, 1)
        if result[0] != 'budget':
            raise ValueError(f'Field direction probe stopped: {result}')
    raise ValueError('Field direction instruction budget exhausted')


def audit(source):
    from build_dnf_skill_runtime import (HUNDRED_SWORD_ORDER, HUNDRED_SWORD_POSES, HUNDRED_SWORD_STYLES,
                                         HUNDRED_SWORD_WEAPON_DRAW_ORDER)

    order = unpack('<24I', source.source_bytes(ORDER_TABLE, 96))
    if sorted(order) != list(range(24)) or list(order) != HUNDRED_SWORD_ORDER:
        raise ValueError('Unexpected sword slot order')
    if list(unpack('<24I', source.source_bytes(0x16EBB78, 96))) != HUNDRED_SWORD_STYLES:
        raise ValueError('Formation variant table differs from the original')
    if [pose+1 for pose in unpack('<6I', source.source_bytes(0x16EBC38, 24))] != HUNDRED_SWORD_POSES:
        raise ValueError('Travel pose table differs from the original')
    layer_counts = unpack('<6I', source.source_bytes(0x16EBC50, 24))
    layers = [unpack('<4i', source.source_bytes(0x16EBC68+style*16, 16))[:count]
              for style, count in enumerate(layer_counts) if count]
    if tuple(layers) != HUNDRED_SWORD_WEAPON_DRAW_ORDER:
        raise ValueError('Travel weapon layer order differs from the original')
    positions = [(263+i*17, 333-i*12, i*7-31) for i in range(24)]
    for ground_slots in ((), range(24)):
        for ordinal, slot in enumerate(order):
            x, y, z = positions[slot]
            expected = (x, y, z+(40 if ground_slots else 0))
            if replay(source, ordinal, (-405, 277), positions, ground_slots) != expected:
                raise ValueError(f'Wrong waypoint at {ordinal=} {slot=}')
    origin = (-405, 277)
    if replay(source, 24, origin, positions) != (*origin, 40):
        raise ValueError('Terminal waypoint must return to the saved cast XY')
    if replay(source, 0, origin, [None]*24) != (181, -71, 29):
        raise ValueError('Missing sword must leave output storage unchanged')
    for facing in (0, 1):
        for target_x in (-485, -405, -325):
            expected = facing if target_x == origin[0] else int(target_x > origin[0])
            if replay_field_direction(source, origin[0], target_x, facing) != expected:
                raise ValueError(f'Wrong field hit direction at {target_x=} {facing=}')
    return order


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('client', type=Path)
    parser.add_argument('--decoder-dir', type=Path)
    args = parser.parse_args()
    if args.decoder_dir:
        sys.path.insert(0, str(args.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator

    order = audit(AxisEvaluator(args.client.read_bytes()))
    print(f'[HUNDRED_SWORD] 50 waypoint cases verified. Sword slots: {order}')
    print('[HUNDRED_SWORD] 6 inward hit directions verified')


if __name__ == '__main__':
    main()

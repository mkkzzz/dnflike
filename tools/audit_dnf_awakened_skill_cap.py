"""Replay original awakening eligibility and protected skill cap reads."""
import argparse
import hashlib
import json
from pathlib import Path

from audit_dnf_ice_shatter import signed
from audit_dnf_native_strings import ENGINE_SHA
from audit_dnf_particle_axis import AxisEvaluator

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "game_dnf/data/skill_catalog.json"
CAP, FIT = 0x904AF0, 0x6D5E60
DESCRIPTOR, SECURE_READ = 0xD09590, 0x1195EB0
SWORDMAN_VTABLE = 0x16F972C
SKILL, CHARACTER, VECTOR = 0x60000000, 0x60100000, 0x60200000


def replay(source, entry, first, second, fitness, grow, stage):
    from dnf_native_vm_probe import CPU

    cpu = CPU(source)
    cpu.reg["ecx"] = SKILL if entry == CAP else VECTOR
    cpu.write(0x70000004, 4, grow if entry == CAP else SKILL)
    cpu.write(0x70000008, 4, stage if entry == CAP else CHARACTER)
    cpu.write(CHARACTER, 4, SWORDMAN_VTABLE)
    cpu.write(CHARACTER + 0x3C14, 4, grow)
    cpu.write(CHARACTER + 0x3C18, 4, stage)
    # For these source skills the first-growth fitness list is empty.
    for offset in (0x41C, 0x420, 0x2A0):
        cpu.write(SKILL + offset, 4, VECTOR)
    cpu.write(SKILL + 0x2A4, 4, VECTOR + 12 * len(fitness))
    secure = {SKILL + 0x134 + 12 * i: v for i, v in enumerate(first)}
    secure.update({SKILL + 0x20C + 12 * i: v for i, v in enumerate(second)})
    secure.update({VECTOR + 12 * i: v for i, v in enumerate(fitness)})
    cpu.pc = entry
    for _ in range(1500):
        if cpu.pc == SECURE_READ:
            address, stack = cpu.reg["ecx"], cpu.reg["esp"]
            if cpu.read(stack + 4, 4) != address + 8 or address not in secure:
                raise ValueError(f"Unexpected protected read {address:#x}")
            cpu.write(cpu.read(stack + 8, 4), 4, secure[address])
            cpu.pc = cpu.pop()
            cpu.reg["esp"] += 8
            continue
        stop = cpu.run(cpu.pc, 1)
        if stop[0] == "budget":
            continue
        if stop[0] == "returned":
            return cpu.reg["eax"]
        ins = next(source.decoder.disasm(source.source_bytes(cpu.pc, 15), cpu.pc, count=1))
        if stop[0] == "call" and int(stop[2], 16) in (SECURE_READ, 0x9043B0, DESCRIPTOR):
            cpu.push(cpu.pc + ins.size)
            cpu.pc = int(stop[2], 16)
            continue
        if ins.mnemonic == "imul" and len(ins.operands) == 1:
            product = signed(cpu.reg["eax"]) * signed(cpu.get(ins, ins.operands[0]))
            cpu.reg["eax"] = product & 0xFFFFFFFF
            cpu.reg["edx"] = (product >> 32) & 0xFFFFFFFF
            cpu.flags = (cpu.flags & ~0x801) | (0x801 if not -(1 << 31) <= product < 1 << 31 else 0)
            cpu.pc += ins.size
            continue
        raise ValueError(f"Unexpected replay stop {stop}")
    raise ValueError("Skill cap instruction budget exceeded")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client-exe", required=True, type=Path)
    args = parser.parse_args()
    source = AxisEvaluator(args.client_exe.read_bytes())
    if hashlib.sha256(source.raw).hexdigest() != ENGINE_SHA:
        raise ValueError("Unexpected original client image")
    rows = json.loads(CATALOG.read_text(encoding="utf-8"))["skills"]
    checks = 0
    for row in rows:
        if "second_growtype_max_level" not in row:
            continue
        first = row["growtype_max_level"]
        second = row["second_growtype_max_level"]
        fitness = row["fitness_second_growtype"]
        if row["fitness_growtype"] or any(first) or len(first) != 6 or len(second) != 12:
            raise ValueError(f"Unsupported first-growth data for skill {row['id']}")
        for grow in range(6):
            for stage in (0, 1, 2):
                fits = replay(source, FIT, first, second, fitness, grow, stage) & 0xFF
                expected = stage in fitness and stage > 0 and second[2 * grow + stage - 1] > 0
                if bool(fits) != expected:
                    raise ValueError(f"Skill {row['id']} eligibility differs for {grow}/{stage}")
                checks += 1
                if stage == 0:
                    continue
                cap = replay(source, CAP, first, second, fitness, grow, stage)
                if cap != second[2 * grow + stage - 1]:
                    raise ValueError(f"Skill {row['id']} cap differs for {grow}/{stage}")
                checks += 1
    first = [9, 0, 13, 0, 0, 0]
    for grow, expected in enumerate(first):
        for stage in (1, 2):
            cap = replay(source, CAP, first, list(range(21, 33)), [1, 2], grow, stage)
            if cap != expected:
                raise ValueError(f"First table did not take priority for {grow}/{stage}")
            checks += 1
    print(f"NATIVE AWAKENING CAPS checks={checks}")


if __name__ == "__main__":
    main()

"""Instruction-level adversarial checks; optional Capstone, no original client.

Run with --decoder-dir <optional dependency directory>. Literal x86 snippets
exercise flags, partial registers, stack widths and fail-closed boundaries.
"""
import argparse
from pathlib import Path
import sys
import unittest

parser = argparse.ArgumentParser(add_help=False)
parser.add_argument('--decoder-dir', type=Path)
parser.add_argument('--client', type=Path)
args, remaining = parser.parse_known_args()
if args.decoder_dir:
    sys.path.insert(0, str(args.decoder_dir.resolve()))
import capstone
from dnf_native_vm_probe import CPU


class Snippet:
    def __init__(self, code):
        self.raw = bytes.fromhex(code)+b'\x90'*32
        self.sections = [{'rva': 0x1000, 'offset': 0, 'bytes': len(self.raw), 'virtual_size': len(self.raw)}]
        self.decoder = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        self.decoder.detail = True

    def source_bytes(self, address, size):
        offset = address-0x401000
        if offset < 0 or offset+size > len(self.raw):
            raise ValueError('Unbacked snippet address')
        return self.raw[offset:offset+size]


class NativeVMProbe(unittest.TestCase):
    def run_code(self, code):
        cpu = CPU(Snippet(code))
        self.assertEqual(cpu.run(0x401000, 100), ('returned',))
        return cpu

    def test_wrapping_add_carry_and_zero_branch(self):
        # eax=-1; add eax,1; jnz failure; setc bl; ret
        cpu = self.run_code('b8ffffffff 83c001 7504 0f92c3 c3 cc')
        self.assertEqual(cpu.reg['eax'], 0)
        self.assertEqual(cpu.rr('bl'), 1)
        self.assertTrue(cpu.flags & 0x40)
        self.assertFalse(cpu.flags & 0x800)

    def test_signed_overflow_and_adc_borrow_boundaries(self):
        cpu = self.run_code('b8ffffff7f 83c001 0f90c3 c3')
        self.assertEqual((cpu.reg['eax'], cpu.rr('bl')), (0x80000000, 1))
        cpu = self.run_code('b8ffffffff 83c001 83d000 c3')
        self.assertEqual(cpu.reg['eax'], 1)
        cpu = self.run_code('31c0 83e801 83d800 c3')
        self.assertEqual(cpu.reg['eax'], 0xFFFFFFFE)

    def test_inc_dec_preserve_carry_and_not_preserves_flags(self):
        cpu = self.run_code('31c0 83e801 40 48 f7d0 c3')
        self.assertEqual(cpu.reg['eax'], 0)
        self.assertTrue(cpu.flags & 1)
        self.assertTrue(cpu.flags & 0x80)
        self.assertFalse(cpu.flags & 0x40)

    def test_partial_registers_and_operand_sized_stack(self):
        cpu = self.run_code('b878563412 66b8cdab b4ef 6650 665b c3')
        self.assertEqual(cpu.reg['eax'], 0x1234EFCD)
        self.assertEqual(cpu.reg['ebx'], 0xEFCD)
        self.assertEqual(cpu.reg['esp'], 0x70000004)

    def test_rotate_shift_and_arithmetic_sign_extension(self):
        cpu = self.run_code('b801000080 d1c8 d1f8 d1e0 c3')
        self.assertEqual(cpu.reg['eax'], 0xC0000000)
        cpu = self.run_code('b880000000 6698 98 99 c3')
        self.assertEqual((cpu.reg['eax'], cpu.reg['edx']), (0xFFFFFF80, 0xFFFFFFFF))
        cpu = self.run_code('b080 c0f809 c3')
        self.assertEqual(cpu.rr('al'), 0xFF)
        self.assertTrue(cpu.flags & 1)

    def test_return_immediate_adjusts_only_callee_arguments(self):
        cpu = self.run_code('c20800')
        self.assertEqual(cpu.reg['esp'], 0x7000000C)

    def test_budget_and_unsupported_os_or_cpu_operations_stop(self):
        cpu = CPU(Snippet('ebfe'))
        self.assertEqual(cpu.run(0x401000, 3), ('budget', '0x401000'))
        self.assertEqual(len(cpu.trace), 3)
        for code in ('cd80', '0fa2', '0f05'):
            cpu = CPU(Snippet(code))
            self.assertEqual(cpu.run(0x401000, 3)[0], 'unsupported')
        with self.assertRaises(ValueError):
            cpu.run(0x401000, 150001)

    def test_uninitialized_read_and_cross_boundary_write_rejected(self):
        cpu = CPU(Snippet('a100000040 c3'))
        with self.assertRaisesRegex(ValueError, 'uninitialized'):
            cpu.run(0x401000, 3)
        with self.assertRaisesRegex(ValueError, 'outside'):
            cpu.write(0x7000FFFF, 4, 0)
        with self.assertRaisesRegex(ValueError, 'width'):
            cpu.read(0x70000000, 1024)


@unittest.skipUnless(args.client, 'optional pinned client required for mutation replay')
class BindingMutation(unittest.TestCase):
    def test_modified_operand_changes_observed_store_and_is_rejected(self):
        from audit_dnf_particle_axis import AxisEvaluator
        from audit_dnf_ice_particle_bindings import trace_binding, audit
        source = AxisEvaluator(args.client.read_bytes())
        # Synthetic negative: replace only smoke's encoded destination with
        # the star global. The evaluator must follow the bytes, not a lookup.
        address, target = 0x215BE2D, 0x1A5F828
        value = ((target << 4) | (target >> 28)) & 0xFFFFFFFF
        value = ((value+1) & 0xFFFFFFFF) ^ 0x3C6AAEDE
        value = (~value & 0xFFFFFFFF) ^ 0x1F9BF630
        operand = (value+0x30201078+1-address) & 0xFFFFFFFF
        section = next(s for s in source.sections if 0 <= address+4-0x400000-s['rva'] < s['bytes'])
        offset = section['offset']+address+4-0x400000-section['rva']
        source.raw = source.raw[:offset]+operand.to_bytes(4, 'little')+source.raw[offset+4:]
        row, _, _ = trace_binding(source, 0x775C8D, 0x61500100, (0, 0, 0x202))
        self.assertEqual(row['write']['address'], '0x1a5f828')
        self.assertTrue(row['constructor']['filename'].endswith('IceWaveParticleSmoke.ptl'))
        with self.assertRaisesRegex(ValueError, 'Immediate mismatch'):
            audit(source)

    def test_unrecognized_image_is_rejected_before_interpretation(self):
        from audit_dnf_particle_axis import AxisEvaluator
        from audit_dnf_native_strings import engine_image
        raw, _ = engine_image(args.client.read_bytes())
        changed = raw[:-1]+bytes([raw[-1] ^ 1])
        with self.assertRaisesRegex(ValueError, 'verified native engine'):
            AxisEvaluator(changed)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]]+remaining)

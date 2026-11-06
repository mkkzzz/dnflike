"""Bounded, read-only arithmetic evaluation of native PTL axis function 0xE4F2C0.

Never loads/executes a PE, DLL, native call, or external process. Capstone only
decodes instructions. Integer/SSE operations are evaluated in Python; the two
known trigonometric calls use Python libm (not original x87 bit-exactness).
Unknown instructions/calls/addresses fail closed. Requires optional capstone.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys

from audit_dnf_client_code import pe_inventory
from audit_dnf_native_strings import engine_image, ENGINE_SHA

ENTRY, END, OBJECT, STACK, RETURN = 0xE4F2C0, 0xE4F833, 0x30000000, 0x70000000, 0xDEADBEEF
MASK = 0xFFFFFFFF


def signed(value, bits=32):
    value &= (1 << bits)-1
    return value-(1 << bits) if value & (1 << (bits-1)) else value


def bits(value, double=False):
    return int.from_bytes(struct.pack('<d' if double else '<f', value), 'little')


def real(value, double=False):
    size = 8 if double else 4
    return struct.unpack('<d' if double else '<f', (value & ((1 << (size*8))-1)).to_bytes(size, 'little'))[0]


class AxisEvaluator:
    def __init__(self, raw):
        import capstone
        from capstone.x86_const import X86_OP_REG, X86_OP_IMM, X86_OP_MEM
        self.types = X86_OP_REG, X86_OP_IMM, X86_OP_MEM
        self.raw, self.source = engine_image(raw)
        self.sections = pe_inventory(self.raw)['sections']
        self.decoder = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        self.decoder.detail = True

    def source_bytes(self, address, size):
        rva = address-0x400000
        for section in self.sections:
            relative = rva-section['rva']
            if 0 <= relative and relative+size <= section['bytes']:
                pos = section['offset']+relative
                return self.raw[pos:pos+size]
        raise ValueError(f'Unbacked source address {address:#x}')

    def read(self, address, size):
        if all(address+i in self.memory for i in range(size)):
            return int.from_bytes(bytes(self.memory[address+i] for i in range(size)), 'little')
        if 0x154E000 <= address and address+size <= 0x19CA000:
            return int.from_bytes(self.source_bytes(address, size), 'little')
        raise ValueError(f'Uninitialized evaluator memory {address:#x}/{size}')

    def write(self, address, size, value):
        if not (OBJECT <= address and address+size <= OBJECT+0x100 or
                STACK-0x1000 <= address and address+size <= STACK+0x20):
            raise ValueError(f'Write outside synthetic instance/stack: {address:#x}')
        for i, byte in enumerate((value & ((1 << (size*8))-1)).to_bytes(size, 'little')):
            self.memory[address+i] = byte

    def register(self, name):
        if name in ['ax', 'bx', 'cx', 'dx', 'si', 'di', 'bp', 'sp']:
            return self.registers['e'+name] & 0xFFFF
        return self.registers[name]

    def address(self, instruction, operand):
        mem = operand.mem
        if mem.segment:
            raise ValueError('Segment access outside axis contract')
        return (mem.disp + (self.register(instruction.reg_name(mem.base)) if mem.base else 0) +
                (self.register(instruction.reg_name(mem.index))*mem.scale if mem.index else 0)) & MASK

    def get(self, instruction, operand):
        reg, immediate, memory = self.types
        if operand.type == immediate:
            return operand.imm & MASK
        if operand.type == reg:
            return self.register(instruction.reg_name(operand.reg))
        if operand.type == memory:
            return self.read(self.address(instruction, operand), operand.size)
        raise ValueError('Unsupported operand')

    def put(self, instruction, operand, value):
        if operand.type == self.types[0]:
            name = instruction.reg_name(operand.reg)
            if name not in self.registers:
                raise ValueError('Partial register writes are not used by this function')
            self.registers[name] = value
        elif operand.type == self.types[2]:
            self.write(self.address(instruction, operand), operand.size, value)
        else:
            raise ValueError('Unsupported destination')

    def evaluate(self, case):
        self.memory = {OBJECT+i: 0 for i in range(0x100)}
        self.registers = {name: 0 for name in ['eax','ebx','ecx','edx','esi','edi','ebp','esp']}
        self.registers.update({f'xmm{i}': 0 for i in range(8)})
        self.registers.update(ecx=OBJECT, esp=STACK)
        self.write(STACK,4,RETURN)
        self.write(STACK+4,4,0)  # evaluate X; Y/Z use the same indexed code
        for offset, size, value in [(0x10,2,case['move']), (0x16,4,case['v1'][0]),
                                   (0x1A,4,case['v1'][1]), (0x2E,4,case['v2'][0]),
                                   (0x32,4,case['v2'][1]), (0x46,4,case['term']),
                                   (0x4A,2,case['change']), (0x94,4,case['time'])]:
            self.write(OBJECT+offset,size,value)
        fpu, trace, branches = [], [], []
        zero = negative = less = False
        pc = ENTRY
        for _ in range(1000):
            if not ENTRY <= pc < END:
                raise ValueError(f'Control escaped axis function: {pc:#x}')
            ins = next(self.decoder.disasm(self.source_bytes(pc,15),pc,count=1))
            trace.append(f'{pc:08X} {ins.mnemonic} {ins.op_str}')
            name, args, next_pc = ins.mnemonic, ins.operands, pc+ins.size
            get = lambda operand: self.get(ins,operand)
            put = lambda operand, value: self.put(ins,operand,value)
            if name in ['mov','movzx','movd','movss','movsd','movaps']:
                put(args[0],get(args[1]))
            elif name == 'push':
                value = get(args[0]);self.registers['esp'] -= 4
                self.write(self.registers['esp'],4,value)
            elif name == 'pop':
                put(args[0],self.read(self.registers['esp'],4));self.registers['esp'] += 4
            elif name in ['add','sub','xor','and','or','xorps']:
                a,b = map(get,args)
                value = {'add':lambda:a+b,'sub':lambda:a-b,'xor':lambda:a^b,
                         'and':lambda:a&b,'or':lambda:a|b,'xorps':lambda:a^b}[name]() & MASK
                put(args[0],value)
                if name != 'xorps':zero,negative,less = value==0,signed(value)<0,signed(value)<0
            elif name in ['inc','dec']:
                value = (get(args[0])+(1 if name=='inc' else -1)) & MASK
                put(args[0],value);zero,negative,less = value==0,signed(value)<0,signed(value)<0
            elif name in ['cmp','test']:
                a,b = map(get,args)
                mask = (1 << (args[0].size*8))-1
                value = ((a-b) if name=='cmp' else (a&b)) & mask
                zero,negative = value==0,signed(value,args[0].size*8)<0
                less = signed(a,args[0].size*8)<signed(b,args[0].size*8)
            elif name == 'imul' and len(args)==2:
                put(args[0],(signed(get(args[0]))*signed(get(args[1]))) & MASK)
            elif name == 'cdq':
                self.registers['edx'] = MASK if signed(self.registers['eax'])<0 else 0
            elif name == 'idiv':
                numerator = signed((self.registers['edx'] << 32)|self.registers['eax'],64)
                denominator = signed(get(args[0]))
                quotient = abs(numerator)//abs(denominator)
                if (numerator<0)!=(denominator<0):quotient = -quotient
                if not -(1<<31) <= quotient < (1<<31):raise ValueError('IDIV overflow')
                self.registers['eax'] = quotient & MASK
                self.registers['edx'] = (numerator-quotient*denominator) & MASK
            elif name in ['cvtsi2ss','cvtdq2ps']:
                put(args[0],bits(float(signed(get(args[1])))))
            elif name in ['cvtps2pd','cvtss2sd']:
                put(args[0],bits(real(get(args[1])),True))
            elif name in ['cvtpd2ps','cvtsd2ss']:
                put(args[0],bits(real(get(args[1]),True)))
            elif name in ['addss','subss','mulss','divss','addsd','subsd','mulsd','divsd']:
                double = name.endswith('sd')
                a,b = [real(get(v),double) for v in args]
                value = {'add':lambda:a+b,'sub':lambda:a-b,'mul':lambda:a*b,'div':lambda:a/b}[name[:3]]()
                put(args[0],bits(value,double))
            elif name == 'fld':
                fpu.append(real(get(args[0])))
            elif name == 'fmul':
                fpu[-1] *= real(get(args[0]))
            elif name == 'fstp':
                put(args[0],bits(fpu.pop()))
            elif name == 'call':
                target = get(args[0])
                if target not in [0x11F0FF0,0x11F1060]:raise ValueError(f'Unapproved call {target:#x}')
                angle = real(self.read(self.registers['esp'],8),True)
                fpu.append(math.sin(angle) if target==0x11F0FF0 else math.cos(angle))
            elif name == 'jmp':next_pc = get(args[0])
            elif name.startswith('j'):
                conditions = {'je':zero,'jne':not zero,'jns':not negative,'jge':not less,'jle':less or zero}
                if name not in conditions:raise ValueError('Unsupported condition '+name)
                taken = conditions[name];branches.append([hex(pc),taken])
                if taken:next_pc = get(args[0])
            elif name == 'ret':
                if self.read(self.registers['esp'],4)!=RETURN or len(fpu)!=1:
                    raise ValueError('Return contract mismatch')
                return {'value':real(bits(fpu[0])), 'bits':f'{bits(fpu[0]):08x}',
                        'steps':len(trace),'branches':branches,
                        'trace_sha256':hashlib.sha256('\n'.join(trace).encode()).hexdigest()}
            else:raise ValueError('Unsupported instruction: '+trace[-1])
            pc = next_pc
        raise ValueError('Axis instruction budget exceeded')


def cases():
    # Include boundaries, both ping-pong legs, zero term, negative velocities,
    # nontrivial float32 values, and the native term-zero IMUL overflow branch.
    result = []
    for move in range(4):
        for change in range(3):
            for term in [0,1000]:
                for time in [0,1,250,999,1000,1001,1500,2000,2250,3000]:
                    result.append({'move':move,'change':change,'term':term,'time':time,
                                   'v1':[13,-7],'v2':[800,1300]})
    result.append({'move':1,'change':0,'term':0,'time':100000,'v1':[50000,0],'v2':[0,0]})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('client',type=Path)
    parser.add_argument('--decoder-dir',type=Path,help='Optional directory containing capstone')
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
    evaluator = AxisEvaluator(args.client.read_bytes())
    rows = [{'input':case,**evaluator.evaluate(case)} for case in cases()]
    output = {'schema':'dnf_native_particle_axis/1','engine_sha256':ENGINE_SHA,
              'function':'0xE4F2C0','function_sha256':hashlib.sha256(evaluator.source_bytes(ENTRY,END-ENTRY)).hexdigest(),
              'evaluator_sha256':hashlib.sha256(Path(__file__).read_bytes().replace(b'\r\n',b'\n')).hexdigest(),
              'method':'bounded Python instruction arithmetic; native code not executed; trig calls use Python libm',
              'cases':rows}
    header = json.dumps({k:v for k,v in output.items() if k!='cases'},indent=1)[:-2]
    lines = [header+',',' "cases": [']
    lines.extend('  '+json.dumps(row,separators=(',',':'))+(',' if i+1<len(rows) else '') for i,row in enumerate(rows))
    lines.extend([' ]','}'])
    args.output.write_text('\n'.join(lines)+'\n',encoding='utf8',newline='\n')
    print(f'[PARTICLE_AXIS] Evaluated {len(rows)} cases from verified native bytes')


if __name__ == '__main__':
    main()

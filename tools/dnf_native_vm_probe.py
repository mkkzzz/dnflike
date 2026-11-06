"""Bounded Python-only integer instruction probe; no native execution/OS calls.
Synthetic registers/TEB/stack, source image read as data. Unknown operations,
unmapped memory and external calls stop the probe. Not a full client emulator.
"""
from audit_dnf_native_strings import recover_string
from capstone.x86_const import X86_OP_REG, X86_OP_IMM, X86_OP_MEM

class CPU:

    def __init__(self, source):
        self.source = source
        self.cs = source.decoder
        self.reg = {x: 0 for x in ['eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'ebp']}
        self.reg.update(esp=0x70000000, ecx=0x60000000)
        self.flags = 0x202
        self.memory = {}
        self.trace = []
        self.events = []
        self.pc = 0
        self.write(0x50000018, 4, 0x50000000)
        self.write(0x50000008, 4, 0x6ff00000)
        self.write(0x50000000, 4, 0xffffffff)
        self.write(0x70000000, 4, 0xdeadbeef)
        self.write(0x70000004, 4, 0)
        self.write(0x70000008, 4, 0)
        self.alloc = 0x61000000
        self.strings = {}
        # Optional caller-saved register/flag poison, supplied by the audit.
        self.string_clobber = None
        self.branches = []

    def image_span(self, a, n):
        return any((0 <= a - 0x400000 - s['rva'] and a - 0x400000 - s['rva'] + n <= s['virtual_size'] for s in self.source.sections))

    def source_byte(self, a):
        for s in self.source.sections:
            offset = a - 0x400000 - s['rva']
            if 0 <= offset < s['virtual_size']:
                return self.source.raw[s['offset'] + offset] if offset < s['bytes'] else 0
        raise ValueError(f'uninitialized memory {a:#x}')

    def base(self, name):
        if name in self.reg:
            return (name, 32, 0)
        if name in ['ax', 'bx', 'cx', 'dx', 'si', 'di', 'bp', 'sp']:
            return ('e' + name, 16, 0)
        if name in ['al', 'bl', 'cl', 'dl', 'ah', 'bh', 'ch', 'dh']:
            return ('e' + name[0] + 'x', 8, 8 if name[1] == 'h' else 0)
        raise ValueError('unknown register ' + name)

    def rr(self, name):
        b, n, s = self.base(name)
        return self.reg[b] >> s & (1 << n) - 1

    def rw(self, name, v):
        b, n, s = self.base(name)
        m = (1 << n) - 1 << s
        self.reg[b] = (self.reg[b] & ~m | v << s & m) & 0xffffffff

    def read(self, a, n):
        if n not in (1, 2, 4, 8):
            raise ValueError('Unsupported memory width')
        a &= 0xffffffff
        out = []
        for x in range(a, a + n):
            if x in self.memory:
                out.append(self.memory[x])
                continue
            out.append(self.source_byte(x))
        return int.from_bytes(bytes(out), 'little')

    def write(self, a, n, v):
        if n not in (1, 2, 4, 8):
            raise ValueError('Unsupported memory width')
        a &= 0xffffffff
        if not (self.image_span(a, n) or (0x50000000 <= a and a + n <= 0x50010000) or (0x60000000 <= a and a + n <= 0x62000000) or (0x6ff00000 <= a and a + n <= 0x70010000)):
            raise ValueError(f'write outside synthetic/image memory {a:#x}')
        for j, b in enumerate((v & (1 << n * 8) - 1).to_bytes(n, 'little')):
            self.memory[a + j] = b
        if n == 4 and 0x15b3f00 <= v < 0x15b6500:
            self.events.append(('resource_pointer', hex(self.pc), hex(a), hex(v), hex(self.reg['esi'])))
        if 0x19ca000 <= a < 0x1f00000:
            self.events.append(('global_write', hex(self.pc), hex(a), n, hex(v)))

    def addr(self, i, o):
        m = o.mem
        a = m.disp
        if m.base:
            a += self.rr(i.reg_name(m.base))
        if m.index:
            a += self.rr(i.reg_name(m.index)) * m.scale
        if m.segment:
            seg = i.reg_name(m.segment)
            if seg == 'fs':
                a += 0x50000000
            elif seg not in ['ss', 'ds', 'es']:
                raise ValueError('segment ' + seg)
        return a & 0xffffffff

    def get(self, i, o):
        if o.type == X86_OP_IMM:
            return o.imm & (1 << o.size * 8) - 1
        if o.type == X86_OP_REG:
            return self.rr(i.reg_name(o.reg))
        if o.type == X86_OP_MEM:
            return self.read(self.addr(i, o), o.size)
        raise ValueError('operand')

    def put(self, i, o, v):
        if o.type == X86_OP_REG:
            self.rw(i.reg_name(o.reg), v)
        elif o.type == X86_OP_MEM:
            self.write(self.addr(i, o), o.size, v)
        else:
            raise ValueError('destination')

    def push(self, value, n=4):
        self.reg['esp'] -= n
        self.write(self.reg['esp'], n, value)

    def pop(self, n=4):
        v = self.read(self.reg['esp'], n)
        self.reg['esp'] += n
        return v

    def flag(self, bit, value):
        self.flags = self.flags & ~(1 << bit) | int(value) << bit

    def arith(self, kind, a, b, n, carry=0):
        """32/16/8-bit integer flags; no floating point or undefined-flag claims."""
        mask = (1 << n) - 1
        sign = 1 << n - 1
        if kind == 'add':
            raw = a + b + carry
            cf = raw > mask
            of = ~(a ^ b) & (a ^ raw) & sign != 0
        elif kind == 'sub':
            raw = a - b - carry
            cf = a < b + carry
            of = (a ^ b) & (a ^ raw) & sign != 0
        else:
            raw = {'and': lambda: a & b, 'or': lambda: a | b, 'xor': lambda: a ^ b}[kind]()
            cf = of = False
        v = raw & mask
        self.flag(0, cf)
        self.flag(11, of)
        self.flag(6, v == 0)
        self.flag(7, bool(v & sign))
        self.flag(2, (v & 255).bit_count() % 2 == 0)
        self.flag(4, bool((a ^ b ^ v) & 16))
        return v

    def condition(self, k):
        cf = bool(self.flags & 1)
        pf = bool(self.flags & 4)
        zf = bool(self.flags & 64)
        sf = bool(self.flags & 128)
        of = bool(self.flags & 2048)
        return {'e': zf, 'z': zf, 'ne': not zf, 'nz': not zf, 'b': cf, 'c': cf, 'ae': not cf, 'nc': not cf, 'be': cf or zf, 'a': not cf and (not zf), 'l': sf != of, 'ge': sf == of, 'le': zf or sf != of, 'g': not zf and sf == of, 's': sf, 'ns': not sf, 'o': of, 'no': not of, 'p': pf, 'np': not pf}[k]

    def string(self, address):
        raw = bytes((self.read(address + x, 1) for x in range(1024)))
        text, _ = recover_string(raw, 0, 2)
        return text

    def run(self, start, limit=150000):
        if not 0 < limit <= 150000:
            raise ValueError('Instruction budget must be 1..150000')
        self.pc = start
        for _ in range(limit):
            if self.pc == 0xdeadbeef:
                return ('returned',)
            if self.pc in [0x1194fc0, 0x57d990, 0x5fef30, 0x11a5990]:
                args = [self.read(self.reg['esp'] + 4 + x * 4, 4) for x in range(2)]
                if self.pc == 0x1194fc0:
                    text = self.string(args[0])
                    self.events.append(('string', hex(args[0]), text))
                    address = self.alloc
                    self.alloc += max(256, len(text) * 2 + 2)
                    for j, b in enumerate((text + '\x00').encode('utf-16le')):
                        self.write(address + j, 1, b)
                    self.strings[address] = text
                    self.rw('eax', address)
                    if self.string_clobber is not None:
                        self.reg['ecx'], self.reg['edx'], self.flags = self.string_clobber
                    self.pc = self.pop()
                    continue
                return ('native_entry', hex(self.pc), args)
            i = next(self.cs.disasm(self.source.source_bytes(self.pc, 15), self.pc, count=1), None)
            if self.pc == 0x7b4217:
                self.events.append(('vm_immediate', hex(self.reg['esi']), hex(self.reg['eax'])))
            if not i:
                return ('decode', hex(self.pc))
            self.trace.append(f'{i.address:08X} {i.mnemonic} {i.op_str}')
            k = i.mnemonic
            args = i.operands
            pc = i.address + i.size
            get = lambda o: self.get(i, o)
            put = lambda o, v: self.put(i, o, v)
            if k in ['mov', 'movzx', 'movsx']:
                v = get(args[1])
                bits = args[1].size * 8
                if k == 'movsx' and v & 1 << bits - 1:
                    v -= 1 << bits
                put(args[0], v)
            elif k == 'lea':
                put(args[0], self.addr(i, args[1]))
            elif k == 'push':
                self.push(get(args[0]), args[0].size)
            elif k == 'pop':
                v = self.pop(args[0].size)
                put(args[0], v)
            elif k == 'pushfd':
                self.push(self.flags)
            elif k == 'popfd':
                self.flags = self.pop()
            elif k == 'xchg':
                a, b = map(get, args)
                put(args[0], b)
                put(args[1], a)
            elif k in ['add', 'sub', 'adc', 'sbb', 'xor', 'and', 'or', 'cmp', 'test']:
                a, b = map(get, args)
                name = {'cmp': 'sub', 'test': 'and', 'adc': 'add', 'sbb': 'sub'}.get(k, k)
                v = self.arith(name, a, b, args[0].size * 8, self.flags & 1 if k in ['adc', 'sbb'] else 0)
                if k not in ['cmp', 'test']:
                    put(args[0], v)
            elif k in ['inc', 'dec', 'neg', 'not']:
                a = get(args[0])
                n = args[0].size * 8
                cf = self.flags & 1
                if k == 'not':
                    put(args[0], ~a)
                else:
                    v = self.arith('sub' if k in ['dec', 'neg'] else 'add', 0 if k == 'neg' else a, a if k == 'neg' else 1, n)
                    put(args[0], v)
                    if k != 'neg':
                        self.flag(0, cf)
            elif k in ['rol', 'ror', 'shl', 'shr', 'sar']:
                a, b = map(get, args)
                n = args[0].size * 8
                mask = (1 << n) - 1
                b &= 31
                if k in ['rol', 'ror']:
                    b %= n
                if b:
                    if k == 'rol':
                        v = (a << b | a >> n - b) & mask
                        cf = v & 1
                        of = (v >> n - 1 ^ cf) & 1
                    elif k == 'ror':
                        v = (a >> b | a << n - b) & mask
                        cf = v >> n - 1
                        of = (v >> n - 1 ^ v >> n - 2) & 1
                    else:
                        if k == 'shl':
                            v = a << b & mask
                            cf = a >> n - b & 1 if b <= n else 0
                            of = (v >> n - 1 ^ cf) & 1
                        else:
                            signed = a - (1 << n) if k == 'sar' and a & 1 << n - 1 else a
                            v = signed >> b & mask
                            cf = signed >> b - 1 & 1
                            of = a >> n - 1 if k == 'shr' else 0
                        self.flag(6, v == 0)
                        self.flag(7, bool(v & 1 << n - 1))
                        self.flag(2, (v & 255).bit_count() % 2 == 0)
                    put(args[0], v)
                    self.flag(0, cf)
                    if b == 1:
                        self.flag(11, of)
            elif k.startswith('set'):
                put(args[0], int(self.condition(k[3:])))
            elif k.startswith('j'):
                taken = k == 'jmp' or self.condition(k[1:])
                if k != 'jmp':
                    self.branches.append((hex(self.pc), taken))
                if taken:
                    pc = get(args[0])
            elif k == 'call':
                target = get(args[0])
                head = next(self.cs.disasm(self.source.source_bytes(target, 15), target, count=1), None)
                if head is None:
                    return ('decode_call', hex(target))
                if target < 0x2000000 and target not in [0x1194fc0, 0x57d990, 0x5fef30, 0x11a5990] and (not (head.mnemonic == 'lea' and head.op_str == 'esp, [esp + 4]')):
                    return ('call', hex(self.pc), hex(target), [self.read(self.reg['esp'] + x * 4, 4) for x in range(2)])
                self.push(pc)
                pc = target
            elif k == 'ret':
                pc = self.pop()
                self.reg['esp'] += get(args[0]) if args else 0
            elif k.startswith('lods'):
                size = {'lodsd': 4, 'lodsw': 2, 'lodsb': 1}[k]
                self.rw({4: 'eax', 2: 'ax', 1: 'al'}[size], self.read(self.reg['esi'], size))
                self.reg['esi'] += -size if self.flags & 1024 else size
            elif k == 'rep movsb':
                if self.reg['ecx'] > 65536:
                    raise ValueError('rep copy exceeds bound')
                while self.reg['ecx']:
                    self.write(self.reg['edi'], 1, self.read(self.reg['esi'], 1))
                    delta = -1 if self.flags & 1024 else 1
                    self.reg['edi'] += delta
                    self.reg['esi'] += delta
                    self.reg['ecx'] -= 1
            elif k == 'cwde':
                v = self.rr('ax')
                self.rw('eax', v - 65536 if v & 32768 else v)
            elif k == 'cbw':
                v = self.rr('al')
                self.rw('ax', v - 256 if v & 128 else v)
            elif k == 'cdq':
                self.rw('edx', 0xffffffff if self.rr('eax') & 0x80000000 else 0)
            elif k == 'nop':
                pass
            else:
                return ('unsupported', self.trace[-1])
            self.pc = pc & 0xffffffff
        return ('budget', hex(self.pc))

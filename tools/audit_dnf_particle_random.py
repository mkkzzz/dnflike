"""Read-only instruction arithmetic for native random function 0xE47F50.

Uses synthetic seed/stack memory. The sole timeGetTime import is supplied by
the fixture clock; no client code or OS import is executed. Unknown opcodes,
calls, memory writes and control flow fail closed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from audit_dnf_particle_axis import AxisEvaluator, MASK, STACK, OBJECT, RETURN
from audit_dnf_native_strings import ENGINE_SHA

ENTRY, END, GLOBAL = 0xE47F50, 0xE47FBC, 0x1A2A170


class RandomEvaluator(AxisEvaluator):
    def write(self, address, size, value):
        if address==GLOBAL and size==4:
            for i,byte in enumerate((value & MASK).to_bytes(4,'little')):self.memory[address+i]=byte
        else:super().write(address,size,value)

    def evaluate(self, seed, clock, global_form):
        self.memory = {}
        self.registers = {name:0 for name in ['eax','ebx','ecx','edx','esi','edi','ebp','esp']}
        self.registers['esp'] = STACK
        self.write(STACK,4,RETURN)
        self.write(STACK+4,4,0 if global_form else OBJECT)
        self.write(GLOBAL if global_form else OBJECT,4,seed)
        pc, zero, trace = ENTRY, False, []
        for _ in range(100):
            if not ENTRY<=pc<END:raise ValueError('Control escaped random function')
            ins = next(self.decoder.disasm(self.source_bytes(pc,15),pc,count=1))
            trace.append(f'{pc:08X} {ins.mnemonic} {ins.op_str}')
            name,args,next_pc = ins.mnemonic,ins.operands,pc+ins.size
            get = lambda operand:self.get(ins,operand)
            put = lambda operand,value:self.put(ins,operand,value)
            if name=='mov':put(args[0],get(args[1]))
            elif name=='push':
                value=get(args[0]);self.registers['esp']-=4;self.write(self.registers['esp'],4,value)
            elif name=='pop':
                put(args[0],self.read(self.registers['esp'],4));self.registers['esp']+=4
            elif name in ['add','and','xor','shl','shr']:
                a,b=map(get,args)
                value={'add':lambda:a+b,'and':lambda:a&b,'xor':lambda:a^b,
                       'shl':lambda:a<<(b&31),'shr':lambda:a>>(b&31)}[name]() & MASK
                put(args[0],value);zero=value==0
            elif name=='imul' and len(args)==3:put(args[0],(get(args[1])*get(args[2])) & MASK)
            elif name=='test':zero=(get(args[0])&get(args[1]))==0
            elif name=='jne':
                if not zero:next_pc=get(args[0])
            elif name=='call':
                if args[0].type!=self.types[2] or self.address(ins,args[0])!=0x154E588:
                    raise ValueError('Unapproved random-function call')
                self.registers['eax']=clock & MASK
            elif name=='ret':
                if self.read(self.registers['esp'],4)!=RETURN:raise ValueError('Return contract mismatch')
                return {'value':self.registers['eax'],'state':self.read(GLOBAL if global_form else OBJECT,4),
                        'steps':len(trace),'trace_sha256':hashlib.sha256('\n'.join(trace).encode()).hexdigest()}
            else:raise ValueError('Unsupported instruction: '+trace[-1])
            pc=next_pc
        raise ValueError('Random instruction budget exceeded')


def main():
    parser=argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('client',type=Path)
    parser.add_argument('--decoder-dir',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.decoder_dir:sys.path.insert(0,str(args.decoder_dir.resolve()))
    evaluator=RandomEvaluator(args.client.read_bytes())
    rows=[]
    for global_form in [False,True]:
        for initial in [0,1,0x7fffffff,0xffffffff,0x12345678]:
            seed=initial
            for clock in [0,1,1000,0xffffffff,42]:
                result=evaluator.evaluate(seed,clock,global_form)
                rows.append({'seed':seed,'clock':clock,'global_form':global_form,**result})
                seed=result['state']
    dependencies=['audit_dnf_particle_random.py','audit_dnf_particle_axis.py']
    output={'schema':'dnf_native_particle_random/1','engine_sha256':ENGINE_SHA,'function':hex(ENTRY),
            'function_sha256':hashlib.sha256(evaluator.source_bytes(ENTRY,END-ENTRY)).hexdigest(),
            'evaluator_sha256':hashlib.sha256(b''.join(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n') for n in dependencies)).hexdigest(),
            'method':'bounded Python instruction arithmetic; timeGetTime supplied by fixture; native code not executed'}
    lines=[json.dumps(output,indent=1)[:-2]+',',' "cases": [']
    lines.extend('  '+json.dumps(row,separators=(',',':'))+(',' if i+1<len(rows) else '') for i,row in enumerate(rows))
    lines.extend([' ]','}'])
    args.output.write_text('\n'.join(lines)+'\n',encoding='utf8',newline='\n')
    print(f'[PARTICLE_RANDOM] Evaluated {len(rows)} cases from verified native instructions')


if __name__=='__main__':main()

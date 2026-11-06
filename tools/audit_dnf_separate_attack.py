"""Native ordinary EQU reader -> integer stat accumulation, bounded fragments.

126DABD runtime guard/126F633 body and 77BDD9..77BE75 execute original
instructions. Prepared outer frames and secure storage/lexer are ABI fixtures.
The independently verified 75EB80 mode consumer is replayed with these outputs.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
from audit_dnf_firewave import extra_step
from audit_dnf_ice_shatter import fbits,real,signed
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
from audit_dnf_native_strings import ENGINE_SHA,recover_string
from dnf_equipment_stats import separate_attack

SRC,DST,FRAME=0x60000000,0x60100000,0x6FFFFE00


def replay(source,values,*,initial=(7,19),poison=False):
    separate_attack(values)
    from dnf_native_vm_probe import CPU
    c=CPU(source)
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.write(0x1D8B554,1,1);c.write(0x1D94A4C,4,1)
    secure={DST+0x87C:initial[0]&0xFFFFFFFF,DST+0x888:initial[1]&0xFFFFFFFF}
    c.reg.update(ebp=FRAME,esp=FRAME-0x200,esi=SRC,edi=DST)
    cursor=0;current=None;fp=[];xmm={f'xmm{j}':0 for j in range(8)};phases=[]
    def run(start,end):
        nonlocal cursor,current
        c.pc=start
        for _ in range(4000):
            if c.pc==end:phases.append({'start':hex(start),'end':hex(end),'stack':hex(c.reg['esp'])});return
            if c.pc in (0x1195A10,0x1195EB0,0x119A6F0,0x119A800,0x119A860):
                target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4);result=pop=0
                if target in (0x1195A10,0x1195EB0):
                    key=arg(1) if target==0x1195A10 else arg(0)
                    if key!=this+8:raise ValueError('Wrong secure key')
                    if target==0x1195A10:secure[this]=c.read(arg(0),4)
                    else:c.write(arg(1),4,secure[this])
                    pop=8
                elif target==0x119A6F0:
                    if cursor>=len(values):raise ValueError('Unexpected read beyond field')
                    current=values[cursor];cursor+=1;result=2 if type(current)==int else 4
                elif target==0x119A800:
                    if type(current)!=int:raise ValueError('Wrong integer getter')
                    result=current&0xFFFFFFFF
                else:
                    if type(current)!=float:raise ValueError('Wrong floating getter')
                    fp.append(real(fbits(current)))
                c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
                c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
                for k in xmm:xmm[k]=0x0123456789ABCDEF if poison else 0
                continue
            stop=c.run(c.pc,1)
            if stop[0]=='budget':continue
            i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
            if stop[0]=='call':
                target=int(stop[2],16)
                if target not in (0x1218A80,0x4041C0,0x1195A10,0x1195EB0,0x119A6F0,0x119A800,0x119A860,0x13CD690):raise ValueError(f'Unknown call {target:#x}')
                c.push(c.pc+i.size);c.pc=target;continue
            if stop[0]!='unsupported':raise ValueError(f'Unknown stop {stop}')
            if i.mnemonic=='leave':c.reg['esp']=c.reg['ebp'];c.reg['ebp']=c.pop()
            elif i.mnemonic=='fstp' and i.operands[0].size in (4,8):
                v=fp.pop();op=i.operands[0];c.put(i,op,fbits(v) if op.size==4 else int.from_bytes(struct.pack('<d',v),'little'))
            elif i.mnemonic=='cvttsd2si':
                v=struct.unpack('<d',c.get(i,i.operands[1]).to_bytes(8,'little'))[0];c.put(i,i.operands[0],math.trunc(v))
            else:extra_step(c,xmm,i);continue
            c.pc+=i.size
        raise ValueError('Instruction budget')
    run(0x126DABD,0x126F227)
    parsed=[signed(secure[SRC+off]) for off in (0x948,0x954)]
    run(0x77BDD9,0x77BE75)
    row={'fixture':{'values':values,'initial':list(initial),'poison':poison},'parsed':parsed,
         'accumulated':[signed(secure[DST+off]) for off in (0x87C,0x888)],'phases':phases,'cursor':cursor,
         'frame_preserved':c.reg['ebp']==FRAME and c.reg['esi']==SRC and c.reg['edi']==DST,
         'fp_depth':len(fp),'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)}
    return row,c.trace


def verify(row):
    f=row['fixture'];parsed=separate_attack(f['values'])
    if row['parsed']!=parsed or row['accumulated']!=[signed((a+b)&0xFFFFFFFF) for a,b in zip(f['initial'],parsed)]:raise ValueError('Separate attack field mapping mismatch')
    if row['cursor']!=2 or row['fp_depth'] or not row['frame_preserved'] or any(p['stack']!=hex(FRAME-0x200) for p in row['phases']):raise ValueError('Fragment ABI mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    cases=[([26,14],[0,0]),([31,18],[7,19]),([400,264],[0,0]),([64,39],[0,0]),
           ([-5,0],[7,19]),([2147483647,-2147483648],[1,-1]),([3.9,-2.9],[7,19]),([0,0],[0,0])]
    runs=[];traces=[];consumers=[]
    from audit_dnf_fixed_base import replay as consume,verify as verify_consumer
    for values,initial in cases:
        for poison in (False,True):
            row,trace=replay(source,values,initial=initial,poison=poison);verify(row);runs.append(row);traces.append(trace)
        if values in ([26,14],[400,264],[64,39]):
            for mode in (1,3,4,5,7,9):
                # Existing consumer fixture encodes distinct info-kind offsets;
                # cancel them explicitly to feed the parsed accumulator values.
                a,b=row['accumulated']
                result,trace=consume(source,mode=mode,table_mode=1,info_kind=3,add_normal=a-3,add_special=b-3,
                                     mul_normal=1,mul_special=1-3/8,final_add=-3,poison=True)
                verify_consumer(result);traces.append(trace);consumers.append({'values':values,'accumulated':[a,b],'run':result})
    provenance=[]
    for start,end in ((0x126DABD,0x126DAFF),(0x126DAFF,0x126DB41),(0x127157D,0x12715CB)):
        raw=source.source_bytes(start,end-start)
        provenance.append({'start':hex(start),'sha256':hashlib.sha256(raw).hexdigest(),
            'instructions':[f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in source.decoder.disasm(raw,start)]})
    names=('audit_dnf_separate_attack.py','dnf_equipment_stats.py','audit_dnf_fixed_base.py','audit_dnf_firewave.py',
           'audit_dnf_ice_shatter.py','audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    return {'schema':'dnf_separate_attack/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
            'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
            'tags':{hex(va):recover_string(source.source_bytes(va,8192),0,2)[0] for va in (0x185CDAC,0x18627B4)},
            'runs':runs,'consumers':consumers,'blocks':source_blocks(source,traces),'static_provenance':provenance,
            'boundaries':['Prepared parser/accumulator frames; full outer equipment parser and full 77AA90 stat aggregation are excluded.',
                'Secure storage and token stream are ABI fixtures; original integer reader/writer and accumulation instructions execute.',
                'Separate 75EB80 replays use emitted accumulators, synthetic base tables and neutral multipliers; not one complete character lifecycle.',
                '17CC separate attack writes 948/954; adjacent 17D0 separate rate writes 960/96C and is not this tag.',
                '127157D four-value reinforcement context is recorded only as static provenance and remains unsupported by this ordinary-field compiler.',
                'Modes 4/5 select the second accumulator in the stable-mode consumer; runtime mapping applies only the first to current offline PVE. Full damage formula remains adaptation.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite source')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[SEPARATE_ATTACK] {len(e['runs'])} source field paths; {len(e['consumers'])} native consumers")


if __name__=='__main__':main()

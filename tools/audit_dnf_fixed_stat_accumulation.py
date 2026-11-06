"""Original stat reset, EQU fixed-attack multipliers and final-add mode branch.

D02B70 executes from entry through RET. The equipment parser and 77AA90
accumulator use bounded original fragments with prepared outer frames.
No client executable is launched; encryption, lexer and singleton are ABI inputs.
"""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sys
from audit_dnf_firewave import extra_step
from audit_dnf_ice_shatter import fbits,real,signed
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
from audit_dnf_native_strings import ENGINE_SHA,recover_string
from dnf_equipment_stats import separate_attack

SRC,DST,MANAGER,FRAME=0x60000000,0x60100000,0x60200000,0x6FFFFE00
OFFSETS=(0x87C,0x888,0x894,0x8A0,0x8AC)


def f32(v):return real(fbits(v))


def replay(source,items,*,manager_mode=3,alternate=False,poison=False):
    from dnf_native_vm_probe import CPU
    c=CPU(source)
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.write(0x1D8B554,1,1);c.write(0x1D94A4C,4,1)
    c.write(MANAGER+0xF90,4,manager_mode);c.write(MANAGER+0xB0128,1,int(alternate))
    secure={DST+off:0xBAD0C0DE for off in OFFSETS}
    tokens=[];cursor=0;current=None;fp=[];xmm={f'xmm{j}':0 for j in range(8)};phases=[]
    def snapshot():
        return [signed(secure[DST+off]) if j in (0,1,4) else real(secure[DST+off]) for j,off in enumerate(OFFSETS)]
    def run(start,end=None):
        nonlocal cursor,current
        c.pc=start
        for _ in range(12000):
            if c.pc==end:
                phases.append({'start':hex(start),'end':hex(end),'stack':hex(c.reg['esp'])});return
            if c.pc in (0x1195930,0x1195A10,0x1195EB0,0x119A6F0,0x119A800,0x119A860,0x6FC760):
                target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4);result=pop=0
                if target in (0x1195930,0x1195A10,0x1195EB0):
                    write=target!=0x1195EB0
                    if arg(1 if write else 0)!=this+8:raise ValueError('Wrong secure key')
                    if write:secure[this]=c.read(arg(0),1 if target==0x1195930 else 4)
                    else:c.write(arg(1),4,secure[this])
                    pop=8
                elif target==0x119A6F0:
                    if cursor>=len(tokens):raise ValueError('Read beyond field')
                    current=tokens[cursor];cursor+=1;result=2 if type(current)==int else 4
                elif target==0x119A800:
                    if type(current)!=int:raise ValueError('Wrong integer getter')
                    result=current&0xFFFFFFFF
                elif target==0x119A860:
                    if type(current)!=float:raise ValueError('Wrong float getter')
                    fp.append(f32(current))
                else:result=MANAGER
                c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
                c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
                for key in xmm:xmm[key]=0x0123456789ABCDEF if poison else 0
                continue
            stop=c.run(c.pc,1)
            if stop[0]=='returned':
                if end is not None:raise ValueError('Unexpected return')
                phases.append({'start':hex(start),'end':'return','stack':hex(c.reg['esp'])});return
            if stop[0]=='budget':continue
            i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
            if stop[0]=='call':
                target=int(stop[2],16)
                if target not in (0x1195930,0x1195A10,0x1195EB0,0x119A6F0,0x119A800,0x119A860,0x1218A80,0x1218B30,0x4041C0,0x13CD690,0x6FC760,0x750CF0):raise ValueError(f'Unknown call {target:#x}')
                c.push(c.pc+i.size);c.pc=target;continue
            if stop[0]!='unsupported':raise ValueError(f'Unexpected stop {stop}')
            if i.mnemonic=='fld' and i.operands[0].size==4:fp.append(real(c.get(i,i.operands[0])))
            elif i.mnemonic=='fstp' and i.operands[0].size==4:c.put(i,i.operands[0],fbits(fp.pop()))
            else:extra_step(c,xmm,i);continue
            c.pc+=i.size
        raise ValueError('Instruction budget')
    c.reg.update(ecx=DST,ebx=17,esi=29,edi=31,ebp=37)
    run(0xD02B70)
    reset=snapshot();reset_abi=[c.reg[k] for k in ('ebx','esi','edi','ebp','esp')]
    states=[];parsed=[]
    for item in items:
        # Both fields have two-value ordinary EQU grammar. The final-add source
        # values are separate ABI inputs; their producer is not guessed here.
        separate_attack(item['attack'])
        if len(item['rate'])!=2 or len(item['final'])!=2:raise ValueError('Fixture arity')
        c.reg.update(ebp=FRAME,esp=FRAME-0x200,esi=SRC,edi=DST)
        tokens=item['attack'];cursor=0;run(0x126DABD,0x126F227)
        if cursor!=2:raise ValueError('Attack token count')
        tokens=item['rate'];cursor=0;run(0x126DAFF,0x126F227)
        if cursor!=2:raise ValueError('Rate token count')
        parsed.append({'attack':[signed(secure[SRC+o]) for o in (0x948,0x954)],'rate':[real(secure[SRC+o]) for o in (0x960,0x96C)]})
        for off,value in zip((0x978,0x984),item['final']):secure[SRC+off]=value&0xFFFFFFFF
        run(0x77BDD9,0x77BF85)
        states.append(snapshot())
    row={'fixture':{'items':items,'manager_mode':manager_mode,'alternate':alternate,'poison':poison},
         'reset':reset,'reset_abi':reset_abi,'parsed':parsed,'states':states,'phases':phases,
         'fp_depth':len(fp),'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)}
    return row,c.trace


def verify(row):
    f=row['fixture'];state=[0,0,1.,1.,0];states=[];parsed=[]
    selected=f['manager_mode'] in (8,13,15,16) and f['alternate']
    for item in f['items']:
        attack=separate_attack(item['attack']);rate=[f32(v) for v in item['rate']]
        parsed.append({'attack':attack,'rate':rate})
        state=[signed((state[0]+attack[0])&0xFFFFFFFF),signed((state[1]+attack[1])&0xFFFFFFFF),
               f32(state[2]*rate[0]),f32(state[3]*rate[1]),signed((state[4]+item['final'][int(selected)])&0xFFFFFFFF)]
        states.append(state)
    if row['reset']!=[0,0,1.,1.,0] or row['reset_abi']!=[17,29,31,37,0x70000004]:raise ValueError('Reset mismatch')
    if row['parsed']!=parsed or row['states']!=states:raise ValueError('Fixed stat accumulation mismatch')
    if row['fp_depth'] or any(p['stack']!=hex(0x70000004 if i==0 else FRAME-0x200) for i,p in enumerate(row['phases'])):raise ValueError('Fragment ABI mismatch')


def inventory():
    from dnf_pvf import open_library
    with closing(open_library()) as lib:
        matches=[i for i in range(lib.strings.count) if lib.strings.get(i)=='[separate rate]']
        return {'asset_version':lib.asset_version,'string_table_sha256':hashlib.sha256(lib.strings.content).hexdigest(),
                'separate_rate_string_ids':matches,
                'meaning':'No exact tag in this archived string table; synthetic rate fixtures prove code semantics, not existing equipment content.'}


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    cases=[[],[{'attack':[26,14],'rate':[1,1],'final':[7,11]}],
        [{'attack':[31,18],'rate':[1.1,1.25],'final':[7,11]},{'attack':[56,34],'rate':[0.9,0.8],'final':[13,17]}],
        [{'attack':[2147483647,-2147483648],'rate':[1.0000001192092896,0.5],'final':[2147483647,-2147483648]},
         {'attack':[1,-1],'rate':[1.0000001192092896,0],'final':[1,-1]}],
        [{'attack':[-5,3],'rate':[-0.75,16777217],'final':[-7,13]}]]
    runs=[];traces=[];consumers=[]
    from audit_dnf_fixed_base import replay as consume,verify as verify_consumer
    for index,items in enumerate(cases):
        modes=(3,) if index==0 else (3,8,13,14,15,16)
        for manager_mode in modes:
            for alternate in (False,True):
                for poison in (False,True):
                    row,trace=replay(source,items,manager_mode=manager_mode,alternate=alternate,poison=poison)
                    verify(row);runs.append(row);traces.append(trace)
                if index==2:
                    a,b,m,n,z=row['states'][-1]
                    for mode in (3,4,5,7,9):
                        result,trace=consume(source,mode=mode,table_mode=1,info_kind=3,add_normal=a-3,add_special=b-3,
                            mul_normal=m,mul_special=n-3/8,final_add=z-3,poison=True)
                        verify_consumer(result);traces.append(trace)
                        consumers.append({'state':row['states'][-1],'manager_mode':manager_mode,'alternate':alternate,'run':result})
    names=('audit_dnf_fixed_stat_accumulation.py','dnf_equipment_stats.py','audit_dnf_fixed_base.py','audit_dnf_firewave.py',
        'audit_dnf_ice_shatter.py','audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    return {'schema':'dnf_fixed_stat_accumulation/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
        'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
        'tag':recover_string(source.source_bytes(0x18627B4,8192),0,2)[0],
        'constant_one':{'address':'0x15560bc','bits':int.from_bytes(source.source_bytes(0x15560BC,4),'little')},
        'inventory':inventory(),'runs':runs,'consumers':consumers,'blocks':source_blocks(source,traces),
        'boundaries':['D02B70 reset runs from entry through RET; secure byte/integer storage is an ABI fixture, not native encryption.',
            'Ordinary EQU parser branches and final 77AA90 segment run with prepared frames; the whole parser and character aggregation are not replayed.',
            'Final-add source 978/984 and manager F90/B0128 are synthetic inputs. Their producers and meanings are not established here.',
            'Manager F90 mode for final-add selection and stable 752880 current mode for 75EB80 selection are distinct fixture inputs; no equivalence is assumed.',
            'Separate full 75EB80 replays use accumulated outputs and synthetic base tables; not a full actor lifecycle or final damage formula.',
            'Finite integer/float token types 2/4 tested; lexer type3 and invalid/nonfinite input excluded. Runtime code is unchanged.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite source')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[FIXED_STATS] {len(e['runs'])} reset/accumulation paths; {len(e['consumers'])} base consumers")


if __name__=='__main__':main()

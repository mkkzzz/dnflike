"""Python-only replay of original basic mastery attack-record adjustment.

83FA10, the swordman eligibility override, column selection and rank wrapper
execute original instructions. Protected skill-value/static services are ABI
inputs, not bypassed source implementations. No native process is launched.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys
from audit_dnf_firewave import extra_step
from audit_dnf_ice_shatter import fbits, real, signed
from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_native_strings import ENGINE_SHA

OWNER, ATTACK, SKILL, STATE, STATE_VT = 0x60000000,0x60100000,0x60200000,0x60300000,0x60400000
VTABLE = 0x16F972C
STATE_OFFSETS = (0x6A44,0x6514,0x67E8)


def f32(value):return real(fbits(value))


def replay(source, *, category=8, rank=1, values=(24.,48.,72.), initial=35,
           static=1, learned=1, skill_exists=True, attack_exists=True,
           states=(None,None,None), poison=False):
    from dnf_native_vm_probe import CPU
    if len(values)!=3 or len(states)!=3 or any(x is not None and x not in (0,1) for x in states):raise ValueError('Fixture shape')
    if any(not math.isfinite(v) or not -2147483648<=v<2147483648 for v in values):raise ValueError('Finite conversion domain')
    c=CPU(source)
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.write(OWNER,4,VTABLE);c.write(0x70000004,4,ATTACK if attack_exists else 0);c.write(0x70000008,4,category)
    for index,(off,status) in enumerate(zip(STATE_OFFSETS,states)):
        c.write(OWNER+off,4,0 if status is None else STATE+index*0x100)
        if status is not None:c.write(STATE+index*0x100,4,STATE_VT)
    c.write(STATE_VT+0x70,4,0)
    secure={ATTACK+0x24:initial&0xFFFFFFFF,SKILL+0x59C:rank&0xFFFFFFFF}
    c.reg.update(ecx=OWNER,ebx=17,esi=29,edi=31,ebp=37);c.pc=0x83FA10
    xmm={f'xmm{j}':0 for j in range(8)};fp=[];calls=[];writes=[];state_calls=[]
    def clobber():
        c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
        for name in xmm:xmm[name]=0x0123456789ABCDEF if poison else 0
    def finish(value,count):
        c.reg['eax']=value&0xFFFFFFFF;c.pc=c.pop();c.reg['esp']+=count*4;clobber()
    for _ in range(12000):
        arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
        if c.pc in (0xC9EE7A,0xC9EE94,0xC9EEAE):
            index=(c.reg['ecx']-STATE)//0x100
            if index not in (0,1,2) or states[index] is None or c.reg['edx']!=0:raise ValueError('Unknown status ABI')
            state_calls.append(index);c.reg['eax']=states[index];clobber();c.pc+=2;continue
        if c.pc in (0x8444F0,0x8406C0):
            if c.reg['ecx']!=OWNER or arg(0)!=174:raise ValueError('Skill lookup ABI')
            calls.append({'service':'learned' if c.pc==0x8444F0 else 'lookup','id':arg(0)})
            finish(learned if c.pc==0x8444F0 else SKILL if skill_exists else 0,1);continue
        if c.pc==0x908510:
            if c.reg['ecx']!=SKILL or [arg(0),arg(1)]!=[0,OWNER]:raise ValueError('Static ABI')
            calls.append({'service':'static','column':0});finish(static,2);continue
        if c.pc==0x908770:
            actual=[signed(arg(j)) for j in range(8)]
            expected=[actual[0],rank,OWNER,-1,-1,14,0,0]
            if c.reg['ecx']!=SKILL or actual!=expected or actual[0] not in (0,1,2):raise ValueError('Value-service ABI')
            calls.append({'service':'value','args':actual});fp.append(f32(values[actual[0]]));finish(0,8);continue
        if c.pc==0x13CD690:
            finish(math.trunc(fp.pop()),0);continue
        if c.pc in (0x1195EB0,0x1195A10):
            write=c.pc==0x1195A10;this=c.reg['ecx']
            if this not in secure or arg(1 if write else 0)!=this+8:raise ValueError('Secure ABI')
            if write:
                secure[this]=c.read(arg(0),4);writes.append({'offset':hex(this-ATTACK),'value':signed(secure[this])})
            else:c.write(arg(1),4,secure[this])
            finish(0,2);continue
        stop=c.run(c.pc,1)
        if stop[0]=='returned':break
        if stop[0]=='budget':continue
        i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
        if stop[0]=='call':
            target=int(stop[2],16)
            if target not in (0x8444F0,0x8406C0,0xC9EE60,0x83C020,0x83C040,0x9095B0,0x908510,0x908770,0x13CD690,0x1195EB0,0x1195A10,0x4041C0,0x42CDB0):raise ValueError(f'Unknown call {target:#x}')
            c.push(c.pc+i.size);c.pc=target;continue
        if stop[0]!='unsupported':raise ValueError(f'Unmodeled stop {stop}')
        if i.mnemonic in ('addss','subss'):
            dst,src=i.operands;name=i.reg_name(dst.reg);b=xmm[i.reg_name(src.reg)] if src.type==1 else c.get(i,src)
            value=real(xmm[name])+real(b) if i.mnemonic=='addss' else real(xmm[name])-real(b)
            xmm[name]=(xmm[name]&~0xFFFFFFFF)|fbits(value)
        elif i.mnemonic=='imul' and len(i.operands)==1:
            product=signed(c.reg['eax'])*signed(c.get(i,i.operands[0]));c.reg['eax']=product&0xFFFFFFFF;c.reg['edx']=(product>>32)&0xFFFFFFFF
            c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=product<=2147483647 else 0)
        else:extra_step(c,xmm,i);continue
        c.pc+=i.size
    else:raise ValueError('Instruction budget')
    return {'fixture':{'category':category,'rank':rank,'values':list(values),'initial':initial,'static':static,'learned':learned,
        'skill_exists':skill_exists,'attack_exists':attack_exists,'states':list(states),'poison':poison},
        'value':signed(secure[ATTACK+0x24]),'calls':calls,'writes':writes,'state_calls':state_calls,
        'stop':list(stop),'abi':[c.reg[k] for k in ('ebx','esi','edi','ebp','esp')],'fp_depth':len(fp),
        'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify(row):
    f=row['fixture'];expected=f['initial'];calls=[];states=[];writes=[]
    if f['attack_exists']:
        calls.append({'service':'learned','id':174})
        if f['learned']>0:
            calls.append({'service':'lookup','id':174})
            if f['skill_exists']:
                for j,value in enumerate(f['states']):
                    if value is not None:states.append(j)
                    if value==1:break
                if 1 not in f['states'] and f['category'] in (8,7,15):
                    col={8:0,7:1,15:2}[f['category']]
                    calls.extend([{'service':'lookup','id':174},{'service':'static','column':0},{'service':'lookup','id':174},
                        {'service':'value','args':[col,f['rank'],OWNER,-1,-1,14,0,0]}])
                    v=math.trunc(f32(f['values'][col]))
                    if f['static']:
                        a=f32(f32(v)*f32(.1));a=f32(a+100.)
                        b=f32(signed((expected+100)&0xFFFFFFFF));b=f32(b*a);b=f32(b*f32(.01));b=f32(b-100.)
                        expected=math.trunc(b)
                    else:expected=signed((expected+math.trunc(v/10))&0xFFFFFFFF)
                    writes=[{'offset':'0x24','value':expected}]
    if (row['value'],row['calls'],row['state_calls'],row['writes'])!=(expected,calls,states,writes):raise ValueError('Basic mastery scope/arithmetic mismatch')
    if row['stop']!=['returned'] or row['abi']!=[17,29,31,37,0x7000000C] or row['fp_depth']:raise ValueError('Basic mastery ABI mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    cases=[]
    for category in (-1,0,7,8,15,18,31):
        for static in (0,1):cases.append({'category':category,'static':static})
    for rank in (1,2,10,60,100):cases.append({'rank':rank,'values':(24.*(rank-1),)*3})
    for value in (-121.9,-24.9,0.,24.9,1416.,2376.):
        for static in (0,1):cases.append({'values':(value,)*3,'static':static})
    cases.extend([{'attack_exists':False},{'learned':0},{'learned':-1},{'skill_exists':False},
        {'states':(0,0,0)},{'states':(1,1,1)},{'states':(None,1,0)},{'states':(0,None,1)},
        {'initial':-101},{'initial':-100},{'initial':0},{'initial':100},{'static':-1}])
    traces=[];runs=[]
    for case in cases:
        for poison in (False,True):
            row,trace=replay(source,**case,poison=poison);verify(row);runs.append(row);traces.append(trace)
    names=('audit_dnf_basic_mastery.py','audit_dnf_firewave.py','audit_dnf_ice_shatter.py','audit_dnf_ice_particle_bindings.py',
        'audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    return {'schema':'dnf_basic_mastery/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
        'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
        'vtable':{'address':hex(VTABLE),'slots':{hex(o):source.source_bytes(VTABLE+o,4).hex() for o in (0x7D0,0x804,0x878,0x87C)}},
        'constants':{hex(a):source.source_bytes(a,4).hex() for a in (0x156889C,0x1556DF8,0x1559C80)},
        'runs':runs,'blocks':source_blocks(source,traces),'boundaries':[
            '83FA10 full entry/return, actual swordman vtable, C9EE60/83C020 eligibility, 83C040 column selection and 9095B0 rank wrapper execute original bytes.',
            'Learned-rank lookup, skill pointer, protected static/value services, inner status virtuals and secure storage are explicit ABI fixtures.',
            'The value wrapper passes stored rank and owner with -1/-1 normalization inputs; rank production/automatic level progression remains unresolved.',
            'Attack record +24 is observed, but its original producer/field semantics and downstream damage consumer are not certified by this replay.',
            'Three swordman state-pointer gates are observed without naming their production or complete lifecycle.',
            'Finite binary32 round-to-nearest and in-range conversions only; no complete damage formula or original-equivalent gameplay claim.']}


def skill_source():
    from contextlib import closing
    from dnf_pvf import open_library,parse_script
    from audit_dnf_reusable_data import TextResolver
    with closing(open_library()) as lib:
        path='skill/swordman/basicattackup.skl';raw,sha=lib.raw(path);resolver=TextResolver(lib)
        fields=parse_script(raw,lib.strings)['fields'];text=resolver.fields(raw)
        table,entries=resolver.table(12)
        prop=next(f for f in fields if f['tag']=='[level property]')
        key=lib.strings.get(prop['values'][3]['raw'])
        return {'asset_version':'dnf-native-assets-v1-20261022','skill_id':174,'path':path,'sha256':sha,
            'fields':{f['tag']:f['values'] for f in fields if f['tag'] in ('[level info]','[static data]',
                '[maximum level]','[growtype maximum level]','[required level]','[required level range]','[feature skill index]','[level property]')},
            'text':text,'level_property':{'table':table,'key':key,**entries[key]},'text_sources':resolver.sources}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite source')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));e['skill_source']=skill_source();a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[BASIC_MASTERY] {len(e['runs'])} original attack-record paths")


if __name__=='__main__':main()

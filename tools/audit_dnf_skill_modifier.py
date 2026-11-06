"""Native 906250 linked-skill modifiers, selector and percent initialization.

Runs original 906250/905D70/4F9A20/77A330 and mode gates. The initial constant
write runs the explicit 14F1E83..14F1EB4 fragment, not complete CRT startup.
Owner skill lookup and secure storage are ABI fixtures; modifier records are
synthetic. No PVF-to-record loader or full skill/damage formula is claimed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from audit_dnf_firewave import extra_step
from audit_dnf_ice_shatter import fbits, real, signed
from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_native_strings import ENGINE_SHA

SKILL,OWNER,MANAGER,LINKED,RECORDS=0x60000000,0x60100000,0x60200000,0x60300000,0x60400000
PERCENT=0x1A5FFA4
DEFAULT_RECORDS=((1,0,0,3),(1,0,1,2),(1,0,2,5))
FIXTURES={0x1197630,0x1195A10,0x1195EB0,0x1195B90,0x6FC760,0x8406C0}
NATIVE={0x905D70,0x752850,0x752880,0x4F9A20,0x77A330}


def f32(x):return real(fbits(x))


def replay(source,*,records=DEFAULT_RECORDS,value=100.0,column=0,flag=1,phase=2,
           rank=3,mode=3,skill_mode=1,linked_id=21,found=True,owner_arg=True,
           fallback_owner=True,poison=False):
    from dnf_native_vm_probe import CPU
    c=CPU(source)
    for a in range(0x6FFFF000,0x70000000,4):c.write(a,4,0)
    c.write(SKILL+0x34,4,OWNER if fallback_owner else 0);c.write(OWNER,4,0x16F972C)
    c.write(MANAGER+0xA4,4,0x12345678)
    c.write(LINKED+0x534,4,RECORDS);c.write(LINKED+0x538,4,RECORDS+len(records)*40)
    secure={SKILL+0x4A4:skill_mode&0xFFFFFFFF,SKILL+0x518:linked_id&0xFFFFFFFF,
            LINKED+0x59C:rank&0xFFFFFFFF}
    for index,(kind,col,op,amount) in enumerate(records):
        base=RECORDS+index*40;c.write(base,1,kind)
        for offset,v in ((4,col),(0x10,op),(0x1C,amount)):secure[base+offset]=v&0xFFFFFFFF
    events=[];fp=[];xmm={f'xmm{j}':0 for j in range(8)}

    def run(start,end=None):
        c.pc=start
        for _ in range(15000):
            if end is not None and c.pc==end:return ['boundary',hex(end)]
            if c.pc in FIXTURES:
                target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
                e={'target':hex(target)};result=0;pop=0
                if target==0x6FC760:result=MANAGER;e['kind']='singleton_fixture'
                elif target==0x1195B90:
                    if c.read(arg(0),4)!=0x12345678:raise ValueError('Unknown mode handle')
                    c.write(arg(1),4,mode);e.update(kind='mode_decode_fixture',value=mode)
                elif target==0x1197630:
                    if this!=PERCENT:raise ValueError('Unexpected secure constructor')
                    secure[this]=0;e.update(kind='secure_construct_fixture',this=hex(this))
                elif target==0x1195A10:
                    if this!=PERCENT or arg(1)!=this+8:raise ValueError('Unexpected percent write')
                    secure[this]=c.read(arg(0),4);pop=8;e.update(kind='secure_write_fixture',this=hex(this),bits=secure[this])
                elif target==0x1195EB0:
                    if this not in secure or arg(0)!=this+8:raise ValueError(f'Unmodeled secure field {this:#x}')
                    c.write(arg(1),4,secure[this]);pop=8;e.update(kind='secure_read_fixture',this=hex(this),bits=secure[this])
                else:
                    if this!=OWNER or arg(0)!=(linked_id&0xFFFFFFFF):raise ValueError('Unexpected owner lookup')
                    result=LINKED if found else 0;pop=4
                    e.update(kind='owner_skill_lookup_fixture',this=hex(this),id=arg(0),result=hex(result))
                events.append(e);c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
                c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
                for name in xmm:xmm[name]=0x0123456789ABCDEF if poison else 0
                continue
            stop=c.run(c.pc,1)
            if stop[0]=='returned':return list(stop)
            if stop[0]=='budget':continue
            i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
            if stop[0]=='call':
                target=int(stop[2],16)
                if target not in FIXTURES|NATIVE:raise ValueError(f'Unmodeled call {target:#x}')
                c.push(c.pc+i.size);c.pc=target;continue
            if stop[0]!='unsupported':raise ValueError(f'Unexpected stop {stop}')
            op=i.operands[0]
            if i.mnemonic=='imul' and op.size==4 and len(i.operands) in (1,2):
                if len(i.operands)==1:
                    product=signed(c.reg['eax'])*signed(c.get(i,op))
                    c.reg['eax']=product&0xFFFFFFFF;c.reg['edx']=(product>>32)&0xFFFFFFFF
                else:
                    product=signed(c.get(i,op))*signed(c.get(i,i.operands[1]));c.put(i,op,product)
                c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=product<=2147483647 else 0)
            elif i.mnemonic in ('addss','subss'):
                dst,src=i.operands;name=i.reg_name(dst.reg)
                bits=xmm[i.reg_name(src.reg)] if src.type==1 else c.get(i,src)
                a,b=real(xmm[name]),real(bits);xmm[name]=(xmm[name]&~0xFFFFFFFF)|fbits(a+b if i.mnemonic=='addss' else a-b)
            elif i.mnemonic=='fld' and op.size==4:fp.append(real(c.get(i,op)))
            else:extra_step(c,xmm,i);continue
            c.pc+=i.size
        raise ValueError('Instruction budget exceeded')

    # Explicit static-initializer fragment; no claim of full CRT execution.
    c.reg.update(ebp=0x6FFFF800,esp=0x6FFFF700)
    init_stop=run(0x14F1E83,0x14F1EB4);init_steps=len(c.trace)
    saved={'edi':0x12345678,'esi':0x23456789,'ebx':0x3456789A,'ebp':0x456789AB}
    c.reg.update(saved);c.reg.update(esp=0x70000000,ecx=SKILL)
    for j,v in enumerate((OWNER if owner_arg else 0,column,fbits(value),flag,phase)):
        c.write(0x70000004+j*4,4,v)
    stop=run(0x906250)
    return {'fixture':dict(records=[list(r) for r in records],value=value,column=column,flag=flag,phase=phase,
                rank=rank,mode=mode,skill_mode=skill_mode,linked_id=linked_id,found=found,owner_arg=owner_arg,
                fallback_owner=fallback_owner,poison=poison),
            'value':fp[-1] if fp else None,'bits':fbits(fp[-1]) if fp else None,'fp_depth':len(fp),
            'percent_bits':secure[PERCENT],'events':events,'stop':stop,'init_stop':init_stop,'init_steps':init_steps,
            'stack':hex(c.reg['esp']),'preserved':{name:c.reg[name]==v for name,v in saved.items()},
            'steps':len(c.trace),'branches':c.branches,'trace_sha256':trace_hash(c.trace)},c.trace


def expected(f):
    value=f32(f['value'])
    selected=(f['mode'] not in (4,5,9) and f['skill_mode'] not in (4,5)
              and (f['owner_arg'] or f['fallback_owner']) and f['linked_id']!=-1 and f['found'] and f['rank']>0)
    if not selected:return value
    for kind,col,op,amount in f['records']:
        if kind!=(f['flag']&255) or col!=f['column']:continue
        term=f32(signed((amount*f['rank'])&0xFFFFFFFF))
        if f['phase'] in (1,2) and op in (0,1):value=f32(value+term if op==0 else value-term)
        if f['phase'] in (0,2) and op==2:value=f32(value+f32(f32(term*f32(.01))*value))
    return value


def verify(row):
    if row['stop']!=['returned'] or row['stack']!='0x70000018' or row['fp_depth']!=1 or not all(row['preserved'].values()):
        raise ValueError('Return/ABI mismatch')
    if row['init_stop']!=['boundary','0x14f1eb4'] or row['percent_bits']!=fbits(.01):raise ValueError('Percent initialization mismatch')
    if row['bits']!=fbits(expected(row['fixture'])):raise ValueError('Modifier arithmetic mismatch')
    f=row['fixture'];lookups=[e for e in row['events'] if e['kind']=='owner_skill_lookup_fixture']
    eligible=f['mode'] not in (4,5,9) and f['skill_mode'] not in (4,5) and (f['owner_arg'] or f['fallback_owner']) and f['linked_id']!=-1
    count=0 if not eligible else 1 if not f['found'] else 2 if f['rank']<=0 else 3
    if len(lookups)!=count:raise ValueError('Linked-skill selection mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    fixtures=[dict(phase=p) for p in (0,1,2,3)]
    fixtures += [dict(records=[(1,0,op,7)],phase=p) for op in (0,1,2,3) for p in (0,1,2)]
    fixtures += [dict(rank=r) for r in (-1,0,1,20)]
    fixtures += [dict(mode=m) for m in (1,4,5,9)] + [dict(skill_mode=m) for m in (4,5)]
    fixtures += [dict(linked_id=-1),dict(found=False),dict(owner_arg=False),dict(owner_arg=False,fallback_owner=False)]
    fixtures += [dict(records=[]),dict(column=1),dict(flag=0),dict(flag=257),
                 dict(records=[(0,0,0,100),(1,1,0,100),(1,0,0,3),(1,0,2,5)]),
                 dict(records=[(1,0,2,5),(1,0,0,3)]),dict(value=-12.5),
                 dict(records=[(1,0,2,-5)]),dict(records=[(1,0,0,0x40000001)],rank=3),
                 dict(value=16777216,rank=1,records=[(1,0,0,1),(1,0,0,1)]),
                 dict(records=[(1,0,2,5),(1,0,0,3)],phase=1),
                 dict(records=[(1,0,2,5),(1,0,0,3)],phase=0,value=109)]
    runs=[];traces=[]
    for fixture in fixtures:
        for poison in (False,True):
            row,trace=replay(source,poison=poison,**fixture);verify(row);runs.append(row);traces.append(trace)
    names=('audit_dnf_skill_modifier.py','audit_dnf_firewave.py','audit_dnf_ice_shatter.py',
           'audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    return {'schema':'dnf_skill_modifier/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
            'method':__doc__.strip(),'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
            'boundaries':['906250 full entry and original linked selector/gates/level getter/vector accessor are replayed.',
                'Owner virtual +804 resolves from original vtable to 8406C0; lookup result is an explicit stable fixture, not reconstructed owner skill storage.',
                'Initializer 14F1E83..14F1EB4 sets secure global from original binary32 .01; constructor/write/read are ABI fixtures, full CRT and later writes excluded.',
                '40-byte modifier records and skill fields are synthetic; original PVF loader/field names not proved.',
                '907D40 equipment/status service, protected 908770 entry, outer mode wrapper and final damage remain excluded.'],
            'constant':{'address':'0x1559c80','raw':source.source_bytes(0x1559C80,4).hex()},
            'owner_lookup':{'vtable':'0x16f972c','slot':'0x804','target':hex(int.from_bytes(source.source_bytes(0x16F972C+0x804,4),'little'))},
            'runs':runs,'blocks':source_blocks(source,traces)}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path)
    p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite client')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    result=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(result,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[SKILL_MODIFIER] {len(result['runs'])} source paths verified")


if __name__=='__main__':main()

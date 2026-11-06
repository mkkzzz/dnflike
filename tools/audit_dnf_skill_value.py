"""Bounded 908794 skill-value body replay; does not bypass a protected entry.

The fixture explicitly starts AFTER the unproved 908770 protected prologue and
initial alternate-table selection, on the own-table branch. Later 905D70 calls
and mode gates run original instructions with a -1 linked-skill field. Four
modifier services and normalization values are ABI fixtures, not game formulas.
No PE execution. x87 intermediates use Python floats with binary32 stores.
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

SKILL, OWNER, MANAGER, VECTORS = 0x60000000,0x60100000,0x60200000,0x60300000
FRAME=0x6FFFFF00
TABLE=((1.25,584.0,1234.5),(-5.0,0.0,6.25,9.0),(100.0,))
FIXTURES={0x1195EB0,0x1195B90,0x6FC760,0x906250,0x907D40,0x75BF00}
NATIVE={0x905D70,0x752880,0x752850}


def f32(x):return real(fbits(x))


def replay(source,*,column=0,rank=2,mode=3,skill_mode=1,level_a=40,level_b=40,
           normalization_column=14,modifiers=False,poison=False):
    from dnf_native_vm_probe import CPU
    c=CPU(source)
    for a in range(FRAME-0x1000,FRAME+0x40,4):c.write(a,4,0)
    saved={'edi':0x12345678,'esi':0x23456789,'ebx':0x3456789A,'ebp':0x456789AB}
    for j,name in enumerate(('edi','esi','ebx','ebp')):c.write(FRAME-12+j*4,4,saved[name])
    c.write(FRAME+4,4,0xDEADBEEF)
    for j,v in enumerate((column,rank,OWNER,level_a,level_b,normalization_column,0,0)):
        c.write(FRAME+8+j*4,4,v)
    c.reg.update(ebp=FRAME,esp=FRAME-12,esi=SKILL,ebx=OWNER)
    c.write(SKILL+0x34,4,OWNER);c.write(SKILL+0x3D0,4,VECTORS)
    c.write(SKILL+0x3D4,4,VECTORS+len(TABLE)*20);c.write(MANAGER+0xA4,4,0x12345678)
    secured={SKILL+0x4A4:skill_mode,SKILL+0x518:0xFFFFFFFF,SKILL+0x38:20}
    for col,values in enumerate(TABLE):
        base=VECTORS+0x100+col*0x100
        c.write(VECTORS+col*20+4,4,base);c.write(VECTORS+col*20+8,4,base+len(values)*12)
        for row,value in enumerate(values):secured[base+row*12]=fbits(value)
    events=[];fp=[];xmm={f'xmm{j}':0 for j in range(8)};modifier_count=0
    c.pc=0x908794
    for _ in range(10000):
        if c.pc in FIXTURES:
            target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
            e={'target':hex(target),'this':hex(this)};result=0;pop=0
            if target==0x6FC760:result=MANAGER;e['kind']='singleton_fixture'
            elif target==0x1195B90:
                if c.read(arg(0),4)!=0x12345678:raise ValueError('Unmodeled mode handle')
                c.write(arg(1),4,mode);e.update(kind='mode_decode_fixture',value=mode)
            elif target==0x1195EB0:
                if this not in secured or arg(0)!=this+8:raise ValueError('Unmodeled secured field')
                c.write(arg(1),4,secured[this]);pop=8;e.update(kind='secure_read_fixture',bits=secured[this])
            elif target in (0x906250,0x907D40):
                n=5 if target==0x906250 else 6;args=[arg(j) for j in range(n)]
                index=2 if target==0x906250 else 1;value=real(args[index])
                if modifiers:
                    value=(value+3,value*2,value-7,value*.25)[modifier_count]
                value=f32(value);fp.append(value);modifier_count+=1;pop=n*4
                e.update(kind='modifier_fixture',args=args,input=real(args[index]),output=value)
            else:
                args=[arg(j) for j in range(3)];value=2.0 if args[0]==level_a else 4.0
                fp.append(value);e.update(kind='normalization_fixture',args=args,output=value)
            if target in (0x6FC760,0x1195B90,0x75BF00):e.pop('this')  # cdecl: ECX is not an input
            events.append(e);c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
            c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
            for name in xmm:xmm[name]=0x0123456789ABCDEF if poison else 0
            continue
        stop=c.run(c.pc,1)
        if stop[0]=='returned':break
        if stop[0]=='budget':continue
        i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
        if stop[0]=='call':
            target=int(stop[2],16)
            if target not in FIXTURES|NATIVE:raise ValueError(f'Unmodeled call {target:#x}')
            c.push(c.pc+i.size);c.pc=target;continue
        if stop[0]!='unsupported':raise ValueError(f'Unexpected stop {stop}')
        if i.mnemonic=='imul' and len(i.operands)==1 and i.operands[0].size==4:
            product=signed(c.reg['eax'])*signed(c.get(i,i.operands[0]))
            c.reg['eax']=product&0xFFFFFFFF;c.reg['edx']=(product>>32)&0xFFFFFFFF
            overflow=not -2147483648<=product<=2147483647
            c.flags=(c.flags&~0x801)|(0x801 if overflow else 0)
        elif i.mnemonic=='fldz':fp.append(0.0)
        elif i.mnemonic in ('fst','fstp'):
            if len(fp)!=1:raise ValueError('Unexpected floating stack')
            op=i.operands[0]
            if op.type==1:
                if i.mnemonic!='fstp' or i.op_str!='st(0)':raise ValueError('Unmodeled FP register form')
            elif op.size==4:c.put(i,op,fbits(fp[-1]))
            else:raise ValueError('Unmodeled FP store')
            if i.mnemonic=='fstp':fp.pop()
        elif i.mnemonic in ('fmul','fdivr'):
            if len(fp)!=1 or i.operands[0].size!=4:raise ValueError('Unmodeled FP arithmetic')
            v=real(c.get(i,i.operands[0]));fp[-1]=fp[-1]*v if i.mnemonic=='fmul' else v/fp[-1]
        else:extra_step(c,xmm,i);continue
        c.pc+=i.size
    else:raise ValueError('Instruction budget exceeded')
    return {'fixture':dict(column=column,rank=rank,mode=mode,skill_mode=skill_mode,level_a=level_a,
                level_b=level_b,normalization_column=normalization_column,modifiers=modifiers,poison=poison),
            'value':fp[-1] if fp else None,'bits':fbits(fp[-1]) if fp else None,'fp_depth':len(fp),
            'events':events,'stop':list(stop),'stack':hex(c.reg['esp']),
            'preserved':{name:c.reg[name]==value for name,value in saved.items()},
            'steps':len(c.trace),'branches':c.branches,'trace_sha256':trace_hash(c.trace)},c.trace


def verify(row):
    f=row['fixture'];col,rank=f['column'],f['rank']
    valid=0<=col<len(TABLE) and 1<=rank<=len(TABLE[col])
    mods=[e for e in row['events'] if e['kind']=='modifier_fixture']
    norms=[e for e in row['events'] if e['kind']=='normalization_fixture']
    if row['stop']!=['returned'] or row['stack']!=hex(FRAME+40) or row['fp_depth']!=1 or not all(row['preserved'].values()):
        raise ValueError('Return/ABI mismatch')
    value=TABLE[col][rank-1] if valid else 0.0
    if len(mods)!=(4 if valid else 0):raise ValueError('Modifier count mismatch')
    for j,e in enumerate(mods):
        if j%2==0:target=0x906250;args=[OWNER,col,fbits(value),1,1-j//2]
        else:target=0x907D40;args=[OWNER,fbits(value),col,1,20,1-j//2]
        if e['target']!=hex(target) or e['this']!=hex(SKILL) or e['args']!=args:raise ValueError('Modifier order/arguments mismatch')
        if f['modifiers']:value=f32((value+3,value*2,value-7,value*.25)[j])
        if e['output']!=value:raise ValueError('Modifier fixture result mismatch')
    normalized=valid and f['normalization_column']!=14 and f['level_a']!=f['level_b']
    if len(norms)!=(2 if normalized else 0):raise ValueError('Normalization gate mismatch')
    if normalized:
        for e,level in zip(norms,(f['level_a'],f['level_b'])):
            if e['args']!=[level,f['normalization_column'],0]:raise ValueError('Normalization arguments mismatch')
        value=f32(value*2)/4
    if row['bits']!=fbits(value):raise ValueError('Skill value mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    fixtures=[dict(column=c,rank=r) for c,r in ((0,1),(0,2),(0,3),(0,4),(0,0),(0,-1),
                 (1,1),(1,2),(1,3),(1,4),(1,5),(2,1),(2,2),(3,1),(-1,1))]
    fixtures += [dict(modifiers=True),dict(modifiers=True,column=1,rank=1)]
    fixtures += [dict(mode=m) for m in (4,5,9)] + [dict(skill_mode=m) for m in (4,5)]
    fixtures += [dict(normalization_column=n,level_b=b,modifiers=True) for n,b in ((14,20),(13,40),(13,20))]
    runs=[];traces=[]
    for fixture in fixtures:
        for poison in (False,True):
            row,trace=replay(source,poison=poison,**fixture);verify(row);runs.append(row);traces.append(trace)
    names=('audit_dnf_skill_value.py','audit_dnf_firewave.py','audit_dnf_ice_shatter.py',
           'audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    return {'schema':'dnf_skill_value_body/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
            'method':__doc__.strip(),'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
            'boundaries':['Entry is 908794 with an explicit prepared frame, NOT full 908770 or wrapper 9089A0.',
                'Initial own-table selection is assumed. Later 905D70 calls execute, linked field +518=-1; alternate skills are excluded.',
                'Columns/rows are synthetic unequal-length 20-byte vectors of 12-byte secured binary32 entries; PVF loader not traced.',
                'Modifier helpers are explicit identity/noncommuting ABI fixtures, not equipment/status implementations.',
                'Normalization inputs are fixtures; x87 precision/control-word/exceptions and special outer-mode rescaling excluded.'],
            'table_fixture':TABLE,'runs':runs,'blocks':source_blocks(source,traces)}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path)
    p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite client')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    result=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(result,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[SKILL_VALUE_BODY] {len(result['runs'])} bounded source paths verified")


if __name__=='__main__':main()

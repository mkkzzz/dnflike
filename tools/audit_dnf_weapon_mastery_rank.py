"""Original skill-27 caller: source columns -> effective target rank additions.

Native CD9F4E..CDA05C and 9095B0 execute. Protected static/value services are
explicit ABI inputs from the unmodified PVF; not a full protected evaluator.
"""
import argparse
from contextlib import closing
import hashlib
import json
import math
from pathlib import Path
import sys
from audit_dnf_basic_mastery import OWNER,SKILL,VTABLE
from audit_dnf_ice_shatter import fbits,real,signed
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
from audit_dnf_native_strings import ENGINE_SHA


def skill_source():
    from dnf_pvf import open_library,parse_script
    with closing(open_library()) as lib:
        listing=lib.listing('skill/swordmanskill.lst');path='skill/'+listing[27].lower();raw,sha=lib.raw(path)
        fields=parse_script(raw,lib.strings,'skl')['fields'];get=lambda tag:next(f['values'] for f in fields if f['tag']==tag)
        ids=get('[static data]');levels=get('[level info]');columns=levels[0]
        if columns!=len(ids) or (len(levels)-1)%columns:raise ValueError('Source column alignment')
        return {'id':27,'path':path,'sha256':sha,'maximum_level':get('[maximum level]')[0],
            'static_data':ids,'columns':columns,'rows':[levels[j:j+columns] for j in range(1,len(levels),columns)],
            'targets':[{'id':n,'path':'skill/'+listing[n].lower()} for n in ids]}


def replay(source,targets,*,passive=1,rank=1,ceiling=50,values=(3,3,3,3,2),poison=False):
    from dnf_native_vm_probe import CPU
    if len(targets)!=5 or len(set(targets))!=5 or 27 in targets or len(values)!=5:raise ValueError('Five target columns required')
    if any(type(v)!=int or not -2147483648<=v<=2147483647 for v in (passive,rank,ceiling)):raise ValueError('Signed rank domain')
    if any(not math.isfinite(v) or not -2147483648<=real(fbits(v))<2147483648 for v in values):raise ValueError('Finite value domain')
    c=CPU(source);frame=0x6FFFFE00;vector=0x60800000;data=vector+0x1000
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.reg.update(esi=OWNER,ebp=frame,esp=frame-0x20)
    c.write(OWNER,4,VTABLE);c.write(OWNER+0x3C08,4,0);c.write(OWNER+0x4C0C,4,0)
    pointers={n:SKILL+j*0x1000 for j,n in enumerate([27,*targets])}
    for j in range(255):
        c.write(OWNER+0x4018+j*4,4,pointers.get(j,0));c.write(OWNER+0x4414+j*4,4,pointers.get(j,0))
    secure={}
    for n,ptr in pointers.items():secure.update({ptr+0x59C:(passive if n==27 else rank)&0xFFFFFFFF,ptr+0x54:ceiling&0xFFFFFFFF})
    c.write(vector+4,4,data);c.write(vector+8,4,data+len(targets)*12)
    resolved=[];writes=[];calls=[];fp=[];c.pc=0xCD9F4E
    native={0x8444F0,0x8406C0,0x905D50,0x9095B0};abi={0x1195EB0,0x1195A10,0x905E90,0x908510,0x908770,0x13CD690}
    for _ in range(9000):
        if c.pc==0xCDA05C:break
        if c.pc in abi:
            target=c.pc;this=c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4);result=pop=0
            if target==0x905E90:
                if this!=pointers[27] or arg(0)!=OWNER:raise ValueError('Mastery vector ABI')
                result=vector;pop=4
            elif target==0x908510:
                if this!=pointers[27] or arg(1)!=OWNER or not 0<=arg(0)<5:raise ValueError('Mastery static resolver ABI')
                result=targets[arg(0)];resolved.append(result);pop=8
            elif target==0x908770:
                actual=[signed(arg(j)) for j in range(8)];col=actual[0]
                if this!=pointers[27] or actual!=[col,passive,OWNER,-1,-1,14,0,0] or not 0<=col<5:raise ValueError('Mastery value wrapper ABI')
                calls.append(actual);fp.append(real(fbits(values[col])));pop=32
            elif target==0x13CD690:result=math.trunc(fp.pop())&0xFFFFFFFF
            else:
                write=target==0x1195A10
                if this not in secure or arg(1 if write else 0)!=this+8:raise ValueError('Mastery secure ABI')
                if write:
                    n=next((n for n,p in pointers.items() if p+0x59C==this),None)
                    if n is None or n==27:raise ValueError('Mastery unexpected write')
                    secure[this]=c.read(arg(0),4);writes.append([n,signed(secure[this])])
                else:c.write(arg(1),4,secure[this])
                pop=8
            c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
            c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
            continue
        stop=c.run(c.pc,1)
        if stop[0]=='budget':continue
        i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
        if stop[0]=='call':
            target=int(stop[2],16)
            if target not in native|abi:raise ValueError(f'Mastery unknown call {target:#x}')
            c.push(c.pc+i.size);c.pc=target;continue
        if stop[0]=='unsupported' and i.mnemonic=='imul':
            if len(i.operands)==3:
                dst,left,right=i.operands;v=signed(c.get(i,left))*signed(c.get(i,right));c.put(i,dst,v&0xFFFFFFFF)
            elif len(i.operands)==1:
                v=signed(c.reg['eax'])*signed(c.get(i,i.operands[0]));c.reg['eax']=v&0xFFFFFFFF;c.reg['edx']=(v>>32)&0xFFFFFFFF
            else:raise ValueError('Mastery unsupported imul')
            c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=v<=2147483647 else 0);c.pc+=i.size;continue
        raise ValueError(f'Mastery stop {stop}')
    else:raise ValueError('Mastery instruction budget')
    return {'fixture':{'passive':passive,'rank':rank,'ceiling':ceiling,'values':list(values),'poison':poison},
        'resolved':resolved,'writes':writes,'value_calls':calls,'levels':[[n,signed(secure[p+0x59C])] for n,p in pointers.items()],
        'stack':c.reg['esp'],'fp_depth':len(fp),'stop':hex(c.pc),'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify(row,targets):
    f=row['fixture'];enabled=f['passive']>0;add=enabled and 0<f['rank']<f['ceiling']
    result=[signed((f['rank']+math.trunc(real(fbits(v))))&0xFFFFFFFF) if add else f['rank'] for v in f['values']]
    writes=[[n,v] for n,v in zip(targets,result)] if add else []
    calls=[[j,f['passive'],OWNER,-1,-1,14,0,0] for j in range(5)] if add else []
    if (row['resolved'],row['writes'],row['levels'],row['value_calls'],row['stack'],row['fp_depth'],row['stop'])!=(
        targets if enabled else [],writes,[[27,f['passive']]]+[[n,v] for n,v in zip(targets,result)],calls,0x6FFFFDE0,0,'0xcda05c'):raise ValueError('Mastery rank mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    skl=skill_source();runs=[];traces=[]
    cases=[dict(passive=j+1,values=row) for j,row in enumerate(skl['rows'])]
    cases += [dict(passive=p,rank=r) for p in (0,1) for r in (-1,0,49,50,51)]
    cases += [dict(values=[2.9,-2.9,0,52,1]),dict(rank=49,values=[3,4,5,6,7]),dict(rank=2147483646,ceiling=2147483647,values=[3]*5)]
    for case in cases:
        for poison in (False,True):
            r,t=replay(source,skl['static_data'],**case,poison=poison);verify(r,skl['static_data']);runs.append(r);traces.append(t)
    names=('audit_dnf_weapon_mastery_rank.py','audit_dnf_basic_mastery.py','audit_dnf_firewave.py',
        'audit_dnf_ice_shatter.py','audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    return {'schema':'dnf_weapon_mastery_rank/1','engine_sha256':ENGINE_SHA,'input_source':source.source,'skill_source':skl,
        'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
        'runs':runs,'blocks':source_blocks(source,traces),'boundaries':[
            'CD9F4E..CDA05C runs after the generic and ghost-skill rebuild with explicit prepared effective ranks; this is not full loaded-character initialization.',
            'Original effective-rank getters, cached lookups, ceiling getter, 9095B0 wrapper, caller comparisons and final additions execute source instructions.',
            '905E90/908510 static selection and 908770 protected values are ABI inputs from unmodified source rows. 13CD690 conversion is an explicit truncation service; secure storage is synthetic.',
            'The upper bound is a precondition, not a final clamp. Source rank 1 and target rank 49 can produce 52; no general min(maximum, result) is introduced.',
            'Negative/overflow/fractional fixtures only test caller arithmetic. Missing-cache allocation and modified static IDs or values are not covered.',
            'This caller adds effective target ranks; it does not prove learning-cap bonuses or complete native mastery damage formulas.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite source')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[WEAPON_MASTERY_RANK] {len(e['runs'])} source caller paths")


if __name__=='__main__':main()

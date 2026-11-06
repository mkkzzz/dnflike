"""Native rank rebuild with explicit empty equipment and prepared modifier lists.

Runs CD9E50 -> 861D80 through return. Swordman skills 27/35/63 are absent;
equipment acquisition, secure storage and one container cleanup are ABI inputs.
This verifies supported paths, not all builds or the origin of modifier rows.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
from audit_dnf_basic_mastery import OWNER,SKILL,VTABLE
from audit_dnf_ice_shatter import signed
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
from audit_dnf_native_strings import ENGINE_SHA

HEAD,MODE=0x60800000,0x60900000


def ghost_source():
    from contextlib import closing
    from dnf_pvf import open_library,parse_script
    with closing(open_library()) as lib:
        listing=lib.listing('skill/swordmanskill.lst');path='skill/'+listing[35].lower();raw,sha=lib.raw(path)
        fields=parse_script(raw,lib.strings,'skl')['fields']
        ids=next(f['values'] for f in fields if f['tag']=='[static data]')
        return {'id':35,'path':path,'sha256':sha,'static_data':ids,
            'targets':[{'id':n,'path':'skill/'+listing[n].lower()} for n in ids]}


def ghost_bonus(source,targets,*,passive=1,rank=5,ceiling=50,poison=False):
    """CD9E60..CD9F4E on effective ranks prepared after the generic rebuild.

    Static-vector selection and protected 908510 resolution are ABI fixtures;
    target eligibility, effective-rank getters and +1 writes are native.
    """
    from dnf_native_vm_probe import CPU
    c=CPU(source);frame=0x6FFFFE00;vector=HEAD;data=HEAD+0x1000
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.reg.update(esi=OWNER,ebp=frame,esp=frame-0x20)
    c.write(OWNER,4,VTABLE);c.write(OWNER+0x3C08,4,0);c.write(OWNER+0x4C0C,4,0)
    pointers={n:SKILL+j*0x1000 for j,n in enumerate([35,*targets])}
    for j in range(255):
        c.write(OWNER+0x4018+j*4,4,pointers.get(j,0));c.write(OWNER+0x4414+j*4,4,pointers.get(j,0))
    secure={}
    for n,ptr in pointers.items():secure.update({ptr+0x59C:(passive if n==35 else rank)&0xFFFFFFFF,ptr+0x54:ceiling&0xFFFFFFFF})
    c.write(vector+4,4,data);c.write(vector+8,4,data+len(targets)*12)
    resolved=[];writes=[];c.pc=0xCD9E60
    native={0x8444F0,0x8406C0,0x905D50};abi={0x1195EB0,0x1195A10,0x905E90,0x908510}
    for _ in range(6000):
        if c.pc==0xCD9F4E:break
        if c.pc in abi:
            target=c.pc;this=c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4);result=pop=0
            if target==0x905E90:
                if this!=pointers[35] or arg(0)!=OWNER:raise ValueError('Ghost vector ABI')
                result=vector;pop=4
            elif target==0x908510:
                if this!=pointers[35] or arg(1)!=OWNER or not 0<=arg(0)<len(targets):raise ValueError('Ghost static resolver ABI')
                result=targets[arg(0)];resolved.append(result);pop=8
            else:
                write=target==0x1195A10
                if this not in secure or arg(1 if write else 0)!=this+8:raise ValueError('Ghost secure ABI')
                if write:
                    n=next((n for n,p in pointers.items() if p+0x59C==this),None)
                    if n is None or n==35:raise ValueError('Ghost unexpected write')
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
            if target not in native|abi:raise ValueError(f'Ghost unknown call {target:#x}')
            c.push(c.pc+i.size);c.pc=target;continue
        if stop[0]=='unsupported' and i.mnemonic=='imul' and len(i.operands)==3:
            dst,left,right=i.operands;v=signed(c.get(i,left))*signed(c.get(i,right));c.put(i,dst,v&0xFFFFFFFF)
            c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=v<=2147483647 else 0);c.pc+=i.size;continue
        if stop[0]=='unsupported' and i.mnemonic=='imul' and len(i.operands)==1:
            v=signed(c.reg['eax'])*signed(c.get(i,i.operands[0]));c.reg['eax']=v&0xFFFFFFFF;c.reg['edx']=(v>>32)&0xFFFFFFFF
            c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=v<=2147483647 else 0);c.pc+=i.size;continue
        raise ValueError(f'Ghost stop {stop}')
    else:raise ValueError('Ghost instruction budget')
    return {'fixture':{'passive':passive,'rank':rank,'ceiling':ceiling,'poison':poison},'resolved':resolved,'writes':writes,
        'levels':[[n,signed(secure[p+0x59C])] for n,p in pointers.items()],
        'stack':c.reg['esp'],'stop':hex(c.pc),'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify_ghost(row,targets):
    f=row['fixture'];enabled=f['passive']>0;add=enabled and 0<f['rank']<f['ceiling']
    if (row['resolved'],row['writes'],row['levels'],row['stack'],row['stop'])!=(
        targets if enabled else [],[[n,f['rank']+1] for n in targets] if add else [],
        [[35,f['passive']]]+[[n,f['rank']+int(add)] for n in targets],0x6FFFFDE0,'0xcd9f4e'):raise ValueError('Ghost result mismatch')


def replay(source,*,rank=60,ceiling=100,bonus=0,skill_id=174,flag=0,mode15=False,rows=(),tail=(),poison=False):
    from dnf_native_vm_probe import CPU
    if skill_id not in (174,190,191,199,200,209,210,254):raise ValueError('Unsupported skill fixture')
    if any(type(x)!=int or not -2147483648<=x<=2147483647 for x in (rank,ceiling,bonus)):raise ValueError('Signed fixture domain')
    c=CPU(source)
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.reg.update(ecx=OWNER,ebx=17,esi=29,edi=31,ebp=37)
    c.write(OWNER,4,VTABLE);c.write(OWNER+0x3C08,4,0);c.write(OWNER+0x4C0C,4,0)
    for j in range(255):
        c.write(OWNER+0x4018+j*4,4,SKILL if j==skill_id else 0)
        c.write(OWNER+0x4414+j*4,4,SKILL if j==skill_id else 0)
    c.write(OWNER+0x4C58,4,HEAD+0x20);c.write(HEAD+0x20,4,OWNER+0x4C58)
    c.write(OWNER+0x4C5C,4,HEAD);c.write(HEAD,4,HEAD);c.write(HEAD+4,4,HEAD)
    c.write(OWNER+0x4C60,4,0);c.write(SKILL+0x54C,1,flag);c.write(0x1A5F184,4,0)
    secure={SKILL+0x38:skill_id,SKILL+0x54:ceiling,SKILL+0x590:rank,SKILL+0x59C:77,OWNER+0x52FC:bonus}
    for k,(offset,items) in enumerate(((0x4C98,rows),(0x5560,tail))):
        container=OWNER+offset;proxy=HEAD+0x100+k*0x20;data=HEAD+0x1000+k*0x1000
        c.write(container,4,proxy);c.write(proxy,4,container)
        c.write(container+4,4,data);c.write(container+8,4,data+len(items)*28)
        for j,(job,target,delta) in enumerate(items):
            if not 0<=target<255 or any(type(v)!=int or not -2147483648<=v<=2147483647 for v in (job,delta)):raise ValueError('Row fixture domain')
            ptr=data+j*28;c.write(ptr,4,job);secure[ptr+4]=target;secure[ptr+16]=delta
    secure={a:v&0xFFFFFFFF for a,v in secure.items()}
    writes=[];equipment=[];services=[];reads=[]
    c.pc=0xCD9E50
    native={0x861D80,0x904490,0x9044E0,0x905D50,0x11E98F0,0xB09680,0x110F7C0,
        0x84B560,0x8452D0,0x6CA280,0xD09590,0x8406C0,0x8444F0}
    abi={0x1195EB0,0x1195A10,0x113B500,0x6FC760,0x756620,0x844850,0x85B400}
    for _ in range(18000):
        if c.pc in abi:
            target=c.pc;this=c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4);result=pop=0
            if target in (0x1195EB0,0x1195A10):
                write=target==0x1195A10
                if this not in secure or arg(1 if write else 0)!=this+8:raise ValueError('Rebuild secure ABI')
                if write:
                    if this!=SKILL+0x59C:raise ValueError('Rebuild unexpected field write')
                    secure[this]=c.read(arg(0),4);writes.append(signed(secure[this]))
                else:c.write(arg(1),4,secure[this]);reads.append(hex(this))
                pop=8
            elif target==0x113B500:
                if this!=OWNER+0x4C68 or arg(0)!=0x10:raise ValueError('Container cleanup ABI')
                services.append('container_cleanup');pop=8
            elif target==0x6FC760:result=MODE
            elif target==0x756620:
                if this!=MODE or arg(0)!=15:raise ValueError('Mode predicate ABI')
                services.append('mode15');result=int(mode15);pop=4
            else:
                if this!=OWNER or not 0<=arg(0)<26:raise ValueError('Equipment slot ABI')
                equipment.append([hex(target),arg(0)]);pop=4
            c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
            c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
            continue
        stop=c.run(c.pc,1)
        if stop[0]=='returned':break
        if stop[0]=='budget':continue
        i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
        if stop[0]=='call':
            target=int(stop[2],16)
            if target not in native|abi:raise ValueError(f'Unexpected rebuild call {target:#x}')
            c.push(c.pc+i.size);c.pc=target;continue
        if stop[0]=='unsupported' and i.mnemonic=='imul' and len(i.operands)==3:
            dst,left,right=i.operands;v=signed(c.get(i,left))*signed(c.get(i,right));c.put(i,dst,v&0xFFFFFFFF)
            c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=v<=2147483647 else 0);c.pc+=i.size;continue
        raise ValueError(f'Rebuild stop {stop}')
    else:raise ValueError('Rebuild instruction budget')
    return {'fixture':{'rank':rank,'ceiling':ceiling,'bonus':bonus,'skill_id':skill_id,'flag':flag,
        'mode15':mode15,'rows':[list(r) for r in rows],'tail':[list(r) for r in tail],'poison':poison},
        'base':signed(secure[SKILL+0x590]),'effective':signed(secure[SKILL+0x59C]),'writes':writes,
        'equipment':equipment,'services':services,'reads':reads,'counter':c.read(0x1A5F184,4),
        'abi':[c.reg[k] for k in ('ebx','esi','edi','ebp','esp')],
        'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify(row):
    f=row['fixture'];value=f['rank'];expected=[value]
    eligible=f['bonus']>0 and not 191<=f['skill_id']<=209 and value!=0
    mode_check=eligible
    if eligible and not (f['mode15'] and f['flag']):
        value=min(f['ceiling'],signed((value+f['bonus'])&0xFFFFFFFF));expected.append(value)
    for job,target,delta in f['rows']+f['tail']:
        if job in (0,11) and target==f['skill_id'] and f['rank']!=0:
            value=max(1,min(f['ceiling'],signed((value+delta)&0xFFFFFFFF)));expected.append(value)
    services=['container_cleanup']+(['mode15'] if mode_check else [])
    if (row['base'],row['effective'],row['writes'],row['counter'],row['abi'],row['services'])!=(f['rank'],value,expected,1,[17,29,31,37,0x70000004],services):raise ValueError('Rebuild result mismatch')
    if row['equipment']!=[[hex(t),j] for j in range(26) for t in (0x844850,0x85B400)]:raise ValueError('Equipment iteration mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    cases=[{},dict(bonus=3),dict(bonus=-3),dict(bonus=50),dict(rank=0,bonus=3),dict(rank=101),dict(rank=101,bonus=1),
        dict(rank=-2,bonus=1),dict(rank=2147483647,bonus=1),dict(bonus=3,flag=1,mode15=True),
        dict(bonus=3,flag=1),dict(bonus=3,mode15=True)]
    cases += [dict(bonus=3,skill_id=j) for j in (190,191,199,200,209,210,254)]
    cases += [dict(rows=[[11,174,x] for x in ds]) for ds in ([50,-50],[-50,50],[-100,2],[2,-100])]
    cases += [dict(rows=[[11,174,50]],tail=[[0,174,-50]]),dict(rows=[[1,174,8],[0,174,2],[11,174,3]]),
        dict(rank=0,rows=[[11,174,5]]),dict(bonus=3,rows=[[11,174,50]],tail=[[11,174,-50]]),
        dict(ceiling=0,rows=[[11,174,2]]),dict(rank=2147483647,rows=[[11,174,1]])]
    runs=[];traces=[]
    for case in cases:
        for poison in (False,True):
            r,t=replay(source,**case,poison=poison);verify(r);runs.append(r);traces.append(t)
    ghost=ghost_source();ghost_runs=[]
    for passive in (0,1,5):
        for rank in (-1,0,1,49,50,51):
            for poison in (False,True):
                r,t=ghost_bonus(source,ghost['static_data'],passive=passive,rank=rank,poison=poison)
                verify_ghost(r,ghost['static_data']);ghost_runs.append(r);traces.append(t)
    names=('audit_dnf_skill_rank_rebuild.py','audit_dnf_basic_mastery.py','audit_dnf_firewave.py',
        'audit_dnf_ice_shatter.py','audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    return {'schema':'dnf_skill_rank_rebuild/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
        'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
        'runs':runs,'ghost_source':ghost,'ghost_runs':ghost_runs,'blocks':source_blocks(source,traces),'boundaries':[
            'CD9E50 and generic 861D80 execute to return for these prepared states. Skills 27/35/63 are absent, so their swordman-specific branches are not covered.',
            'Both equipment acquisition services return empty for all 26 slots. Nonempty gear acquisition and its modifier traversal are not covered.',
            'Secure storage, mode15 and 113B500 container cleanup are explicit ABI fixtures. Modifier rows and owner+52FC are prepared inputs; their producers are not proven here.',
            'Base copy, ID exclusion getters, ceiling getter, both 28-byte row iterators, class filtering, cached skill lookup and per-row clamp execute native instructions.',
            'Separate ghostpowerup fragment CD9E60..CD9F4E uses prepared effective ranks after generic rebuild. 905E90/908510 static selection/resolution are ABI inputs from the unmodified source list, not a complete protected resolver replay.',
            'Signed overflow, negative ranks and zero ceilings are arithmetic boundary fixtures, not claims that gameplay allows those inputs.',
            'This audit supplies evidence, not a complete runtime rank engine. Full loaded-character initialization, other class branches, source modifier loading and final damage remain unresolved.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite source')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[SKILL_RANK_REBUILD] {len(e['runs'])} native paths")


if __name__=='__main__':main()

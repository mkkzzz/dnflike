"""Bounded fragments of handler 0x25: byte/profile/skill-174 synchronization.

UI/transport boundaries are explicit. Zero rank stops before deletion; this
does not replay the full handler or certify initial login/level semantics.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
from audit_dnf_basic_mastery import OWNER,SKILL,VTABLE
from audit_dnf_basic_mastery_sync import INFO,FRAME
from audit_dnf_ice_shatter import signed
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
from audit_dnf_native_strings import ENGINE_SHA

MANAGER=0x60800000


def replay(source,*,old=59,new=60,dual=False,bank=0,poison=False):
    from dnf_native_vm_probe import CPU
    if any(type(v)!=int or not 0<=v<=255 for v in (old,new)) or bank not in (0,1):raise ValueError('Byte/profile fixture domain')
    c=CPU(source)
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.reg.update(ebp=FRAME,esp=FRAME-0x500,ebx=0,esi=29,edi=31)
    c.write(0x1A5FAE8,4,MANAGER);c.write(MANAGER+0x3C,4,INFO);c.write(0x1AB7CDC,4,OWNER)
    c.write(OWNER,4,VTABLE);c.write(OWNER+0x3C08,4,0);c.write(OWNER+0x4C10,1,int(dual));c.write(OWNER+0x4C0C,4,bank)
    secure={INFO+0x24:old}
    for j in range(2):
        ptr=SKILL+j*0x1000;c.write(OWNER+0x4414+j*0x3FC+174*4,4,ptr)
        secure[ptr+0x590]=3+j;secure[ptr+0x59C]=19+j
    phases=[];calls=[];writes=[];switches=[];packet_reads=[];profile_lookups=0
    def run(start,ends):
        nonlocal profile_lookups
        c.pc=start
        for _ in range(3000):
            if c.pc in ends:
                phases.append({'start':hex(start),'end':hex(c.pc),'stack':hex(c.reg['esp'])});return
            arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
            if c.pc==0x11AEA00:
                if [arg(0),arg(1)]!=[FRAME-0x434,1]:raise ValueError('Local packet byte ABI')
                c.write(arg(0),1,new);packet_reads.append(new);pop=0
            elif c.pc in (0x1195EB0,0x1195A10):
                this=c.reg['ecx'];write=c.pc==0x1195A10
                if this not in secure or arg(1 if write else 0)!=this+8:raise ValueError('Local secure ABI')
                if write:
                    if this not in (INFO+0x24,SKILL+0x590,SKILL+0x1590):raise ValueError('Local unexpected write')
                    secure[this]=c.read(arg(0),4)
                    writes.append({'target':'profile' if this==INFO+0x24 else f'bank{(this-SKILL)//0x1000}',
                        'field':'0x24' if this==INFO+0x24 else '0x590','value':signed(secure[this])})
                else:
                    if this!=INFO+0x24:raise ValueError('Unexpected profile read')
                    c.write(arg(1),4,secure[this])
                pop=8
            elif c.pc in (0xCD9E50,0x84D000):
                if c.reg['ecx']!=OWNER:raise ValueError('Local rebuild owner')
                calls.append({'service':'rebuild' if c.pc==0xCD9E50 else 'refresh','bank':c.read(OWNER+0x4C0C,4)});pop=0
            else:
                if c.pc==0x91BA90:
                    if c.reg['ecx']!=MANAGER:raise ValueError('Profile manager ABI')
                    profile_lookups+=1
                if c.pc==0x83DB80:
                    if c.reg['ecx']!=OWNER:raise ValueError('Local bank setter ABI')
                    switches.append(arg(0))
                if c.pc==0x844880:
                    if c.reg['ecx']!=OWNER or [arg(0),arg(1)]!=[174,new]:raise ValueError('Local skill setter ABI')
                    calls.append({'service':'set_base','bank':c.read(OWNER+0x4C0C,4),'rank':arg(1)})
                stop=c.run(c.pc,1)
                if stop[0]=='budget':continue
                i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
                if stop[0]=='call':
                    target=int(stop[2],16)
                    if target not in (0x11AEA00,0x1195EB0,0x1195A10,0x91BA90,0x83DB80,0x844880,0x8406C0,0xCD9E50,0x84D000):raise ValueError(f'Unknown local call {target:#x}')
                    c.push(c.pc+i.size);c.pc=target;continue
                if stop[0]=='unsupported' and i.mnemonic=='imul' and len(i.operands)==3:
                    dst,left,right=i.operands;product=signed(c.get(i,left))*signed(c.get(i,right));c.put(i,dst,product&0xFFFFFFFF)
                    c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=product<=2147483647 else 0);c.pc+=i.size;continue
                raise ValueError(f'Local stop {stop}')
            c.pc=c.pop();c.reg['esp']+=pop;c.reg['eax']=0
            c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
        raise ValueError('Local instruction budget')
    run(0x735618,{0x735645})
    # The omitted packet fields and UI work have a balanced stack before
    # 7357B1. This prepared-frame adjustment is not native transport execution.
    c.reg['esp']=FRAME-0x510
    run(0x7357A2,{0x7357DC,0x735B04})
    if c.pc==0x7357DC:
        run(0x73582E,{0x735834})  # Original instruction saves the old value in EDI.
        run(0x735862,{0x73588D})
        run(0x735A06,{0x735AA6,0x844892})
    return {'fixture':{'old':old,'new':new,'dual':dual,'bank':bank,'poison':poison},
        'packet_reads':packet_reads,'profile_lookups':profile_lookups,'profile_value':signed(secure[INFO+0x24]),
        'calls':calls,'writes':writes,'switches':switches,'final_bank':c.read(OWNER+0x4C0C,4),
        'ranks':[[signed(secure[SKILL+j*0x1000+o]) for o in (0x590,0x59C)] for j in range(2)],
        'phases':phases,'stop':hex(c.pc),'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify(row):
    f=row['fixture'];change=f['old']!=f['new'];delete=change and f['new']==0
    banks=([0,1] if f['dual'] else [f['bank']]) if change and not delete else []
    writes=[{'target':'profile','field':'0x24','value':f['new']}] if change else []
    calls=[];ranks=[[3,19],[4,20]]
    for b in banks:
        writes.append({'target':f'bank{b}','field':'0x590','value':f['new']});ranks[b][0]=f['new']
        calls.extend([{'service':'set_base','bank':b,'rank':f['new']},{'service':'rebuild','bank':b},{'service':'refresh','bank':b}])
    if delete:calls=[{'service':'set_base','bank':0 if f['dual'] else f['bank'],'rank':0}]
    switches=([0] if delete else [0,1,f['bank']]) if change and f['dual'] else []
    final_bank=0 if delete and f['dual'] else f['bank']
    stop='0x844892' if delete else '0x735aa6' if change else '0x735b04'
    if (row['packet_reads'],row['profile_lookups'],row['profile_value'],row['calls'],row['writes'],row['switches'],row['final_bank'],row['ranks'],row['stop'])!=([f['new']],2 if change else 1,f['new'],calls,writes,switches,final_bank,ranks,stop):raise ValueError('Local sync mismatch')
    phases=[('0x735618','0x735645',FRAME-0x508),('0x7357a2','0x7357dc' if change else '0x735b04',FRAME-0x500)]
    if change:phases.extend([('0x73582e','0x735834',FRAME-0x500),('0x735862','0x73588d',FRAME-0x500),
        ('0x735a06',stop,FRAME-0x518 if delete else FRAME-0x500)])
    if row['phases']!=[{'start':a,'end':b,'stack':hex(c)} for a,b,c in phases]:raise ValueError('Local sync phase ABI mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    runs=[];traces=[]
    for old,new in ((0,0),(0,1),(1,2),(59,60),(60,59),(60,60),(1,0),(100,255),(255,100),(255,255)):
        for dual in (False,True):
            for bank in (0,1):
                for poison in (False,True):
                    r,t=replay(source,old=old,new=new,dual=dual,bank=bank,poison=poison);verify(r);runs.append(r);traces.append(t)
    provenance=[]
    for start,end in ((0x74D5AA,0x74D5B6),(0x7355A0,0x735618),(0x7357DC,0x735862),
        (0x73588D,0x735A06),(0x735AA6,0x735ABD)):
        raw=source.source_bytes(start,end-start)
        provenance.append({'start':hex(start),'end':hex(end),'sha256':hashlib.sha256(raw).hexdigest(),
            'instructions':[f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in source.decoder.disasm(raw,start)]})
    names=('audit_dnf_basic_mastery_local_sync.py','audit_dnf_basic_mastery_sync.py','audit_dnf_basic_mastery.py',
        'audit_dnf_firewave.py','audit_dnf_ice_shatter.py','audit_dnf_ice_particle_bindings.py',
        'audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    return {'schema':'dnf_basic_mastery_local_sync/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
        'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
        'runs':runs,'blocks':source_blocks(source,traces),'static_provenance':provenance,'boundaries':[
            'Static registration maps message 0x25 to 7355A0; this is not a claim about server protocol names or login initialization.',
            'Five explicit fragments share one CPU/profile/skill fixture: input byte, change comparison, old-value register save, profile write, bank synchronization.',
            'Transport, other packet fields and UI spans are omitted; the prepared-frame stack adjustment is explicit. Full handler preconditions are not executed.',
            '91BA90 executes its cached profile getter; 83DB80, 844880 nonzero setter and 8406C0 cached skill lookup execute source instructions.',
            'Changed zero reaches 844892 deletion entry and stops before cleanup; no cache deletion, bank restoration or callbacks are claimed on that path.',
            'CD9E50/84D000 rebuild and refresh are ABI events. Effective ranks remain sentinel fixtures; full rank rebuild is still unresolved.',
            'This handler compares inequality, unlike the separate growth-only 509930 path. Profile field semantics, initial skill loading and final damage are still unresolved.',
            'No native process is launched and no runtime rank behavior changes in this batch.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite source')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[BASIC_MASTERY_LOCAL_SYNC] {len(e['runs'])} original fragment paths")


if __name__=='__main__':main()

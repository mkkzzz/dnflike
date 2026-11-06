"""Native byte input -> growth gate -> skill 174 writes in one/two banks.

The profile field's complete semantic origin is not certified. Rebuild/refresh
are ABI boundaries: no claim that the written base rank is the effective rank.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
from audit_dnf_basic_mastery import OWNER,SKILL,VTABLE
from audit_dnf_firewave import extra_step
from audit_dnf_ice_shatter import signed
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
from audit_dnf_native_strings import ENGINE_SHA

INFO,DATA,OBSERVER,FRAME=0x60500000,0x60600000,0x60700000,0x6FFFFE00


def read_byte(source,value,*,poison=False):
    from dnf_native_vm_probe import CPU
    if type(value)!=int or not 0<=value<=255:raise ValueError('Unsigned byte input')
    c=CPU(source)
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.reg.update(ebp=FRAME,esp=FRAME-0x400,ebx=0,esi=29,edi=31);c.pc=0x50B02B
    reads=[];writes=[]
    for _ in range(100):
        if c.pc==0x50B068:break
        arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
        if c.pc==0x11AEA00:
            if [arg(0),arg(1)]!=[FRAME-0x379,1]:raise ValueError('Byte input ABI')
            reads.append({'bytes':1,'value':value});c.write(arg(0),1,value);pop=0
        elif c.pc==0x1195A10:
            if c.reg['ecx']!=FRAME-0x364 or arg(1)!=c.reg['ecx']+8:raise ValueError('Profile byte target')
            writes.append({'offset':'0x14','value':signed(c.read(arg(0),4))});pop=8
        else:
            stop=c.run(c.pc,1)
            if stop[0]=='budget':continue
            if stop[0]=='call' and int(stop[2],16) in (0x11AEA00,0x1195A10):
                i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1));c.push(c.pc+i.size);c.pc=int(stop[2],16);continue
            raise ValueError(f'Byte reader stop {stop}')
        c.pc=c.pop();c.reg['esp']+=pop;c.reg['eax']=0xBAD0C0DE
        c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
    else:raise ValueError('Byte reader budget')
    return {'fixture':{'value':value,'poison':poison},'reads':reads,'writes':writes,
        'abi':[c.reg[k] for k in ('ebx','esi','edi','ebp','esp')],
        'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify_byte(row):
    v=row['fixture']['value']
    if row['reads']!=[{'bytes':1,'value':v}] or row['writes']!=[{'offset':'0x14','value':v}]:raise ValueError('Byte decode mismatch')
    if row['abi']!=[0,29,31,FRAME,FRAME-0x400]:raise ValueError('Byte reader ABI mismatch')


def sync(source,*,old=59,new=60,profile_kind=0,observer_exists=True,current_observer=True,actor_exists=True,
         dual=False,bank=0,poison=False):
    from dnf_native_vm_probe import CPU
    if type(old)!=int or not 0<=old<=255 or type(new)!=int or not 0<=new<=255 or bank not in (0,1):raise ValueError('Sync fixture domain')
    c=CPU(source)
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.write(0x70000004,4,INFO);c.write(0x70000008,4,DATA)
    c.write(INFO+0x30,4,profile_kind);c.write(INFO+0x398,4,OBSERVER if observer_exists else 0)
    c.write(0x1AB7CE0,4,OBSERVER if current_observer else OBSERVER+0x100)
    c.write(0x1AB7CDC,4,OWNER if actor_exists else 0)
    c.write(OWNER,4,VTABLE);c.write(OWNER+0x3C08,4,0);c.write(OWNER+0x4C10,1,int(dual));c.write(OWNER+0x4C0C,4,bank)
    secure={INFO+0x24:old&0xFFFFFFFF,DATA+0x14:new}
    for j in range(2):
        ptr=SKILL+j*0x1000;c.write(OWNER+0x4414+j*0x3FC+174*4,4,ptr)
        secure[ptr+0x590]=3+j;secure[ptr+0x59C]=19+j
    c.reg.update(ebx=17,esi=29,edi=31,ebp=37);c.pc=0x509930
    writes=[];calls=[];switches=[];reads=[];xmm={f'xmm{j}':0 for j in range(8)}
    for _ in range(3000):
        if c.pc in (0x5099C2,0x80A755,0x80A75B):break
        arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
        if c.pc in (0x1195EB0,0x1195A10):
            this=c.reg['ecx'];write=c.pc==0x1195A10
            if this not in secure or arg(1 if write else 0)!=this+8:raise ValueError('Sync secure ABI')
            if write:
                if this not in (SKILL+0x590,SKILL+0x1590):raise ValueError('Unexpected rank write')
                secure[this]=c.read(arg(0),4);writes.append({'bank':(this-SKILL)//0x1000,'field':'0x590','value':signed(secure[this])})
            else:
                reads.append('old' if this==INFO+0x24 else 'new' if this==DATA+0x14 else hex(this));c.write(arg(1),4,secure[this])
            pop=8
        elif c.pc in (0xCD9E50,0x84D000):
            if c.reg['ecx']!=OWNER:raise ValueError('Rebuild owner ABI')
            calls.append({'service':'rebuild' if c.pc==0xCD9E50 else 'refresh','bank':c.read(OWNER+0x4C0C,4)})
            pop=0
        else:
            if c.pc==0x83DB80:
                if c.reg['ecx']!=OWNER:raise ValueError('Bank setter owner')
                switches.append(arg(0))
            if c.pc==0x844880:
                if c.reg['ecx']!=OWNER or [arg(0),arg(1)]!=[174,new]:raise ValueError('Skill setter ABI')
                calls.append({'service':'set_base','bank':c.read(OWNER+0x4C0C,4),'id':arg(0),'rank':arg(1)})
            stop=c.run(c.pc,1)
            if stop[0]=='budget':continue
            i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
            if stop[0]=='call':
                target=int(stop[2],16)
                if target not in (0x9197C0,0x80A680,0x83DB80,0x844880,0x8406C0,0xCD9E50,0x84D000,0x1195EB0,0x1195A10):raise ValueError(f'Unknown sync call {target:#x}')
                c.push(c.pc+i.size);c.pc=target;continue
            if stop[0]=='unsupported':
                if i.mnemonic=='imul' and len(i.operands)==3:
                    dst,left,right=i.operands;product=signed(c.get(i,left))*signed(c.get(i,right));c.put(i,dst,product&0xFFFFFFFF)
                    c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=product<=2147483647 else 0);c.pc+=i.size;continue
                extra_step(c,xmm,i);continue
            raise ValueError(f'Sync stop {stop}')
        c.pc=c.pop();c.reg['esp']+=pop;c.reg['eax']=0
        c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
    else:raise ValueError('Sync instruction budget')
    return {'fixture':{'old':old,'new':new,'profile_kind':profile_kind,'observer_exists':observer_exists,
        'current_observer':current_observer,'actor_exists':actor_exists,'dual':dual,'bank':bank,'poison':poison},
        'reads':reads,'writes':writes,'calls':calls,'switches':switches,'final_bank':c.read(OWNER+0x4C0C,4),
        'ranks':[[signed(secure[SKILL+j*0x1000+o]) for o in (0x590,0x59C)] for j in range(2)],
        'stop':hex(c.pc),'stack':hex(c.reg['esp']),'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify_sync(row):
    f=row['fixture'];growth=f['old']!=0 and f['new']>f['old'];notify=growth and f['profile_kind'] in (0,6) and f['observer_exists']
    update=notify and f['current_observer'] and f['actor_exists'];banks=([0,1] if f['dual'] else [f['bank']]) if update else []
    reads=['old']+(['new','old'] if f['old'] else [])+(['new'] if notify else [])
    writes=[{'bank':b,'field':'0x590','value':f['new']} for b in banks]
    calls=[];ranks=[[3,19],[4,20]]
    for b in banks:
        calls.extend([{'service':'set_base','bank':b,'id':174,'rank':f['new']},{'service':'rebuild','bank':b},{'service':'refresh','bank':b}]);ranks[b][0]=f['new']
    switches=[0,1,f['bank']] if update and f['dual'] else []
    stop='0x80a755' if update else '0x80a75b' if notify else '0x5099c2'
    if (row['reads'],row['writes'],row['calls'],row['switches'],row['ranks'],row['final_bank'],row['stop'])!=(reads,writes,calls,switches,ranks,f['bank'],stop):raise ValueError('Rank sync mismatch')
    if row['stack']!=('0x6fffff9c' if notify else '0x6fffffe4'):raise ValueError('Sync stack mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    traces=[];bytes_in=[];events=[]
    for value in (0,1,2,60,100,127,128,255):
        for poison in (False,True):
            r,t=read_byte(source,value,poison=poison);verify_byte(r);bytes_in.append(r);traces.append(t)
    cases=[{}, {'old':0,'new':1},{'old':0,'new':60},{'old':60},{'old':61},{'new':0},
        {'profile_kind':1},{'profile_kind':6},{'profile_kind':7},{'observer_exists':False},
        {'current_observer':False},{'actor_exists':False}]
    cases.extend({'old':old,'new':new} for old,new in ((1,2),(2,10),(99,100),(100,255)))
    for bank in (0,1):
        for dual in (False,True):
            for poison in (False,True):
                for case in cases:
                    r,t=sync(source,**case,bank=bank,dual=dual,poison=poison);verify_sync(r);events.append(r);traces.append(t)
    names=('audit_dnf_basic_mastery_sync.py','audit_dnf_basic_mastery.py','audit_dnf_firewave.py',
        'audit_dnf_ice_shatter.py','audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py',
        'audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    return {'schema':'dnf_basic_mastery_sync/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
        'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
        'input':bytes_in,'events':events,'blocks':source_blocks(source,traces),'boundaries':[
            '50B02B..50B068 unsigned packet-byte conversion into incoming record +14 executes; transport and secure write are ABI fixtures.',
            '509930 growth predicate, 9197C0 kind predicate, 80A680 prefix, 83DB80 bank setter, 844880 nonzero rank setter and 8406C0 cached lookup execute original bytes.',
            'Notification connects incoming +14 to skill 174 +590. Complete profile-field semantics and the actor level-stat production chain are still unresolved.',
            'Profile kind 0/6 is tested without guessing job/mode names. First load with old value zero does not enter this growth path.',
            'CD9E50 rebuild and 84D000 refresh are ABI event boundaries; effective ranks deliberately remain sentinel fixtures, not production results.',
            'UI suffix after 80A755/80A75B and notification suffix after 5099C2 are excluded. Initial skill loading, missing-cache allocation and final damage remain unresolved.',
            'Packet input and notification are composed as field-value evidence, not full network processing. No runtime rank or basic mastery implementation change.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite source')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[BASIC_MASTERY_SYNC] {len(e['input'])} byte paths / {len(e['events'])} notification paths")


if __name__=='__main__':main()

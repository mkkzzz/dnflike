"""Native 904550 two-vector skill modifier aggregation and mode predicates.

Runs original function, owner virtual getter and 75C090/752850/7527D0 mode
dispatch with original known vtables. Secure reads, singleton and mode decoding
are explicit ABI fixtures; modifier rows/owner classification are synthetic.
An optional original 26-slot loop fragment uses callsite lookup/item fixtures.
No equipment-record loader, full 907D40 or final damage claim. x87 uses Python
binary64, not an 80-bit/control-word emulator.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
from audit_dnf_firewave import extra_step
from audit_dnf_ice_shatter import fbits,real,signed
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
from audit_dnf_native_strings import ENGINE_SHA

SKILL,OWNER,MODIFIER,MANAGER,MODULE=0x60000000,0x60100000,0x60200000,0x60300000,0x60400000
BANKS=(0x60500000,0x60600000)
MODE_VTABLES={0:0x15B0FEC,1:0x15B105C,2:0x15B10D4,3:0x1829E54,5:0x15B1354}
# classification, skill ID, column, category, mode predicate, percent kind, amount
DEFAULT_BANKS=(((11,20,0,1,20,1,10),(11,20,0,1,20,0,3)),
               ((11,20,0,1,20,1,20),(11,20,0,1,20,0,7)))
FIXTURES={0x1195EB0,0x1195B90,0x6FC760}
NATIVE={0x904550,0x75C090,0x752850,0x7527D0,0xD09590,0xE4F970,0x43DE80}
SLOT_FRAME,ITEM,ITEM_VTABLE=0x6FFFFF00,0x60700000,0x60710000


def f32(v):return real(fbits(v))


def replay(source,*,banks=DEFAULT_BANKS,value=100.0,skill_id=20,column=0,category=1,
           phase=2,owner_kind=0,mode=3,has_module=True,has_owner=True,has_modifier=True,poison=False,slots=None):
    from dnf_native_vm_probe import CPU
    c=CPU(source)
    for a in range(0x6FFFF000,0x70000000,4):c.write(a,4,0)
    c.write(OWNER,4,0x16F972C);c.write(OWNER+0x3C08,4,owner_kind)
    c.write(MANAGER+0xA4,4,0x12345678)
    for m in range(17):c.write(MANAGER+0xA8+m*4,4,0)
    if has_module and mode in MODE_VTABLES:
        c.write(MANAGER+0xA8+mode*4,4,MODULE);c.write(MODULE,4,MODE_VTABLES[mode])
    secure={}
    for bank,rows in enumerate(banks):
        begin=BANKS[bank];offset=(0x4A4,0x4CC)[bank]
        c.write(MODIFIER+offset,4,begin);c.write(MODIFIER+offset+4,4,begin+len(rows)*52)
        for j,(kind,sid,col,flag,restriction,percentage,amount) in enumerate(rows):
            base=begin+j*52
            for off,v in ((0,kind),(0x10,col),(0x2C,flag),(0x30,restriction)):c.write(base+off,4,v)
            for off,v in ((4,sid),(0x14,percentage),(0x20,amount)):secure[base+off]=v&0xFFFFFFFF
    saved={'ebx':0x12345678,'esi':0x23456789,'edi':0x3456789A,'ebp':0x456789AB}
    c.reg.update(saved);c.reg['ecx']=SKILL
    args=(OWNER if has_owner else 0,fbits(value),column,category,skill_id,MODIFIER if has_modifier else 0,phase)
    for j,v in enumerate(args):c.write(0x70000004+j*4,4,v)
    events=[];fp=[];xmm={f'xmm{j}':0 for j in range(8)};c.pc=0x904550
    if slots is not None:
        if not has_owner or not has_modifier:raise ValueError('Slot fragment assumes present owner/context')
        # Item virtual calls are callsite ABI fixtures; placeholder slots are
        # read but never executed or advertised as original item vtable targets.
        c.write(ITEM,4,ITEM_VTABLE)
        for off in (0x104,0xF4,0x16C):c.write(ITEM_VTABLE+off,4,0)
        c.reg.update(ebp=SLOT_FRAME,esp=SLOT_FRAME-0x200,edi=OWNER)
        c.write(SLOT_FRAME-0x34,4,SKILL)
        for j,v in enumerate((OWNER,fbits(value),column,category,skill_id,phase)):
            c.write(SLOT_FRAME+8+j*4,4,v)
        saved={'ebp':SLOT_FRAME,'edi':OWNER};c.pc=0x907E09
    for _ in range(100000):
        if slots is not None and c.pc==0x907EA5:
            stop=('boundary','0x907ea5');break
        if slots is not None and c.pc in (0x907E1B,0x907E2D,0x907E3D,0x907E71):
            index=c.reg['ebx'];spec=next((r for r in slots if r[0]==index),None)
            i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
            c.trace.append(f'{i.address:08X} {i.mnemonic} {i.op_str}')
            if c.pc==0x907E1B:
                if c.read(c.reg['esp'],4)!=index or c.reg['ecx']!=OWNER:raise ValueError('Wrong slot lookup ABI')
                result=ITEM if spec else 0;c.reg['esp']+=4;kind='slot_lookup_fixture'
            else:
                if spec is None or c.reg['ecx']!=ITEM:raise ValueError('Wrong item virtual ABI')
                if c.pc==0x907E2D:result=int(spec[1]);kind='item_enabled_fixture'
                else:
                    result=MODIFIER if spec[2 if c.pc==0x907E3D else 3] else 0
                    kind='item_primary_fixture' if c.pc==0x907E3D else 'item_secondary_fixture'
            events.append({'kind':kind,'callsite':hex(c.pc),'slot':index,'result':result})
            c.reg['eax']=result;c.pc+=i.size
            c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
            for name in xmm:xmm[name]=0x0123456789ABCDEF if poison else 0
            continue
        if c.pc in FIXTURES:
            target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
            result=0;pop=0;e={'target':hex(target)}
            if target==0x6FC760:result=MANAGER;e['kind']='singleton_fixture'
            elif target==0x1195B90:
                if c.read(arg(0),4)!=0x12345678:raise ValueError('Unmodeled mode handle')
                c.write(arg(1),4,mode);e.update(kind='mode_decode_fixture',value=mode)
            else:
                if this not in secure or arg(0)!=this+8:raise ValueError('Unmodeled secure field')
                c.write(arg(1),4,secure[this]);pop=8;e.update(kind='secure_read_fixture',this=hex(this),value=signed(secure[this]))
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
        if stop[0]!='unsupported':raise ValueError(f'Unmodeled stop {stop}')
        op=i.operands[0]
        if i.mnemonic=='imul' and len(i.operands)==1 and op.size==4:
            product=signed(c.reg['eax'])*signed(c.get(i,op));c.reg['eax']=product&0xFFFFFFFF;c.reg['edx']=(product>>32)&0xFFFFFFFF
            c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=product<=2147483647 else 0)
        elif i.mnemonic=='addss':
            dst,src=i.operands;name=i.reg_name(dst.reg)
            b=xmm[i.reg_name(src.reg)] if src.type==1 else c.get(i,src)
            xmm[name]=(xmm[name]&~0xFFFFFFFF)|fbits(real(xmm[name])+real(b))
        elif i.mnemonic=='fild' and op.size==4:fp.append(float(signed(c.get(i,op))))
        elif i.mnemonic=='fld' and op.size==4:fp.append(real(c.get(i,op)))
        elif i.mnemonic=='fadd' and op.size==4:fp[-1]+=real(c.get(i,op))
        elif i.mnemonic=='fstp' and op.size==4:
            if len(fp)!=1:raise ValueError('Wrong slot floating stack')
            c.put(i,op,fbits(fp.pop()))
        else:extra_step(c,xmm,i);continue
        c.pc+=i.size
    else:raise ValueError('Instruction budget exceeded')
    returned=real(c.read(SLOT_FRAME+0xC,4)) if slots is not None else fp[-1] if fp else None
    return {'fixture':dict(banks=[[list(r) for r in b] for b in banks],value=value,skill_id=skill_id,column=column,
                category=category,phase=phase,owner_kind=owner_kind,mode=mode,has_module=has_module,
                has_owner=has_owner,has_modifier=has_modifier,poison=poison,slots=slots),
            'value':returned,'binary32_bits':fbits(returned) if returned is not None else None,'fp_depth':len(fp),
            'events':events,'stop':list(stop),'stack':hex(c.reg['esp']),
            'preserved':{name:c.reg[name]==v for name,v in saved.items()},
            'steps':len(c.trace),'branches':c.branches,'trace_sha256':trace_hash(c.trace)},c.trace


def expected(f):
    value=f32(f['value']);add=percent=0
    if f['slots'] is not None:
        inner=dict(f,slots=None)
        for index in range(26):
            spec=next((r for r in f['slots'] if r[0]==index),None)
            if not spec or not spec[1]:continue
            for present in spec[2:]:
                inner.update(value=value,has_modifier=present);value=f32(expected(inner))
        return value
    if not f['has_owner'] or not f['has_modifier']:return value
    for rows in f['banks']:
        for kind,sid,col,flag,restriction,percentage,amount in rows:
            mode_ok=(restriction==20 or restriction==f['mode'] or
                restriction==18 and f['mode'] in (4,5,7,9) or
                restriction==19 and (f['mode']==2 or f['mode']==3 and f['has_module']))
            if flag!=f['category'] or sid!=f['skill_id'] or not mode_ok or col!=f['column'] or kind not in (11,f['owner_kind']):continue
            if percentage and f['phase'] in (0,2):percent=signed((percent+amount)&0xFFFFFFFF)
            if not percentage and f['phase'] in (1,2):add=signed((add+amount)&0xFFFFFFFF)
    if percent:value=f32(value+f32(f32(f32(percent)*f32(.01))*value))
    return float(add)+value


def verify(row):
    slots=row['fixture']['slots'];is_slots=slots is not None
    if row['stop']!=(['boundary','0x907ea5'] if is_slots else ['returned']) or row['stack']!=(hex(SLOT_FRAME-0x200) if is_slots else '0x70000020') or row['fp_depth']!=(0 if is_slots else 1) or not all(row['preserved'].values()):raise ValueError('Return/ABI mismatch')
    if is_slots:
        lookups=[e['slot'] for e in row['events'] if e['kind']=='slot_lookup_fixture']
        if lookups!=list(range(26)):raise ValueError('Slot traversal mismatch')
        for kind in ('item_primary_fixture','item_secondary_fixture'):
            indices=[e['slot'] for e in row['events'] if e['kind']==kind]
            if indices!=sorted(r[0] for r in slots if 0<=r[0]<26 and r[1]):raise ValueError('Item enable gate mismatch')
    value=expected(row['fixture'])
    if row['value']!=value or row['binary32_bits']!=fbits(value):raise ValueError('Modifier aggregation mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    fixtures=[dict(phase=p) for p in (0,1,2,3)]
    fixtures += [dict(has_owner=False),dict(has_modifier=False),dict(banks=([],[])),dict(banks=([],DEFAULT_BANKS[1])),dict(banks=(DEFAULT_BANKS[0],[]))]
    fixtures += [dict(category=0),dict(category=257),dict(skill_id=21),dict(column=1)]
    for index,value in ((0,0),(0,1),(1,21),(2,1),(3,0),(5,-1)):
        row=list(DEFAULT_BANKS[0][0]);row[index]=value;fixtures.append(dict(banks=([row],[])))
    for restriction in (1,2,3,5,18,19,20):
        row=(11,20,0,1,restriction,1,10)
        for mode in (1,2,3,4,5,7,9):fixtures.append(dict(banks=([row],[]),mode=mode))
    for mode in (1,2,3,5):fixtures.append(dict(banks=([(11,20,0,1,19,1,10)],[]),mode=mode,has_module=False))
    fixtures += [dict(value=-12.5),dict(banks=([(11,20,0,1,20,1,-10)],[])),
        dict(value=16777216,banks=([(11,20,0,1,20,0,1)],[])),
        dict(banks=([(11,20,0,1,20,0,2147483647)],[(11,20,0,1,20,0,1)])),
        dict(banks=([DEFAULT_BANKS[0][1],DEFAULT_BANKS[0][0]],list(reversed(DEFAULT_BANKS[1])))),
        dict(banks=([(11,20,0,1,20,1,10)],[(11,20,0,1,20,1,-10)]))]
    fixtures += [dict(slots=s) for s in ([],[(0,True,True,False)],[(0,True,True,True)],
        [(0,False,True,True),(25,True,False,True),(26,True,True,True)],[(0,True,False,False)],
        [(2,True,True,True),(10,True,True,True)])]
    runs=[];traces=[]
    for fixture in fixtures:
        for poison in (False,True):
            row,trace=replay(source,poison=poison,**fixture);verify(row);runs.append(row);traces.append(trace)
    names=('audit_dnf_item_skill_modifier.py','audit_dnf_firewave.py','audit_dnf_ice_shatter.py',
           'audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    return {'schema':'dnf_item_skill_modifier/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
            'method':__doc__.strip(),'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
            'boundaries':['Full 904550 entry/return, 52-byte row filtering, two-vector integer aggregation and native mode dispatch run.',
                'Rows, owner +3C08 classification and manager table entries are synthetic; vtables/getter targets are original. Only known modes 0/1/2/3/5 can have fixture modules.',
                'Secure storage and manager acquisition/decoding are ABI fixtures. Original equipment/PVF field producers are excluded.',
                'Optional 907E09..907EA5 slot fragment runs original 26-slot loop, enable gate, both 904550 calls and binary32 stores; item lookup/virtual results are explicit callsite fixtures. Full 907D40 prologue and subsequent owner/state branches are excluded.',
                'Percent portion uses native binary32 operations; final integer addition returns through x87. binary32_bits records an explicit prospective caller store, not an instruction in this function.',
                'No full x87 precision/control-word/exception emulation or final skill/damage claim.'],
            'vtables':{'owner':{'address':'0x16f972c','slot':'0x738','target':hex(int.from_bytes(source.source_bytes(0x16F972C+0x738,4),'little'))},
                'modes':{str(m):{'address':hex(v),'slot_28':hex(int.from_bytes(source.source_bytes(v+0x28,4),'little'))} for m,v in MODE_VTABLES.items()}},
            'runs':runs,'blocks':source_blocks(source,traces)}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path)
    p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite client')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    result=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(result,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[ITEM_SKILL_MODIFIER] {len(result['runs'])} source paths verified")


if __name__=='__main__':main()

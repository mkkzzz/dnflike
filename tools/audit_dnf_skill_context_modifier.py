"""Original 907D40 context modifier and 904800 ordered state records.

Full function entries/returns, native slot lookup, both modifier algorithms,
state getters and tree iteration run in one bounded CPU. Item virtual results,
range-key vector production, secure storage and profiler services are ABI
fixtures. Synthetic object fields do not establish a complete item lifecycle.
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
from audit_dnf_item_skill_modifier import DEFAULT_BANKS,MODE_VTABLES,f32,expected as equipment_expected

SKILL,OWNER,MODIFIER,MANAGER,MODULE=0x60000000,0x60100000,0x60200000,0x60300000,0x60400000
DATA,ITEMS,ITEM_VTABLE,STATE,LEVEL_OBJECT,LEVEL_VTABLE,LEVEL_MANAGER=0x60500000,0x60600000,0x60700000,0x60800000,0x60900000,0x60910000,0x60920000
TREE,PROXY,PAYLOADS=0x60A00000,0x60A10000,0x60B00000
DEFAULT_ROWS=tuple(r for bank in DEFAULT_BANKS for r in bank)
FIXTURES={0x1195EB0,0x1195B90,0x6FC760,0x1183720,0x11833D0,0x412130,0x1182340,
          0x13CADD7,0x13CC5BA,0x6EB4A0,0x485C90}
NATIVE={0x907D40,0x904550,0x904800,0x4EB120,0x75C090,0x752850,0x7527D0,0xD09590,
        0xE4F970,0x43DE80,0x844850,0x843410,0x750970,0x8312D0,0x779B10,0x779A50,
        0x83E580,0x83E5A0,0x80EEA0,0x485870,0x45F8B0,0x110F7C0,0x6EBE50,0x13CC488}


def replay(source,*,entry='context',banks=DEFAULT_BANKS,slots=(),special_rows=None,level_rows=None,
           status_rows=(),value=100.0,skill_id=20,column=0,category=1,phase=2,owner_kind=0,
           mode=3,load_mode=0,has_module=True,has_owner=True,poison=False,warm_profile=True):
    from dnf_native_vm_probe import CPU
    if entry not in ('context','state'):raise ValueError('Unknown entry')
    if any(len(s)!=6 or not 0<=s[0]<26 or s[1] not in (0,1) for s in slots):raise ValueError('Unsupported slot fixture')
    if len({(s[0],s[1]) for s in slots})!=len(slots):raise ValueError('Duplicate slot fixture')
    c=CPU(source);secure={};events=[];allocated=DATA;vectors={}
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.write(OWNER,4,0x16F972C);c.write(OWNER+0x3C08,4,owner_kind)
    secure[OWNER+0x5668]=int(special_rows is not None)
    c.write(OWNER+0x5664,4,STATE);c.write(OWNER+0x551D,1,int(level_rows is not None));c.write(OWNER+0x560C,4,LEVEL_OBJECT)
    c.write(MANAGER+0xA4,4,0x12345678);c.write(MANAGER+0xF90,4,load_mode)
    c.write(0x1AB7C88,4,int(warm_profile));c.write(0x1A5AA44,4,LEVEL_MANAGER)
    c.write(LEVEL_OBJECT,4,LEVEL_VTABLE);c.write(LEVEL_VTABLE+0x238,4,0)
    for off in (0x104,0xF4,0x16C):c.write(ITEM_VTABLE+off,4,0)
    for m in range(17):c.write(MANAGER+0xA8+m*4,4,0)
    if has_module and mode in MODE_VTABLES:
        c.write(MANAGER+0xA8+mode*4,4,MODULE);c.write(MODULE,4,MODE_VTABLES[mode])

    def vector(address,rows,label):
        nonlocal allocated
        begin=allocated;allocated+=max(16,len(rows)*52)
        if allocated>=ITEMS:raise ValueError('Row allocation budget')
        for off,val in ((0,0),(4,begin),(8,begin+len(rows)*52),(12,begin+len(rows)*52)):c.write(address+off,4,val)
        for j,(job,sid,col,cat,restriction,percentage,amount) in enumerate(rows):
            base=begin+j*52
            for off,v in ((0,job),(0x10,col),(0x2C,cat),(0x30,restriction)):c.write(base+off,4,v)
            for off,v in ((4,sid),(0x14,percentage),(0x20,amount)):secure[base+off]=v&0xFFFFFFFF
        vectors[address]=label

    for j,rows in enumerate(banks):vector(MODIFIER+(0x4A0,0x4C8)[j],rows,f'equipment:{j}')
    vector(STATE+0x1DF8,special_rows or [],'special')
    if entry=='state':vector(STATE+0x1DF8,DEFAULT_ROWS if special_rows is None else special_rows,'standalone')
    specs={}
    for j in range(26):
        for off in (0x3010,0x37B8,0x4E84):c.write(OWNER+off+j*4,4,0)
    for j,spec in enumerate(slots):
        index,bank,enabled,primary,secondary,equal_shadow=spec;item=ITEMS+j*0x100
        c.write(item,4,ITEM_VTABLE);c.write(OWNER+(0x3010,0x37B8)[bank]+index*4,4,item)
        if equal_shadow:c.write(OWNER+0x4E84+index*4,4,item)
        specs[item]=list(spec)

    # Valid synthetic ordered tree with original iterator layout; insertion and
    # rebalancing are outside this replay. Native begin/end and successor run.
    tree_map=OWNER+0x3858;sentinel=TREE
    c.write(tree_map,4,PROXY);c.write(PROXY,4,tree_map);c.write(tree_map+8,4,sentinel)
    c.write(sentinel+0x11,1,1)
    nodes=[TREE+0x100*(j+1) for j in range(len(status_rows))]
    def link(lo,hi,parent):
        if lo>=hi:return sentinel
        mid=(lo+hi)//2;node=nodes[mid]
        c.write(node+4,4,parent);c.write(node+0x11,1,0)
        c.write(node,4,link(lo,mid,node));c.write(node+8,4,link(mid+1,hi,node))
        rows=status_rows[mid];payload=PAYLOADS+mid*0x1000 if rows is not None else 0
        c.write(node+0xC,4,payload)
        if payload:vector(payload+0xAC,rows,f'status:{mid}')
        return node
    root=link(0,len(nodes),sentinel)
    c.write(sentinel,4,nodes[0] if nodes else sentinel);c.write(sentinel+4,4,root);c.write(sentinel+8,4,nodes[-1] if nodes else sentinel)

    saved={'ebx':0x12345678,'esi':0x23456789,'edi':0x3456789A,'ebp':0x456789AB}
    c.reg.update(saved);c.reg['ecx']=SKILL
    args=[OWNER if has_owner else 0,fbits(value),column,category,skill_id]
    if entry=='state':args.append(STATE+0x1DF8)
    args.append(phase)
    for j,v in enumerate(args):c.write(0x70000004+j*4,4,v)
    fp=[];xmm={f'xmm{j}':0 for j in range(8)}
    clobber=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
    c.string_clobber=clobber;c.pc=0x907D40 if entry=='context' else 0x904800
    for _ in range(200000):
        if c.pc in (0x904550,0x904800):
            arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
            events.append({'kind':'native_modifier','entry':hex(c.pc),'container':vectors.get(arg(5),'equipment' if arg(5)==MODIFIER else 'null'),
                           'value':real(arg(1)),'column':arg(2),'category':arg(3),'skill_id':arg(4),'phase':arg(6)})
        if c.pc==0x844850:events.append({'kind':'native_slot_query','index':c.read(c.reg['esp']+4,4)})
        if c.pc==0x907E1D:
            events.append({'kind':'native_slot_result','index':c.reg['ebx'],'item':hex(c.reg['eax'])})
        if c.pc in (0x907E2D,0x907E3D,0x907E71,0x907F05):
            i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
            c.trace.append(f'{i.address:08X} {i.mnemonic} {i.op_str}')
            if c.pc==0x907F05:
                if c.reg['ecx']!=LEVEL_OBJECT:raise ValueError('Wrong level query receiver')
                result=42;kind='level_key_fixture'
            else:
                spec=specs.get(c.reg['ecx'])
                if spec is None:raise ValueError('Wrong item virtual receiver')
                if c.pc==0x907E2D:result=int(spec[2]);kind='item_enabled_fixture'
                else:result=MODIFIER if spec[3 if c.pc==0x907E3D else 4] else 0;kind='item_source_fixture'
            events.append({'kind':kind,'callsite':hex(c.pc),'result':result})
            c.reg['eax']=result;c.pc+=i.size;c.reg['ecx'],c.reg['edx'],c.flags=clobber
            for name in xmm:xmm[name]=0x0123456789ABCDEF if poison else 0
            continue
        if c.pc in FIXTURES:
            target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4);result=0;pop=0
            if target==0x6FC760:result=MANAGER
            elif target==0x1195B90:
                if c.read(arg(0),4)!=0x12345678:raise ValueError('Wrong mode handle')
                c.write(arg(1),4,mode)
            elif target==0x1195EB0:
                if this not in secure or arg(0)!=this+8:raise ValueError(f'Unmodeled secure field {this:#x}')
                c.write(arg(1),4,secure[this]);pop=8
            elif target==0x1183720:
                if arg(0)!=0x1AB7C40:raise ValueError('Wrong profiler scope')
                pop=4;events.append({'kind':'profile_begin_fixture'})
            elif target==0x11833D0:events.append({'kind':'profile_end_fixture'})
            elif target==0x412130:
                # Only profiling-name storage/destruction is abstracted.
                c.write(this,4,0);c.write(this+0x14,4,0);c.write(this+0x18,4,7);pop=4
            elif target==0x1182340:
                if this!=0x1AB7C40:raise ValueError('Wrong profiler initialization')
                pop=4;events.append({'kind':'profile_init_fixture'})
            elif target==0x6EB4A0:
                if this!=LEVEL_MANAGER or arg(1)!=42 or level_rows is None:raise ValueError('Wrong level-vector query')
                result=arg(0);vector(result,level_rows,'level');pop=8
                events.append({'kind':'level_vector_fixture','key':42,'rows':len(level_rows)})
            elif target==0x485C90:
                if level_rows is None or arg(1)-arg(0)!=len(level_rows)*52:raise ValueError('Wrong destruction range')
                events.append({'kind':'vector_destruct_fixture','rows':len(level_rows)})
            else:events.append({'kind':'free_or_atexit_fixture','entry':hex(target)})
            c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop;c.reg['ecx'],c.reg['edx'],c.flags=clobber
            for name in xmm:xmm[name]=0x0123456789ABCDEF if poison else 0
            continue
        stop=c.run(c.pc,1)
        if stop[0]=='returned':break
        if stop[0]=='budget':continue
        i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
        if stop[0]=='call':
            target=int(stop[2],16)
            if target not in FIXTURES|NATIVE:raise ValueError(f'Unmodeled call {c.pc:#x} -> {target:#x}')
            c.push(c.pc+i.size);c.pc=target;continue
        if stop[0]!='unsupported':raise ValueError(f'Unmodeled stop {stop}')
        if not i.operands:extra_step(c,xmm,i);continue
        op=i.operands[0]
        if i.mnemonic=='imul' and len(i.operands)==1 and op.size==4:
            product=signed(c.reg['eax'])*signed(c.get(i,op));c.reg['eax']=product&0xFFFFFFFF;c.reg['edx']=(product>>32)&0xFFFFFFFF
            c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=product<=2147483647 else 0)
        elif i.mnemonic=='imul' and len(i.operands)==3 and op.size==4:
            product=signed(c.get(i,i.operands[1]))*signed(c.get(i,i.operands[2]));c.put(i,op,product)
            c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=product<=2147483647 else 0)
        elif i.mnemonic=='addss':
            dst,src=i.operands;name=i.reg_name(dst.reg);b=xmm[i.reg_name(src.reg)] if src.type==1 else c.get(i,src)
            xmm[name]=(xmm[name]&~0xFFFFFFFF)|fbits(real(xmm[name])+real(b))
        elif i.mnemonic=='cvtdq2ps':
            dst,src=i.operands;v=xmm[i.reg_name(src.reg)] if src.type==1 else c.get(i,src)
            xmm[i.reg_name(dst.reg)]=sum(fbits(signed((v>>(32*j))&0xFFFFFFFF))<<(32*j) for j in range(4))
        elif i.mnemonic=='fild' and op.size==4:fp.append(float(signed(c.get(i,op))))
        elif i.mnemonic=='fld' and op.size==4:fp.append(real(c.get(i,op)))
        elif i.mnemonic=='fadd' and op.size==4:fp[-1]+=real(c.get(i,op))
        elif i.mnemonic=='fstp' and op.size==4:
            if len(fp)!=1:raise ValueError('Wrong floating stack')
            c.put(i,op,fbits(fp.pop()))
        else:extra_step(c,xmm,i);continue
        c.pc+=i.size
    else:raise ValueError('Instruction budget exceeded')
    return {'fixture':dict(entry=entry,banks=[[list(r) for r in b] for b in banks],slots=[list(s) for s in slots],
                special_rows=special_rows,level_rows=level_rows,status_rows=status_rows,value=value,skill_id=skill_id,column=column,
                category=category,phase=phase,owner_kind=owner_kind,mode=mode,load_mode=load_mode,has_module=has_module,
                has_owner=has_owner,poison=poison,warm_profile=warm_profile),
            'value':fp[-1] if fp else None,'binary32_bits':fbits(fp[-1]) if fp else None,'fp_depth':len(fp),
            'events':events,'stop':list(stop),'stack':hex(c.reg['esp']),'preserved':{k:c.reg[k]==v for k,v in saved.items()},
            'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def state_expected(f,rows,value):
    value=f32(value)
    if not f['has_owner']:return value
    for job,skill,col,cat,restriction,percentage,amount in rows:
        mode=f['mode'];mode_ok=(restriction==20 or restriction==mode or restriction==18 and mode in (4,5,7,9) or
            restriction==19 and (mode==2 or mode==3 and f['has_module']))
        if job not in (11,f['owner_kind']) or skill!=f['skill_id'] or col!=f['column'] or cat!=f['category'] or not mode_ok:continue
        if percentage and f['phase'] in (0,2):value=f32(value+f32(f32(f32(amount)*f32(.01))*value))
        if not percentage and f['phase'] in (1,2):value=f32(value+f32(amount))
    return value


def expected(f):
    value=f32(f['value']);chain=[];selected=[]
    def state(rows,label):
        nonlocal value
        chain.append((label,value));value=state_expected(f,rows,value)
    if f['entry']=='state':
        state(DEFAULT_ROWS if f['special_rows'] is None else f['special_rows'],'standalone')
        return value,chain,selected
    if not f['has_owner']:return value,chain,selected
    special=f['special_rows'] is not None
    for index in range(26):
        bank=int(not special and 10<=index<=21 and f['load_mode'] in (14,15,16))
        found=next(((j,s) for j,s in enumerate(f['slots']) if s[0]==index and s[1]==bank),None)
        if found is not None and found[1][5] and not special:found=None
        selected.append(hex(ITEMS+found[0]*0x100) if found is not None else '0x0')
        if found is None or not found[1][2]:continue
        for enabled in found[1][3:5]:
            chain.append(('equipment' if enabled else 'null',value))
            value=f32(equipment_expected(dict(f,value=value,slots=None,has_modifier=enabled)))
    if special:state(f['special_rows'],'special')
    if f['level_rows'] is not None:state(f['level_rows'],'level')
    for j,rows in enumerate(f['status_rows']):
        if rows is not None:state(rows,f'status:{j}')
    return value,chain,selected


def verify(row):
    f=row['fixture'];value,chain,selected=expected(f)
    if row['stop']!=['returned'] or row['stack']!=('0x7000001c' if f['entry']=='context' else '0x70000020') or row['fp_depth']!=1 or not all(row['preserved'].values()):raise ValueError('Return/ABI mismatch')
    if row['value']!=value or row['binary32_bits']!=fbits(value):raise ValueError('Context/state calculation mismatch')
    calls=[e for e in row['events'] if e['kind']=='native_modifier']
    if [(e['container'],e['value']) for e in calls]!=chain:raise ValueError('Source order/value mismatch')
    for e in calls:
        if any(e[k]!=f[k] for k in ('column','category','skill_id','phase')):raise ValueError('Modifier argument mismatch')
    lookups=[e['index'] for e in row['events'] if e['kind']=='native_slot_query']
    if lookups!=(list(range(26)) if f['entry']=='context' and f['has_owner'] else []):raise ValueError('Slot traversal mismatch')
    if [e['item'] for e in row['events'] if e['kind']=='native_slot_result']!=selected:raise ValueError('Native slot selection mismatch')
    profiles=[e['kind'] for e in row['events'] if e['kind'].startswith('profile_')]
    want=([] if f['warm_profile'] else ['profile_init_fixture'])+['profile_begin_fixture','profile_end_fixture'] if f['entry']=='context' else []
    if profiles!=want:raise ValueError('Profiler scope mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    fixtures=[('empty',{}),('cold',dict(warm_profile=False)),('null',dict(has_owner=False)),
              ('null_cold',dict(has_owner=False,warm_profile=False))]
    for phase in (0,1,2,3):fixtures.append((f'state:phase:{phase}',dict(entry='state',phase=phase)))
    for change in (dict(special_rows=[]),dict(has_owner=False),dict(category=0),dict(category=257),dict(column=1),dict(skill_id=21),
                   dict(value=-12.5),dict(special_rows=list(reversed(DEFAULT_ROWS))),
                   dict(special_rows=[(11,20,0,1,20,1,10),(11,20,0,1,20,1,-10)]),
                   dict(value=16777216,special_rows=[(11,20,0,1,20,0,1)]*2)):
        fixtures.append((f'state:case:{len(fixtures)}',dict(entry='state',**change)))
    for field,value in ((0,0),(0,1),(1,21),(2,1),(3,257),(5,-1),(6,-10),(6,2147483647)):
        row=list(DEFAULT_ROWS[0]);row[field]=value
        fixtures.append((f'state:field:{field}:{value}',dict(entry='state',special_rows=[row])))
    for rule in (1,3,5,18,19,20):
        for mode in (1,2,3,4,5,7,9):
            fixtures.append((f'state:mode:{rule}:{mode}',dict(entry='state',special_rows=[(11,20,0,1,rule,1,10)],mode=mode)))
    fixtures.append(('state:no_module',dict(entry='state',special_rows=[(11,20,0,1,19,1,10)],has_module=False)))
    for slot in (0,9,10,11,21,22,25):
        for load_mode in (0,14,15,16):
            fixtures.append((f'slot:{slot}:{load_mode}',dict(load_mode=load_mode,slots=[
                (slot,0,True,True,False,False),(slot,1,True,True,True,False)])))
    fixtures += [('slot:disabled',dict(slots=[(0,0,False,True,True,False)])),
                 ('slot:empty_sources',dict(slots=[(0,0,True,False,False,False)])),
                 ('slot:shadow',dict(slots=[(0,0,True,True,False,True)])),
                 ('slot:special_shadow',dict(slots=[(0,0,True,True,False,True)],special_rows=[])),
                 ('slot:special_bank',dict(load_mode=14,slots=[(11,0,True,True,False,False),(11,1,True,True,True,False)],special_rows=[]))]
    fixtures += [('special',dict(special_rows=DEFAULT_ROWS)),('level',dict(level_rows=DEFAULT_ROWS)),
                 ('level:empty',dict(level_rows=[])),('tree:empty_payload',dict(status_rows=[None])),
                 ('tree:inorder',dict(status_rows=[[(11,20,0,1,20,0,1)],None,[(11,20,0,1,20,1,10)],[],[(11,20,0,1,20,0,3)]]))]
    for phase in (0,1,2,3):
        fixtures.append((f'all:{phase}',dict(slots=[(0,0,True,True,True,False),(25,0,True,True,False,False)],
            special_rows=DEFAULT_ROWS,level_rows=list(reversed(DEFAULT_ROWS)),status_rows=[DEFAULT_ROWS,None,[(11,20,0,1,20,0,2)]],phase=phase)))
    runs=[];traces=[]
    for case,fixture in fixtures:
        for poison in (False,True):
            row,trace=replay(source,**fixture,poison=poison);verify(row);row['case']=case
            runs.append(json.loads(json.dumps(row)));traces.append(trace)
    names=('audit_dnf_skill_context_modifier.py','audit_dnf_item_skill_modifier.py','audit_dnf_firewave.py','audit_dnf_ice_shatter.py',
           'audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    return {'schema':'dnf_skill_context_modifier/1','engine_sha256':ENGINE_SHA,'input_source':source.source,'method':__doc__.strip(),
            'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
            'runs':runs,'blocks':source_blocks(source,traces),
            'owner_vtable':{hex(off):hex(int.from_bytes(source.source_bytes(0x16F972C+off,4),'little')) for off in (0x38,0x738,0x798)},
            'boundaries':['Full 907D40 entry/return and full 904800 ordered modifier execute; original 904550 executes in the same CPU for equipment sources.',
                'Original 844850/843410 slot lookup selects synthetic arrays at owner+3010/+37B8 with manager+F90 and owner+5668; item virtual enable/primary/secondary results remain explicit callsite fixtures.',
                'Original special-owner flag getter, owner+5664 vector selection, owner+551D/+560C getters and tree begin/end/successor run. Object construction, loading and lifetime are not established.',
                'Object virtual +238 returns fixture key 42; native singleton fast path runs, while 6EB4A0 vector query/copy is an ABI fixture. The label level is a fixture name, not proof of the key business meaning; selection rules and archive producer are excluded.',
                'Tree is a valid synthetic balanced tree; native traversal is exercised, not insertion/rebalancing. State-object vector getter +AC runs without a phase filter.',
                'Secure reads, manager acquisition/mode decoding, profiling services, string storage, frees and temporary-vector destruction are ABI fixtures. No resource failure/exception replay.',
                'x87 uses bounded Python binary64, not full 80-bit/control-word emulation. Original caller stores and state arithmetic use binary32. No production formula or full skill service claim.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path)
    p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite client')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    result=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(result,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[SKILL_CONTEXT_MODIFIER] {len(result['runs'])} original paths verified")


if __name__=='__main__':main()

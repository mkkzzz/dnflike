"""Replay native mode dispatch, dungeon normalization and requested-level lookup.

The pinned PE is read as data, never executed. Manager/object lifetimes, table
values and map nodes are synthetic ABI inputs. Original vtables, mode bounds,
enabled gate, vector clamp, binary-tree lookup and iterator checks are replayed.
Secure scalar/float primitives and singleton access are explicit fixtures.
This does not prove which original dungeon enables or populates these tables.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from audit_dnf_ice_shatter import fbits, real, signed
from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_native_strings import ENGINE_SHA, recover_string

MANAGER, MODULE, STAGE, DUNGEON = 0x60000000, 0x60100000, 0x60200000, 0x60300000
NORMALIZER, ROWS = DUNGEON+0x44, 0x61000000
VTABLES = {0:0x15B0FEC, 1:0x15B105C, 2:0x15B10D4, 3:0x1829E54}
LEVEL_MAP = {10:8, 40:25, 80:60}
FIXTURES = {0x6FC760, 0x1195B90, 0x1195EB0}
NATIVE = {0x7527D0, 0x759C30, 0xE49010, 0x42C7D0, 0x42C780,
          0x7D3460, 0x935780, 0x9357F0, 0x9357B0, 0x935870,
          0x924C20, 0x110F7C0, 0xFCA930}


def table_value(row, column):
    # Exact binary fractions distinguish both row and column without x87 rounding.
    return 1.0 + row/16 + column/256


def replay(source, *, operation='scale', mode=3, level=40, column=13,
           count=60, enabled=True, missing='', empty_map=False, owner_arg=0,
           poison=False):
    from dnf_native_vm_probe import CPU
    if operation not in ('scale','map') or missing not in ('','module','stage','dungeon'):
        raise ValueError('Unknown fixture route')
    if mode not in VTABLES and mode not in (-1,17,99):raise ValueError('Unmodeled mode')
    if not 0<=count<=100 or not 0<=column<14 or level < -1:
        raise ValueError('Unsupported fixture bounds')
    c=CPU(source)
    for a in range(0x6FFFFC00,0x70000000,4):c.write(a,4,0)
    for j,value in enumerate((level,column,owner_arg)):
        c.write(0x70000004+j*4,4,value)
    c.write(MANAGER+0xA4,4,0x12345678)
    for j in range(17):c.write(MANAGER+0xA8+j*4,4,0)
    if mode in VTABLES:
        c.write(MANAGER+0xA8+mode*4,4,0 if missing=='module' else MODULE)
        c.write(MODULE,4,VTABLES[mode])
    c.write(MODULE+0x14,4,0 if missing=='stage' else STAGE)
    c.write(STAGE+0x8C,4,0 if missing=='dungeon' else DUNGEON)
    c.write(NORMALIZER+0x50,1,int(enabled))
    secured={}
    # Three distinct banks expose an accidental owner_arg -> bank substitution.
    for bank in range(3):
        base=ROWS+bank*0x10000
        c.write(NORMALIZER+bank*20+4,4,base)
        c.write(NORMALIZER+bank*20+8,4,base+count*168)
        for row in range(count):
            for col in range(14):secured[base+row*168+col*12]=fbits(table_value(row,col)+bank*10)
    container=NORMALIZER+0x3C;proxy=0x60400000;sentinel=0x60400100
    nodes={key:0x60401000+j*0x100 for j,key in enumerate(sorted(LEVEL_MAP))}
    c.write(container,4,proxy);c.write(proxy,4,container)
    c.write(container+8,4,sentinel)
    c.write(sentinel+4,4,sentinel if empty_map else nodes[40])
    c.write(sentinel+0x15,1,1)
    for key,node in nodes.items():
        c.write(node,4,nodes[10] if key==40 else sentinel)
        c.write(node+8,4,nodes[80] if key==40 else sentinel)
        c.write(node+0xC,4,key);c.write(node+0x10,4,LEVEL_MAP[key])
        c.write(node+0x15,1,0)
    fp=[];events=[];c.pc=0x75BF00 if operation=='scale' else 0x75BF90
    for _ in range(3000):
        if c.pc in NATIVE:
            events.append({'kind':'native_call','target':hex(c.pc),'this':hex(c.reg['ecx'])})
        if c.pc in FIXTURES:
            target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
            result,pop=0,0;e={'target':hex(target),'this':hex(this)}
            if target==0x6FC760:result=MANAGER;e['kind']='singleton_fixture'
            elif target==0x1195B90:
                if c.read(arg(0),4)!=0x12345678:raise ValueError('Unknown encoded mode')
                c.write(arg(1),4,mode);e.update(kind='mode_fixture',value=mode)
            else:
                if arg(0)!=this+8 or this not in secured:raise ValueError(f'Unmodeled secure read {this:#x}')
                c.write(arg(1),4,secured[this]);pop=8
                e.update(kind='secure_float_fixture',value_bits=secured[this])
            events.append(e);c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
            c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
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
        if i.mnemonic=='fld1':fp.append(1.0)
        elif i.mnemonic=='fld' and i.operands[0].size==4:fp.append(real(c.get(i,i.operands[0])))
        elif i.mnemonic=='imul' and len(i.operands) in (1,3):
            if len(i.operands)==1:
                product=signed(c.reg['eax'])*signed(c.get(i,i.operands[0]))
                c.reg['eax']=product&0xffffffff;c.reg['edx']=(product>>32)&0xffffffff
            else:
                product=signed(c.get(i,i.operands[1]))*signed(c.get(i,i.operands[2]))
                c.put(i,i.operands[0],product)
            c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=product<=2147483647 else 0)
        else:raise ValueError(f'Unmodeled instruction {i.mnemonic} {i.op_str}')
        c.pc+=i.size
    else:raise ValueError('Normalization instruction budget')
    return {'fixture':dict(operation=operation,mode=mode,level=level,column=column,count=count,
                enabled=enabled,missing=missing,empty_map=empty_map,owner_arg=owner_arg,poison=poison),
            'value':fp[-1] if operation=='scale' and fp else signed(c.reg['eax']),
            'fp_depth':len(fp),'stack':hex(c.reg['esp']),'stop':list(stop),
            'events':events,'branches':c.branches,'steps':len(c.trace),
            'trace_sha256':trace_hash(c.trace)},c.trace


def active(f):
    return f['mode']==3 and f['missing']=='' and f['enabled']


def expected(f):
    if f['operation']=='map':
        return LEVEL_MAP.get(f['level'],-1) if active(f) and not f['empty_map'] else -1
    if not active(f) or f['level'] in (-1,0) or f['count']==0:return 1.0
    return table_value(min(f['level'],f['count'])-1,f['column'])


def verify(row):
    f=row['fixture']
    if row['stop']!=['returned'] or row['stack']!='0x70000004' or row['fp_depth']!=int(f['operation']=='scale'):
        raise ValueError('Normalization return/ABI mismatch')
    if row['value']!=expected(f):raise ValueError('Normalization result mismatch')
    reads=[e for e in row['events'] if e['kind']=='secure_float_fixture']
    used=f['operation']=='scale' and active(f) and f['level']>0 and f['count']>0
    addresses=[e['this'] for e in reads]
    want=[hex(ROWS+(min(f['level'],f['count'])-1)*168+f['column']*12)] if used else []
    if addresses!=want:raise ValueError('Normalization table address mismatch')
    if f['operation']=='map' and active(f):
        targets={e['target'] for e in row['events'] if e['kind']=='native_call'}
        if not {'0x935870','0x924c20','0x110f7c0','0xfca930'}<=targets:
            raise ValueError('Native map lookup missing')


def audit(source):
    cases=[{}]+[dict(mode=m) for m in (0,1,2,-1,17,99)]
    cases += [dict(missing=x) for x in ('module','stage','dungeon')]
    cases += [dict(enabled=False),dict(count=0),dict(count=1),dict(owner_arg=2)]
    cases += [dict(level=x) for x in (-1,0,1,2,60,61,100)]
    cases += [dict(column=x) for x in (0,1,12)]
    cases += [dict(operation='map',level=x) for x in (-1,0,9,10,11,39,40,41,79,80,81,100)]
    cases += [dict(operation='map',**x) for x in
              [dict(mode=m) for m in (0,1,2,-1,17)]+[dict(missing=m) for m in ('module','stage','dungeon')]+
              [dict(enabled=False),dict(empty_map=True)]]
    runs=[];traces=[]
    for case in cases:
        for poison in (False,True):
            row,trace=replay(source,poison=poison,**case);verify(row);runs.append(row);traces.append(trace)
    # Static provenance supplements runtime fixtures; ctor/factory are not replayed.
    provenance=[]
    for start,end in ((0x75B6AE,0x75B725),(0x1102A70,0x1102AB1),(0x759B70,0x759BB1),
                      (0x1102F00,0x1102F44),(0x110B920,0x110B96B)):
        raw=source.source_bytes(start,end-start)
        provenance.append({'start':hex(start),'length':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),
            'instructions':[f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in source.decoder.disasm(raw,start)]})
    labels=[]
    for mode,address in ((1,0x182A858),(3,0x1829EFC)):
        raw=source.source_bytes(address,256);label,size=recover_string(raw,0,2)
        labels.append({'mode':mode,'address':hex(address),'text':label,
            'raw':raw[:size+4].hex(),'sha256':hashlib.sha256(raw[:size+4]).hexdigest(),
            'proc':hex(int.from_bytes(source.source_bytes(VTABLES[mode]+4,4),'little'))})
    names=('audit_dnf_level_normalization.py','audit_dnf_ice_shatter.py','audit_dnf_ice_particle_bindings.py',
           'audit_dnf_native_strings.py','dnf_native_vm_probe.py','audit_dnf_particle_axis.py')
    return {'schema':'dnf_level_normalization/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
            'method':__doc__.strip(),'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
            'vtable_slots':[{'mode':mode,'vtable':hex(v),'scale':hex(int.from_bytes(source.source_bytes(v+0x40,4),'little')),
                'map':hex(int.from_bytes(source.source_bytes(v+0x44,4),'little'))} for mode,v in VTABLES.items()],
            'static_provenance':provenance,'diagnostic_labels':labels,
            'boundaries':['Tables/map/object pointers and lifetimes are synthetic; original loader and dungeon enable policy are not established.',
                'Original manager dispatch and map tree/iterator functions are replayed; allocations/constructors are not. Factory/constructor excerpts are separate static evidence.',
                'Modes 0/1/2/3, invalid modes and missing module are covered; PVP and other valid modes are excluded.',
                'Scale columns 0..13 and levels -1/0/positive only; other invalid inputs are not made safe by this audit.',
                'Manager remains present and stable; allocation failure, concurrent changes and malformed tree/vector memory are excluded.',
                'No production damage formula or original final-hit behavior is changed or validated by this artifact.'],
            'runs':runs,'blocks':source_blocks(source,traces)}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path)
    p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite client')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    evidence=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(evidence,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[LEVEL_NORMALIZATION] {len(evidence['runs'])} source paths verified")


if __name__=='__main__':main()

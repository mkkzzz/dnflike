"""Original 121EFF0 equipment skill-data reader with class/mode/category decode.

Full reader and native constructors/copies execute as source instructions;
lexer, std::map, allocation/reserve, secure storage and destructors are ABI
fixtures. Native class-string initializer runs; this is not full CRT startup.
Only typed, complete seven-token rows are accepted by this input harness.
Malformed original occurrences are inventoried, never silently repaired.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
from audit_dnf_firewave import extra_step
from audit_dnf_ice_shatter import fbits,real,signed
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
from audit_dnf_native_strings import ENGINE_SHA

OBJECT,VECTOR=0x60010000,0x60200000
FIXTURES={0x1197630,0x1195A10,0x1195EB0,0x1195DC0,0x13CBDCA,0x13CADD7,0x13CC5BA,
          0x119A390,0x1199E00,0x1199E30,0x451130,0x450BF0,0x110F7C0,0x121A480,
          0x119A6F0,0x119A800,0x119A860,0x485D80}
NATIVE={0x121EFF0,0x7801D0,0x485930,0x1219100,0x121E3F0,0x121D8D0,0x401C80,0x13CC488,0x13CD690}
CLASSES=['[swordman]','[fighter]','[gunner]','[mage]','[priest]','[at gunner]',
         '[thief]','[at fighter]','[at mage]','[demonic swordman]','[creator mage]','[all]']
MODES={'[pvp]':4,'[fair pvp]':5,'[dungeon]':3,'[main game]':3,'[dead tower]':10,
       '[war room]':7,'[room list]':1,'[assault]':9,'[pvp type]':18,'[dungeon type]':19,
       '[all]':20,'[blood system]':11,'[tournament dungeon]':16,'[despair tower]':12}
CATEGORIES=['[static]','[level]','[cooltime]','[mp]','[maintain mp]','[skill consume item]','[casting time]']


def validate(values):
    if len(values)%7:raise ValueError('Incomplete seven-token row')
    if len(values)//7>1200:raise ValueError('Reserved fixture capacity exceeded')
    for j in range(0,len(values),7):
        row=values[j:j+7]
        if any(type(row[k])!=str for k in (0,2,3,5)):raise ValueError('Unsupported string token')
        if row[3] not in CATEGORIES:raise ValueError('Unknown category outside lexer fixture domain')
        if any(len(row[k])>100 for k in (0,2,3,5)):raise ValueError('String fixture budget exceeded')
        for k in (1,4,6):
            v=row[k]
            if type(v) not in (int,float) or not math.isfinite(v) or not -2147483648<=v<2147483648:
                raise ValueError('Numeric fixture domain exceeded')
            if type(v)==float and not -2147483648<=real(fbits(v))<2147483648:
                raise ValueError('Binary32 numeric fixture domain exceeded')


def replay(source,values,*,poison=False):
    validate(values)
    from dnf_native_vm_probe import CPU
    c=CPU(source)
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.write(OBJECT+0x4A4,4,VECTOR);c.write(OBJECT+0x4A8,4,VECTOR);c.write(OBJECT+0x4AC,4,VECTOR+0x10000)
    c.write(0x1D94A4C,4,1)  # original SSE2 numeric truncation branch
    c.string_clobber=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
    secure={};maps={};roots={};marks={};events=[];allocated=0x60800000;cursor=0;current=None
    fp=[];xmm={f'xmm{j}':0 for j in range(8)}

    def alloc(size):
        nonlocal allocated
        result=allocated;allocated+=(size+15)&~15
        if allocated>0x60900000:raise ValueError('Fixture allocation budget')
        for j in range((size+3)//4):c.write(result+4*j,4,0)
        return result

    def zstring(address):
        chars=[]
        for j in range(256):
            v=c.read(address+j*2,2)
            if not v:return ''.join(chars)
            chars.append(chr(v))
        raise ValueError('Unterminated fixture string')

    def put_string(dest,word):
        raw=(word+'\0').encode('utf-16le');base=dest+4 if len(word)<8 else alloc(len(raw))
        for j,b in enumerate(raw):c.write(base+j,1,b)
        if len(word)>=8:c.write(dest+4,4,base)
        c.write(dest+0x14,4,len(word));c.write(dest+0x18,4,max(7,len(word)))

    def iterator(map_address,out,node=None):
        if map_address not in roots:
            root=alloc(4);end=alloc(24);c.write(root,4,root);roots[map_address]=(root,end)
        root,end=roots[map_address]
        c.write(out,4,root);c.write(out+4,4,0);c.write(out+8,4,end if node is None else node)
        return out

    def record(base):
        return [c.read(base,4),signed(secure[base+4]),signed(c.read(base+0x10,4)),c.read(base+0x2C,4),
                signed(c.read(base+0x30,4)),signed(secure[base+0x14]),signed(secure[base+0x20])]

    def run(start,end=None):
        nonlocal cursor,current
        c.pc=start
        for _ in range(200000):
            if end is not None and c.pc==end:return ['boundary',hex(end)]
            if c.pc in FIXTURES:
                target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
                result=0;pop=0
                if target==0x1197630:secure[this]=0
                elif target==0x1195A10:
                    if arg(1)!=this+8:raise ValueError('Wrong secure write key')
                    secure[this]=c.read(arg(0),4);pop=8
                elif target==0x1195EB0:
                    if this not in secure or arg(0)!=this+8:raise ValueError(f'Unmodeled secure read {this:#x}')
                    c.write(arg(1),4,secure[this]);pop=8
                elif target==0x13CBDCA:
                    if arg(0) not in (8,24):raise ValueError('Unexpected allocation')
                    result=alloc(arg(0))
                elif target in (0x13CADD7,0x13CC5BA,0x1195DC0,0x119A390):pass
                elif target==0x1199E00:marks[this]=cursor
                elif target==0x1199E30:cursor=marks[this]
                elif target==0x451130:
                    pair=arg(1);word=zstring(c.read(pair,4));enum=c.read(pair+4,4)
                    node=alloc(24);c.write(node+0x10,4,enum);maps.setdefault(this,{})[word]=node
                    result=iterator(this,arg(0),node);pop=8
                    events.append({'kind':'native_registration','map':hex(this),'tag':word,'enum':enum})
                elif target==0x450BF0:
                    word=zstring(c.read(arg(1),4));node=maps.get(this,{}).get(word)
                    result=iterator(this,arg(0),node);pop=8
                elif target==0x110F7C0:result=iterator(this,arg(0));pop=4
                elif target==0x121A480:
                    if cursor<len(values):
                        if not isinstance(values[cursor],str):raise ValueError('Nonstring token at string reader boundary')
                        put_string(arg(0),values[cursor]);cursor+=1;result=1
                elif target==0x119A6F0:
                    if cursor>=len(values):current=None;result=0
                    else:
                        current=values[cursor];cursor+=1
                        if type(current)==int:result=2
                        elif type(current)==float:result=4
                        else:raise ValueError('Nonnumeric token at numeric boundary')
                elif target==0x119A800:
                    if type(current)!=int:raise ValueError('Wrong integer getter')
                    result=current&0xFFFFFFFF
                elif target==0x119A860:
                    if type(current)!=float:raise ValueError('Wrong float getter')
                    fp.append(real(fbits(current)))
                else:
                    if this!=OBJECT+0x4A0 or arg(0)!=20:raise ValueError('Wrong reserve boundary')
                    pop=4;events.append({'kind':'reserve_fixture','this':hex(this),'requested':20})
                c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
                c.reg['ecx'],c.reg['edx'],c.flags=c.string_clobber
                for name in xmm:xmm[name]=0x0123456789ABCDEF if poison else 0
                continue
            if c.pc in (0x121F6DB,0x121F6AD):
                obj=c.reg['esi'] if c.pc==0x121F6DB else c.reg['edi']
                events.append({'kind':'native_append','record':record(c.read(obj+8,4))})
            stop=c.run(c.pc,1)
            if stop[0]=='returned':return list(stop)
            if stop[0]=='budget':continue
            i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
            if stop[0]=='call':
                target=int(stop[2],16)
                if target not in FIXTURES|NATIVE:raise ValueError(f'Unmodeled call {target:#x}')
                c.push(c.pc+i.size);c.pc=target;continue
            if stop[0]!='unsupported':raise ValueError(f'Unmodeled stop {stop}')
            if i.mnemonic=='cmovb':
                if c.flags&1:c.put(i,i.operands[0],c.get(i,i.operands[1]))
            elif i.mnemonic=='leave':
                c.reg['esp']=c.reg['ebp'];c.reg['ebp']=c.pop()
            elif i.mnemonic=='fstp':
                if len(fp)!=1:raise ValueError('Unmodeled floating stack')
                op=i.operands[0];v=fp.pop()
                if op.type==1:
                    if i.op_str!='st(0)':raise ValueError('Unmodeled floating register')
                else:c.put(i,op,fbits(v) if op.size==4 else int.from_bytes(struct.pack('<d',v),'little'))
            elif i.mnemonic=='cvttsd2si':
                v=struct.unpack('<d',c.get(i,i.operands[1]).to_bytes(8,'little'))[0]
                if not math.isfinite(v) or not -2147483648<=v<2147483648:raise ValueError('Out-of-range numeric fixture')
                c.put(i,i.operands[0],math.trunc(v))
            else:extra_step(c,xmm,i);continue
            c.pc+=i.size
        raise ValueError('Instruction budget exceeded')

    # Original static class-string table initializer; string decryption uses
    # the shared explicit ABI implementation in the bounded CPU.
    init=run(0x15338E0);classes=[zstring(c.read(0x1D1DC98+j*4,4)) for j in range(12)]
    saved={'ebx':0x12345678,'esi':0x23456789,'edi':0x3456789A,'ebp':0x456789AB}
    c.reg.update(saved);c.reg.update(esp=0x70000000,esi=OBJECT)
    stop=run(0x1270AD5,0x126F227)
    if cursor!=len(values):raise ValueError('Unread input tokens')
    count=(c.read(OBJECT+0x4A8,4)-VECTOR)//52
    return {'fixture':{'values':values,'poison':poison},'classes':classes,'init_stop':init,'stop':stop,
            'records':[record(VECTOR+j*52) for j in range(count)],'events':events,'cursor':cursor,
            'stack':hex(c.reg['esp']),'preserved':{k:c.reg[k]==v for k,v in saved.items() if k!='esi'},
            'fp_depth':len(fp),'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def expected(values):
    validate(values);records=[]
    trunc=lambda v:math.trunc(real(fbits(v))) if type(v)==float else v
    for j in range(0,len(values),7):
        job,skill,mode,category,column,op,amount=values[j:j+7]
        cat=CATEGORIES.index(category)
        records.append([CLASSES.index(job) if job in CLASSES else 11,trunc(skill),
                        trunc(column) if cat in (0,1,5) else 0,cat,MODES.get(mode,17),int(op!='+'),trunc(amount)])
    return records


def verify(row):
    records=expected(row['fixture']['values'])
    if row['init_stop']!=['returned'] or row['stop']!=['boundary','0x126f227'] or row['stack']!='0x70000000' or row['fp_depth']!=0 or not all(row['preserved'].values()):
        raise ValueError('Return/ABI mismatch')
    if row['classes']!=CLASSES:raise ValueError('Native class table mismatch')
    if row['records']!=records:raise ValueError('Decoded equipment records mismatch')
    if [e['record'] for e in row['events'] if e['kind']=='native_append']!=records:
        raise ValueError('Native append mismatch')
    if row['cursor']!=len(row['fixture']['values']):raise ValueError('Unread tokens')


def inventory():
    from collections import Counter
    from contextlib import closing
    from dnf_pvf import open_library
    from audit_dnf_design import decode_tokens
    counts={k:Counter() for k in ('class','mode','category','operator','types')}
    scanned=files=fields=rows=0;invalid=[];samples=[];covered=set();manifest=hashlib.sha256()
    with closing(open_library()) as lib:
        version=lib.asset_version
        indices=[i for i in range(lib.strings.count) if lib.strings.get(i)=='[skill data up]']
        if not indices:raise ValueError('Missing source tag')
        needles=[b'\x05'+i.to_bytes(4,'little') for i in indices]
        for path,raw in sorted(lib.files('.equ')):
            scanned+=1
            if not any(n in raw for n in needles):continue
            selected=[f for f in decode_tokens(raw,lib.strings)['tag_spans'] if f['tag']=='[skill data up]']
            if not selected:continue
            files+=1;digest=hashlib.sha256(raw).hexdigest()
            for f in selected:
                fields+=1;v=[t['value'] for t in f['values']];types=[t['type'] for t in f['values']]
                entry={'path':path,'sha256':digest,'offset':f['offset'],'values':v,'types':types}
                manifest.update((json.dumps(entry,ensure_ascii=True,separators=(',',':'))+'\n').encode())
                try:
                    validate(v)
                    if any(types[j:j+7] not in ([7,2,7,7,2,7,2],[7,2,7,7,2,7,4]) for j in range(0,len(v),7)):
                        raise ValueError('Unsupported archive token types')
                except ValueError as ex:
                    entry['reason']=str(ex);invalid.append(entry);continue
                keys=set()
                for j in range(0,len(v),7):
                    rows+=1
                    for name,k in (('class',0),('mode',2),('category',3),('operator',5)):
                        counts[name][v[j+k]]+=1;keys.add((name,v[j+k]))
                    type_key=','.join(map(str,types[j:j+7]));counts['types'][type_key]+=1;keys.add(('types',type_key))
                    if v[j]=='[swordman]' and v[j+1] in (20,21,22):keys.add(('wave',v[j+1]))
                if keys-covered:samples.append(entry);covered.update(keys)
    return {'asset_version':version,'scanned_equ':scanned,'files_with_field':files,'fields':fields,
            'aligned_supported_rows':rows,'counts':{k:dict(sorted(v.items())) for k,v in counts.items()},
            'ordered_field_manifest_sha256':manifest.hexdigest(),'samples':samples,'unreplayed_fields':invalid,
            'selection':'Sorted paths; first whole field adding class/mode/category/operator/token-type or swordman 20/21/22 coverage. Counts cover all typed seven-token fields; only samples are replayed.'}


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    inv=inventory();fixtures=[('empty',[])]
    base=['[swordman]',20,'[all]','[level]',3,'%',10]
    for index,choices in ((0,CLASSES+['[theif]','[unknown]','']),
                          (2,list(MODES)+['[all]]','']), (3,CATEGORIES), (5,['+','-','%','*',''])):
        for value in choices:
            v=list(base);v[index]=value;fixtures.append((f'field:{index}:{value}',v))
    for cat in CATEGORIES:
        fixtures.append((f'float:{cat}',['[theif]',20.9,'[all]',cat,-3.9,'-',-10.9]))
    fixtures.append(('multi',sum(([CLASSES[j%12],20+j,'[all]',CATEGORIES[j%7],j,'+' if j%2 else '%',j] for j in range(22)),[])))
    fixtures.extend((f'archive:{s["path"]}:{s["offset"]}',s['values']) for s in inv['samples'])
    runs=[];traces=[]
    for case,v in fixtures:
        for poison in (False,True):
            row,trace=replay(source,v,poison=poison);verify(row);row['case']=case;runs.append(row);traces.append(trace)
    from audit_dnf_item_skill_modifier import replay as modify,verify as verify_modifier
    applications=[]
    for row in runs:
        if row['fixture']['poison'] or not row['case'].startswith('archive:'):continue
        # One query per distinct selector; source fields remain separate.
        for job,skill,column,category,mode in sorted({tuple(r[:5]) for r in row['records']}):
            result,trace=modify(source,banks=(row['records'],[]),value=100,owner_kind=job,skill_id=skill,
                                column=column,category=category,mode=3,phase=2,poison=True)
            verify_modifier(result);traces.append(trace)
            applications.append({'case':row['case'],'query_mode':3,'field_mode':mode,'run':result})
    names=('audit_dnf_item_modifier_load.py','audit_dnf_item_skill_modifier.py','audit_dnf_firewave.py','audit_dnf_ice_shatter.py',
           'audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py','dnf_pvf.py','audit_dnf_design.py')
    from audit_dnf_native_strings import recover_string
    tag,size=recover_string(source.source_bytes(0x1860FC0,8192),0,2)
    if tag!='[skill data up]':raise ValueError('Unexpected native source tag')
    provenance=[]
    for start,end in ((0x126E71D,0x126E75F),(0x1270AD5,0x1270AE9)):
        raw=source.source_bytes(start,end-start)
        provenance.append({'start':hex(start),'sha256':hashlib.sha256(raw).hexdigest(),
            'instructions':[f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in source.decoder.disasm(raw,start)]})
    return {'schema':'dnf_item_modifier_load/1','engine_sha256':ENGINE_SHA,'input_source':source.source,'method':__doc__.strip(),
            'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
            'inventory':inv,'runs':runs,'applications':applications,'blocks':source_blocks(source,traces),
            'static_provenance':provenance,'tag':{'text':tag,'va':'0x1860fc0',
                'encoded_sha256':hashlib.sha256(source.source_bytes(0x1860FC0,size)).hexdigest(),'enum':0x1941,'map':'0x1d8b55c'},
            'boundaries':['Original class initializer and 1270AD5 caller fragment through full 121EFF0 entry/return execute; outer equipment tag dispatch, whole equipment parser and CRT startup are excluded.',
                'Lexer values, secure storage, std::map insertion/lookup/iterators, allocation/reserve and destruction are explicit ABI fixtures. Native registration arguments, class/mode/category dispatch, constructors and row copies execute.',
                'Preallocated vector excludes growth and alias-copy path; each field starts empty. Unknown categories and incomplete rows remain unreplayed, not repaired.',
                'Float tokens use binary32 and the selected original SSE2 truncation helper. No full x87 environment or out-of-range conversion claim.',
                'Inventory is archive presence, not active 60-level content or effective PVE/PVP selection. Replayed source samples are selected by lexical coverage, not every field.',
                'Parsed records feed separate original 904550 calls with synthetic base 100 and mode 3; no full equipment instance lifecycle, whole skill service, final damage or production runtime change.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path)
    p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite client')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    result=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(result,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[ITEM_MODIFIER_LOAD] {len(result['runs'])} reader paths; {len(result['applications'])} native applications")


if __name__=='__main__':main()

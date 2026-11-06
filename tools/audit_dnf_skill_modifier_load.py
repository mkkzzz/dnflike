"""Bounded SKL feature index / special-level-up registration, parse and copy.

Native enum dispatch, record constructor, operator comparison, vector append and
record copy constructor run as source instructions. Token/string input, secure
storage, allocation, clear/destruction and final vector assignment are explicit
ABI fixtures. Each field is independent: mode-section selection and full SKL
startup are excluded. No PE execution. Archive all raw source field occurrences.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
from audit_dnf_native_strings import ENGINE_SHA,recover_string
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
from audit_dnf_ice_shatter import signed

FRAME,RECORD,SKILL,VECTOR,COPY=0x6FFFF000,0x60010000,0x60100000,0x60200000,0x60300000
TAGS=(('[feature skill index]',0x12CCDE0,0x1870578,0x2BE),
      ('[special level up]',0x12CCE64,0x1870514,0x2C4))
FIXTURES={0x1218A80,0x121A480,0x1197630,0x1195A10,0x1195EB0,0x1195DC0,
          0x13CBDCA,0x13CADD7,0x909680,0xEECD10,0x1060EE0,0x90AAF0}
NATIVE={0x4041C0,0x12CA890,0x12CB460,0x904E10,0x401C80,0x401DD0}


def replay(source,values,*,feature=21,poison=False):
    from dnf_native_vm_probe import CPU
    c=CPU(source)
    for a in range(FRAME-0x4000,FRAME+0x100,4):c.write(a,4,0)
    for base in (RECORD,SKILL):
        for a in range(base,base+0x800,4):c.write(a,4,0)
    c.write(RECORD+0x544,4,VECTOR);c.write(RECORD+0x548,4,VECTOR)
    c.write(RECORD+0x54C,4,VECTOR+0x10000)
    secure={RECORD+0x520:0xFFFFFFFF,RECORD+0x52C:0xFFFFFFFF}
    events=[];phases=[];stream=[];cursor=0;allocated=0x60800000
    c.string_clobber=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)

    def fields(base):return [c.read(base,1)]+[signed(secure[base+off]) for off in (4,0x10,0x1C)]

    def run(start,end,label):
        nonlocal cursor,allocated
        begin=len(c.trace);c.pc=start
        for _ in range(100000):
            if c.pc==end:
                phases.append({'name':label,'start':hex(start),'end':hex(end),'steps':len(c.trace)-begin});return
            if c.pc in FIXTURES:
                target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
                result=0;pop=0
                if target==0x1218A80:
                    valid=cursor<len(stream) and isinstance(stream[cursor],int)
                    if arg(0):c.write(arg(0),1,int(valid))
                    if valid:result=stream[cursor]&0xFFFFFFFF;cursor+=1
                    elif cursor<len(stream):raise ValueError('Noninteger token outside fixture domain')
                elif target==0x121A480:
                    if cursor>=len(stream) or not isinstance(stream[cursor],str):raise ValueError('Expected operator token')
                    word=stream[cursor];cursor+=1
                    if len(word)>=8:raise ValueError('Only short operator strings modeled')
                    dest=arg(0);raw=(word+'\0').encode('utf-16le')
                    for j,b in enumerate(raw):c.write(dest+4+j,1,b)
                    c.write(dest+0x14,4,len(word));c.write(dest+0x18,4,7);result=1
                elif target==0x1197630:secure[this]=0
                elif target==0x1195A10:
                    if arg(1)!=this+8:raise ValueError('Wrong secure write key')
                    secure[this]=c.read(arg(0),4);pop=8
                elif target==0x1195EB0:
                    if this not in secure or arg(0)!=this+8:raise ValueError(f'Unmodeled secure read {this:#x}')
                    c.write(arg(1),4,secure[this]);pop=8
                elif target==0x13CBDCA:
                    if arg(0)!=8:raise ValueError('Unmodeled allocation')
                    result=allocated;allocated+=16
                elif target in (0x13CADD7,0x1195DC0,0xEECD10,0x1060EE0):pass
                elif target==0x909680:
                    if this!=RECORD+0x540:raise ValueError('Unexpected vector clear')
                    c.write(this+8,4,c.read(this+4,4));events.append({'kind':'clear_fixture','this':hex(this)})
                else:
                    if this!=SKILL+0x530 or arg(0)!=RECORD+0x540:raise ValueError('Wrong runtime vector assignment')
                    count=(c.read(RECORD+0x548,4)-VECTOR)//40
                    for j in range(count):
                        src,dst=VECTOR+j*40,COPY+j*40;c.write(dst,1,c.read(src,1))
                        for off in (4,0x10,0x1C):secure[dst+off]=secure[src+off]
                    c.write(this+4,4,COPY);c.write(this+8,4,COPY+count*40);pop=4;result=this
                    events.append({'kind':'vector_assignment_fixture','source':hex(arg(0)),'destination':hex(this),'count':count})
                c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
                c.reg['ecx'],c.reg['edx'],c.flags=c.string_clobber;continue
            if c.pc==0x12CB501:
                events.append({'kind':'native_append','record':fields(c.read(c.reg['edi']+8,4))})
            stop=c.run(c.pc,1)
            if stop[0]=='budget':continue
            i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
            if stop[0]=='call':
                target=int(stop[2],16)
                if target not in FIXTURES|NATIVE|{0x451130}:raise ValueError(f'Unmodeled call {target:#x}')
                c.push(c.pc+i.size);c.pc=target;continue
            if stop[0]=='unsupported' and i.mnemonic=='cmovb':
                if c.flags&1:c.put(i,i.operands[0],c.get(i,i.operands[1]))
                c.pc+=i.size;continue
            raise ValueError(f'Unmodeled stop {stop}')
        raise ValueError('Instruction budget exceeded')

    registrations=[]
    for tag,start,_,_ in TAGS:
        c.reg.update(ebp=FRAME,esp=FRAME-0x2000)
        run(start,0x451130,'register '+tag)
        pair=c.read(c.reg['esp']+8,4)
        registrations.append({'tag':c.strings[c.read(pair,4)],'enum':c.read(pair+4,4),'map':hex(c.reg['ecx'])})
    for registration,inputs in zip(registrations,([feature],values)):
        stream=list(inputs);cursor=0
        c.reg.update(ebp=FRAME,esp=FRAME-0x2000,eax=registration['enum'],ebx=0)
        c.write(FRAME-0xB0,4,RECORD);c.write(0x1D8F808,1,1)
        run(0x12CBF4E,0x12CD0A8,'parse '+registration['tag'])
        if cursor!=len(stream):raise ValueError('Unused field tokens')
    count=(c.read(RECORD+0x548,4)-VECTOR)//40
    parsed=[fields(VECTOR+j*40) for j in range(count)]
    # Actual caller local record starts at EBP-7BC. This prepared frame aliases
    # the parsed record so the original field offsets/call arguments run.
    c.reg.update(ebp=RECORD+0x7BC,esp=FRAME-0x2000,esi=SKILL)
    run(0x913CAD,0x913D3B,'record_to_runtime')
    return {'fixture':{'values':list(values),'feature':feature,'poison':poison},'registrations':registrations,
            'parsed':parsed,'runtime_records':[fields(COPY+j*40) for j in range(count)],
            'runtime_feature':signed(secure[SKILL+0x518]),'events':events,'phases':phases,
            'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify(row):
    f=row['fixture'];v=f['values']
    if len(v)%4:raise ValueError('Incomplete input record')
    expected=[[int(v[i]==-1),v[i+1],{'+':0,'-':1,'%':2}.get(v[i+2],0),v[i+3]] for i in range(0,len(v),4)]
    if row['parsed']!=expected or row['runtime_records']!=expected:raise ValueError('Parsed/runtime record mismatch')
    if row['runtime_feature']!=f['feature']:raise ValueError('Runtime feature mismatch')
    expected_tags=[{'tag':tag,'enum':enum,'map':'0x1d8f810'} for tag,_,_,enum in TAGS]
    if row['registrations']!=expected_tags:raise ValueError('Wrong tag registration')
    appended=[e['record'] for e in row['events'] if e['kind']=='native_append']
    if appended!=expected:raise ValueError('Native append mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    from contextlib import closing
    from dnf_pvf import open_library,resolve
    from audit_dnf_design import decode_tokens
    inventory=[];unique={};total=0
    with closing(open_library()) as lib:
        version=lib.asset_version
        list_path='skill/swordmanskill.lst';listing=lib.listing(list_path)
        links={'path':list_path,'sha256':lib.raw(list_path)[1],
               'entries':{str(k):resolve(list_path,listing[k]) for k in (140,212,216)}}
        for path,raw in lib.files('.skl'):
            total+=1;decoded=decode_tokens(raw,lib.strings);fields=[]
            for field in decoded['tag_spans']:
                if field['tag'] not in ('[feature skill index]','[special level up]'):continue
                values=[v['value'] for v in field['values']];types=[v['type'] for v in field['values']]
                entry={'tag':field['tag'],'offset':field['offset'],'values':values,'types':types}
                if field['tag']=='[special level up]':
                    if len(values)%4 or types!=[2,2,7,2]*(len(values)//4):raise ValueError('Unexpected special-level-up record shape')
                    key=json.dumps(values,separators=(',',':'));digest=hashlib.sha256(key.encode()).hexdigest()
                    unique[digest]=values;entry['case']=digest
                elif types!=[2]:raise ValueError('Unexpected feature skill index shape')
                fields.append(entry)
            if fields:inventory.append({'path':path,'sha256':hashlib.sha256(raw).hexdigest(),'fields':fields})
    runs=[];traces=[]
    cases=[(key,value,21) for key,value in sorted(unique.items())]
    cases += [(f'feature:{feature}',[-1,0,'+',3,0,1,'-',2,-2,2,'%',8],feature) for feature in (-1,0,194)]
    for key,values,feature in cases:
        for poison in (False,True):
            row,trace=replay(source,values,feature=feature,poison=poison);verify(row)
            row['case']=key;runs.append(row);traces.append(trace)
    # Use the native parser's emitted records as inputs to the separately
    # reconstructed modifier. These are two explicit 906250 calls; intervening
    # 907D40 and mode block selection are NOT silently assumed to run.
    from audit_dnf_skill_modifier import replay as modify,verify as verify_modifier
    applications=[];by_case={r['case']:r for r in runs if not r['fixture']['poison']}
    for item in inventory:
        if item['path'] not in links['entries'].values():continue
        for field in item['fields']:
            if field['tag']!='[special level up]':continue
            records=by_case[field['case']]['runtime_records']
            for column in sorted({r[1] for r in records if r[0]==1}):
                value=100.0;calls=[]
                for phase in (1,0):
                    row,trace=modify(source,records=records,value=value,rank=2,column=column,phase=phase,poison=True)
                    verify_modifier(row);value=row['value'];calls.append(row);traces.append(trace)
                applications.append({'path':item['path'],'field_offset':field['offset'],'case':field['case'],
                                     'column':column,'calls':calls,'value':value})
    names=('audit_dnf_skill_modifier_load.py','audit_dnf_skill_modifier.py','audit_dnf_firewave.py','audit_dnf_native_strings.py','audit_dnf_ice_particle_bindings.py',
           'audit_dnf_ice_shatter.py','dnf_native_vm_probe.py','audit_dnf_particle_axis.py','dnf_pvf.py','audit_dnf_design.py')
    provenance=[]
    for start,end in ((0x9122EB,0x912301),(0x12CBC6E,0x12CBC94)):
        raw=source.source_bytes(start,end-start)
        provenance.append({'start':hex(start),'sha256':hashlib.sha256(raw).hexdigest(),
            'instructions':[f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in source.decoder.disasm(raw,start)]})
    return {'schema':'dnf_skill_modifier_load/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
            'method':__doc__.strip(),'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
            'asset_version':version,'scanned_skl':total,'inventory':inventory,'runs':runs,'blocks':source_blocks(source,traces),
            'wave_index':links,'modifier_applications':applications,
            'static_provenance':provenance,
            'boundaries':['Each field starts at enum dispatch with a prepared parser frame; full tokenization, include inheritance and PVE/PVP block selection are excluded.',
                'Original constructor, operator comparisons, append and element copy constructor run; allocation/destruction/secure storage are fixtures. Reserved capacity excludes growth.',
                'Caller field-copy fragment runs; final 90AAF0 vector assignment is a checked ABI fixture, not full assignment implementation.',
                'All occurrences remain separate inventory records; a file with multiple fields is not flattened into one effective skill. No production formula or enabled-skill scope changes.',
                'Wave examples feed native parser records to two separate 906250 phase 1/0 replays with synthetic base value 100 and linked rank 2; no interposed 907D40, full skill service or final damage claim.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path)
    p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite client')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    result=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(result,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[SKILL_MODIFIER_LOAD] {len(result['runs'])} source paths verified")


if __name__=='__main__':main()

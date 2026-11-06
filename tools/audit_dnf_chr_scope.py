"""Replay CHR parser group selection, not stat formulas or a full client loader."""
import argparse,hashlib,json,sys
from pathlib import Path
from audit_dnf_native_strings import ENGINE_SHA
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
OWNER,FRAME,STACK=0x60000000,0x6fffe000,0x6fffdf00
SLOTS=(0x320,0x324,0x32c,0x344,0x348)
# Pointer offsets independently read from the native branches.
OFFSETS={0:(0x24,0x288,0x314,0x670,0x5555)}
for n in range(1,7):OFFSETS[n]=(0x7b+(n-1)*0x57,0x29c+(n-1)*0x14,0x358+(n-1)*0x44,0x7d0+(n-1)*0x160,0x4f0+(n-1)*0x40)

def replay(source,order,poison=False):
    from dnf_native_vm_probe import CPU
    c=CPU(source)
    for p in range(FRAME-0x1000,FRAME+0x100,4):c.write(p,4,0)
    c.reg.update(edi=OWNER,ebp=FRAME,esp=STACK)
    c.write(FRAME-0x348,4,OWNER+0x5555)
    if poison:c.string_clobber=(0x12345678,0x87654321,0xa97)
    results=[]
    for tag in order:
        c.pc=0x129c49e;c.reg['esp']=STACK
        for _ in range(1000):
            if c.pc==0x129e5b1 or (tag=='[awakening name]' and c.pc==0x129c7d9):break
            if c.pc==0x401dd0:
                a=c.read(c.reg['esp']+4,4);b=c.read(c.reg['esp']+8,4)
                if a!=FRAME-0x230 or b not in c.strings:raise ValueError('Unexpected comparison ABI')
                c.reg['eax']=int(c.strings[b]==tag);c.pc=c.pop()
                c.reg['ecx'],c.reg['edx'],c.flags=(0x12345678,0x87654321,0xa97) if poison else (0,0,0x202)
                continue
            stop=c.run(c.pc,1)
            if stop[0]=='budget':continue
            if stop[0]=='call' and int(stop[2],16) in (0x1194fc0,0x401dd0):
                ins=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1));c.push(c.pc+ins.size);c.pc=int(stop[2],16);continue
            raise ValueError('Scope replay stop '+str(stop))
        else:raise ValueError('Scope instruction budget')
        row={'tag':tag,'slots':[hex(c.read(FRAME-p,4)-OWNER) for p in SLOTS],
             'selected_stat':hex(c.reg['ebx']-OWNER),'stack':hex(c.reg['esp']),'stop':hex(c.pc)}
        if tag=='[awakening name]':row['selected_name']=hex(c.reg['esi']-OWNER)
        results.append(row)
    return {'order':order,'poison':poison,'states':results,'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace

def verify(row):
    state=None
    for tag,result in zip(row['order'],row['states']):
        if tag=='[initial value]':state=list(OFFSETS[0])
        elif tag.startswith('[growtype '):state=list(OFFSETS[int(tag[10:-1])])
        elif tag in ('[awakening 1]','[awakening 2]'):
            base=state[3];second=tag=='[awakening 2]'
            state[:3]=[base+(0x57 if second else 0),base+(0xc4 if second else 0xb0),base+(0x11c if second else 0xd8)]
        elif tag!='[awakening name]':raise ValueError('Unverified tag')
        if result['slots']!=list(map(hex,state)) or result['selected_stat']!=hex(state[0]) or result['stack']!=hex(STACK):raise ValueError('Scope mismatch')
        if tag=='[awakening name]' and result.get('selected_name')!=hex(state[4]):raise ValueError('Name scope mismatch')
        if result['stop']!=('0x129c7d9' if tag=='[awakening name]' else '0x129e5b1'):raise ValueError('Stop mismatch')

def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected engine')
    rows=[];traces=[]
    orders=[['[initial value]']]
    for n in range(1,7):orders.append([f'[growtype {n}]','[awakening name]','[awakening 1]','[awakening 2]','[awakening 1]'])
    orders += [[tag for n in order for tag in [f'[growtype {n}]','[awakening 2]','[awakening 1]']] for order in [range(1,7),range(6,0,-1)]]
    for poison in (False,True):
        for order in orders:
            row,trace=replay(source,order,poison);verify(row);rows.append(row);traces.append(trace)
    names=['audit_dnf_chr_scope.py','dnf_native_vm_probe.py','audit_dnf_native_strings.py','audit_dnf_particle_axis.py','audit_dnf_ice_particle_bindings.py']
    return {'schema':'dnf_chr_scope/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
        'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
        'cases':rows,'blocks':source_blocks(source,traces),'boundaries':['129C49E group-dispatch prefix to 129E5B1 or 129C7D9 executes original instruction bytes.',
        '1194FC0 uses existing read-only original string decoder; 401DD0 comparison is an explicit text-equality ABI fixture.',
        'Prepared EDI parser object and EBP locals; full CHR parsing, allocation and field value writes are not executed.',
        'Awakening name path stops before 121A480 string writes. Pointer association, not complete localized-name loading, is proved.',
        'Growth formulas, automatic skill grants and gameplay progression remain unresolved.']}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite source')
    from audit_dnf_particle_axis import AxisEvaluator
    result=audit(AxisEvaluator(a.client.read_bytes()));a.output.write_text(json.dumps(result,indent=1)+'\n',encoding='utf-8')
    print('CHR_SCOPE cases',len(result['cases']))
if __name__=='__main__':main()

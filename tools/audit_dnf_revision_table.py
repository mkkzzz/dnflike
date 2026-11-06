"""Replay native normalization file loader 9363B0 -> 935C70 as data only.

Ordered tokens come from pinned PVF bytes. File opening, tag/string token reads,
allocator/reset, secure storage and generic array-copy/destructor helpers are ABI
fixtures. Native tag comparisons, type selection, numeric reader, 14-column row
loop, bank iteration, vector append/end updates and enable flag execute in the
bounded Python interpreter. No native PE or client startup is executed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from audit_dnf_ice_shatter import fbits, real, signed
from audit_dnf_firewave import extra_step
from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_native_strings import ENGINE_SHA

OBJECT=0x60000000
FIXTURES={0x9359E0,0x1218A40,0x13CBDCA,0x13CADD7,0x121A540,0x121A480,
          0x8DCD40,0x7D4B90,0x119A6F0,0x119A800,0x119A860,0x1195A10,
          0x13CD27B,0x13CDB1C,0x13CCEF4,0x1060EE0,0x923FF0}
NATIVE={0x935C70,0x401C80,0x75EA90,0x1218B30,0xB09680,0x110F7C0,0x764910,0xBF2520,0x13CC488}


def replay(source,tokens,*,poison=False,opened=True):
    from dnf_native_vm_probe import CPU
    c=CPU(source);c.reg['ecx']=OBJECT;c.write(0x70000004,4,0x60700000)
    for a in range(0x6FFFF000,0x70000000,4):c.write(a,4,0)
    c.string_clobber=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
    c.write(OBJECT+0x50,1,1)  # wrapper must clear an old enabled state
    cursor=0;current=None;allocated=0x60800000;secured={};fp=[];events=[];appends=[]
    xmm={f'xmm{j}':0 for j in range(8)};c.pc=0x9363B0
    digest=hashlib.sha256();unique={};steps=0

    def alloc(size):
        nonlocal allocated
        base=allocated;allocated+=(size+15)&~15
        if allocated>=0x60F00000:raise ValueError('Allocation fixture budget')
        for j in range(0,(size+3)//4*4,4):c.write(base+j,4,0)
        return base

    def next_token():
        nonlocal cursor,current
        current=tokens[cursor] if cursor<len(tokens) else {'type':0,'value':None}
        if cursor<len(tokens):cursor+=1
        return current

    def string_at(out,text):
        encoded=(text+'\0').encode('utf-16le');base=alloc(len(encoded)+2)
        for j in range(0,len(encoded),2):c.write(base+j,2,int.from_bytes(encoded[j:j+2],'little'))
        c.write(out+4,4,base);c.write(out+0x14,4,len(text));c.write(out+0x18,4,max(8,len(text)))

    def drain():
        nonlocal steps
        for line in c.trace:
            digest.update((line+'\n').encode());unique[int(line[:8],16)]=line
        steps+=len(c.trace);c.trace.clear()

    for _ in range(4000000):
        if len(c.trace)>4096:drain()
        if c.pc==0x764910:
            arg=c.read(c.reg['esp']+4,4)
            appends.append({'bank':(c.reg['ecx']-OBJECT)//20,
                            'bits':[secured[arg+j*12] for j in range(14)]})
        if c.pc in FIXTURES:
            target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
            result,pop=0,0
            if target==0x9359E0:
                if this!=OBJECT:raise ValueError('Wrong reset object')
                for bank in range(3):
                    base=0x61200000+bank*0x10000;proxy=alloc(8);vector=OBJECT+bank*20
                    for j,v in enumerate((proxy,base,base,base+60000,0)):c.write(vector+j*4,4,v)
                    c.write(proxy,4,vector)
                c.write(OBJECT+0x50,1,0);events.append({'kind':'reset_fixture'})
            elif target==0x1218A40:
                if [arg(0),arg(1)]!=[0x1AB8E98,0x60700000]:raise ValueError('Unexpected open arguments')
                result=int(opened);events.append({'kind':'open_fixture','ok':opened})
            elif target==0x13CBDCA:result=alloc(arg(0))
            elif target in (0x13CADD7,0x1060EE0,0x923FF0):pass
            elif target in (0x121A540,0x121A480):
                token=next_token();want=5 if target==0x121A540 else 7
                result=int(token['type']==want)
                if result:string_at(arg(0),token['value'])
                events.append({'kind':'tag_fixture' if want==5 else 'string_fixture','type':token['type'],'value':token.get('value'),'ok':bool(result)})
            elif target==0x8DCD40:
                # The local selector vector is newly constructed and empty.
                if any(c.read(this+j,4) for j in (4,8,12)):raise ValueError('Nonempty selector clear')
            elif target==0x7D4B90:
                if any(c.read(this+j,4) for j in (4,8,12)):raise ValueError('Unexpected selector growth')
                base=alloc(256);c.write(this+4,4,base);c.write(this+8,4,base);c.write(this+12,4,base+256);pop=4
            elif target==0x119A6F0:result=next_token()['type']
            elif target==0x119A800:
                if current['type']!=2:raise ValueError('Wrong integer token')
                result=current['value']&0xffffffff
            elif target==0x119A860:
                if current['type']!=4:raise ValueError('Wrong float token')
                fp.append(real(fbits(current['value'])))
            elif target==0x1195A10:
                if arg(1)!=this+8:raise ValueError('Secure write key mismatch')
                secured[this]=c.read(arg(0),4);pop=8
            elif target==0x13CD27B:
                if [arg(j) for j in range(1,5)]!=[12,14,0x42CE70,0xB675E0]:raise ValueError('Unexpected row constructor')
                for j in range(14):secured[arg(0)+j*12]=0
                pop=20
            elif target==0x13CDB1C:
                if [arg(j) for j in range(2,6)]!=[12,14,0x4A13F0,0xB675E0]:raise ValueError('Unexpected array copy')
                for j in range(14):secured[arg(0)+j*12]=secured[arg(1)+j*12]
                pop=24
            elif target==0x13CCEF4:
                if [arg(j) for j in range(1,4)]!=[12,14,0xB675E0]:raise ValueError('Unexpected row destructor')
                pop=16
            c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
            c.reg['ecx'],c.reg['edx'],c.flags=c.string_clobber
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
        if stop[0]!='unsupported':raise ValueError(str(stop))
        if i.mnemonic=='repz ret':c.pc=c.pop();continue
        elif i.mnemonic=='cmovb':
            if c.flags&1:c.put(i,i.operands[0],c.get(i,i.operands[1]))
        elif i.mnemonic=='fld':fp.append(real(c.get(i,i.operands[0])))
        elif i.mnemonic=='fstp':c.put(i,i.operands[0],fbits(fp.pop()))
        elif i.mnemonic=='imul' and len(i.operands) in (1,3):
            if len(i.operands)==1:
                p=signed(c.reg['eax'])*signed(c.get(i,i.operands[0]));c.reg['eax']=p&0xffffffff;c.reg['edx']=(p>>32)&0xffffffff
            else:
                p=signed(c.get(i,i.operands[1]))*signed(c.get(i,i.operands[2]));c.put(i,i.operands[0],p)
            c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=p<=2147483647 else 0)
        else:extra_step(c,xmm,i);continue
        c.pc+=i.size
    else:raise ValueError('Loader instruction budget')
    drain();banks=[]
    for bank in range(3):
        base=c.read(OBJECT+bank*20+4,4);size=c.read(OBJECT+bank*20+8,4)-base
        if size%168 or not 0<=size<=60000:raise ValueError('Invalid native vector end')
        banks.append([[secured[base+row*168+j*12] for j in range(14)] for row in range(size//168)])
    return {'poison':poison,'opened':opened,'return_bool':bool(c.reg['eax']&0xff),'enabled':c.read(OBJECT+0x50,1),
            'cursor':cursor,'token_count':len(tokens),'stack':hex(c.reg['esp']),'fp_depth':len(fp),
            'stop':list(stop),'banks':banks,'appends':appends,'events':events,
            'steps':steps,'trace_sha256':digest.hexdigest()},list(unique.values())


def expected(tokens,opened):
    """Independent fixture oracle for supported tag/string/numeric token grammar."""
    banks=[[],[],[]];cursor=0
    if not opened:return False,banks
    def take():
        nonlocal cursor
        t=tokens[cursor] if cursor<len(tokens) else {'type':0,'value':None}
        cursor+=1;return t
    while True:
        token=take()
        if token['type']!=5:return True,banks
        if token['value']!='[Revision Table]':continue
        token=take()
        if token['type']!=5 or token['value']!='[type]':return False,banks
        groups=[]
        while True:
            token=take()
            if token['type']!=7:break
            if token['value'] not in ('character','apc','monster'):return False,banks
            groups.append(('character','apc','monster').index(token['value']))
        while True:
            token=take()
            if token['type'] not in (2,4):break
            values=[fbits(token['value'])]
            for _ in range(13):
                token=take();values.append(fbits(token['value']) if token['type'] in (2,4) else fbits(0))
            for bank in groups:banks[bank].append(values[:])


def verify(row,tokens):
    ok,banks=expected(tokens,row['opened'])
    if row['stop']!=['returned'] or row['stack']!='0x70000008' or row['fp_depth']:
        raise ValueError('Loader ABI mismatch')
    if row['return_bool']!=ok or row['enabled']!=int(ok):raise ValueError('Loader enable/result mismatch')
    if row['banks']!=banks:raise ValueError('Loader bank/row values mismatch')
    for bank in range(3):
        if [a['bits'] for a in row['appends'] if a['bank']==bank]!=banks[bank]:raise ValueError('Append sequence mismatch')


def audit(source):
    from contextlib import closing
    from dnf_pvf import open_library
    from audit_dnf_design import decode_tokens
    paths=('dungeon/towers/table/towerofillusion.tbl','dungeon/towers/table/towerofdeath.tbl',
           'dungeon/towers/table/towerofdespair.tbl','dungeon/towers/table/towerofbloodyfight.tbl',
           'dungeon/warroom/table/towerofbloodyfight.tbl','dungeon/event/dual/table/dual_raid.tbl',
           'dungeon/southerndale/table/southerndale.tbl')
    inputs=[]
    with closing(open_library()) as library:
        for path in paths:
            raw,sha=library.raw(path)
            inputs.append({'name':path,'sha256':sha,'asset_version':library.asset_version,
                'tokens':[{'type':t['type'],'value':t['value']} for t in decode_tokens(raw,library.strings)['tokens']]})
    def tag(t):return {'type':5,'value':t}
    def string(t):return {'type':7,'value':t}
    prefix=[tag('[Revision Table]'),tag('[type]')]
    inputs += [{'name':'synthetic_shared_groups','tokens':prefix+[string('monster'),string('character'),tag('[/type]')]+
                [{'type':2,'value':v} for v in range(28)]+[tag('[/Revision Table]')]},
               {'name':'synthetic_unknown_group','tokens':prefix+[string('unknown')]},
               {'name':'synthetic_empty_file','tokens':[]}]
    runs=[];traces=[]
    for entry in inputs:
        for poison in (False,True):
            row,trace=replay(source,entry['tokens'],poison=poison);verify(row,entry['tokens'])
            row['input']=entry['name'];runs.append(row);traces.append(trace)
    row,trace=replay(source,inputs[0]['tokens'],opened=False);verify(row,inputs[0]['tokens'])
    row['input']=inputs[0]['name'];runs.append(row);traces.append(trace)
    names=('audit_dnf_revision_table.py','audit_dnf_ice_shatter.py','audit_dnf_firewave.py','audit_dnf_ice_particle_bindings.py',
           'audit_dnf_native_strings.py','dnf_native_vm_probe.py','audit_dnf_particle_axis.py','dnf_pvf.py','audit_dnf_design.py')
    return {'schema':'dnf_revision_table/1','engine_sha256':ENGINE_SHA,'input_source':source.source,'method':__doc__.strip(),
            'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
            'inputs':inputs,'runs':runs,'blocks':source_blocks(source,traces),
            'boundaries':['File/tag/string/token readers, reset/allocator, secure writes and generic row copy/destructor are ABI fixtures.',
                'Original 1218B30 handles integer/float types and numeric failure; original 401C80 compares UTF16 strings. Type3/indirect strings/error diagnostics excluded.',
                'Tables are passed as explicit ordered tokens. DGN filename dispatch, actual PVF selection, object lifetime and final damage are not established.',
                'Reserved vectors avoid growth; generic copy verifies original count14/stride12/copy function4A13F0 but does not replay the copy helper body.',
                'Empty successful file enables the object while tables remain empty; open/type failures return false after reset. These source behaviors are not recommended validation policy.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path)
    p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite client')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[REVISION_TABLE] {len(e['runs'])} source paths verified")


if __name__=='__main__':main()

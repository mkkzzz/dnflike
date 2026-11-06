"""Replay protected native skill-base table routing and append loops as data.

Uses a source-derived VM frame spliced at recovered tag operands, not the full
client startup. Decoded tag equality, token source, secure primitives and empty
preallocated vector storage are explicit ABI fixtures. Original VM control flow,
integer reader, secure temporary constructor, vector append and cursor updates
run in the bounded Python instruction interpreter. Never executes a native PE.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from audit_dnf_native_strings import ENGINE_SHA, recover_string
from audit_dnf_ice_particle_bindings import vm_frame, HANDLER, decode_immediate, source_blocks
from audit_dnf_ice_shatter import signed

ROUTES={
    'dungeon':{'tag':'[skill damage base parameter dungeon]','operand':0x2182E63,'string':0x15B35E8,'base':0x1A66978},
    'pvp':{'tag':'[skill damage base parameter pvp]','operand':0x217F79B,'string':0x15B3598,'base':0x1A66A04},
}
FIXTURES={0x401DD0,0x441540,0x119A6F0,0x119A800,0x1197630,0x1195A10,0x1195EB0,0x1195DC0}
NATIVE={0x40A950,0x406970}
NEXT_TAG=0x121A540


def replay(source, mode, values, *, poison=False, entry=None):
    """Feed integer tokens only. Stop when source asks for the following tag."""
    if mode not in ROUTES or len(values)>700 or any(type(v) is not int for v in values):
        raise ValueError('Unmodeled token fixture')
    route=ROUTES[mode];c,prefix=vm_frame(source)
    c.string_clobber=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
    c.reg['esi']=route['operand'] if entry is None else entry;c.pc=HANDLER
    secured={};vectors={};clears=[];comparisons=[];reads=[];appends=[];cursor=0
    digest=hashlib.sha256();unique={};steps=0;stop=None

    def drain():
        nonlocal steps
        for line in c.trace:
            digest.update((line+'\n').encode());unique[int(line[:8],16)]=line
        steps+=len(c.trace);c.trace.clear()

    for _ in range(2000000):
        if len(c.trace)>=4096:drain()
        if c.pc==NEXT_TAG:
            stop='next_tag';break
        if c.pc in FIXTURES:
            target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
            returned,pop=0,0
            if target==0x401DD0:
                text=c.strings.get(arg(1))
                if text not in [r['tag'] for r in ROUTES.values()]:raise ValueError('Unexpected compared tag')
                returned=int(text==route['tag']);comparisons.append({'tag':text,'matched':bool(returned)})
            elif target==0x441540:
                if this not in {0x1A66978+j*20 for j in range(14)}:raise ValueError('Unexpected vector clear')
                if this in vectors:raise ValueError('Repeated clear')
                base=0x61200000+(this-0x1A66978)//20*0x10000
                # Allocation/clear body is excluded. Empty vectors have reserved
                # capacity, so original append never needs host allocation.
                for j,value in enumerate((0,base,base,base+1200,0)):c.write(this+j*4,4,value)
                vectors[this]=base;clears.append(hex(this))
            elif target==0x119A6F0:
                if this!=0x1D176C8:raise ValueError('Unknown token cursor')
                returned=2 if cursor<len(values) else 5
                reads.append({'cursor':cursor,'token_type':returned})
            elif target==0x119A800:
                if this!=0x1D176C8 or cursor>=len(values):raise ValueError('Invalid integer token request')
                returned=values[cursor]&0xffffffff;cursor+=1
            elif target==0x1197630:secured[this]=0
            elif target==0x1195A10:
                if arg(1)!=this+8:raise ValueError('Secure write key mismatch')
                value=c.read(arg(0),4);secured[this]=value;pop=8
                for vector,base in vectors.items():
                    if base<=this<base+1200:
                        appends.append({'vector':hex(vector),'index':(this-base)//12,'value':signed(value)})
                        break
            elif target==0x1195EB0:
                if arg(0)!=this+8 or this not in secured:raise ValueError(f'Unmodeled secure read {this:#x}')
                c.write(arg(1),4,secured[this]);pop=8
            elif target==0x1195DC0:
                if this not in secured:raise ValueError('Destroy unknown secure value')
                del secured[this]
            c.reg['eax']=returned;c.pc=c.pop();c.reg['esp']+=pop
            c.reg['ecx'],c.reg['edx'],c.flags=c.string_clobber
            continue
        result=c.run(c.pc,1)
        if result[0]=='budget':continue
        ins=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
        if result[0]=='call' and int(result[2],16) in FIXTURES|NATIVE:
            c.push(c.pc+ins.size);c.pc=int(result[2],16);continue
        if result[0]=='unsupported' and ins.mnemonic=='imul' and len(ins.operands)==1:
            product=signed(c.reg['eax'])*signed(c.get(ins,ins.operands[0]))
            c.reg['eax']=product&0xffffffff;c.reg['edx']=(product>>32)&0xffffffff
            overflow=not -2147483648<=product<=2147483647
            c.flags=(c.flags&~0x801)|(0x801 if overflow else 0);c.pc+=ins.size;continue
        raise ValueError(f'Loader stopped outside known boundary: {result}')
    else:raise ValueError('Loader instruction budget')
    drain()
    columns=[]
    for vector,base in sorted(vectors.items()):
        size=c.read(vector+8,4)-base
        if size<0 or size%12 or size>1200:raise ValueError('Invalid vector end')
        columns.append({'vector':hex(vector),'values':[signed(secured[base+j*12]) for j in range(size//12)]})
    return {'mode':mode,'entry':hex(route['operand'] if entry is None else entry),'poison':poison,
            'input_values':list(values),'stop':stop,'token_cursor':cursor,'clears':clears,
            'comparisons':comparisons,'token_reads':reads,'appends':appends,'columns':columns,
            'steps':steps,'trace_sha256':digest.hexdigest(),'branch_count':len(c.branches)},prefix,list(unique.values())


def verify(row):
    route=ROUTES[row['mode']];values=row['input_values']
    padding=(-len(values))%7
    stored=values+[0]*padding
    expected_vectors=[hex(route['base']+j*20) for j in range(7)]
    if row['stop']!='next_tag' or row['token_cursor']!=len(values):raise ValueError('Incomplete table parsing')
    if row['clears']!=expected_vectors or [c['vector'] for c in row['columns']]!=expected_vectors:
        raise ValueError('Table routed to wrong global vectors')
    expected=[{'vector':expected_vectors[j%7],'index':j//7,'value':v} for j,v in enumerate(stored)]
    if row['appends']!=expected:raise ValueError('Original append order/values differ')
    if [c['values'] for c in row['columns']]!=[stored[j::7] for j in range(7)]:
        raise ValueError('Column transposition differs')
    if row['token_reads']!=[{'cursor':j,'token_type':2} for j in range(len(values))]+[{'cursor':len(values),'token_type':5}]*(padding+1):
        raise ValueError('Token stream termination differs')


def audit(source):
    from contextlib import closing
    from dnf_pvf import open_library
    with closing(open_library()) as library:
        doc=library.script('etc/etcparameter.etc')
        fields={f['tag']:f['values'] for f in doc['fields'] if f['tag'] in [r['tag'] for r in ROUTES.values()]}
        record={'path':'etc/etcparameter.etc','sha256':doc['sha256'],'asset_version':library.asset_version,'fields':fields}
    operands=[]
    for mode,r in ROUTES.items():
        if decode_immediate(source,r['operand'])!=r['string']:raise ValueError('Wrong protected tag operand')
        raw=source.source_bytes(r['string'],128);text,size=recover_string(raw,0,2)
        if text!=r['tag']:raise ValueError('Wrong original tag')
        operands.append({'mode':mode,'address':hex(r['operand']),'raw8':source.source_bytes(r['operand'],8).hex(),
                         'decoded':hex(r['string']),'string_raw':raw[:size+4].hex(),'text':text})
    runs=[];traces=[]
    for mode,r in ROUTES.items():
        for poison in (False,True):
            row,prefix,trace=replay(source,mode,fields[r['tag']],poison=poison)
            verify(row);runs.append(row);traces.extend((prefix,trace))
        for values in ([],[1,99,98],list(range(14))):
            row,prefix,trace=replay(source,mode,values,poison=True)
            verify(row);runs.append(row);traces.append(trace)
    names=('audit_dnf_fixed_table_loader.py','audit_dnf_ice_particle_bindings.py','dnf_native_vm_probe.py',
           'audit_dnf_native_strings.py','audit_dnf_particle_axis.py','audit_dnf_ice_shatter.py','dnf_pvf.py','audit_dnf_design.py')
    return {'schema':'dnf_fixed_table_loader/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
            'method':__doc__.strip(),'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
            'source_table':record,'operands':operands,'runs':runs,'blocks':source_blocks(source,traces),
            'boundaries':['VM frame comes from 7711D0, spliced at tag immediate operands; full etcparameter loader startup and file selection are not replayed.',
                'Comparison receives the selected original tag; token source supplies only original integer values, then type5 terminator; file tokenization not replayed.',
                'Clear/allocation is an empty reserved-vector ABI fixture; original append and pointer increments are replayed with secure storage fixtures.',
                'Full 700-token fields produce 100 elements per column, with no extra sentinel in this loaded-field path. Later mutations outside this path not covered.',
                'Table column1 binding is established together with prior 90A6F0/75EB80 evidence; owner-stat provenance, normalization, skill values and hit engine remain incomplete.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path)
    p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite client')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    doc=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(doc,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[FIXED_TABLE_LOADER] {len(doc['runs'])} source paths verified")


if __name__=='__main__':main()

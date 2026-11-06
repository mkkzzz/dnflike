"""Bounded native DGN revision filename registration/dispatch/copy/load routing.

Three source blocks use explicitly prepared stack frames, not full DGN parsing
or dungeon construction. Native tag registration operands, enum jump tables,
record offsets, copy gates, SSO pointer selection and load-call arguments are
replayed. String read/copy and the final loader call are ABI boundaries; original
table loading has a separate artifact. Fresh objects and stable pointers only.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from audit_dnf_native_strings import ENGINE_SHA, recover_string
from audit_dnf_ice_particle_bindings import source_blocks, trace_hash

FRAME, RECORD, OBJECT = 0x6FFFF000,0x60000000,0x60100000
TAG_VA=0x18759F8


def replay(source,filename,*,poison=False):
    from dnf_native_vm_probe import CPU
    c=CPU(source);c.reg['ebp']=FRAME;c.reg['esp']=FRAME-0x2000
    for a in range(FRAME-0x2100,FRAME+0x10,4):c.write(a,4,0)
    for base in (RECORD,OBJECT):
        for j in range(0,0x800,4):c.write(base+j,4,0)
    c.string_clobber=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
    events=[];phases=[];allocated=0x60800000

    def set_string(out,value):
        nonlocal allocated
        data=(value+'\0').encode('utf-16le')
        if len(value)<8:base=out+4;capacity=7
        else:
            base=allocated;allocated+=(len(data)+15)&~15;capacity=len(value)
            c.write(out+4,4,base)
        for j in range(0,len(data),2):c.write(base+j,2,int.from_bytes(data[j:j+2],'little'))
        c.write(out+0x14,4,len(value));c.write(out+0x18,4,capacity)

    def read_z(base):
        chars=[]
        for j in range(512):
            value=c.read(base+j*2,2)
            if not value:return ''.join(chars)
            chars.append(chr(value))
        raise ValueError('Unterminated filename fixture')

    def get_string(out):
        return read_z(c.read(out+4,4) if c.read(out+0x18,4)>=8 else out+4)

    def run(start,end,phase):
        c.pc=start;begin=len(c.trace)
        for _ in range(2000):
            if c.pc==end:
                phases.append({'phase':phase,'start':hex(start),'end':hex(end),'steps':len(c.trace)-begin});return
            if c.pc in (0x121A480,0x405420,0x9363B0):
                target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
                result,pop=0,0
                if target==0x121A480:
                    out=arg(0);set_string(out,filename);result=1
                    events.append({'kind':'string_read_fixture','destination':hex(out),'value':filename})
                elif target==0x405420:
                    if [arg(1),arg(2)]!=[0,0xffffffff]:raise ValueError('Unexpected string copy slice')
                    value=get_string(arg(0));set_string(this,value);result=this;pop=12
                    events.append({'kind':'string_copy_fixture','source':hex(arg(0)),'destination':hex(this),'value':value})
                else:
                    events.append({'kind':'load_boundary','this':hex(this),'filename':read_z(arg(0)),
                                   'filename_pointer':hex(arg(0))});pop=4
                c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
                c.reg['ecx'],c.reg['edx'],c.flags=c.string_clobber;continue
            stop=c.run(c.pc,1)
            if stop[0]=='budget':continue
            if stop[0]=='call':
                target=int(stop[2],16)
                if target not in (0x451130,0x121A480,0x405420,0x9363B0):raise ValueError(f'Unmodeled call {target:#x}')
                i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
                c.push(c.pc+i.size);c.pc=target;continue
            raise ValueError(f'Unmodeled dispatch stop {stop}')
        raise ValueError('Dispatch instruction budget')

    # Registration is a separate observed operand -> tag/id boundary, not a
    # claim that the original std::map insertion/initialization was performed.
    run(0x12F9DD9,0x451130,'registration')
    pair=c.read(c.reg['esp']+8,4)
    registration={'tag':c.strings[c.read(pair,4)],'enum':c.read(pair+4,4),'map':hex(c.reg['ecx'])}
    c.reg['esp']=FRAME-0x2000;c.reg['ebp']=FRAME
    c.write(FRAME-0x1F8,4,RECORD);set_string(RECORD+0x72C,'')
    if filename is not None:
        c.reg['eax']=registration['enum'];c.write(0x1D90EF8,1,1)
        run(0x12F3CA1,0x12FB1EE,'field_dispatch')
    parsed=get_string(RECORD+0x72C)
    # Caller 7E1DF0's local record begins at EBP-834; +72C is EBP-108.
    set_string(FRAME-0x108,parsed);set_string(OBJECT+0x4F0,'')
    c.reg['esp']=FRAME-0x2000;c.reg['edi']=OBJECT;c.reg['ebp']=FRAME
    run(0x7E3BE0,0x7E3BFF,'record_to_object')
    copied=get_string(OBJECT+0x4F0)
    c.reg['esp']=FRAME-0x2000;c.reg['ebx']=OBJECT
    run(0x7DE9D9,0x7DEA06,'load_gate')
    return {'filename':filename,'poison':poison,'registration':registration,'parsed':parsed,'copied':copied,
            'events':events,'phases':phases,'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify(row):
    name=row['filename'];value=name or ''
    if row['registration']!={'tag':'[revision table]','enum':0x85D,'map':'0x1d90f00'}:
        raise ValueError('Wrong DGN field registration')
    if row['parsed']!=value or row['copied']!=value:raise ValueError('Filename field/copy mismatch')
    reads=[e for e in row['events'] if e['kind']=='string_read_fixture']
    copies=[e for e in row['events'] if e['kind']=='string_copy_fixture']
    loads=[e for e in row['events'] if e['kind']=='load_boundary']
    if reads!=([{'kind':'string_read_fixture','destination':hex(RECORD+0x72C),'value':name}] if name is not None else []):
        raise ValueError('Wrong parsed filename destination')
    if copies!=([{'kind':'string_copy_fixture','source':hex(FRAME-0x108),'destination':hex(OBJECT+0x4F0),'value':value}] if value else []):
        raise ValueError('Wrong filename copy gate/destination')
    if len(loads)!=int(bool(value)):raise ValueError('Wrong filename load gate')
    if loads and (loads[0]['filename']!=value or loads[0]['this']!=hex(OBJECT+0x44)):
        raise ValueError('Wrong normalization load object/filename')
    if value and len(value)<8 and loads[0]['filename_pointer']!=hex(OBJECT+0x4F4):
        raise ValueError('Wrong inline string pointer')


def audit(source):
    from contextlib import closing
    from dnf_pvf import open_library
    from audit_dnf_design import decode_tokens
    inventory=[]
    with closing(open_library()) as library:
        version=library.asset_version
        for path,raw in library.files('.dgn'):
            fields=[]
            for field in decode_tokens(raw,library.strings)['tag_spans']:
                if field['tag']=='[revision table]':
                    values=field['values']
                    if len(values)!=1 or values[0]['type']!=7:raise ValueError(f'Unmodeled DGN filename field: {path}')
                    fields.append({'offset':field['offset'],'value':values[0]['value']})
            inventory.append({'path':path,'sha256':hashlib.sha256(raw).hexdigest(),'fields':fields})
    if not inventory:raise ValueError('No DGN files scanned')
    names=sorted({f['value'] for entry in inventory for f in entry['fields']})
    runs=[];traces=[]
    for name in names+['a.tbl','',None]:
        for poison in (False,True):
            row,trace=replay(source,name,poison=poison);verify(row);runs.append(row);traces.append(trace)
    raw=source.source_bytes(TAG_VA,128);tag,size=recover_string(raw,0,2)
    provenance=[]
    for start,end in ((0x7E1E1E,0x7E1E4D),):
        raw_block=source.source_bytes(start,end-start)
        provenance.append({'start':hex(start),'sha256':hashlib.sha256(raw_block).hexdigest(),
            'instructions':[f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in source.decoder.disasm(raw_block,start)]})
    table_path=Path(__file__).resolve().parents[1]/'docs/reports/ws2/2026-11/native_revision_table.json'
    table=json.loads(table_path.read_text(encoding='utf8'))
    tables={r['input']:{'loaded':r['return_bool'],'enabled':r['enabled'],'rows':[len(b) for b in r['banks']]}
            for r in table['runs'] if r['opened'] and not r['poison'] and r['input'].endswith('.tbl')}
    for name in names:
        if name.lower() not in tables:raise ValueError('Referenced table has no published loader evidence')
    tools=('audit_dnf_revision_dispatch.py','audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py',
           'dnf_native_vm_probe.py','audit_dnf_particle_axis.py','dnf_pvf.py','audit_dnf_design.py')
    return {'schema':'dnf_revision_dispatch/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
            'method':__doc__.strip(),'asset_version':version,'inventory':sorted(inventory,key=lambda x:x['path']),
            'tag':{'address':hex(TAG_VA),'text':tag,'raw':raw[:size+4].hex()},
            'table_evidence':{'path':'docs/reports/ws2/2026-11/native_revision_table.json',
                'sha256':hashlib.sha256(table_path.read_bytes().replace(b'\r\n',b'\n')).hexdigest(),'tables':tables},
            'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in tools},
            'static_provenance':provenance,'runs':runs,'blocks':source_blocks(source,traces),
            'boundaries':['Separate bounded blocks with synthetic frames; registration map insertion/lookup and full DGN constructor are not replayed.',
                'String input/copy are ABI fixtures; replay proves original destinations, gates and SSO selection, not std::wstring allocator behavior.',
                'Final load is a call boundary linked to previous loader evidence by SHA, not full same-instance startup execution.',
                'Inventory covers this archived PVF only. No field in a fresh-object fixture means no call here; other mode paths/later writes remain possible.',
                'Three referenced old-format tables fail under the published reader fixture. Do not claim actual original dungeon failure without effective-version/runtime evidence.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path)
    p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite client')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[REVISION_DISPATCH] {len(e['inventory'])} DGN records, {len(e['runs'])} source paths verified")


if __name__=='__main__':main()

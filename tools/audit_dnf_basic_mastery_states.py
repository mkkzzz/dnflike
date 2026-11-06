"""Original swordman state identities, flag primitives and mastery eligibility.

Constructors are static provenance, not emulated lifecycle. Only the reset,
virtual setter/getter, activation tail and mastery caller execute source bytes.
"""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sys
from audit_dnf_basic_mastery import replay,verify,STATE,STATE_VTABLES,STATE_OFFSETS
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
from audit_dnf_native_strings import ENGINE_SHA

# skill ID, basename, skill argument, owner store, vtable assignment
BINDINGS=((88,'waveeye',0xCD31E9,0xCD32DE,0xCC1E7B),
          (82,'kalla',0xCA4CF2,0xCA4D52,0xCA4D3C),
          (18,'ghoststep',0xCA4E32,0xCA4E77,0xCA31CF))


def bindings(source):
    rows=[]
    for (skill,name,arg,store,assign),off,vt in zip(BINDINGS,STATE_OFFSETS,STATE_VTABLES):
        instructions=[]
        for pc in (arg,store,assign):
            i=next(source.decoder.disasm(source.source_bytes(pc,15),pc,count=1))
            instructions.append({'address':hex(pc),'bytes':i.bytes.hex(),'instruction':f'{i.mnemonic} {i.op_str}'})
        a,b,c=[next(source.decoder.disasm(bytes.fromhex(x['bytes']),int(x['address'],16),count=1)) for x in instructions]
        if (a.mnemonic!='push' or a.operands[0].type!=2 or a.operands[0].imm!=skill or
            b.mnemonic!='mov' or b.operands[0].type!=3 or b.operands[0].mem.disp!=off or b.reg_name(b.operands[0].mem.base)!='esi' or
            c.mnemonic!='mov' or c.operands[1].type!=2 or c.operands[1].imm!=vt):raise ValueError('State binding mismatch')
        slots={hex(o):hex(int.from_bytes(source.source_bytes(vt+o,4),'little')) for o in (0x58,0x6C,0x70)}
        if slots!={'0x58':'0x928b70','0x6c':'0x42d640','0x70':'0x42d650'}:raise ValueError('State virtual binding mismatch')
        rows.append({'skill_id':skill,'name':name,'owner_offset':hex(off),'vtable':hex(vt),'slots':slots,'instructions':instructions})
    return rows


def flag_primitives(source,index,values=(1,0,255,256,-1)):
    """Replay reset and virtual flag methods on one persistent synthetic object."""
    from dnf_native_vm_probe import CPU
    if index not in range(3) or any(type(v)!=int or not -2147483648<=v<=2147483647 for v in values):raise ValueError('Flag fixture domain')
    c=CPU(source)
    for a in range(0x6FFFF000,0x70000000,4):c.write(a,4,0)
    for j in range(0xAC):c.write(STATE+j,1,0xCC)
    c.write(STATE,4,STATE_VTABLES[index]);events=[]
    def run(start,pop=0,end=None):
        c.reg.update(ecx=STATE,edi=STATE,ebx=17,esi=29,ebp=37,esp=0x70000000,eax=0xA1B2C3D4)
        c.write(0x70000000,4,0xDEADBEEF);c.pc=start
        for _ in range(100):
            if c.pc==end:break
            stop=c.run(c.pc,1)
            if stop[0]=='returned':break
            if stop[0]=='budget':continue
            if stop[0]=='call' and int(stop[2],16)==0x42D640:
                i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
                c.push(c.pc+i.size);c.pc=0x42D640;continue
            raise ValueError(f'Unmodeled flag stop {stop}')
        else:raise ValueError('Flag instruction budget')
        expected_stack=0x70000000 if end is not None else 0x70000004+pop
        if [c.reg[k] for k in ('ebx','esi','edi','ebp','esp')]!=[17,29,STATE,37,expected_stack]:raise ValueError('Flag ABI mismatch')
    def snapshot():return bytes(c.read(STATE+j,1) for j in range(0x30,0xAC)).hex()
    run(0x9287E0);reset=snapshot()
    c.write(STATE+0x41,1,0xA5);c.write(STATE+0x42,1,0x5A)
    for value in values:
        before=snapshot();c.write(0x70000004,4,value)
        run(c.read(STATE_VTABLES[index]+0x6C,4),4)
        after=snapshot();run(c.read(STATE_VTABLES[index]+0x70,4))
        events.append({'input':value,'before':before,'after':after,'al':c.rr('al'),'eax':c.reg['eax']})
    before=snapshot();run(0x92900C,end=0x929017);after=snapshot()
    run(c.read(STATE_VTABLES[index]+0x70,4))
    return {'fixture':{'index':index,'values':list(values)},'reset':reset,'events':events,
        'activation_tail':{'before':before,'after':after,'al':c.rr('al')},
        'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify_flags(row):
    expected=bytearray([0xCC]*0x7C)
    # Independent expected field map from the reset routine; padding preserved.
    for offset,width,value in ((0x3C,4,0),(0x40,2,0),(0x42,1,0),(0x44,4,0),(0x48,4,-1),(0x4C,4,-1),
        (0x50,4,0),(0x84,4,-1),(0x80,4,0),(0x88,1,0),(0x8C,4,-1),(0x90,4,1),(0x94,4,0),(0x98,4,0),
        (0x54,4,0x1B2E7),(0x78,4,1),(0x9C,4,0),(0xA0,4,11),(0xA4,4,-1)):
        expected[offset-0x30:offset-0x30+width]=(value&((1<<(8*width))-1)).to_bytes(width,'little')
    if row['reset']!=expected.hex():raise ValueError('State reset mismatch')
    expected[0x11]=0xA5;expected[0x12]=0x5A
    if [e['input'] for e in row['events']]!=row['fixture']['values']:raise ValueError('State input mismatch')
    for event in row['events']:
        if event['before']!=expected.hex():raise ValueError('State continuity mismatch')
        value=event['input']&255;expected[0x10]=value
        if event['after']!=expected.hex() or event['al']!=value or event['eax']!=0xA1B2C300+value:raise ValueError('State flag mismatch')
    event=row['activation_tail']
    if event['before']!=expected.hex():raise ValueError('State activation continuity mismatch')
    expected[0x10]=1
    if event['after']!=expected.hex() or event['al']!=1:raise ValueError('State activation mismatch')


def source_skills():
    from dnf_pvf import open_library
    from audit_dnf_reusable_data import TextResolver
    with closing(open_library()) as lib:
        lst='skill/swordmanskill.lst';_,sha=lib.raw(lst);mapping=lib.listing(lst);resolver=TextResolver(lib);rows=[]
        for skill,name,*_ in BINDINGS:
            path=mapping[skill].replace('\\','/').lower()
            if not path.startswith('skill/'):path='skill/'+path
            if Path(path).stem!=name:raise ValueError('Unexpected original skill ID binding')
            raw,digest=lib.raw(path);rows.append({'skill_id':skill,'path':path,'sha256':digest,'text':resolver.fields(raw)})
        return {'lst':lst,'sha256':sha,'skills':rows,'text_sources':resolver.sources}


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    identities=bindings(source);primitives=[];runs=[];traces=[]
    for index in range(3):
        row,trace=flag_primitives(source,index);verify_flags(row);primitives.append(row);traces.append(trace)
    cases=((None,None,None),(0,0,0),(1,None,None),(None,1,None),(None,None,1),
           (2,0,0),(0,2,0),(0,0,255),(1,1,1),(0,1,1),(0,None,1),(None,0,0))
    for states in cases:
        for category in (8,7,15,18):
            for poison in (False,True):
                row,trace=replay(source,category=category,rank=60,learned=60,values=(1416.,)*3,
                    states=states,caller=True,cached_skill=True,native_states=True,poison=poison)
                verify(row);runs.append(row);traces.append(trace)
    provenance=[]
    for start,end in ((0xCD31E1,0xCD32E4),(0xCC1E30,0xCC1E81),(0xCA4CC0,0xCA4D58),
                      (0xCA4E00,0xCA4E7D),(0xCA3190,0xCA31D5)):
        raw=source.source_bytes(start,end-start)
        provenance.append({'start':hex(start),'end':hex(end),'sha256':hashlib.sha256(raw).hexdigest(),
            'instructions':[f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in source.decoder.disasm(raw,start)]})
    names=('audit_dnf_basic_mastery_states.py','audit_dnf_basic_mastery.py','audit_dnf_firewave.py',
        'audit_dnf_ice_shatter.py','audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py',
        'audit_dnf_particle_axis.py','dnf_native_vm_probe.py','dnf_pvf.py','audit_dnf_reusable_data.py')
    return {'schema':'dnf_basic_mastery_states/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
        'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
        'bindings':identities,'static_provenance':provenance,'primitives':primitives,'runs':runs,'blocks':source_blocks(source,traces),
        'boundaries':[
            'Skill IDs, owner pointer stores and constructor vtable assignments are static provenance; constructors and allocation are not replayed.',
            'Reset 9287E0, virtual setter 42D640 and getter 42D650 execute full entry/return; getter returns AL, not a canonical full-register boolean.',
            '92900C..929017 activation tail executes a prepared frame through the real virtual setter; protected activation entry, duration, expiration and cleanup remain unresolved.',
            'CA6EE0 caller executes through mastery, native cached skill rank and actual state vtables/getter with synthetic owner/state objects.',
            'Protected skill static/value and secure storage remain ABI fixtures. State pointer production, automatic ranks and final damage consumer are not closed.',
            'No original client process is launched; no runtime skill, animation or full gameplay fidelity claim.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite source')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));e['skill_sources']=source_skills();a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[BASIC_MASTERY_STATES] {len(e['primitives'])} state primitive sequences, {len(e['runs'])} original caller paths")


if __name__=='__main__':main()

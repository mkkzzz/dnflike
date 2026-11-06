"""Original ATK damage-bonus field -> swordman caller -> basic mastery record.

Parser registration and enum dispatch are bounded native fragments; the actual
CA6EE0 callsite executes through 83FA10 and returns to CA6F05. Lexer, dictionary
storage and protected skill services remain explicit ABI fixtures.
"""
import argparse
from contextlib import closing
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
from audit_dnf_basic_mastery import replay,verify,skill_source,OWNER,SKILL,VTABLE
from audit_dnf_firewave import extra_step
from audit_dnf_ice_shatter import fbits,real,signed
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
from audit_dnf_native_strings import ENGINE_SHA

SRC,NODE,FRAME=0x60500000,0x60600000,0x6FFFFE00


def parse_bonus(source,value,*,poison=False):
    from dnf_native_vm_probe import CPU
    if type(value) not in (int,float) or not math.isfinite(value) or not -2147483648<=value<2147483648:raise ValueError('Finite integer-conversion domain')
    if type(value)==float and not -2147483648<=real(fbits(value))<2147483648:raise ValueError('Finite integer-conversion domain after binary32 rounding')
    c=CPU(source)
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.reg.update(ebp=FRAME,esp=FRAME-0x800,esi=SRC,ebx=NODE,edi=31)
    c.write(0x1D8F828,1,0);c.write(0x1D94A4C,4,1)
    c.string_clobber=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
    secure={SRC+0x24:0xBAD0C0DE};cursor=0;fp=[];xmm={f'xmm{j}':0 for j in range(8)};registration=[];phases=[];writes=[]
    def run(start,end):
        nonlocal cursor
        c.pc=start
        for _ in range(3000):
            if c.pc==end:
                phases.append({'start':hex(start),'end':hex(end),'stack':hex(c.reg['esp'])});return
            if c.pc in (0x451130,0x119A6F0,0x119A800,0x119A860,0x1195A10):
                target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4);result=pop=0
                if target==0x451130:
                    if this!=0x1D8F830:raise ValueError('Wrong parser dictionary')
                    pair=arg(1);registration.append({'tag':c.strings[c.read(pair,4)],'enum':c.read(pair+4,4)});pop=8
                elif target==0x119A6F0:
                    if cursor:raise ValueError('Read beyond scalar field')
                    cursor+=1;result=2 if type(value)==int else 4
                elif target==0x119A800:
                    if type(value)!=int:raise ValueError('Wrong integer token getter')
                    result=value&0xFFFFFFFF
                elif target==0x119A860:
                    if type(value)!=float:raise ValueError('Wrong float token getter')
                    fp.append(real(fbits(value)))
                else:
                    if this not in secure or arg(1)!=this+8:raise ValueError('Unexpected parsed field')
                    secure[this]=c.read(arg(0),4);writes.append({'offset':hex(this-SRC),'value':signed(secure[this])});pop=8
                c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
                c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
                for name in xmm:xmm[name]=0x0123456789ABCDEF if poison else 0
                continue
            stop=c.run(c.pc,1)
            if stop[0]=='budget':continue
            i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
            if stop[0]=='call':
                target=int(stop[2],16)
                if target not in (0x451130,0x1218A80,0x4041C0,0x1195A10,0x119A6F0,0x119A800,0x119A860,0x13CD690):raise ValueError(f'Unknown parser call {target:#x}')
                c.push(c.pc+i.size);c.pc=target;continue
            if stop[0]!='unsupported':raise ValueError(f'Parser stop {stop}')
            if i.mnemonic=='leave':c.reg['esp']=c.reg['ebp'];c.reg['ebp']=c.pop()
            elif i.mnemonic=='fstp' and i.operands[0].size in (4,8):
                v=fp.pop();op=i.operands[0];c.put(i,op,fbits(v) if op.size==4 else int.from_bytes(struct.pack('<d',v),'little'))
            elif i.mnemonic=='cvttsd2si':
                v=struct.unpack('<d',c.get(i,i.operands[1]).to_bytes(8,'little'))[0];c.put(i,i.operands[0],math.trunc(v))
            else:extra_step(c,xmm,i);continue
            c.pc+=i.size
        raise ValueError('Parser instruction budget')
    run(0x12CFA55,0x12CFA97)
    c.write(NODE+0x10,4,registration[0]['enum']);c.write(0x1D8F828,1,1)
    run(0x12CF93C,0x12D1609)
    return {'fixture':{'value':value,'poison':poison},'registration':registration,'value':signed(secure[SRC+0x24]),
        'writes':writes,'cursor':cursor,'phases':phases,'fp_depth':len(fp),
        'abi':[c.reg[k] for k in ('ebx','esi','edi','ebp','esp')],
        'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify_parser(row):
    v=row['fixture']['value'];expected=v if type(v)==int else math.trunc(real(fbits(v)))
    if row['registration']!=[{'tag':'[damage bonus]','enum':78}] or row['value']!=expected or row['writes']!=[{'offset':'0x24','value':expected}]:raise ValueError('ATK bonus mapping mismatch')
    if row['cursor']!=1 or row['fp_depth'] or row['abi']!=[NODE,SRC,31,FRAME,FRAME-0x800]:raise ValueError('ATK parser ABI mismatch')
    if any(p['stack']!=hex(FRAME-0x800) for p in row['phases']):raise ValueError('ATK fragment stack mismatch')


def rank_transition(source,rank,*,exists=True,poison=False):
    """Full nonzero-rank setter, then the original base-to-effective copy loop.

    Rebuild stops before additional modifiers. This is not automatic leveling.
    """
    from dnf_native_vm_probe import CPU
    if type(rank)!=int or rank==0 or not -2147483648<=rank<=2147483647:raise ValueError('Nonzero signed-rank domain')
    c=CPU(source)
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.write(OWNER,4,VTABLE);c.write(0x70000004,4,174);c.write(0x70000008,4,rank)
    c.reg.update(ecx=OWNER,ebx=17,esi=29,edi=31,ebp=37)
    secure={SKILL+0x590:1,SKILL+0x59C:37};writes=[];lookups=[];phases=[]
    def run(start,end=None):
        c.pc=start
        for _ in range(6000):
            if c.pc==end:
                phases.append({'start':hex(start),'end':hex(end),'abi':[c.reg[k] for k in ('ebx','esi','edi','ebp','esp')]});return
            if c.pc in (0x8406C0,0x1195A10,0x1195EB0):
                this=c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4);result=0
                if c.pc==0x8406C0:
                    if this!=OWNER or arg(0)!=174:raise ValueError('Rank lookup ABI')
                    lookups.append(174);result=SKILL if exists else 0;pop=4
                else:
                    write=c.pc==0x1195A10
                    if this not in secure or arg(1 if write else 0)!=this+8:raise ValueError('Rank secure ABI')
                    if write:
                        secure[this]=c.read(arg(0),4);writes.append({'offset':hex(this-SKILL),'value':signed(secure[this])})
                    else:c.write(arg(1),4,secure[this])
                    pop=8
                c.reg['eax']=result;c.pc=c.pop();c.reg['esp']+=pop
                c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
                continue
            stop=c.run(c.pc,1)
            if stop[0]=='returned':
                if end is not None:raise ValueError('Premature rank-loop return')
                phases.append({'start':hex(start),'end':'return','abi':[c.reg[k] for k in ('ebx','esi','edi','ebp','esp')]});return
            if stop[0]=='budget':continue
            i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
            if stop[0]=='call':
                target=int(stop[2],16)
                if target not in (0x8406C0,0x1195A10,0x1195EB0):raise ValueError(f'Unknown rank call {target:#x}')
                c.push(c.pc+i.size);c.pc=target;continue
            raise ValueError(f'Rank stop {stop}')
        raise ValueError('Rank instruction budget')
    run(0x844880)
    after_setter=[signed(secure[SKILL+o]) for o in (0x590,0x59C)]
    for j in range(255):c.write(OWNER+0x4018+j*4,4,SKILL if exists and j==174 else 0)
    c.write(0x1A5F184,4,0)
    c.reg.update(ecx=OWNER,ebx=17,esi=29,edi=31,ebp=37,esp=0x70000000)
    run(0x861D80,0x861DEC)
    return {'fixture':{'rank':rank,'exists':exists,'poison':poison},'after_setter':after_setter,
        'after_base_copy':[signed(secure[SKILL+o]) for o in (0x590,0x59C)],'writes':writes,'lookups':lookups,'phases':phases,
        'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify_rank(row):
    f=row['fixture'];rank=f['rank'];exists=f['exists']
    expected=[{'offset':'0x590','value':rank},{'offset':'0x59c','value':rank}] if exists else []
    if row['after_setter']!=([rank,37] if exists else [1,37]) or row['after_base_copy']!=([rank,rank] if exists else [1,37]) or row['writes']!=expected or row['lookups']!=[174]:raise ValueError('Rank transition mismatch')
    if row['phases']!=[{'start':'0x844880','end':'return','abi':[17,29,31,37,0x7000000C]},
        {'start':'0x861d80','end':'0x861dec','abi':[255,OWNER,OWNER+0x4018+255*4,0x6FFFFFFC,0x6FFFFFB0]}]:raise ValueError('Rank boundary ABI mismatch')


def source_attacks():
    from dnf_pvf import open_library,parse_script
    root=Path(__file__).resolve().parents[1]
    moves=json.loads((root/'game_dnf/data/combat.json').read_text(encoding='utf8'))['moves']
    rows=[]
    with closing(open_library()) as lib:
        for name,category in (('attack1',8),('attack2',8),('attack3',8),('dash_attack',7),('air_attack',15)):
            path=moves[name]['atk'];raw,sha=lib.raw(path)
            fields=[f['values'] for f in parse_script(raw,lib.strings)['fields'] if f['tag']=='[damage bonus]']
            rows.append({'move':name,'path':path,'sha256':sha,'fields':fields,'category_fixture':category,
                'status':'explicit_source_field' if fields else 'missing_field_default_not_proven'})
    return rows


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    traces=[];parsers=[];consumers=[];ranks=[];skill=skill_source();attacks=source_attacks()
    for value in (-15,0,20,40,10,-2.9,3.9,16777217,16777217.,-2147483648,2147483647):
        for poison in (False,True):
            row,t=parse_bonus(source,value,poison=poison);verify_parser(row);parsers.append(row);traces.append(t)
    for attack in attacks:
        if not attack['fields']:continue
        if len(attack['fields'])!=1 or len(attack['fields'][0])!=1:raise ValueError('Unexpected ATK scalar shape')
        parsed,t=parse_bonus(source,attack['fields'][0][0],poison=True);verify_parser(parsed);traces.append(t)
        for rank in (1,2,10,60,100):
            values=skill['fields']['[level info]'][1+(rank-1)*3:1+rank*3]
            for poison in (False,True):
                row,t=replay(source,caller=True,cached_skill=True,learned=rank,category=attack['category_fixture'],rank=rank,values=values,
                    static=skill['fields']['[static data]'][0],initial=parsed['value'],poison=poison)
                verify(row);consumers.append({'move':attack['move'],'parsed':parsed,'run':row});traces.append(t)
    callers=[]
    for case in ({'category':0},{'category':18},{'states':(1,None,None)}, {'states':(0,1,None)},
                 {'states':(0,0,1)},{'states':(0,0,0)},{'learned':0},{'skill_exists':False},{'static':0}):
        for poison in (False,True):
            row,t=replay(source,caller=True,**case,poison=poison);verify(row);callers.append(row);traces.append(t)
    for case in ({'rank':0,'learned':0},{'rank':-1,'learned':-1},{'skill_exists':False}):
        for poison in (False,True):
            row,t=replay(source,caller=True,cached_skill=True,**case,poison=poison);verify(row);callers.append(row);traces.append(t)
    for rank in (-1,1,2,10,60,100,101):
        for exists in (False,True):
            for poison in (False,True):
                row,t=rank_transition(source,rank,exists=exists,poison=poison);verify_rank(row);ranks.append(row);traces.append(t)
    names=('audit_dnf_basic_mastery_pipeline.py','audit_dnf_basic_mastery.py','audit_dnf_reusable_data.py','dnf_pvf.py',
        'audit_dnf_firewave.py','audit_dnf_ice_shatter.py','audit_dnf_ice_particle_bindings.py',
        'audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    provenance=[]
    for start,end in ((0x509930,0x5099C2),(0x80A680,0x80A755),(0x861DEC,0x861F77)):
        raw=source.source_bytes(start,end-start)
        provenance.append({'start':hex(start),'end':hex(end),'sha256':hashlib.sha256(raw).hexdigest(),
            'instructions':[f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in source.decoder.disasm(raw,start)]})
    return {'schema':'dnf_basic_mastery_pipeline/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
        'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
        'skill_source':skill,'attack_sources':attacks,'parsers':parsers,'consumers':consumers,'callers':callers,'ranks':ranks,
        'blocks':source_blocks(source,traces),'static_provenance':provenance,'boundaries':[
            'Original tag registration and enum jump table execute; dictionary allocation/search and lexer are fixtures. Full ATK outer loop is excluded.',
            'Original CA6EE0 fragment reads owner+3094 and passes owner+2D4 to 83FA10; native helper returns to CA6F05 in the same CPU. Outer action handler is excluded.',
            'Source consumers execute 8444F0 effective-rank getter and 8406C0 cached skill lookup in bank 0. Cache construction and missing-cache allocation are excluded; synthetic caller edge cases retain explicit lookup ABI fixtures.',
            'Parser and action runs are composed through the parsed value; full resource allocation/copy chain is not replayed.',
            'Existing Godot move-to-ATK bindings and category labels select source samples; this does not prove the entire original action selects those exact files.',
            'Attack2 lacks the field; no zero default is fabricated in this evidence.',
            '844880 nonzero setter and 861D80 base-copy loop run; zero removes a skill and is excluded. Equipment/status modifiers after 861DEC and the event producing rank remain unresolved.',
            '509930 notification prefix, 80A680 skill-174 synchronization prefix and 861DEC follow-up rebuild are static provenance, not replayed paths.',
            'Ranks are explicit fixture inputs from source rows; automatic rank production, protected value service, inner status lifecycle and final damage consumer remain unresolved.',
            'No runtime damage changes or claim of complete basic mastery restoration.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite source')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[BASIC_PIPELINE] {len(e['parsers'])} parser / {len(e['consumers'])} source consumer / {len(e['callers'])} caller / {len(e['ranks'])} rank paths")


if __name__=='__main__':main()

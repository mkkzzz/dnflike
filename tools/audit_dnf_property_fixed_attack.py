"""Original 97A930 property dispatcher, scoped to separate-attack property 53.

Full entry/return, native vector indexing, vtable gates and integer/float update
helpers execute original instructions. Records, owner status and secure storage
are explicit ABI inputs. Other property cases fail closed except native skips.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys
from audit_dnf_firewave import extra_step
from audit_dnf_ice_shatter import fbits,real,signed
from audit_dnf_ice_particle_bindings import source_blocks,trace_hash
from audit_dnf_native_strings import ENGINE_SHA,recover_string

OBJECT,STATS,ROWS,OWNER,OWNER_VTABLE,WORD=0x60000000,0x60100000,0x60200000,0x60300000,0x60400000,0x60500000
VTABLES={'plain':0x155B9AC,'owner_gate':0x169EC2C}
OFFSETS=(0x87C,0x888,0x894,0x8A0,0x8AC)


def f32(x):return real(fbits(x))


def replay(source,rows,*,initial=(7,19,1.25,1.75,5),gate='plain',owner_status=0,poison=False):
    from dnf_native_vm_probe import CPU
    if gate not in VTABLES or len(initial)!=5:raise ValueError('Fixture shape')
    c=CPU(source)
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.write(OBJECT,4,VTABLES[gate]);c.write(OBJECT+4,4,OWNER)
    c.write(OBJECT+0xB0,4,ROWS);c.write(OBJECT+0xB4,4,ROWS+len(rows)*36)
    c.write(OWNER,4,OWNER_VTABLE);c.write(OWNER_VTABLE+0xAC,4,0)
    c.write(0x70000004,4,STATS)
    secure={STATS+off:(fbits(value) if j in (2,3) else value&0xFFFFFFFF) for j,(off,value) in enumerate(zip(OFFSETS,initial))}
    for j,row in enumerate(rows):
        prop,op,amount=row
        if prop!=53 and 0<=prop<=76:raise ValueError('Other property semantics outside this replay')
        if not math.isfinite(amount) or not -2147483648<=f32(amount)<2147483648:raise ValueError('Finite signed conversion domain')
        base=ROWS+j*36
        for off,value in ((0,prop),(12,op),(24,fbits(amount))):secure[base+off]=value&0xFFFFFFFF
    def state():return [real(secure[STATS+off]) if j in (2,3) else signed(secure[STATS+off]) for j,off in enumerate(OFFSETS)]
    fp=[];xmm={f'xmm{j}':0 for j in range(8)};updates=[];indices=[];states=[];gate_calls=[]
    c.reg.update(ecx=OBJECT,ebx=17,esi=29,edi=31,ebp=37);c.pc=0x97A930
    def clobber():
        c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
        for k in xmm:xmm[k]=0x0123456789ABCDEF if poison else 0
    for _ in range(30000):
        if c.pc==0xA500EB:
            if c.reg['ecx']!=OWNER or c.reg['edx']!=0:raise ValueError('Unknown owner gate ABI')
            gate_calls.append(owner_status);c.reg['eax']=owner_status&0xFFFFFFFF;clobber();c.pc+=2;continue
        if c.pc==0x523520:indices.append(c.read(c.reg['esp']+4,4))
        if c.pc==0x97D5D6:states.append(state())
        if c.pc in (0x1195A10,0x1195EB0):
            write=c.pc==0x1195A10;this=c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
            if arg(1 if write else 0)!=this+8:raise ValueError('Wrong secure key')
            if write:
                secure[this]=c.read(arg(0),4)
                if STATS<=this<STATS+0x900:updates.append({'offset':hex(this-STATS),'bits':secure[this]})
            else:c.write(arg(1),4,secure[this])
            c.reg['eax']=0;c.pc=c.pop();c.reg['esp']+=8;clobber();continue
        stop=c.run(c.pc,1)
        if stop[0]=='returned':break
        if stop[0]=='budget':continue
        i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
        if stop[0]=='call':
            target=int(stop[2],16)
            if target not in (0x1195A10,0x1195EB0,0x523520,0x42CDB0,0x4468B0,0x43DE80,0xA500E0):raise ValueError(f'Unmodeled call {target:#x}')
            c.push(c.pc+i.size);c.pc=target;continue
        if stop[0]!='unsupported':raise ValueError(f'Unmodeled stop {stop}')
        op=i.operands[0]
        if i.mnemonic=='imul' and len(i.operands)==1 and op.size==4:
            product=signed(c.reg['eax'])*signed(c.get(i,op));c.reg['eax']=product&0xFFFFFFFF;c.reg['edx']=(product>>32)&0xFFFFFFFF
            c.flags=(c.flags&~0x801)|(0x801 if not -2147483648<=product<=2147483647 else 0)
        elif i.mnemonic=='addss':
            dst,src=i.operands;name=i.reg_name(dst.reg);b=xmm[i.reg_name(src.reg)] if src.type==1 else c.get(i,src)
            xmm[name]=(xmm[name]&~0xFFFFFFFF)|fbits(real(xmm[name])+real(b))
        elif i.mnemonic=='fld' and op.size==4:fp.append(real(c.get(i,op)))
        elif i.mnemonic=='fstp' and i.op_str=='st(0)':fp.pop()
        else:extra_step(c,xmm,i);continue
        c.pc+=i.size
    else:raise ValueError('Instruction budget')
    return {'fixture':{'rows':rows,'initial':list(initial),'gate':gate,'owner_status':owner_status,'poison':poison},
        'state':state(),'row_states':states,'updates':updates,'indices':indices,'owner_gate_calls':gate_calls,
        'stop':list(stop),'abi':[c.reg[k] for k in ('ebx','esi','edi','ebp','esp')],
        'seh':c.read(0x50000000,4),'fp_depth':len(fp),'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify(row):
    f=row['fixture'];state=[f32(x) if j in (2,3) else x for j,x in enumerate(f['initial'])];states=[];updates=[];indices=[]
    blocked=f['gate']=='owner_gate' and f['owner_status']>0
    if not blocked:
        for index,(prop,op,amount) in enumerate(f['rows']):
            if prop==53:
                if op==0:
                    for j in (0,1):state[j]=signed((state[j]+math.trunc(f32(amount)))&0xFFFFFFFF)
                    changed=(0,1)
                else:
                    for j in (2,3):state[j]=f32(state[j]+f32(f32(amount)*f32(.01)))
                    changed=(2,3)
                for j in changed:updates.append({'offset':hex(OFFSETS[j]),'bits':fbits(state[j]) if j in (2,3) else state[j]&0xFFFFFFFF})
                indices.extend([index]*3)
            states.append(state.copy())
    if row['state']!=state or row['row_states']!=states or row['updates']!=updates:raise ValueError('Property arithmetic mismatch')
    if row['indices']!=indices or row['owner_gate_calls']!=([f['owner_status']] if f['gate']=='owner_gate' else []):raise ValueError('Property dispatch mismatch')
    if row['stop']!=['returned'] or row['abi']!=[17,29,31,37,0x70000008] or row['seh']!=0xFFFFFFFF or row['fp_depth']:raise ValueError('Property ABI mismatch')


def decode_property(source,word,*,poison=False):
    """Full original string-to-property enum reader, native string comparison."""
    from dnf_native_vm_probe import CPU
    c=CPU(source)
    for a in range(0x6FFFC000,0x70000000,4):c.write(a,4,0)
    c.write(WORD+4,4,WORD+0x100);c.write(WORD+0x14,4,len(word));c.write(WORD+0x18,4,100)
    for j,b in enumerate((word+'\0').encode('utf-16le')):c.write(WORD+0x100+j,1,b)
    c.write(0x70000004,4,WORD);c.reg.update(esi=29,edi=31,ebp=37)
    c.string_clobber=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202);c.pc=0x124FF50
    for _ in range(30000):
        stop=c.run(c.pc,1)
        if stop[0]=='returned':break
        if stop[0]=='budget':continue
        i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
        if stop[0]=='call':
            target=int(stop[2],16)
            if target not in (0x401C80,0x401DD0,0x13CC488):raise ValueError(f'Unknown enum helper {target:#x}')
            c.push(c.pc+i.size);c.pc=target;continue
        if stop[0]=='unsupported' and i.mnemonic=='cmovb':
            if c.flags&1:c.put(i,i.operands[0],c.get(i,i.operands[1]))
            c.pc+=i.size;continue
        raise ValueError(f'Enum stop {stop}')
    else:raise ValueError('Enum budget')
    return {'word':word,'poison':poison,'property':signed(c.reg['eax']),'stop':list(stop),
        'abi':[c.reg[k] for k in ('esi','edi','ebp','esp')],'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def verify_decode(row):
    expected={'[separate attack]':53,'[not a native property]':-1}[row['word']]
    if row['property']!=expected:raise ValueError('Property enum mismatch')
    if row['stop']!=['returned'] or row['abi']!=[29,31,37,0x70000004]:raise ValueError('Enum ABI mismatch')


def audit(source):
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    traces=[];runs=[];decodes=[];consumers=[]
    for word in ('[separate attack]','[not a native property]'):
        for poison in (False,True):
            row,trace=decode_property(source,word,poison=poison);verify_decode(row);decodes.append(row);traces.append(trace)
    cases=[[],[[53,0,3.9]],[[53,0,-3.9]],[[53,1,10.]],[[53,-1,-10.]],[[53,7,10.]],
        [[53,1,10.],[53,1,-10.]],[[53,0,3.9],[53,0,-2.9],[53,1,10.],[53,1,20.]],
        [[77,0,100.],[53,0,3.9],[-1,1,200.]],[[53,0,16777217.]],
        [[53,1,16777216.],[53,1,1.],[53,1,-16777216.]]]
    from audit_dnf_fixed_base import replay as consume,verify as verify_consumer
    for rows in cases:
        for gate,status in (('plain',99),('owner_gate',0),('owner_gate',1),('owner_gate',-1)):
            for poison in (False,True):
                row,trace=replay(source,rows,gate=gate,owner_status=status,poison=poison);verify(row);runs.append(row);traces.append(trace)
            if rows==cases[7]:
                a,b,m,n,z=row['state']
                for mode in (3,4,5,7,9):
                    result,trace=consume(source,mode=mode,table_mode=1,info_kind=3,add_normal=a-3,add_special=b-3,
                        mul_normal=m,mul_special=n-3/8,final_add=z-3,poison=True)
                    verify_consumer(result);traces.append(trace);consumers.append({'state':row['state'],'gate':gate,'owner_status':status,'run':result})
    for rows,initial in (([[53,0,1.]],(2147483647,-2147483648,1,1,5)),([[53,1,1.],[53,1,1.]],(0,0,16777216,16777216,5))):
        for poison in (False,True):
            row,trace=replay(source,rows,initial=initial,poison=poison);verify(row);runs.append(row);traces.append(trace)
    names=('audit_dnf_property_fixed_attack.py','audit_dnf_fixed_base.py','audit_dnf_firewave.py','audit_dnf_ice_shatter.py',
        'audit_dnf_ice_particle_bindings.py','audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py')
    jump_index=source.source_bytes(0x97D6E8+53,1)[0]
    return {'schema':'dnf_property_fixed_attack/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
        'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
        'tag':recover_string(source.source_bytes(0x185CDAC,8192),0,2)[0],
        'dispatch':{'property':53,'index':jump_index,'target':hex(int.from_bytes(source.source_bytes(0x97D610+jump_index*4,4),'little'))},
        'constant_percent':{'address':'0x1559c80','bits':int.from_bytes(source.source_bytes(0x1559C80,4),'little')},
        'vtables':{name:{'address':hex(v),'entry_slot':source.source_bytes(v+12,4).hex(),'gate_slot':source.source_bytes(v+0xAC,4).hex()} for name,v in VTABLES.items()},
        'decodes':decodes,'runs':runs,'consumers':consumers,'blocks':source_blocks(source,traces),
        'boundaries':['Full enum-reader and 97A930 entries/returns run; only property 53 and out-of-range skips are covered, not other property cases.',
            'Original vtable gates 43DE80/A500E0 execute. Inner owner virtual status is an ABI fixture; real owner status production and class construction remain unresolved.',
            'Records are synthetic 36-byte inputs, not parsed real appendage content. Secure storage and native string allocation are ABI fixtures.',
            'Float math models finite binary32 round-to-nearest; NaN, infinity, out-of-range CVTTSS2SI and alternate MXCSR modes are excluded.',
            'Separate base-service replays use accumulated outputs, synthetic base tables and stable consumer modes; complete actor rebuild order and final damage remain unresolved.',
            'No Godot runtime damage changes or claim of original-equivalent skills/status lifecycle.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite source')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[PROPERTY_FIXED] {len(e['decodes'])} enum paths; {len(e['runs'])} dispatcher paths; {len(e['consumers'])} consumers")


if __name__=='__main__':main()

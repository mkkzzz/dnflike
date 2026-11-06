"""Replay original fixed-attack base service 75EB80 with explicit input fixtures.

No PE execution. Vector contents, secure storage, singleton and owner object
are synthetic ABI inputs, not reconstructed original character data. Native code
selects vector/level, reads field offsets and computes the base. x87 is restricted
to finite binary64 intermediates and explicit stores; only SSE2 truncation helper
branch is replayed. The original configuration loader remains unverified.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys

from audit_dnf_ice_shatter import fbits, real, signed
from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_native_strings import ENGINE_SHA

OWNER, MANAGER, OUT = 0x60000000, 0x60100000, 0x60300000
FIXTURES = {0x1197630, 0x1195A10, 0x1195EB0, 0x1195DC0, 0x1195B90,
            0x6FC760, 0x1194FC0, 0xE6E070}
NATIVE = {0xFEECF0, 0x406970, 0x40A950, 0x42CDB0, 0x752880, 0x752850,
          0x75E960, 0x75E990, 0x13CD690, 0xD07390}


def table_value(bank, column, row):
    return 100 + bank * 100000 + column * 1000 + row * 3


def replay(source, *, table_mode=1, mode=1, column=1, level=40, count=101,
           info_kind=3, owner_fallback=False, poison=False,
           add_normal=7, add_special=19, mul_normal=1.25, mul_special=1.75,
           final_add=5, unused_parameter=0):
    from dnf_native_vm_probe import CPU
    c=CPU(source)
    for a in range(0x6FFFFC00,0x70000000,4):c.write(a,4,0)
    for j,value in enumerate((OUT,table_mode,column,level,unused_parameter,0 if owner_fallback else OWNER,info_kind)):
        c.write(0x70000004+j*4,4,value)
    c.write(OWNER,4,0x16F972C)
    c.write(0x1AB7CDC,4,OWNER);c.write(MANAGER+0xA4,4,0x12345678)
    c.write(0x1D94A4C,4,1)  # explicitly select source SSE2 truncation path
    secured={}
    for bank in range(2):
        for col in range(7):
            base=0x61000000+bank*0x10000+col*0x1000
            vector=0x1A66978+bank*140+col*20
            c.write(vector+4,4,base);c.write(vector+8,4,base+count*12)
            for row in range(count):secured[base+row*12]=table_value(bank,col,row)
    for kind in set((3,info_kind)):
        info=OWNER+0x8AC+kind*0x8D0
        # Distinct info-kind values expose source's special multiplier query of 3.
        secured.update({info+0x87C:add_normal+kind,info+0x888:add_special+kind,
                        info+0x894:fbits(mul_normal),info+0x8A0:fbits(mul_special+kind/8),
                        info+0x8AC:final_add+kind})
    secured={key:value&0xffffffff for key,value in secured.items()}
    fp=[];events=[];c.pc=0x75EB80
    for _ in range(4000):
        if c.pc in (0xFEECF0,0xD07390):
            events.append({'kind':'vector_lookup' if c.pc==0xFEECF0 else 'native_owner_info',
                           'target':hex(c.pc),'this':hex(c.reg['ecx']),
                           'argument':c.read(c.reg['esp']+4,4)})
        if c.pc in FIXTURES:
            target,this=c.pc,c.reg['ecx'];arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
            e={'target':hex(target),'this':hex(this)};result,pop=0,0
            if target==0x1197630:
                secured[this]=0;e.update(kind='secure_init')
            elif target==0x1195A10:
                if arg(1)!=this+8:raise ValueError('Secure write key mismatch')
                secured[this]=c.read(arg(0),4);pop=8;e.update(kind='secure_write',value=signed(secured[this]))
            elif target==0x1195EB0:
                if arg(0)!=this+8 or this not in secured:raise ValueError(f'Unmodeled secure read {this:#x}')
                c.write(arg(1),4,secured[this]);pop=8;e.update(kind='secure_read',value=signed(secured[this]))
            elif target==0x1195DC0:e.update(kind='secure_destroy')
            elif target==0x1195B90:
                if c.read(arg(0),4)!=0x12345678:raise ValueError('Unknown mode storage fixture')
                c.write(arg(1),4,mode);e.update(kind='mode_decode',value=mode)
            elif target==0x6FC760:result=MANAGER;e.update(kind='singleton_fixture')
            elif target==0x1194FC0:result=0x60402000;e.update(kind='diagnostic_string_fixture',address=hex(arg(0)))
            elif target==0xE6E070:pop=12;e.update(kind='diagnostic_fixture',args=[arg(j) for j in range(3)])
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
        if i.mnemonic=='leave':
            c.reg['esp']=c.reg['ebp'];c.reg['ebp']=c.pop();c.pc+=i.size;continue
        if not i.operands:raise ValueError(f'Unmodeled instruction {i.mnemonic}')
        op=i.operands[0]
        if i.mnemonic=='imul' and len(i.operands) in (1,3) and op.size==4:
            if len(i.operands)==1:
                product=signed(c.reg['eax'])*signed(c.get(i,op))
                c.reg['eax']=product&0xffffffff;c.reg['edx']=(product>>32)&0xffffffff
            else:
                product=signed(c.get(i,i.operands[1]))*signed(c.get(i,i.operands[2]))
                c.put(i,op,product)
            overflow=not -2147483648<=product<=2147483647
            c.flags=(c.flags&~0x801)|(0x801 if overflow else 0)
        elif i.mnemonic=='fild' and op.size==4:fp.append(float(signed(c.get(i,op))))
        elif i.mnemonic=='fld' and op.size==4:fp.append(real(c.get(i,op)))
        elif i.mnemonic=='fmul' and op.size==4:fp[-1]*=real(c.get(i,op))
        elif i.mnemonic=='fstp' and op.size in (4,8):
            value=fp.pop()
            if not math.isfinite(value):raise ValueError('Non-finite fixture')
            bits=fbits(value) if op.size==4 else int.from_bytes(struct.pack('<d',value),'little')
            c.put(i,op,bits)
        elif i.mnemonic=='cvttsd2si' and i.operands[1].size==8:
            value=struct.unpack('<d',c.get(i,i.operands[1]).to_bytes(8,'little'))[0]
            if not math.isfinite(value) or not -2147483648<=value<2147483648:raise ValueError('Out of range truncation fixture')
            c.put(i,op,math.trunc(value))
        else:raise ValueError(f'Unmodeled floating instruction {i.mnemonic} {i.op_str}')
        c.pc+=i.size
    else:raise ValueError('Base service instruction budget')
    return {'fixture':dict(table_mode=table_mode,mode=mode,column=column,level=level,count=count,
                info_kind=info_kind,owner_fallback=owner_fallback,poison=poison,
                add_normal=add_normal,add_special=add_special,mul_normal=mul_normal,mul_special=mul_special,
                final_add=final_add,unused_parameter=unused_parameter),
            'value':signed(secured[OUT]),'result_pointer':hex(c.reg['eax']),'stop':list(stop),
            'stack':hex(c.reg['esp']),'fp_depth':len(fp),'events':events,'branches':c.branches,
            'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def expected(f):
    if not 0<=f['column']<=6 or not 0<f['level']<f['count']:return 0
    value=table_value(int(f['table_mode'] in (4,5,9)),f['column'],f['level']-1)
    if f['column']==1:
        # With a present singleton, mode 4/5 is the only route to special branch;
        # checks of 7/9/18 there are unreachable for this stable mode fixture.
        special=f['mode'] in (4,5)
        add=f['add_special'] if special else f['add_normal']
        multiplier=real(fbits(f['mul_special']+3/8 if special else f['mul_normal']))
        value=math.trunc(real(fbits(value+add+f['info_kind']))*multiplier)
    return signed((value+f['final_add']+f['info_kind'])&0xffffffff)


def verify(row):
    if row['stop']!=['returned'] or row['stack']!='0x70000004' or row['fp_depth'] or row['result_pointer']!=hex(OUT):
        raise ValueError('Base service return/ABI mismatch')
    if row['value']!=expected(row['fixture']):raise ValueError('Base service arithmetic mismatch')
    f=row['fixture'];lookups=[e for e in row['events'] if e['kind']=='vector_lookup']
    valid=0<=f['column']<=6 and 0<f['level']<f['count']
    bank=int(f['table_mode'] in (4,5,9))
    if valid:
        if len(lookups)!=1 or lookups[0]['this']!=hex(0x1A66978+140*bank+20*f['column']) or lookups[0]['argument']!=f['level']-1:
            raise ValueError('Wrong original vector or level index')
    elif lookups:raise ValueError('Invalid level/column reached table')


def audit(source):
    cases=[{}]+[dict(table_mode=m,mode=m) for m in (0,4,5,7,9,18)]
    cases += [dict(column=x) for x in (-1,0,2,6,7)]
    cases += [dict(level=x) for x in (-1,0,1,99,100,101,102)]
    cases += [dict(level=100,count=100),dict(owner_fallback=True),dict(unused_parameter=123456)]
    cases += [dict(info_kind=2,mode=m,table_mode=m) for m in (1,4,5,9)]
    cases += [dict(table_mode=4,mode=1),dict(table_mode=1,mode=4)]
    cases += [dict(add_normal=-1300,mul_normal=.75,final_add=-20)]
    runs=[];traces=[]
    for case in cases:
        for poison in (False,True):
            row,trace=replay(source,poison=poison,**case);verify(row);runs.append(row);traces.append(trace)
    names=('audit_dnf_fixed_base.py','audit_dnf_ice_shatter.py','audit_dnf_ice_particle_bindings.py',
           'audit_dnf_native_strings.py','dnf_native_vm_probe.py','audit_dnf_particle_axis.py')
    return {'schema':'dnf_fixed_base/1','engine_sha256':ENGINE_SHA,'input_source':source.source,
            'method':__doc__.strip(),'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
            'owner_vtable_slot':{'address':'0x16f9b6c','raw':source.source_bytes(0x16F972C+0x440,4).hex()},
            'boundaries':['All table/character/mode values are synthetic inputs; no original loader mapping or character stat provenance asserted.',
                'Singleton is present and mode stable during a call; null manager / concurrent mode change / null final owner-info are excluded.',
                'Secure primitives are ABI fixtures; original owner vtable +440 getter D07390, field getters, vector indexing, secure copy/add wrappers and SSE2 truncation helper are replayed.',
                'Finite x87 operations use binary64 intermediates; full x87 precision/control-word/exception and non-SSE2 helper not modeled.',
                'Fixture vector lengths are 100 or 101. Native strict level<count is proved; actual loaded length/sentinel remains unknown.'],
            'runs':runs,'blocks':source_blocks(source,traces)}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path)
    p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite client')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    evidence=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(evidence,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[FIXED_BASE] {len(evidence['runs'])} source paths verified")


if __name__=='__main__':main()

"""Replay native 90A950 -> 90A6F0 fixed-attack arithmetic, without executing PE.

Original control flow and SSE instructions consume explicitly injected base-stat,
normalization and skill-value service results. These inputs are NOT reconstructed
character stats. The optional skill-extension multiplier is excluded. x87 uses
Python binary64 intermediates with explicit binary32 stores, not an x87 emulator.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

from audit_dnf_firewave import extra_step
from audit_dnf_ice_shatter import fbits, real, signed
from audit_dnf_ice_particle_bindings import source_blocks, trace_hash
from audit_dnf_native_strings import ENGINE_SHA, recover_string

SKILL, OWNER = 0x60000000, 0x60100000
SERVICES = {0xD07760, 0x1195EB0, 0x75EB80, 0x1195DC0, 0x75BF00, 0x75BF90, 0x9089A0}


def f32(value):
    return real(fbits(value))


def replay(source, *, column=0, rank=1, owner_level=40, normalization_object=0, mapped_level=20,
           rank_override=-1, divisor_parameter=-65535, multiplier=1.0,
           base_stat=100, skill_value=584.0, normalization=1.0,
           lower_normalization=1.0, has_owner=True, poison=False):
    from dnf_native_vm_probe import CPU
    c = CPU(source)
    for address in range(0x6FFFFE00, 0x70000000, 4):c.write(address,4,0)
    for address in range(SKILL,SKILL+0x700,4):c.write(address,4,0)
    c.write(SKILL+0x34,4,OWNER if has_owner else 0)
    c.write(OWNER,4,0x16F972C)
    c.write(OWNER+0x304,4,0)  # opaque field passed to base-stat service
    for j,value in enumerate((column,divisor_parameter,normalization_object,fbits(multiplier),rank_override)):
        c.write(0x70000004+j*4,4,value)
    xmm={f'xmm{j}':0 for j in range(8)}
    fp=[]
    secured={SKILL+0x4A4:1,SKILL+0x59C:rank}
    events=[]
    c.pc=0x90A950
    for _ in range(3000):
        if c.pc in SERVICES:
            target,this=c.pc,c.reg['ecx']
            arg=lambda j:c.read(c.reg['esp']+4+j*4,4)
            event={'target':hex(target),'this':hex(this)}
            returned,pop_bytes=0,0
            if target==0xD07760:
                event.update(kind='owner_level_fixture',value=owner_level)
                returned=owner_level
            elif target==0x1195EB0:
                if this not in secured:raise ValueError(f'Unmodeled secure field {this:#x}')
                if arg(0)!=this+8:raise ValueError('Unexpected secure read key')
                event.update(kind='secure_read_fixture',value=secured[this])
                c.write(arg(1),4,secured[this]);pop_bytes=8
            elif target==0x75EB80:
                event.update(kind='base_stat_fixture',args=[arg(j) for j in range(7)],value=base_stat)
                returned=arg(0);secured[returned]=base_stat
            elif target==0x1195DC0:
                event.update(kind='secure_destroy_fixture')
            elif target==0x75BF90:
                if arg(0)!=normalization_object:raise ValueError('Wrong normalization object')
                event.update(kind='object_level_mapping_fixture',args=[arg(0)],value=mapped_level)
                returned=mapped_level  # object-key lookup result, not input level identity
            elif target==0x75BF00:
                value=normalization if arg(0)==owner_level else lower_normalization
                event.update(kind='normalization_fixture',args=[arg(j) for j in range(3)],value=f32(value))
                fp.append(f32(value))
            elif target==0x9089A0:
                event.update(kind='skill_value_fixture',args=[arg(j) for j in range(6)],value=f32(skill_value))
                fp.append(f32(skill_value));pop_bytes=24
            events.append(event)
            c.reg['eax']=returned
            c.pc=c.pop();c.reg['esp']+=pop_bytes
            c.reg['ecx'],c.reg['edx'],c.flags=(0xBAADF00D,0xBAD0C0DE,0xA97) if poison else (0,0,0x202)
            # All XMM registers are caller-saved on the native x86 ABI.
            for name in xmm:xmm[name]=0x0123456789ABCDEF if poison else 0
            continue
        result=c.run(c.pc,1)
        if result[0]=='returned':break
        if result[0]=='budget':continue
        i=next(source.decoder.disasm(source.source_bytes(c.pc,15),c.pc,count=1))
        if result[0]=='call':
            target=int(result[2],16)
            if target not in SERVICES|{0x90A6F0,0x4429C0}:
                raise ValueError(f'Unmodeled native call {target:#x}')
            c.push(c.pc+i.size);c.pc=target;continue
        if result[0]!='unsupported':raise ValueError(f'Unexpected stop {result}')
        if i.mnemonic in ('subss','addss','divss'):
            dst,src=i.operands;name=i.reg_name(dst.reg)
            right=xmm[i.reg_name(src.reg)] if src.type==1 else c.get(i,src)
            a,b=real(xmm[name]),real(right)
            value=a-b if i.mnemonic=='subss' else a+b if i.mnemonic=='addss' else a/b
            if not math.isfinite(value):raise ValueError('Non-finite fixture outside model')
            xmm[name]=(xmm[name]&~0xffffffff)|fbits(value)
        elif i.mnemonic in ('fmul','fdivr','fstp'):
            if len(fp)!=1 or i.operands[0].size!=4:raise ValueError('Unmodeled x87 form/stack')
            if i.mnemonic=='fstp':
                value=fp.pop();c.put(i,i.operands[0],fbits(value))
            else:
                value=real(c.get(i,i.operands[0]))
                fp[-1]=fp[-1]*value if i.mnemonic=='fmul' else value/fp[-1]
        else:
            extra_step(c,xmm,i);continue
        c.pc+=i.size
    else:raise ValueError('Fixed-attack instruction budget exceeded')
    return {'fixture':dict(column=column,rank=rank,owner_level=owner_level,normalization_object=normalization_object,mapped_level=mapped_level,
                rank_override=rank_override,divisor_parameter=divisor_parameter,multiplier=multiplier,
                base_stat=base_stat,skill_value=skill_value,normalization=normalization,
                lower_normalization=lower_normalization,has_owner=has_owner,poison=poison),
            'events':events,'value':signed(c.reg['eax']),'stop':list(result),'stack':hex(c.reg['esp']),
            'fp_depth':len(fp),'branches':c.branches,'steps':len(c.trace),'trace_sha256':trace_hash(c.trace)},c.trace


def expected(f):
    """Independent algebra check, retaining the observed binary32 store points."""
    if not f['has_owner']:return 0
    base=f32(f32(f['base_stat'])*f32(f['normalization']))
    if f['normalization_object']!=0 and f['mapped_level']<f['owner_level']:base=f32(base/f32(f['lower_normalization']))
    ratio=f32(f32(f32(f['skill_value'])-100.0)*f32(.01))
    ratio=f32(ratio+1.0)
    value=f32(f32(ratio*base)*f32(f['multiplier']))
    if f['divisor_parameter']!=-65535:
        value=f32(f32(value*100.0)/f32(max(1,f['divisor_parameter']+100)))
    return math.trunc(value)


def verify(row):
    f=row['fixture']
    if row['stop']!=['returned'] or row['stack']!='0x70000018' or row['fp_depth']:
        raise ValueError('Incomplete return / ABI / floating stack')
    if row['value']!=expected(f):raise ValueError('Fixed-attack arithmetic differs')
    pick=lambda kind:[e for e in row['events'] if e['kind']==kind]
    if not f['has_owner']:
        if row['events']:raise ValueError('Ownerless request invoked services')
        return
    values=pick('skill_value_fixture')
    rank=f['rank'] if f['rank_override']==-1 else f['rank_override']
    if len(values)!=1 or values[0]['args']!=[f['column'],rank,OWNER,f['owner_level'],f['owner_level'],14]:
        raise ValueError('Wrong native skill column/rank arguments')
    if [e['args'] for e in pick('object_level_mapping_fixture')] != ([[f['normalization_object']]] if f['normalization_object'] else []):
        raise ValueError('Wrong object-to-level mapping argument')
    if [e['args'] for e in pick('normalization_fixture')] != [[f['owner_level'],13,0]]+([[f['mapped_level']&0xffffffff,13,0]] if f['normalization_object']!=0 and f['mapped_level']<f['owner_level'] else []):
        raise ValueError('Wrong level normalization branch')
    base=pick('base_stat_fixture')
    if len(base)!=1 or base[0]['args'][1:]!=[1,1,f['owner_level'],0,OWNER,3]:
        raise ValueError('Wrong base-stat service inputs')


def audit(source):
    fixtures=[{}]+[dict(skill_value=v) for v in (1170,645,1289,1129,2257,251,0,-125.5,100,100.5)]
    fixtures += [dict(base_stat=b,normalization=1.25,skill_value=584) for b in (0,59,100,367,999)]
    fixtures += [dict(normalization_object=0x60510000,mapped_level=l,normalization=1.5,lower_normalization=1.0 if l<=0 else .75) for l in (-1,0,20,40,60)]
    fixtures += [dict(divisor_parameter=d) for d in (-150,-99,0,50,100)]
    fixtures += [dict(rank=10,column=1,rank_override=r,multiplier=.75) for r in (-1,2)]
    fixtures += [dict(has_owner=False)]
    runs,traces=[],[]
    for fixture in fixtures:
        for poison in (False,True):
            row,trace=replay(source,poison=poison,**fixture)
            verify(row);runs.append(row);traces.append(trace)
    # Callee source is archived for the next dependency investigation, not
    # included in the list of instructions replayed by this resolver probe.
    for start,size in ((0x75EB80,0x2EC),(0x75BF00,0x41),(0x908C23,0x17)):
        traces.append([f'{i.address:08X} {i.mnemonic} {i.op_str}'
                       for i in source.decoder.disasm(source.source_bytes(start,size),start)])
    from contextlib import closing
    from dnf_pvf import open_library
    with closing(open_library()) as library:
        record=library.script('etc/etcparameter.etc')
        tags=('[skill damage base parameter dungeon]','[skill damage base parameter pvp]')
        candidates={'path':'etc/etcparameter.etc','sha256':record['sha256'],
                    'asset_version':library.asset_version,
                    'status':'candidate: matching source tags; loader-to-global-array mapping and column semantics NOT proved',
                    'fields':[f for f in record['fields'] if f['tag'] in tags]}
        if len(candidates['fields'])!=2:raise ValueError('Missing candidate base-parameter tags')
    native_tags=[]
    for address in (0x15B3598,0x15B35E8):
        raw=source.source_bytes(address,128)
        value,size=recover_string(raw,0,2)
        if value not in tags:raise ValueError('Native base-parameter tag identity changed')
        native_tags.append({'address':hex(address),'raw':raw[:size+4].hex(),'text':value})
    names=('audit_dnf_fixed_attack.py','audit_dnf_firewave.py','audit_dnf_ice_shatter.py',
           'dnf_native_vm_probe.py','audit_dnf_particle_axis.py','audit_dnf_native_strings.py',
           'audit_dnf_ice_particle_bindings.py','dnf_pvf.py','audit_dnf_design.py')
    return {'schema':'dnf_fixed_attack/2','engine_sha256':ENGINE_SHA,'input_source':source.source,
            'method':__doc__.strip(),'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
            'boundaries':['Integer and finite SSE arithmetic/branches from original wrapper/resolver; no native execution.',
                'Base stat, normalization, skill value and secure storage are ABI fixtures; final damage/defense/crit not replayed.',
                'Skill+30 is null: optional skill-extension modifier branch excluded. Skill field +4A4 uses opaque fixture 1.',
                'Object-to-level service uses explicit mapped_level fixture; no object pointer is used as a level. Missing (-1) and zero results exercise the native lower-level branch. x87 precision/control word/exception modes are not reproduced.',
                '0xFFFF0001 parameter skips an optional divisor; its full domain meaning remains unverified.'],
            'constants':[{'address':hex(a),'raw':source.source_bytes(a,4).hex()} for a in (0x1556DF8,0x1559C80,0x15560BC)],
            'candidate_parameters':candidates,'native_parameter_tags':native_tags,
            'runs':runs,'blocks':source_blocks(source,traces)}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite client')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()))
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f"[FIXED_ATTACK] {len(e['runs'])} source traces verified")


if __name__=='__main__':main()

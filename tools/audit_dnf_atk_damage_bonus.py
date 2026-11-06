"""Compare actual archive scalar/duplicate ATK fields with original integer writes."""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sys
from audit_dnf_basic_mastery_pipeline import parse_bonus,verify_parser
from audit_dnf_ice_particle_bindings import source_blocks
from audit_dnf_native_strings import ENGINE_SHA
from compile_dnf_content import decode_fields


def audit(source):
    from dnf_pvf import open_library,parse_script,canonical
    if hashlib.sha256(source.raw).hexdigest()!=ENGINE_SHA:raise ValueError('Unexpected client')
    rows=[];traces=[];files=fields_count=0;float_files=repeat_files=0;changed_values=0
    with closing(open_library()) as lib:
        for path,raw in lib.files('.atk'):
            files+=1;parsed=parse_script(raw,lib.strings,'atk')['fields']
            fields=[f for f in parsed if canonical(f['tag'])=='[damage bonus]'];fields_count+=len(fields)
            if not fields:continue
            if any(len(f['values'])!=1 or type(f['values'][0]) not in (int,float) for f in fields):raise ValueError(f'Unexpected scalar: {path}')
            values=[f['values'][0] for f in fields]
            floating=any(type(v)==float for v in values);repeat=len(values)>1
            float_files+=int(floating);repeat_files+=int(repeat)
            if not floating and not repeat:continue
            decoded,_,_=decode_fields('atk',parsed,path);runs=[]
            for poison in (False,True):
                row,trace=parse_bonus(source,values[0],tail_values=values[1:],poison=poison)
                verify_parser(row);runs.append(row);traces.append(trace)
            expected=runs[0]['value']
            if decoded['damage_bonus']!=expected or type(decoded['damage_bonus'])!=int:raise ValueError(f'Compiler differs from original: {path}')
            changed_values+=int(values[0]!=expected)
            rows.append({'path':path,'sha256':hashlib.sha256(raw).hexdigest(),'values':values,
                'offsets':[f['offset'] for f in fields],'decoded':decoded['damage_bonus'],'runs':runs})
        version=lib.asset_version
    # Evidence of the loader's zero reset is static only in this batch. Do not
    # pretend that the full parser/reset/container cleanup has been emulated.
    provenance=[]
    for start,end in ((0x12CF643,0x12CF64A),(0x12AD4B0,0x12AD4FA)):
        raw=source.source_bytes(start,end-start)
        provenance.append({'start':hex(start),'end':hex(end),'sha256':hashlib.sha256(raw).hexdigest(),
            'instructions':[f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in source.decoder.disasm(raw,start)]})
    names=('audit_dnf_atk_damage_bonus.py','audit_dnf_basic_mastery_pipeline.py','audit_dnf_basic_mastery.py',
        'audit_dnf_firewave.py','audit_dnf_ice_shatter.py','audit_dnf_ice_particle_bindings.py',
        'audit_dnf_native_strings.py','audit_dnf_particle_axis.py','dnf_native_vm_probe.py',
        'compile_dnf_content.py','dnf_pvf.py','dnf_particle_fields.py')
    return {'schema':'dnf_atk_damage_bonus/1','engine_sha256':ENGINE_SHA,'input_source':source.source,'asset_version':version,
        'tools_sha256':{n:hashlib.sha256(Path(__file__).with_name(n).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for n in names},
        'census':{'atk_files':files,'top_level_fields':fields_count,'float_files':float_files,
            'repeated_field_files':repeat_files,'numeric_changes_from_first_raw_value':changed_values},
        'cases':sorted(rows,key=lambda r:r['path']),'blocks':source_blocks(source,traces),'static_provenance':provenance,
        'boundaries':[
            'Every top-level archive damage bonus field was inventoried; float/repeated-field files are replayed, not every integer-only file.',
            'Each file sequence executes original registration once and enum dispatch/integer reader/write repeatedly on the same synthetic record.',
            'Lexer and secure storage remain ABI fixtures; field boundaries are supplied in archive order. Other intervening tags and full outer parser are excluded.',
            'Loader/reset prefix is static provenance only. Missing fields remain absent in decoded data; this change adds no fabricated source tag.',
            'Raw PVF fields, order, offsets and bytes are preserved. Only damage bonus uses integer conversion and last-write semantics; other fields remain unaudited.',
            'Correct ATK decoding does not prove original action selection, basic mastery integration or final damage formula.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('client',type=Path);p.add_argument('--decoder-dir',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.client.resolve()==a.output.resolve():raise ValueError('Cannot overwrite source')
    if a.decoder_dir:sys.path.insert(0,str(a.decoder_dir.resolve()))
    from audit_dnf_particle_axis import AxisEvaluator
    e=audit(AxisEvaluator(a.client.read_bytes()));a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(e,indent=1)+'\n',encoding='utf8',newline='\n')
    print(json.dumps(e['census']));print(f"[ATK_DAMAGE_BONUS] {len(e['cases'])} archive cases matched original writes")


if __name__=='__main__':main()

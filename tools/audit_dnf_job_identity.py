"""Audit swordman job identity from CHR name order, localization and SP tree.

Does not infer stat units or execute growth formulas. Original files are read-only.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from dnf_pvf import open_library, closing, parse_script
from audit_dnf_reusable_data import TextResolver, string_bytes

ROOT = Path(__file__).resolve().parents[1]
CHR = 'character/swordman/swordman.chr'
TREE = 'clientonly/skilltree/swordman_sp.co'
KEYS = {'growtype_name_75':'swordman','growtype_name_80':'weaponmaster',
        'growtype_name_85':'soulbringer','growtype_name_90':'berserker','growtype_name_95':'asura'}

def audit(lib):
    raw, digest = lib.raw(CHR)
    fields = parse_script(raw,lib.strings,'chr')['fields']
    refs = next(f for f in fields if f['tag']=='[growtype name]')['values']
    if len(refs)%2:raise ValueError('unpaired job name references')
    resolver = TextResolver(lib)
    names=[]
    for i in range(0,len(refs),2):
        table_id,key_ref=refs[i:i+2]
        if table_id['link_type']!=9 or key_ref['link_type']!=10:raise ValueError('unexpected name reference type')
        key=string_bytes(lib.strings,key_ref['raw']).decode('ascii')
        path,table=resolver.table(table_id['raw'])
        if key not in table:raise ValueError('missing job name '+key)
        names.append({'source_index':i//2,'name_key':key,'name':table[key]['text'],'references':[table_id,key_ref],
                      'name_table':path,'line':table[key]['line'],'local_id':KEYS.get(key),
                      'chr_group':'[growtype %d]' % (i//2+1)})
    tree_raw,tree_sha=lib.raw(TREE)
    branches=[f['values'][1] for f in parse_script(tree_raw,lib.strings,'co')['fields'] if f['tag']=='[character job]']
    tree_jobs=['swordman' if x=='none' else x for x in branches]
    registry={n['local_id']:n['source_index'] for n in names if n['local_id'] in tree_jobs}
    if set(registry)!=set(KEYS.values()) or set(registry)!=set(tree_jobs):raise ValueError('CHR names and supported SP branches disagree')
    groups={}
    for i,node in enumerate(fields):
        if node['tag']=='[initial value]' or (node['tag'].startswith('[growtype ') and node['tag']!='[growtype name]'):
            rows=[]
            for f in fields[i+1:]:
                if f['tag'].startswith(('[growtype ','[awakening ','[waiting motion]')):break
                rows.append({'tag':f['tag'],'values':f['values'],'types':f['types'],'offset':f['offset']})
            groups[node['tag']]=rows
    probes={}
    for job,skill in [('soulbringer','ghostpowerup'),('asura','armormasteryplatewave')]:
        path='skill/swordman/'+skill+'.skl'
        skill_raw,skill_sha=lib.raw(path)
        caps=next(f['values'] for f in parse_script(skill_raw,lib.strings,'skl')['fields'] if f['tag']=='[growtype maximum level]')
        if [i for i,v in enumerate(caps) if v>0]!=[registry[job]]:raise ValueError('exclusive skill column disagrees with job order')
        probes[job]={'path':path,'sha256':skill_sha,'growtype_max_level':caps}
    return {'schema':'dnf_job_identity_evidence/1','source':{'chr':{'path':CHR,'sha256':digest},
             'tree':{'path':TREE,'sha256':tree_sha},'name_tables':resolver.sources},
            'name_order':names,'sp_branches':branches,'runtime_identity':registry,'exclusive_skill_probes':probes,
            'growth_fields_uninterpreted':groups,
            'boundary':'Name/column identity only. CHR group arithmetic, units, job change grants and server requirements are not established by this audit.'}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'docs/reports/ws2/2026-11/source_job_identity.json')
    args=parser.parse_args()
    with closing(open_library()) as lib:result=audit(lib)
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result['runtime_identity'],ensure_ascii=True))
    return 0
if __name__=='__main__':raise SystemExit(main())

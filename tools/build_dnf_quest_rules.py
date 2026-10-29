"""Compile all indexed QST from the immutable migrated source, without a PVF.

Objective grammar support, executable dependencies and current-player eligibility
are separate. No level/chapter cap; unknown fields stay blocked with exact reasons.
The v1 source/runtime bytes remain unchanged; v2 is an additive runtime layer.
"""
from pathlib import Path
from collections import Counter
import argparse,gzip,hashlib,json
from build_dnf_native_catalog import compile_quest, NPCS

ROOT=Path(__file__).resolve().parents[1]
DATA=ROOT/'game_dnf/data';BASE=ROOT/'game_dnf/assets_local/native_data_v1'
OUT=DATA/'native_quest_rules_v2.json'
AUDIT=ROOT/'docs/reports/ws2/2026-10/2026-10-29_通用原任务规则覆盖.json'
STATUS=DATA/'native_quest_status_v2.json.gz'

def load(path):return json.loads(path.read_text(encoding='utf-8'))
def compressed(path):return json.loads(gzip.decompress(path.read_bytes()))
def digest(path):
    # Input JSON semantics, not checkout-specific CRLF/LF or indentation.
    return hashlib.sha256(json.dumps(load(path),ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest()
def write(path,value):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value,ensure_ascii=False,indent=1)+'\n',encoding='utf-8',newline='\n')
def status_bytes(audit):
    value={'schema':'dnf_native_quest_status/2','rows':{str(r['id']):{'state':r['state'],'reasons':r['reasons']} for r in audit['rows']}}
    return gzip.compress(json.dumps(value,ensure_ascii=True,separators=(',',':')).encode(),mtime=0)

def build():
    index=compressed(BASE/'index.json.gz');old=load(DATA/'quests.json');native=load(DATA/'native_runtime.json')
    previous=old['quests']+native['quests']
    existing={q['source']['id']:q['id'] for q in previous if q.get('source',{}).get('id') is not None}
    items={**native['items'],**load(DATA/'runtime_items.json')['items']}
    monster_rows=load(DATA/'monster_catalog.json')['monsters']
    registered={v['mob'] for v in load(DATA/'combat.json')['monsters'].values()}
    monsters={v['id']:v['path'] for v in monster_rows.values() if v['path'] in registered}
    routes=load(DATA/'dungeons.json')['dungeons'];dungeons={};names={};inputs={}
    towns=load(DATA/'towns.json');placed={npc for scene in towns['locations'].values() for npc in scene.get('npcs',{})}
    npcs={i:key for i,key in NPCS.items() if key in old['npcs'] and key in placed}
    source=load(BASE/'manifest.json')['source']
    for path in [DATA/'quests.json',DATA/'native_runtime.json',DATA/'runtime_items.json',DATA/'monster_catalog.json',DATA/'combat.json',DATA/'dungeons.json',DATA/'towns.json',BASE/'manifest.json']:
        inputs[path.relative_to(ROOT).as_posix()]=digest(path)
    for key,row in routes.items():
        if not row.get('map_export'):continue
        path=ROOT/'game_dnf'/row['map_export'].removeprefix('res://');export=load(path);doc=export['dungeon']
        if export['source'].get('config_db_sha256')!=source['extraction_database_sha256']:raise ValueError('Cross-archive DGN identity: '+key)
        if type(doc.get('index')) is not int:raise ValueError('Missing source DGN index: '+key)
        if doc['index'] in dungeons:raise ValueError('Ambiguous runtime DGN mapping: '+key)
        dungeons[doc['index']]=key;names[key]=row['name'];inputs[path.relative_to(ROOT).as_posix()]=digest(path)
    records={}
    for shard in sorted({index['locations'][p] for p in index['indexes']['quests'].values()}):records.update(compressed(BASE/shard)['records'])
    pending={};rows=[];groups=Counter();types=Counter()
    for number,path in sorted(index['indexes']['quests'].items(),key=lambda kv:int(kv[0])):
        record=records[path];fields={f['tag']:f['values'] for f in record.get('fields',[]) if not f['tag'].startswith('[/')}
        q,plan,reasons=compile_quest(int(number),path,record['sha256'],fields,record['text'],existing,items,monsters,custom_events={211},dungeon_index=dungeons,npc_index=npcs)
        reasons.extend('repeated_field:'+tag for tag in record.get('repeated_fields',[]))
        row={'id':int(number),'path':path,'sha256':record['sha256'],'name':q['name'],'grade':fields.get('[grade]',[]),'raw_type':fields.get('[type]',[]),'raw_sub_type':fields.get('[sub type]',[]),'raw_int_data':fields.get('[int data]',[]),'objective_plan':plan,'reasons':sorted(set(reasons)),'state':'existing' if int(number) in existing else 'blocked'}
        rows.append(row);groups[str(fields.get('[grade]'))]+=1;types[str(fields.get('[type]'))+' / '+str(fields.get('[sub type]'))]+=1
        if int(number) not in existing:pending[q['id']]=(q,row)
    available=set(existing.values());quests=[]
    while True:
        admitted=[k for k,(q,r) in pending.items() if not r['reasons'] and all(p in available for p in q['requires'])]
        if not admitted:break
        for key in sorted(admitted):
            q,row=pending.pop(key);available.add(key);quests.append(q);row['state']='admitted'
    for q,row in pending.values():
        if any(p not in available for p in q['requires']):row['reasons'].append('prerequisite_not_executable')
    blocked=Counter(reason for _,r in pending.values() for reason in r['reasons'])
    summary={'indexed_quests':len(rows),'existing':len(existing),'new_executable':len(quests),'total_executable':len(existing)+len(quests),'objective_parsed':sum(bool(r['objective_plan']) for r in rows),'new_lifecycles':dict(Counter(q.get('lifecycle','once') for q in quests)),'blocked':len(pending)}
    hash_policy='SHA256 canonical UTF-8 JSON, sort_keys=true, compact separators; source record SHA remains the original raw bytes'
    runtime={'schema':'dnf_native_quest_rules/2','source_inputs':inputs,'input_hash_policy':hash_policy,'calendar':{'utc_offset_minutes':480,'reset_hour':0,'evidence':'E-ADAPT configurable daily reset; not inferred from QST grade'},'dungeons':names,'quests':quests,'coverage':summary}
    audit={'schema':'dnf_native_quest_rule_audit/2','summary':summary,'source_inputs':inputs,'input_hash_policy':hash_policy,'grade_counts':dict(groups),'type_counts':dict(types),'blocked_reasons':dict(blocked.most_common()),'rows':rows}
    runtime['status_file']='res://data/'+STATUS.name;runtime['status_sha256']=hashlib.sha256(status_bytes(audit)).hexdigest()
    return runtime,audit

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--check',action='store_true');args=p.parse_args()
    runtime,audit=build()
    if args.check:
        if load(OUT)!=runtime or load(AUDIT)!=audit or STATUS.read_bytes()!=status_bytes(audit):raise ValueError('Quest v2 definitions/audit are stale; rebuild explicitly')
        print('QUEST RULES VERIFIED',runtime['coverage']);return
    write(OUT,runtime);write(AUDIT,audit);STATUS.write_bytes(status_bytes(audit))
    print('QUEST RULES BUILT',runtime['coverage'])
if __name__=='__main__':main()

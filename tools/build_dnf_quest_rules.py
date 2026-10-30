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
CAMPAIGN=DATA/'campaign_1_16.json'
CATALOG=DATA/'quest_catalog.json'

def load(path):return json.loads(path.read_text(encoding='utf-8'))
def compressed(path):return json.loads(gzip.decompress(path.read_bytes()))
def digest(path):
    # Input JSON semantics, not checkout-specific CRLF/LF or indentation.
    return hashlib.sha256(json.dumps(load(path),ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest()
def write(path,value):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value,ensure_ascii=False,indent=1)+'\n',encoding='utf-8',newline='\n')
def status_bytes(audit):
    value={'schema':'dnf_native_quest_status/2','rows':{str(r['id']):{'state':r['state'],'reasons':r['reasons']} for r in audit['rows']}}
    return gzip.compress(json.dumps(value,ensure_ascii=True,separators=(',',':')).encode(),mtime=0)

def sync_catalog(runtime):
    catalog=load(CATALOG)
    entries={row['path'].lower():row for row in catalog['quests']}
    missing=[]
    for quest in load(DATA/'quests.json')['quests']+load(DATA/'native_runtime.json')['quests']+runtime['quests']:
        source=quest.get('source') or {};path=str(source.get('path','')).lower()
        if not path:continue
        row=entries.get(path)
        if row is None:
            missing.append(path);continue
        row['implemented']=True;row['local_id']=quest['id'];row['local_name']=quest['name']
    catalog['summary']['implemented']=sum(1 for row in catalog['quests'] if row.get('implemented'))
    return catalog,missing

def build():
    index=compressed(BASE/'index.json.gz');old=load(DATA/'quests.json');native=load(DATA/'native_runtime.json')
    campaign=load(CAMPAIGN)
    previous=old['quests']+native['quests']
    existing={q['source']['id']:q['id'] for q in previous if q.get('source',{}).get('id') is not None}
    items={**native['items'],**load(DATA/'runtime_items.json')['items']}
    monster_rows=load(DATA/'monster_catalog.json')['monsters']
    registered={v['mob'] for v in load(DATA/'combat.json')['monsters'].values()}
    monsters={v['id']:v['path'] for v in monster_rows.values() if v['path'] in registered}
    routes=load(DATA/'dungeons.json')['dungeons'];dungeons={};names={};inputs={}
    towns=load(DATA/'towns.json');placed={npc for scene in towns['locations'].values() for npc in scene.get('npcs',{})}
    npcs={i:key for i,key in NPCS.items()
          if key in old['npcs'] and (key in placed or key=='the_last_mehmet')}
    source=load(BASE/'manifest.json')['source']
    for path in [DATA/'quests.json',DATA/'native_runtime.json',DATA/'runtime_items.json',DATA/'monster_catalog.json',DATA/'combat.json',DATA/'dungeons.json',DATA/'towns.json',CAMPAIGN,BASE/'manifest.json']:
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
    source_jobs={}
    for number,path in index['indexes']['quests'].items():
        record=records[path]
        source_jobs[int(number)]=next(
            (field['values'] for field in record.get('fields',[]) if field['tag']=='[job]'),
            ['[all]'],
        )
    pending={};rows=[];groups=Counter();types=Counter()
    for number,path in sorted(index['indexes']['quests'].items(),key=lambda kv:int(kv[0])):
        record=records[path]
        fields={}
        for field in record.get('fields',[]):
            if field['tag'].startswith('[/'):continue
            fields.setdefault(field['tag'],[]).extend(field['values'])
        if '[pre required quest]' in fields:
            fields['[pre required quest]']=[
                required for required in fields['[pre required quest]']
                if any(job in ['[all]','[swordman]'] for job in source_jobs.get(required,['[all]']))
            ]
        q,plan,reasons=compile_quest(int(number),path,record['sha256'],fields,record['text'],existing,items,monsters,custom_events={211},dungeon_index=dungeons,npc_index=npcs,map_index=campaign.get('map_targets',{}))
        if int(number) not in campaign.get('auto_source_ids',[]):
            q.pop('auto_accept',None)
            q.pop('auto_complete',None)
        reasons.extend('repeated_field:'+tag for tag in record.get('repeated_fields',[])
                       if tag not in ['[pre required quest]'])
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
    admitted_by_source={q['source']['id']:q['id'] for q in quests}
    existing_by_source={int(number):local for number,local in existing.items()}
    campaign_rows=[]
    for source_id in campaign['required_source_ids']:
        local_id=existing_by_source.get(source_id) or admitted_by_source.get(source_id)
        row={'source_id':source_id,'id':local_id or '', 'state':'existing' if source_id in existing else 'admitted' if source_id in admitted_by_source else 'blocked'}
        if row['state']=='blocked':
            key='original.quest.%d' % source_id
            blocked_quest= pending.get(key,({},{}))[0] or {}
            row['requires']=blocked_quest.get('requires',[])
            row['missing_requires']=[required for required in row['requires'] if required not in available]
            row['reasons']=sorted(set((pending.get(key,({},{}))[1] or {}).get('reasons',[]))) or ['source_index_missing']
        campaign_rows.append(row)
    campaign_missing=[row for row in campaign_rows if row['state']=='blocked']
    campaign_summary={'id':campaign['id'],'target_level':campaign['target_level'],
                      'required':len(campaign_rows),'executable':len(campaign_rows)-len(campaign_missing),
                      'missing':len(campaign_missing),'rows':campaign_rows}
    summary={'indexed_quests':len(rows),'existing':len(existing),'new_executable':len(quests),'total_executable':len(existing)+len(quests),'objective_parsed':sum(bool(r['objective_plan']) for r in rows),'new_lifecycles':dict(Counter(q.get('lifecycle','once') for q in quests)),'blocked':len(pending)}
    hash_policy='SHA256 canonical UTF-8 JSON, sort_keys=true, compact separators; source record SHA remains the original raw bytes'
    runtime={'schema':'dnf_native_quest_rules/2','source_inputs':inputs,'input_hash_policy':hash_policy,'calendar':{'utc_offset_minutes':480,'reset_hour':0,'evidence':'E-ADAPT configurable daily reset; not inferred from QST grade'},'dungeons':names,'quests':quests,'auto_quest_ids':campaign.get('auto_source_ids',[]),'coverage':summary,'campaign':campaign_summary}
    audit={'schema':'dnf_native_quest_rule_audit/2','summary':summary,'campaign':campaign_summary,'source_inputs':inputs,'input_hash_policy':hash_policy,'grade_counts':dict(groups),'type_counts':dict(types),'blocked_reasons':dict(blocked.most_common()),'rows':rows}
    runtime['status_file']='res://data/'+STATUS.name;runtime['status_sha256']=hashlib.sha256(status_bytes(audit)).hexdigest()
    return runtime,audit

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--check',action='store_true');args=p.parse_args()
    runtime,audit=build()
    catalog,missing=sync_catalog(runtime)
    if missing:raise ValueError('Runtime quest paths absent from catalog: '+', '.join(missing[:8]))
    if args.check:
        if load(OUT)!=runtime or load(AUDIT)!=audit or load(CATALOG)!=catalog or STATUS.read_bytes()!=status_bytes(audit):raise ValueError('Quest v2 definitions/audit are stale; rebuild explicitly')
        print('QUEST RULES VERIFIED',runtime['coverage']);return
    write(OUT,runtime);write(AUDIT,audit);write(CATALOG,catalog);STATUS.write_bytes(status_bytes(audit))
    print('QUEST RULES BUILT',runtime['coverage'])
if __name__=='__main__':main()

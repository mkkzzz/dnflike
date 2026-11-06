"""Check/update ordinary separate-attack mappings using the bundled source only.

Touches existing equipment definitions and the runtime checksum; never rebuilds
quests, source shards, art, item admission or persistent gear instances.
"""
import argparse
import copy
from functools import lru_cache
import gzip
import hashlib
import json
from pathlib import Path
from dnf_equipment_stats import apply_separate_attack

ROOT=Path(__file__).resolve().parents[1]


def prepare(root=ROOT):
    base=root/'game_dnf/assets_local/native_data_v1';data=root/'game_dnf/data'
    index=json.loads(gzip.decompress((base/'index.json.gz').read_bytes()))
    @lru_cache(maxsize=8)
    def shard(name):return json.loads(gzip.decompress((base/name).read_bytes()))['records']
    updates={};affected=[];stale=[]
    for name in ('numbers','native_runtime'):
        path=data/(name+'.json');doc=json.loads(path.read_text(encoding='utf8'))
        changed=False
        for key,definition in doc['equipment'].items():
            source=definition.get('source',{});source_path=source.get('path')
            if not source_path:continue
            record=shard(index['locations'][source_path])[source_path]
            if record['sha256']!=source['sha256']:raise ValueError('Source identity mismatch: '+key)
            fields=[f for f in record['fields'] if f['tag']=='[separate attack]']
            if not fields:continue
            if len(fields)!=1:raise ValueError('Repeated/context-dependent field: '+key)
            candidate=copy.deepcopy(definition);apply_separate_attack(candidate,fields[0]['values'])
            affected.append({'file':name,'id':key,'path':source_path,'sha256':source['sha256'],
                             'values':fields[0]['values'],'mapping':candidate['native_separate_attack']})
            if candidate!=definition:
                stale.append(name+':'+key);doc['equipment'][key]=candidate;changed=True
        # Match the checked-in format, not older whole-game builder formatting.
        payload=(json.dumps(doc,ensure_ascii=False,indent=1)+'\n').encode('utf8') if changed else path.read_bytes()
        if changed:updates[path]=payload
        if name=='native_runtime':runtime_sha=hashlib.sha256(payload).hexdigest()
    manifest_path=base/'manifest.json';manifest=json.loads(manifest_path.read_text(encoding='utf8'))
    if manifest['runtime_sha256']!=runtime_sha:
        manifest['runtime_sha256']=runtime_sha
        updates[manifest_path]=(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode('utf8')
    return updates,affected,stale


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--write',action='store_true');p.add_argument('--report',type=Path);a=p.parse_args()
    updates,affected,stale=prepare()
    if a.write:
        for path,payload in updates.items():path.write_bytes(payload)
    if a.report:
        a.report.parent.mkdir(parents=True,exist_ok=True)
        a.report.write_text(json.dumps({'schema':'dnf_separate_attack_migration/1','affected':affected,'changed':stale},ensure_ascii=False,indent=1)+'\n',encoding='utf8',newline='\n')
    print(f'[SEPARATE_ATTACK_DATA] matched={len(affected)} stale={len(stale)} changed_files={len(updates)} write={a.write}')
    if updates and not a.write:raise SystemExit(1)


if __name__=='__main__':main()

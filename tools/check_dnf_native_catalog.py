"""Verify the entire migrated corpus and its executable subset without a PVF."""
import base64
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import struct

from build_dnf_native_catalog import BAD, LISTS

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'game_dnf/assets_local/native_data_v1'


def load(path):
    return json.loads(gzip.decompress(path.read_bytes()))


def validate():
    errors = []
    manifest = json.loads((BASE / 'manifest.json').read_text(encoding='utf8'))
    for name, sha in manifest['files'].items():
        if hashlib.sha256((BASE / name).read_bytes()).hexdigest() != sha:errors.append('package_hash:' + name)
    index = load(BASE / 'index.json.gz')
    pool = load(BASE / 'strings.json.gz')['strings']
    supporting = load(BASE / 'localization_sources.json.gz')['files']
    if 'stringtable.bin' not in supporting or 'n_string.lst' not in supporting:errors.append('missing_supporting_tables')
    for path, source in supporting.items():
        if hashlib.sha256(base64.b64decode(source['raw_base64'])).hexdigest()!=source['sha256']:errors.append('localization_source:' + path)
    records = {}
    for name in sorted(set(index['locations'].values())):
        for path, record in load(BASE / name)['records'].items():
            if path in records:errors.append('duplicate_path:' + path)
            records[path] = record
            raw = base64.b64decode(record['raw_base64'], validate=True)
            if hashlib.sha256(raw).hexdigest() != record['sha256']:errors.append('raw_hash:' + path)
            if record['parse_status'] == 'parsed':
                for kind, value in struct.iter_unpack('<Bi', raw[2:]):
                    if kind in [5, 6, 7, 8, 10] and str(value) not in pool:errors.append('missing_string:' + path)
    if len(records) != manifest['summary']['files']:errors.append('file_count')
    for kind, rows in index['indexes'].items():
        if len(rows) != manifest['summary']['indexed_ids'][kind]:errors.append('index_count:' + kind)
        for number, path in rows.items():
            if path not in records or {'list': LISTS[kind], 'id': int(number)} not in records[path]['source_ids']:
                errors.append('index_reference:' + kind + ':' + number)
    runtime = json.loads((ROOT / 'game_dnf/data/native_runtime.json').read_text(encoding='utf8'))
    if hashlib.sha256((ROOT / 'game_dnf/data/native_runtime.json').read_bytes()).hexdigest()!=manifest['runtime_sha256']:errors.append('runtime_hash')
    from check_dnf_numbers import validate as validate_numbers
    numbers = json.loads((ROOT / 'game_dnf/data/numbers.json').read_text(encoding='utf8'))
    numbers['equipment'].update(runtime['equipment'])
    errors.extend('merged_numbers:' + message for message in validate_numbers(numbers))
    old_items = json.loads((ROOT / 'game_dnf/data/runtime_items.json').read_text(encoding='utf8'))['items']
    all_items = {**runtime['items'], **old_items}
    if set(runtime['items']) & set(old_items):errors.append('curated_item_overwrite')
    atlas = json.loads((ROOT / 'game_dnf/assets_local/items_native_v1/manifest.json').read_text(encoding='utf8'))
    for key, item in runtime['items'].items():
        if BAD.search(item['name'] + item['description']) or not item['name']:errors.append('display_text:' + key)
        if item['kind'] not in ['weapon','material','profession','quest','consumable']:errors.append('item_kind:' + key)
        if type(item['stack_limit']) is not int or item['stack_limit'] < 1:errors.append('stack_limit:' + key)
        source = item['source']
        if source['sha256'] != records[source['path']]['sha256']:errors.append('item_source:' + key)
        if records[source['path']]['execution'][key]['reasons']:errors.append('unsupported_active_item:' + key)
        for group in ['items','field_images']:
            if key not in atlas[group] or atlas[group][key] not in atlas['images']:errors.append('missing_atlas:' + key)
    for key, rule in runtime['consumables'].items():
        effect = rule['effect']
        if key not in all_items or effect['kind'] != 'restore':errors.append('consumable_item:' + key)
        for field in ['hp','mp','hp_percent','mp_percent','duration_ms']:
            v = effect.get(field,0)
            if type(v) is not int or not 0 <= v <= (100 if field.endswith('percent') else 600000):errors.append('consumable_effect:' + key)
    for key, gear in runtime['equipment'].items():
        if key not in runtime['items'] or type(gear['durability']) is not int or gear['durability']<1:errors.append('equipment_instance:' + key)
        if runtime['services'].get(key,{}).get('repair_point',0)<1:errors.append('equipment_repair:' + key)
    quests = json.loads((ROOT / 'game_dnf/data/quests.json').read_text(encoding='utf8'))
    ids = {q['id'] for q in quests['quests']} | {q['id'] for q in runtime['quests']}
    for q in runtime['quests']:
        if any(r not in ids for r in q['requires']):errors.append('quest_dependency:' + q['id'])
        if BAD.search(q['name'] + q['description']):errors.append('quest_text:' + q['id'])
        if q['giver'] not in quests['npcs'] or q['receiver'] not in quests['npcs']:errors.append('quest_npc:' + q['id'])
        for item in set(q['consume']) | set(q['reward']['items']) | {r['item'] for r in q['reward']['choices']} | {r['item'] for r in q['reward']['conditional_items']}:
            if item not in all_items:errors.append('quest_item:' + q['id'])
    summary = {'files': len(records), 'indexed_ids': {k: len(v) for k,v in index['indexes'].items()},
               'runtime': runtime['coverage'], 'errors': len(errors)}
    for error in errors[:30]:print('NATIVE FAIL', error)
    print('NATIVE COVERAGE', json.dumps(summary))
    return errors, summary


if __name__ == '__main__':raise SystemExit(bool(validate()[0]))

"""Read-only early quest/town/NPC evidence from the archived PVF, not a runtime import.

Keep repeated fields and opaque quest payloads. Localized labels are resolved only
through an adjacent type-9 table / type-10 key, n_string.lst and a strict CP950
round trip of this archive's Chinese STR files. Do not change the shared decoder.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
from export_dnf_map import Library
from audit_dnf_design import decode_tokens
from dnf_asset_store import ROOT, LOCK, cache_home

NPC_IDS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 17, 18, 20, 21, 22, 24, 27, 29, 30, 45]
TOWNS = ['town/elvengard.twn', 'town/hendonmyre.twn', 'town/westcoast.twn']
Q_FIELDS = ['[grade]', '[difficulty]', '[level]', '[job]', '[grow type]', '[npc index]',
            '[complete npc index]', '[pre required quest]', '[type]', '[sub type]',
            '[int data]', '[reward type]', '[reward int data]', '[reward selection int data]',
            '[gold multiple]', '[go guide]', '[name]', '[condition message]']


def audit(library: Path) -> dict:
    lib = Library(library, ROOT/'temp/early_world_audit')
    try:
        links = lib.listing('n_string.lst')
        string_tables, diagnostics = {}, []
        sources = {}

        def exists(path):
            return lib.config.execute('select 1 from files where path=?', (path,)).fetchone() is not None

        def script(path):
            value = lib.script(path)
            sources[path] = {'sha256': value['sha256'], 'crc_ok': value['crc_ok']}
            return value

        def text_table(table_id):
            if table_id not in string_tables:
                path = links[table_id].lower()
                row = lib.config.execute('select content,sha256 from files where path=?', (path,)).fetchone()
                text = row[0].decode('cp950', errors='strict')
                if text.encode('cp950') != row[0]:raise ValueError('STR round trip differs: ' + path)
                sources[path] = {'sha256': row[1], 'encoding': 'cp950', 'round_trip': True}
                table = {}
                for line_number, line in enumerate(text.splitlines(), 1):
                    match = re.match(r'^([A-Za-z0-9_]+)>(.*)$', line)
                    if match:
                        if match[1] in table:diagnostics.append({'kind':'duplicate_string_key', 'path':path, 'key':match[1]})
                        table[match[1]] = {'text':match[2].strip(), 'line':line_number}
                string_tables[table_id] = (path, table)
            return string_tables[table_id]

        def field(span):
            values = []
            for token in span['values']:
                if token['type'] in (9, 10):
                    values.append({'type':token['type'], 'raw_int':token['raw_int'], 'offset':token['offset']})
                else:values.append(token.get('value'))
            result = {'tag':span['tag'], 'offset':span['offset'], 'values':values}
            tokens = span['values']
            refs = []
            for previous, token in zip(tokens, tokens[1:]):
                if previous['type'] == 9 and token['type'] == 10:
                    table_id = previous['raw_int']
                    key = lib.strings.get(token['raw_int'])
                    path, table = text_table(table_id)
                    found = table.get(key)
                    refs.append({'table_id':table_id, 'path':path, 'key':key, 'entry':found})
                    if found is None:diagnostics.append({'kind':'missing_string_key', 'path':path, 'key':key})
            if refs:result['localized'] = refs
            if span['tag'] in ['[name]', '[field name]', '[condition message]'] and not refs:
                candidates = []
                for token in tokens:
                    if 'string_index' not in token:continue
                    start, end = struct.unpack_from('<2I', lib.strings.content, 4 + token['string_index'] * 4)
                    raw = lib.strings.content[start+4:end+4]
                    try:
                        value = raw.decode('cp950', errors='strict')
                        if value.encode('cp950') == raw:candidates.append(value)
                    except UnicodeError:pass
                if candidates:result['direct_cp950_candidates'] = candidates
            return result

        def fields(path, wanted):
            return [field(s) for s in script(path)['spans'] if wanted is None or s['tag'] in wanted]

        def values(rows, tag):
            return next((r['values'] for r in rows if r['tag'] == tag), [])

        def label(rows):
            row = next((r for r in rows if r['tag'] == '[name]'), {})
            refs = row.get('localized', [])
            if refs and refs[0]['entry']:return refs[0]['entry']['text']
            candidates = row.get('direct_cp950_candidates', [])
            return candidates[0] if candidates else None

        def listing(path):
            script(path)
            payload = lib.config.execute('select content from files where path=?', (path,)).fetchone()[0]
            tokens = decode_tokens(payload, lib.strings)['tokens']
            if len(tokens) % 2:raise ValueError('Unpaired list entry: ' + path)
            result = {}
            for key, value in zip(tokens[::2], tokens[1::2]):
                if key['type'] != 2 or not isinstance(value.get('value'), str):raise ValueError('Unsupported list shape: ' + path)
                if key['value'] in result:raise ValueError('Ambiguous duplicate list id: ' + path + ':' + str(key['value']))
                result[key['value']] = value['value']
            return result

        quests, npc_paths = listing('n_quest/quest.lst'), listing('npc/npc.lst')
        links = listing('n_string.lst')
        id_by_path = {}
        for key, path in quests.items():id_by_path.setdefault('n_quest/'+path.lower(), []).append(key)
        selected = []
        region_prefixes = ['n_quest/elvengard/', 'n_quest/handonmyre/', 'n_quest/westcost/',
                           'n_quest/common/elvengard/', 'n_quest/common/handonmyre/', 'n_quest/common/westcost/']
        all_quests = lib.config.execute("select path from files where extension='.qst' order by path").fetchall()
        for (path,) in all_quests:
            if not (any(path.startswith(p) for p in region_prefixes) or path.startswith('n_quest/job/s_')):continue
            data = script(path)
            level = next(([v.get('value') for v in s['values']] for s in data['spans'] if s['tag'] == '[level]'), [])
            jobs = next(([v.get('value') for v in s['values']] for s in data['spans'] if s['tag'] == '[job]'), [])
            if not level or not 1 <= level[0] <= 20 or not any(j in ['[all]', '[swordman]'] for j in jobs):continue
            rows = [field(s) for s in data['spans'] if s['tag'] in Q_FIELDS]
            selected.append({'ids':id_by_path.get(path, []), 'path':path, 'name':label(rows), 'fields':rows})
        # Remove scanned-but-excluded records from the compact provenance list.
        selected_paths = {r['path'] for r in selected}
        sources = {k:v for k,v in sources.items() if not k.endswith('.qst') or k in selected_paths}
        by_id = {key:q for q in selected for key in q['ids']}
        for q in selected:
            predecessors = values(q['fields'], '[pre required quest]')
            q['predecessor_references'] = [{'id':key, 'path':('n_quest/'+quests[key].lower()) if key in quests else None,
                                            'in_selected_scope':key in by_id} for key in predecessors if isinstance(key, int) and key >= 0]
        episodes = fields('n_quest/epicquest.lst', None)
        blocks, current = [], []
        for row in episodes:
            if row['tag'] == '[episode]':current = [row]
            elif current:current.append(row)
            if row['tag'] == '[/episode]' and current:
                ids = values(current, '[epic_index]')
                if any(i in by_id for i in ids):blocks.append(current)
                current = []
        npcs = []
        for key in NPC_IDS:
            path = 'npc/'+npc_paths[key].lower()
            rows = fields(path, ['[name]', '[field name]', '[field animation]', '[small face]', '[big face]',
                                 '[popup face]', '[role]', '[skill]'])
            dialogue = [s for s in script(path)['spans'] if s['tag'] == '[dialog]'][:2]
            rows.extend(field(s) for s in dialogue)
            npcs.append({'id':key, 'path':path, 'name':label(rows), 'fields':rows})
        towns, map_paths = [], set()
        for path in TOWNS:
            rows = fields(path, None)
            towns.append({'path':path, 'name':label(rows), 'fields':rows})
            for row in rows:
                if row['tag'] == '[area]' and len(row['values']) > 1:
                    map_paths.add('map/'+row['values'][1].lower())
        # Variants are evidence candidates only; never choose one as effective.
        for row in lib.config.execute("select path from files where extension='.map' and (path like 'map/hendonmyre/(r)%' or path like 'map/hendonmyre/(f)%' or path like 'map/hendonmyre/jap_replace/%')"):
            map_paths.add(row[0])
        maps = []
        for path in sorted(map_paths):
            if not exists(path):
                diagnostics.append({'kind':'town_map_reference_missing', 'path':path})
                continue
            rows = fields(path, ['[NPC]', '[move gate]', '[pass gate]', '[size]', '[tile]'])
            # Tile runs can be large; source hashes remain available, no image export.
            rows = [r for r in rows if r['tag'] != '[tile]']
            maps.append({'path':path, 'fields':rows})
        dungeons = []
        for key, ref in listing('dungeon/dungeon.lst').items():
            path = 'dungeon/'+ref.lower()
            if not exists(path):continue
            rows = fields(path, ['[name]', '[minimum required level]', '[basis level]', '[entering title]'])
            level = values(rows, '[minimum required level]')
            if level and isinstance(level[0], int) and 1 <= level[0] <= 20:
                dungeons.append({'id':key, 'path':path, 'name':label(rows), 'fields':rows})
            else:sources.pop(path, None)
        return {'schema':'dnf_early_world_evidence/1', 'scope':'archived_backup_not_verified_effective_runtime',
                'asset_version':json.loads(LOCK.read_text(encoding='utf-8'))['version'],
                'config_sha256':hashlib.sha256((library/'pvf_config.sqlite').read_bytes()).hexdigest(),
                'selection':'quest min_level 1..20; all/swordman; Elvengard/Handonmyre/WestCost, corresponding common directories and swordman job files; dungeon minimum_required_level 1..20; not an activation whitelist',
                'quest_payload_semantics':'opaque; no gold/XP formula, subtype decoder or server gating inferred',
                'quests':selected, 'episodes':blocks, 'npcs':npcs, 'towns':towns, 'maps':maps,
                'dungeons':dungeons, 'sources':dict(sorted(sources.items())), 'diagnostics':diagnostics}
    finally:lib.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT/'temp/early_world_audit/evidence.json')
    args = parser.parse_args()
    if not args.output.resolve().is_relative_to((ROOT/'temp').resolve()):parser.error('Generated evidence must stay in temp/')
    lock = json.loads(LOCK.read_text(encoding='utf-8'))
    library = args.library or cache_home()/lock['version']/'library_v1'
    result = audit(library)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=1)+'\n', encoding='utf-8')
    print(json.dumps({'quests':len(result['quests']), 'npcs':len(result['npcs']), 'maps':len(result['maps']),
                      'dungeons':len(result['dungeons']), 'diagnostics':len(result['diagnostics'])}))

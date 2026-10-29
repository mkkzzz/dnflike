"""Migrate the complete archived quest/item corpus, then compile supported rules.

No limit, chapter whitelist, or level filter. All files, unindexed records,
aliases and malformed bytes survive in compressed, deterministic source shards.
Executable definitions are a separate output; unsupported semantics have explicit
per-record reasons and never turn into inert equipment or fake completed quests.
Chinese comes from the SAME structural archive, converted to Simplified Chinese.
"""
from __future__ import annotations

import argparse
import base64
from collections import Counter, defaultdict
from functools import lru_cache
import gzip
import hashlib
import json
from pathlib import Path
import re
import struct
import sqlite3

from audit_dnf_reusable_data import TextResolver, string_bytes
from build_dnf_progression_data import clean, simplify, reward_rows, STATS, SLOTS
from dnf_pvf import open_library, resolve

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'game_dnf/data'
LISTS = {'quests': 'n_quest/quest.lst', 'equipment': 'equipment/equipment.lst',
         'stackable': 'stackable/stackable.lst'}
BAD = re.compile(r'[\u1100-\u11ff\u3130-\u318f\uac00-\ud7ff\ue000-\uf8ff\ufffd]')
JOBS = {'[all]': -1, '[swordman]': 0, '[fighter]': 1, '[gunner]': 2,
        '[mage]': 3, '[priest]': 4, '[at gunner]': 5, '[thief]': 6,
        '[at fighter]': 7, '[at mage]': 8, '[demonic swordman]': 9,
        '[creator mage]': 10}
# Metadata has no executable stat/effect semantics. Every other tag must be
# consumed by the compiler, or the item remains in the complete source registry.
ITEM_META = set('name|name2|explain|flavor text|basic explain|detail explain|grade|rarity|weight|price|value|repair price|creation rate|icon|field image|icon mark|move wav|use wav|item group name|item category|minimum level|usable job|attach type|stack limit|npc gift disallowance|equipment type|durability|stackable type|sub type'.split('|'))
ITEM_META = {'[' + x + ']' for x in ITEM_META}
GEAR_PRESENTATION = {'[animation job]','[variation]','[layer variation]','[equipment ani script]','[possible kiri protect]'}
RATE_STATS = {'[attack speed]': ('attack_speed', 1000), '[cast speed]': ('cast_speed', 1000),
              '[move speed]': ('move_speed', 1000), '[physical critical hit]': ('physical_crit', 100),
              '[magical critical hit]': ('magical_crit', 100), '[stuck]': ('hit', -100),
              '[inventory limit]': ('carry_capacity', 1000)}
RESIST = {'[' + x + ' resistance]': x + '_resist' for x in ['fire', 'water', 'light', 'dark']}
NPCS = {1: 'linus', 2: 'seria', 3: 'kanna', 4: 'sinda', 6: 'pungjin',
        7: 'gsd', 8: 'danjin', 9: 'shylock', 13: 'norton', 17: 'kiri', 27: 'albert', 45: 'grandis'}
# IDs independently present in the existing dungeon source definitions.
DUNGEONS = {1: 'lorien', 2: 'lorien_inside', 3: 'mirkwood', 4: 'mirkwood_deep',
            5: 'sunderland', 6: 'sunderland_poison'}
QUEST_META = {'[' + x + ']' for x in 'name|grade|difficulty|gold multiple|npc index|complete npc index|job|grow type|level|pre required quest|type|sub type|int data|reward type|reward int data|reward selection int data|condition message|depend message|solve message|dialog|dungeon info|ignore quest level 4 exp|cant giveup'.split('|')}


def dumps(value):
    return (json.dumps(value, ensure_ascii=True, separators=(',', ':'), allow_nan=False) + '\n').encode()


def write_gzip(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(gzip.compress(dumps(data), mtime=0))


@lru_cache(maxsize=200000)
def chinese(text):
    return clean(simplify(text))


def decode_fields(raw, strings, used):
    """Ordered flat fields plus exact tokens; never coalesce repeated tags."""
    if not raw.startswith(b'\xb0\xd0') or (len(raw) - 2) % 5:
        raise ValueError('unaligned B0D0 script')
    fields, node = [], None
    for kind, bits in struct.iter_unpack('<Bi', raw[2:]):
        if kind in [5, 6, 7, 8, 10]:
            used.add(bits)
        if kind == 5:
            tag = string_bytes(strings, bits).decode('ascii', 'strict')
            node = {'tag': tag, 'values': []}
            fields.append(node)
        elif node is not None:
            if kind == 2:
                value = bits
            elif kind == 4:
                value = struct.unpack('<f', struct.pack('<i', bits))[0]
            elif kind in [6, 7, 8]:
                content = string_bytes(strings, bits)
                try:
                    value = content.decode('ascii')
                except UnicodeDecodeError:
                    # Display text is separately resolved with source provenance.
                    value = {'string_index': bits, 'bytes_base64': base64.b64encode(content).decode()}
            else:
                value = {'token_type': kind, 'bits': bits}
            node['values'].append(value)
    return fields


def scalar(fields, tag, default=None):
    return fields.get(tag, [default])[0] if fields.get(tag) else default


def resolve_extra_text(fields, resolver):
    """Resolve localization pairs in ALL fields, including later/custom fields.

    Known player-facing text is also promoted to record.text. Unknown sections
    retain resolved links inline without pretending to understand their behavior.
    """
    for field in fields:
        pending = None
        for value in field['values']:
            if not isinstance(value, dict):pending = None;continue
            if value.get('token_type') == 9:
                pending = value['bits'];continue
            if value.get('token_type') == 10 and pending is not None:
                try:
                    path, table = resolver.table(pending)
                    key = string_bytes(resolver.lib.strings, value['bits']).decode('ascii')
                    entry = table.get(key)
                    value['localization'] = {'path': path, 'key': key, 'line': entry['line'] if entry else None,
                                              'text': chinese(entry['text']) if entry else '', 'missing': entry is None}
                except (KeyError, ValueError, UnicodeError) as exc:value['localization_error'] = str(exc)
            elif 'bytes_base64' in value:
                try:value['simplified_text'] = chinese(base64.b64decode(value['bytes_base64']).decode('cp950'))
                except UnicodeError as exc:value['text_error'] = str(exc)
            pending = None


def compile_item(number, listing, path, sha, fields, words):
    reasons = []
    name = words.get('[name]', '')
    if not name or BAD.search(name):reasons.append('missing_chinese_name')
    if any(BAD.search(v) for v in words.values()):reasons.append('invalid_display_text')
    gear = listing == LISTS['equipment']
    typ = scalar(fields, '[stackable type]', '')
    kind = 'weapon' if gear else {'[quest]': 'quest', '[material]': 'material', '[material expert job]': 'profession'}.get(typ, 'consumable')
    item = {'name': name, 'kind': kind, 'rarity': scalar(fields, '[rarity]', 0),
            'level': max(1, scalar(fields, '[minimum level]', 1)),
            'weight': scalar(fields, '[weight]', 0) / 1000, 'price': scalar(fields, '[price]', 0),
            'stack_limit': 1 if gear else max(1, scalar(fields, '[stack limit]', 99)),
            'description': words.get('[explain]', ''), 'multiplier': 1.0,
            'icon': fields.get('[icon]', []), 'field_image': fields.get('[field image]', fields.get('[icon]', [])),
            'source': {'id': number, 'list': listing, 'path': path, 'sha256': sha}}
    if item['rarity'] not in range(6):reasons.append('unsupported_rarity')
    for frame in ['icon', 'field_image']:
        value = item[frame]
        if len(value) != 2 or not isinstance(value[0], str) or type(value[1]) is not int or value[1] < 0:
            reasons.append('missing_' + frame)
    # No implicit sell price formula or unrestricted bind handling for new items.
    item.update(purchasable=False, sellable=False)
    equipment = recovery = None
    consumed = set(ITEM_META)
    if gear:
        consumed.update(GEAR_PRESENTATION)
        # The host currently permits equipping only in town. Retain the source
        # swap cooldown; combat-time swapping must not bypass it when added.
        consumed.add('[cool time]')
        item['adaptations'] = ['Town-only equipment changes; source cooldown retained, combat swapping disabled',
                               'Weapon appearance uses the existing three supported families; source variation retained in native record']
        slot = SLOTS.get(scalar(fields, '[equipment type]'))
        if slot is None:reasons.append('equipment_slot:' + str(scalar(fields, '[equipment type]')))
        stats, ranges = {}, {}
        for tag, stat in {**STATS, **RESIST}.items():
            if tag not in fields:continue
            values = fields[tag]
            if len(values) not in [1, 2] or not all(type(v) in [int, float] for v in values):
                reasons.append('stat_grammar:' + tag);continue
            ranges[stat] = [min(values), max(values)]
            stats[stat] = sum(ranges[stat]) / 2
        consumed.update(STATS);consumed.update(RESIST);consumed.update(RATE_STATS)
        for tag, (stat, divisor) in RATE_STATS.items():
            if tag not in fields:continue
            values = fields[tag]
            if len(values) != 1 or type(values[0]) not in [int, float]:
                reasons.append('stat_grammar:' + tag);continue
            stats[stat] = values[0] / divisor;ranges[stat] = [stats[stat], stats[stat]]
        if '[separate attack]' in fields:
            values = fields['[separate attack]']
            if len(values) != 2 or not all(type(v) in [int, float] for v in values):reasons.append('separate_attack_grammar')
            else:
                for stat, value in zip(['physical_independent_attack', 'magical_independent_attack'], values):
                    stats[stat] = value;ranges[stat] = [value, value]
        consumed.add('[separate attack]')
        equipment = {'name': name, 'slot': slot, 'stats': stats, 'stat_ranges': ranges,
                     'required_level': item['level'], 'durability': max(1, scalar(fields, '[durability]', 40)),
                     'usable_jobs': fields.get('[usable job]', ['[all]']), 'source': item['source']}
        if slot == 'weapon':
            weapon = next((v for k, v in [('/katana/', 'katana'), ('/ssword/', 'shortsword'), ('/lsword/', 'greatsword')] if k in path), None)
            if not weapon:reasons.append('weapon_family')
            else:equipment['weapon'] = weapon
    elif kind in ['material', 'profession', 'quest']:
        pass # Ownership, splitting, storage and quest consumption are the behavior.
    elif typ == '[waste]':
        hp = mp = duration = hp_percent = mp_percent = 0
        durations = set()
        for tag, stat in [('[hp recovery]', 'hp'), ('[mp recovery]', 'mp')]:
            if tag not in fields:continue
            values = fields[tag]
            if len(values) != 4 or values[0] not in ['+','%'] or values[3] != 'myself' or not all(type(v) is int and v >= 0 for v in values[1:3]):
                reasons.append('recovery_grammar:' + tag);continue
            if values[0]=='%' and values[1]>100:reasons.append('recovery_percent_range:' + tag);continue
            if stat == 'hp':
                if values[0]=='+':hp = values[1]
                else:hp_percent = values[1]
            else:
                if values[0]=='+':mp = values[1]
                else:mp_percent = values[1]
            duration = max(duration, values[2])
            durations.add(values[2])
        consumed.update(['[hp recovery]', '[mp recovery]', '[cool time]', '[cooltime group]'])
        if not hp and not mp and not hp_percent and not mp_percent:reasons.append('consumable_effect')
        if len(durations)>1:reasons.append('independent_recovery_durations')
        cooldown = scalar(fields, '[cool time]', 0)
        recovery = {'level': item['level'], 'cooldown_ms': cooldown,
                    'group': 'original_%d' % scalar(fields, '[cooltime group]', 0), 'group_cooldown_ms': cooldown,
                    'effect': {'kind': 'restore', 'hp': hp, 'mp': mp, 'duration_ms': duration,
                               'hp_percent':hp_percent,'mp_percent':mp_percent}}
    else:
        reasons.append('item_type:' + str(typ))
    reasons.extend('field:' + tag for tag in fields if tag not in consumed)
    return item, equipment, recovery, sorted(set(reasons))


def quest_plan(fields):
    """Compile only exact, already verified source tuple grammars."""
    kind = scalar(fields, '[type]', '')
    values = fields.get('[int data]', [])
    sub = scalar(fields, '[sub type]', -1)
    if not all(type(v) is int for v in values):return [], ['objective_noninteger']
    if kind == '[meet npc]' and len(values) == 1:
        return [{'type': 'meet_npc', 'npc': values[0], 'amount': 1}], []
    if kind == '[seeking]' and sub == -1 and values and len(values) % 2 == 0:
        if any(i <= 0 or n <= 0 for i, n in zip(values[::2], values[1::2])):return [], ['seeking_quantity']
        return [{'type': 'collect_item', 'item': i, 'amount': n} for i, n in zip(values[::2], values[1::2])], []
    if kind == '[hunt monster]' and sub == -1 and values and len(values) % 4 == 0:
        return [{'type': 'kill_monster', 'dungeon': d, 'difficulty': m, 'monster': i, 'amount': n}
                for d, m, i, n in zip(values[::4], values[1::4], values[2::4], values[3::4])], []
    if kind == '[condition under clear]' and sub == 0 and len(values) == 2:
        return [{'type': 'clear_dungeon', 'dungeon': values[0], 'difficulty': values[1], 'amount': 1}], []
    if kind == '[custom quest]' and sub == 0 and values == [1, 0, 1]:
        return [{'type': 'learn_skill', 'target': 'any', 'amount': 1}], []
    return [], ['objective:' + str(kind) + ':sub=' + str(sub) + ':width=' + str(len(values))]


def compile_quest(number, path, sha, fields, words, existing, items, monster_index):
    plan, reasons = quest_plan(fields)
    if number is None:reasons.append('unindexed')
    if not words.get('[name]') or not words.get('[condition message]'):reasons.append('missing_chinese_text')
    if any(BAD.search(v) for v in words.values()):reasons.append('invalid_display_text')
    reasons.extend('field:' + k for k in fields if k not in QUEST_META)
    if scalar(fields, '[grade]') not in ['[epic]', '[achievement]', '[common unique]', '[training]']:
        reasons.append('quest_grade:' + str(scalar(fields, '[grade]')))
    giver = NPCS.get(scalar(fields, '[npc index]'))
    receiver_num = scalar(fields, '[complete npc index]', -1)
    receiver = giver if receiver_num == -1 else NPCS.get(receiver_num)
    if not giver or not receiver:reasons.append('npc_not_in_town')
    prerequisites = fields.get('[pre required quest]', [])
    jobs = fields.get('[job]', ['[all]'])
    if any(j not in JOBS for j in jobs):reasons.append('unknown_job')
    objectives, consume = [], {}
    for ix, p in enumerate(plan):
        o = {'id': 'objective_%d' % ix, 'type': p['type'], 'amount': p['amount']}
        if not 1 <= p['amount'] <= 1000000:reasons.append('objective_quantity')
        if p['type'] == 'meet_npc':
            o['target'] = NPCS.get(p['npc'], '')
            if not o['target']:reasons.append('target_npc_not_in_town')
        elif p['type'] == 'collect_item':
            o['target'] = 'original_%d' % p['item'];consume[o['target']] = p['amount']
            if o['target'] not in items:reasons.append('item_unavailable:' + o['target'])
        elif p['type'] == 'learn_skill':o['target'] = 'any'
        else:
            dungeon = DUNGEONS.get(p['dungeon'])
            if not dungeon:reasons.append('dungeon_unavailable:' + str(p['dungeon']))
            if p['type'] == 'clear_dungeon':o['target'] = dungeon or ''
            else:
                o['target'] = monster_index.get(p['monster'], '')
                o['dungeon'] = dungeon or ''
                if not o['target']:reasons.append('monster_unavailable:' + str(p['monster']))
            if p['difficulty'] != -1:
                if p['difficulty'] not in [0, 1, 3]:reasons.append('difficulty_not_implemented:' + str(p['difficulty']))
                else:o['difficulty'] = [{0: 'normal', 1: 'adventure', 3: 'king'}[p['difficulty']]]
        objectives.append(o)
    reward = {'gold': 0, 'xp': 0, 'items': {}, 'conditional_items': [], 'choices': []}
    try:
        reward['gold'], reward['items'], reward['conditional_items'] = reward_rows(fields.get('[reward int data]', []))
        choice_gold, choices, conditional = reward_rows(fields.get('[reward selection int data]', []))
        if choice_gold or conditional:raise ValueError('conditional choice')
        reward['choices'] = [{'id': k, 'item': k, 'amount': n} for k, n in choices.items()]
        for item in set(reward['items']) | set(choices) | {r['item'] for r in reward['conditional_items']}:
            if item not in items:reasons.append('reward_item_unavailable:' + item)
        if scalar(fields, '[reward type]', '[item]') != '[item]':reasons.append('reward_type')
    except ValueError as exc:reasons.append('reward_grammar:' + str(exc))
    q = {'id': existing.get(number, 'original.quest.%s' % number),
         'source': {'id': number, 'path': path, 'sha256': sha, 'raw_type': fields.get('[type]', []),
                    'raw_int_data': fields.get('[int data]', []), 'xp_adaptation': 'No unverified XP formula; newly compiled bulk rows award zero XP until source formula is implemented'},
         'name': words.get('[name]', ''), 'description': words.get('[condition message]', ''),
         'dialogue': {'accept': words.get('[depend message]', ''), 'complete': words.get('[solve message]', '')},
         'category': 'main' if scalar(fields, '[grade]') == '[epic]' else 'side',
         'chapter': path.split('/')[1], 'min_level': max(1, scalar(fields, '[level]', 1)),
         'max_level': fields.get('[level]', [1, 999])[-1],
         'requires': [existing.get(i, 'original.quest.%d' % i) for i in prerequisites],
         'eligibility': {'jobs': [JOBS.get(j, -999) for j in jobs], 'grow_types': fields.get('[grow type]', [-1])},
         'giver': giver or '', 'receiver': receiver or '', 'objectives': objectives,
         'reward': reward, 'consume': consume, 'enabled': True, 'abandonable': '[cant giveup]' not in fields}
    return q, plan, sorted(set(reasons))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'game_dnf/assets_local/native_data_v1')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    manifest_file = output / 'manifest.json'
    if args.check:
        doc = json.loads(manifest_file.read_text(encoding='utf8'))
        for path, sha in doc['files'].items():
            if hashlib.sha256((output / path).read_bytes()).hexdigest() != sha:raise ValueError('Package hash: ' + path)
        print('NATIVE PACKAGE VERIFIED', doc['summary']);return
    lib = open_library(args.library)
    # Derive and verify mapping identities from this archive, not guessed NPC IDs.
    npc_index = lib.listing('npc/npc.lst')
    expected_npcs = {'linus':'linus','seria':'seria','kanna':'kanna','sinda':'sinda','pungjin':'poongjin',
                     'gsd':'gsd','danjin':'danjin','shylock':'shylock','norton':'rothon','kiri':'kiri','albert':'albert','grandis':'grandis'}
    for number, target in NPCS.items():
        if Path(npc_index[number].replace('\\','/')).stem.lower() != expected_npcs[target]:raise ValueError('NPC identity mismatch')
    resolver = TextResolver(lib)
    indexes = {key: {str(i): resolve(lst, p) for i, p in lib.listing(lst).items()} for key, lst in LISTS.items()}
    by_path = defaultdict(list)
    for key, rows in indexes.items():
        for i, p in rows.items():by_path[p].append({'list': LISTS[key], 'id': int(i)})
    rows = lib.db.execute("select path,content,sha256,crc_ok from files where extension in ('.qst','.equ','.stk','.etc') order by path").fetchall()
    old_quests = json.loads((DATA / 'quests.json').read_text(encoding='utf8'))
    existing = {q['source']['id']: q['id'] for q in old_quests['quests'] if q.get('source', {}).get('id') is not None}
    old_items = json.loads((DATA / 'runtime_items.json').read_text(encoding='utf8'))['items']
    runtime = {'schema': 'dnf_native_runtime/1', 'items': {}, 'equipment': {}, 'consumables': {}, 'services': {}, 'quests': [], 'coverage': {}}
    records, locations, used, issues, stats = {}, {}, set(), [], Counter()
    candidates, item_fields = {}, {}
    with sqlite3.connect('file:' + (lib.path / 'catalog.sqlite').as_posix() + '?mode=ro', uri=True) as catalog:
        image_rows = catalog.execute("select original_path,container,frame_count from assets where validation='image_data_checked'").fetchall()
    image_counts = {}
    for image_path, container, frames in sorted(image_rows, key=lambda row: (not Path(row[1]).name.lower().startswith('sprite_'), row[1])):
        image_counts.setdefault(image_path.lower().replace('\\','/'), frames)
    quest_candidates = []
    for ix, (path, raw, sha, crc_ok) in enumerate(rows):
        if ix % 10000 == 0:print('NATIVE MIGRATE', ix, '/', len(rows), flush=True)
        record = {'path': path, 'sha256': sha, 'crc_ok': bool(crc_ok), 'source_ids': by_path.get(path, []),
                  'raw_base64': base64.b64encode(raw).decode(), 'text': {}, 'text_references': {}}
        if not record['source_ids']:stats['unindexed_files'] += 1
        try:
            fields = decode_fields(raw, lib.strings, used)
            resolve_extra_text(fields, resolver)
            # Ordered source fields remain here; exact bytes are never discarded.
            record['fields'] = fields
            spans, repeated = {}, []
            for f in fields:
                if f['tag'].startswith('[/'):continue
                if f['tag'] in spans:
                    repeated.append(f['tag']);continue
                spans[f['tag']] = f['values']
            record['repeated_fields'] = sorted(set(repeated))
            text = resolver.fields(raw)
            for tag, values in text.items():
                if values:
                    record['text'][tag] = chinese(values[0]['text'])
                    record['text_references'][tag] = {k: v for k, v in values[0].items() if k != 'text'}
            record['parse_status'] = 'parsed'
            if not crc_ok:raise ValueError('source_crc_failed')
            for ref in record['source_ids']:
                if ref['list'] == LISTS['quests']:
                    quest_candidates.append((ref['id'], record, spans))
                elif ref['list'] in [LISTS['equipment'], LISTS['stackable']]:
                    item, gear, recovery, reasons = compile_item(ref['id'], ref['list'], path, sha, spans, record['text'])
                    reasons.extend('repeated_field:' + tag for tag in record['repeated_fields'] if tag not in GEAR_PRESENTATION)
                    for field in ['icon','field_image']:
                        frame = item[field]
                        if len(frame)==2 and isinstance(frame[0],str) and type(frame[1]) is int:
                            count = image_counts.get('sprite/' + frame[0].lower().replace('\\','/').lstrip('/'), 0)
                            if not 0 <= frame[1] < count:reasons.append('image_unavailable:' + field)
                    key = 'original_%d' % ref['id']
                    if key in candidates:reasons.append('numeric_id_collision')
                    candidates[key] = (item, gear, recovery, reasons)
                    item_fields[key] = spans
        except (ValueError, KeyError, UnicodeError, TypeError, IndexError, OverflowError) as exc:
            record['parse_status'] = 'retained_raw'
            record['diagnostic'] = str(exc)
            issues.append({'path': path, 'code': 'source_parse', 'detail': str(exc)})
        stats[Path(path).suffix] += 1
        records[path] = record
    # The source index can reference files of a different suffix (recipe .equ).
    # All references must have a retained record; never silently skip such rows.
    missing = sorted(set(by_path) - set(records))
    for path in missing:
        found = lib.raw(path)
        records[path] = {'path': path, 'source_ids': by_path[path], 'parse_status': 'retained_raw',
                         'sha256': found[1] if found else '', 'raw_base64': base64.b64encode(found[0]).decode() if found else '',
                         'diagnostic': 'index_target_outside_script_extensions' if found else 'missing_source_file'}
        issues.append({'path': path, 'code': records[path]['diagnostic']})
    for key, (item, gear, recovery, reasons) in candidates.items():
        record = records[item['source']['path']]
        record.setdefault('execution', {})[key] = {'reasons': reasons, 'state': 'unsupported' if reasons else 'compiled'}
        if not reasons and key not in old_items:
            runtime['items'][key] = item
            values = item_fields[key]
            runtime['services'][key] = {'sell':max(0,scalar(values,'[value]',0))}
            if item['kind']!='quest' and scalar(values,'[value]',0)>0:item['sellable']=True
            if gear:
                runtime['equipment'][key] = gear
                runtime['services'][key]['repair_point']=max(1,int(scalar(values,'[repair price]',1))//gear['durability'])
                item['adaptations'].append('Repair-per-point retains the existing project conversion of source repair price divided by durability; original disassembly is not fabricated')
            if recovery:runtime['consumables'][key] = recovery
    available_items = {**runtime['items'], **old_items}
    monsters = {int(i): resolve('monster/monster.lst', p) for i, p in lib.listing('monster/monster.lst').items()}
    qrows = {}
    for number, record, fields in quest_candidates:
        q, plan, reasons = compile_quest(number, record['path'], record['sha256'], fields, record['text'], existing, available_items, monsters)
        reasons.extend('repeated_field:' + tag for tag in record['repeated_fields'])
        record['objective_plan'] = plan
        record['execution'] = {'state': 'existing' if number in existing else 'unsupported' if reasons else 'compiled', 'reasons': reasons}
        if number not in existing:qrows[q['id']] = (q, record, reasons)
    # Dependencies must all be executable. Iterate until stable; this also keeps
    # source cycles/missing prerequisites outside the operational quest graph.
    available_quests = set(existing.values())
    pending = dict(qrows)
    while True:
        admitted = [key for key, (q, _, reasons) in pending.items() if not reasons and all(r in available_quests for r in q['requires'])]
        if not admitted:break
        for key in admitted:
            q, record, _ = pending.pop(key)
            available_quests.add(key);runtime['quests'].append(q)
    for key, (q, record, reasons) in pending.items():
        if any(r not in available_quests for r in q['requires']):reasons.append('prerequisite_not_executable')
        record['execution'] = {'state': 'unsupported', 'reasons': sorted(set(reasons))}
    reason_counts = Counter()
    for record in records.values():
        ex = record.get('execution', {})
        entries = [ex] if 'state' in ex else list(ex.values())
        for entry in entries:reason_counts.update(entry.get('reasons', []))
    runtime['coverage'] = {'new_items': len(runtime['items']), 'new_equipment': len(runtime['equipment']),
                           'new_consumables': len(runtime['consumables']), 'new_quests': len(runtime['quests'])}
    output.mkdir(parents=True, exist_ok=True)
    for ix, start in enumerate(range(0, len(records), 512)):
        keys = sorted(records)[start:start + 512]
        name = 'records_%03d.json.gz' % ix
        write_gzip(output / name, {'schema': 'dnf_native_records/1', 'records': {p: records[p] for p in keys}})
        locations.update({p: name for p in keys})
    pool = {str(i): base64.b64encode(string_bytes(lib.strings, i)).decode() for i in sorted(used)}
    write_gzip(output / 'strings.json.gz', {'schema': 'dnf_native_string_bytes/1', 'strings': pool})
    supporting = {}
    for path in sorted({'stringtable.bin','n_string.lst'} | set(resolver.sources)):
        raw, sha = lib.raw(path)
        supporting[path] = {'sha256':sha,'raw_base64':base64.b64encode(raw).decode()}
    write_gzip(output / 'localization_sources.json.gz', {'schema':'dnf_native_localization_bytes/1','files':supporting})
    write_gzip(output / 'index.json.gz', {'schema': 'dnf_native_index/1', 'indexes': indexes, 'locations': locations,
               'names': {p: r.get('text', {}).get('[name]', '') for p, r in records.items()}})
    runtime_payload = (json.dumps(runtime, ensure_ascii=False, indent=1) + '\n').encode('utf8')
    with lib.db_path.open('rb') as source_file:database_sha = hashlib.file_digest(source_file,'sha256').hexdigest()
    manifest = {'schema': 'dnf_native_catalog/1', 'source': {'kind': '111 archived extraction',
                  'pvf_sha256': 'f48850456b7dc0107278fb3f3a74fd68ee404889b95880f3204ce10fbd179be0',
                  'extraction_database_sha256':database_sha,
                  'encoding': 'cp950', 'display_conversion': 'Traditional to Simplified; no cross-PVF index joins'},
                'summary': {'files': len(records), 'by_extension': dict(stats),
                    'indexed_ids': {k: len(v) for k, v in indexes.items()}, 'retained_raw': len(issues), **runtime['coverage']},
                'diagnostics': issues, 'unsupported_reasons': dict(reason_counts.most_common()),
                'runtime_sha256':hashlib.sha256(runtime_payload).hexdigest(),
                'files': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.glob('*.json.gz'))}}
    manifest_file.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
    (DATA / 'native_runtime.json').write_bytes(runtime_payload)
    lib.close()
    print('NATIVE MIGRATION', json.dumps(manifest['summary']))


if __name__ == '__main__':main()

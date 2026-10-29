"""Compile the next playable quest/item batch; preserve source identity and old IDs.

111 remains the structural baseline. Simplified text is taken only from the same
numeric ID and normalized path in the independently fingerprinted 1031 archive.
Unknown reward/effect encodings fail this build instead of silently dropping data.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
from pathlib import Path

from dnf_pvf import open_library, resolve
from dnf_pvf_archive import Archive
from audit_dnf_reusable_data import TextResolver

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / 'game_dnf'
NEW_QUESTS = {108: 'gran.kaino_legend', 4302: 'gran.goblin_mutation', 109: 'gran.meet_gsd'}
SLOTS = {'[coat]':'coat', '[pants]':'pants', '[shoulder]':'shoulder', '[waist]':'belt',
         '[shoes]':'shoes', '[amulet]':'necklace', '[wrist]':'bracelet', '[ring]':'ring', '[weapon]':'weapon'}
STATS = {'[HP MAX]':'hp_max', '[MP MAX]':'mp_max', '[physical attack]':'strength',
         '[magical attack]':'intelligence', '[physical defense]':'vitality', '[magical defense]':'spirit',
         '[equipment physical attack]':'physical_attack', '[equipment magical attack]':'magical_attack',
         '[equipment physical defense]':'physical_defense', '[equipment magical defense]':'magical_defense'}
NPCS = {1:'linus',2:'seria',4:'sinda',6:'pungjin',7:'gsd',9:'shylock'}


def load(name):
    return json.loads((GAME / 'data' / (name + '.json')).read_text(encoding='utf-8'))


def write(name, data):
    (GAME / 'data' / (name + '.json')).write_text(json.dumps(data, ensure_ascii=False, indent=1 if name == 'dungeons' else 2) + '\n', encoding='utf-8')


def simplify(text):
    """Source-language fallback; do not hand-translate unknown item identities."""
    if not text:
        return text
    try:
        mapper = ctypes.windll.kernel32.LCMapStringEx
    except AttributeError:
        from opencc import OpenCC
        return OpenCC('t2s').convert(text)
    out = ctypes.create_unicode_buffer(len(text) * 2 + 4)
    size = mapper('zh-CN', 0x02000000, text, len(text), out, len(out), None, None, 0)
    if not size:
        raise ValueError('Simplified Chinese conversion failed')
    return out[:size]


def clean(text):
    return text.replace('\\n', '\n').replace('\r\n', '\n').replace('什幺', '什么').replace('怎幺', '怎么')


def reward_rows(values):
    gold, fixed, conditional = 0, {}, []
    index = 0
    while index < len(values):
        number = values[index]
        if type(number) is not int or number < 0:
            raise ValueError('Unsupported reward item ID')
        if index + 1 < len(values) and values[index + 1] == '[job]':
            if index + 4 >= len(values) or not all(type(v) is int for v in values[index + 2:index + 5]):
                raise ValueError('Malformed conditional reward')
            job, grow, amount = values[index + 2:index + 5]
            if number == 0 or amount < 1:
                raise ValueError('Invalid conditional reward')
            conditional.append({'item': 'original_%d' % number, 'amount': amount, 'jobs':[job], 'grow_types':[grow]})
            index += 5
        else:
            if index + 1 >= len(values) or type(values[index + 1]) is not int or values[index + 1] < 1:
                raise ValueError('Malformed fixed reward')
            amount = values[index + 1]
            if number == 0:
                gold += amount
            else:
                key = 'original_%d' % number
                fixed[key] = fixed.get(key, 0) + amount
            index += 2
    return gold, fixed, conditional


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--text-pvf', type=Path, required=True)
    args = parser.parse_args()
    lib, zh = open_library(args.library), Archive(args.text_pvf)
    native, translated = TextResolver(lib), TextResolver(zh, 'gb18030')
    old_indices = {name:lib.listing(name) for name in ['equipment/equipment.lst','stackable/stackable.lst','n_quest/quest.lst']}
    new_indices = {name:zh.listing(name) for name in old_indices}
    qdoc, numbers, recovery, services, dungeons = (load(n) for n in ['quests','numbers','recovery','services','dungeons'])
    numbers['base'].setdefault('physical_independent_attack',0)
    numbers['base'].setdefault('magical_independent_attack',0)
    numbers['base']['carry_capacity']=50
    for container in [numbers['equipment'],recovery['consumables'],services['items']]:
        for key in list(container):
            if key.startswith('original_'):
                del container[key]
    texts = {}

    def label(path, listing, number):
        old = native.fields(lib.raw(path)[0])
        if resolve(listing, new_indices[listing].get(number, '__missing__')) != path:
            raise ValueError('Cross-version ID/path mismatch: %s:%d' % (listing, number))
        other = translated.fields(zh.raw(path)[0])
        output, provenance = {}, {}
        for tag in sorted(set(old) | set(other)):
            values = other.get(tag, [])
            origin = '1031'
            # This distribution has modern custom additions; retain baseline wording.
            if not values or not values[0].get('text') or any(word in values[0]['text'] for word in ['微信', 'QQ群']):
                values = old.get(tag, [])
                origin = '111_t2s'
            if values:
                output[tag] = clean(values[0]['text'] if origin == '1031' else simplify(values[0]['text']))
                provenance[tag] = {'origin':origin, **{k:v for k,v in values[0].items() if k != 'text'}}
        texts[path] = {'fields':output, 'references':provenance, 'text_script_sha256':zh.raw(path)[1]}
        return output

    ids_to_local = {q.get('source', {}).get('id'):q['id'] for q in qdoc['quests']}
    ids_to_local.update(NEW_QUESTS)
    existing = {q['id']:q for q in qdoc['quests']}
    needed = {1106,1112,1107,1113}
    for number in sorted(k for k in ids_to_local if k is not None):
        listing = 'n_quest/quest.lst'
        path = resolve(listing, old_indices[listing][number])
        source = lib.script(path)
        fields = {f['tag']:f['values'] for f in source['fields']}
        words = label(path, listing, number)
        if number in NEW_QUESTS and ids_to_local[number] not in existing:
            giver = NPCS[fields['[npc index]'][0]]
            receiver_number = fields['[complete npc index]'][0]
            receiver = giver if receiver_number == -1 else NPCS[receiver_number]
            target = {'id':'kill','type':'kill_monster','target':'monster/goblin/kinol.mob','dungeon':'sunderland','amount':1}
            if number == 109:
                target = {'id':'meet','type':'meet_npc','target':'gsd','amount':1}
            q = {'id':ids_to_local[number], 'source':{'id':number,'path':path,'sha256':source['sha256']},
                 'name':'', 'category':'main','chapter':'格兰之森','min_level':fields['[level]'][0],
                 'requires':[ids_to_local[k] for k in fields.get('[pre required quest]',[])],
                 'giver':giver,'receiver':receiver,'objectives':[target], 'description':'',
                 'reward':{'gold':0,'xp':180 if number in [108,4302] else 80,'items':{},'choices':[]},
                 'consume':{},'enabled':True,'abandonable':False}
            qdoc['quests'].append(q)
            existing[q['id']] = q
        q = existing[ids_to_local[number]]
        if number in [108,4302]:
            q['objectives'][0]['target'] = 'monster/goblin/kinol.mob'
        q['name'] = words['[name]']
        q['description'] = words['[condition message]']
        q['dialogue'] = {'accept':words.get('[depend message]',''), 'complete':words.get('[solve message]','')}
        q['source']['text_path'] = path
        q['source']['raw_reward'] = fields.get('[reward int data]',[])
        gold, fixed, conditional = reward_rows(fields.get('[reward int data]',[]))
        # The character creator currently supports original job 0 only. Keep all
        # source branches above, activate only rewards for that playable class.
        q['source']['other_class_rewards'] = [row for row in conditional if 0 not in row['jobs'] and -1 not in row['jobs']]
        conditional = [row for row in conditional if 0 in row['jobs'] or -1 in row['jobs']]
        if fields.get('[reward selection int data]'):
            raise ValueError('Selected batch contains an uncompiled choice reward')
        q['reward'].update(gold=gold, items=fixed, conditional_items=conditional)
        needed.update(int(k.removeprefix('original_')) for k in fixed)
        needed.update(int(r['item'].removeprefix('original_')) for r in conditional)
    runtime = {'schema':'dnf_runtime_items/1','revision':1,'items':{},'source_text':{},
               'structural_source':'111 backup; runtime applicability remains separately audited',
               'adaptations':['XP retains existing progression baseline; original XP formula unverified',
                              'Repair per point and disassembly yield remain adapted economy',
                              'Recovery tuple timing interpreted as simulation milliseconds',
                              'Equipment speed uses per-thousand; critical and stuck use percent; fixed attack uses damage-type channels'],
               'text_source_sha256':hashlib.sha256(args.text_pvf.read_bytes()).hexdigest()}
    for number in sorted(needed):
        listing = 'equipment/equipment.lst' if number in old_indices['equipment/equipment.lst'] else 'stackable/stackable.lst'
        path = resolve(listing, old_indices[listing][number])
        source = lib.script(path)
        fields = {f['tag']:f['values'] for f in source['fields']}
        words = label(path, listing, number)
        if not words.get('[name]'):
            raise ValueError('Missing item name: '+path)
        gear = listing.startswith('equipment')
        id = 'original_%d' % number
        get = lambda tag, default: fields.get(tag, [default])[0]
        item = {'name':words['[name]'], 'kind':'weapon' if gear else 'consumable',
                'level':max(1,int(get('[minimum level]',1))), 'rarity':int(get('[rarity]',0)),
                'weight':float(get('[weight]',0))/1000, 'price':int(get('[price]',0)), 'multiplier':1.0,
                'description':words.get('[explain]',''), 'stack_limit':1 if gear else int(get('[stack limit]',1000)),
                'source':{'id':number,'list':listing,'path':path,'sha256':source['sha256']},
                'source_fields':{k:v for k,v in fields.items() if k not in ['[name]','[name2]','[explain]','[flavor text]']},
                'icon':fields.get('[icon]',[]), 'field_image':fields.get('[field image]',[])}
        if gear:
            slot = SLOTS.get(get('[equipment type]',''))
            if not slot:
                # Original weapon types are subtype enums such as [ssword]/[lsword].
                slot = 'weapon' if '/weapon/' in path else None
            if slot is None:
                raise ValueError('Unsupported equipment slot: '+path)
            stats, ranges = {}, {}
            for tag, stat in STATS.items():
                if tag in fields:
                    vals = fields[tag]
                    if not vals or not all(isinstance(v,(int,float)) for v in vals):
                        raise ValueError('Unsupported stat: '+path+tag)
                    ranges[stat] = [float(vals[0]),float(vals[-1])]
                    stats[stat] = sum(ranges[stat])/2
            for tag,stat,divisor in [('[attack speed]','attack_speed',1000),('[cast speed]','cast_speed',1000),
                                     ('[move speed]','move_speed',1000),('[physical critical hit]','physical_crit',100),
                                     ('[magical critical hit]','magical_crit',100),('[stuck]','hit',-100),
                                     ('[inventory limit]','carry_capacity',1000)]:
                if tag in fields:
                    value=float(fields[tag][0])/divisor
                    stats[stat]=value;ranges[stat]=[value,value]
            for element in ['fire','water','light','dark']:
                if '['+element+' resistance]' in fields:
                    value=float(fields['['+element+' resistance]'][0])
                    stats[element+'_resist']=value;ranges[element+'_resist']=[value,value]
            if '[separate attack]' in fields:
                for index,stat in enumerate(['physical_independent_attack','magical_independent_attack']):
                    value=float(fields['[separate attack]'][index])
                    stats[stat]=value;ranges[stat]=[value,value]
            definition = {'name':item['name'],'slot':slot,'required_level':item['level'], 'stats':stats,
                          'stat_ranges':ranges,'source':item['source'],'durability':int(get('[durability]',40)),
                          'usable_jobs':fields.get('[usable job]',['[all]'])}
            if slot == 'weapon':
                definition['weapon'] = 'katana' if 'katana' in path else 'greatsword' if '/lsword/' in path else 'shortsword'
            numbers['equipment'][id] = definition
            services['items'][id] = {'sell':int(get('[value]',0)), 'repair_point':max(1,int(get('[repair price]',1))//max(1,definition['durability'])), 'disassemble':{'scrap_iron':max(1,item['level']//2)}}
            item['description'] = '原版装备 · '+{'weapon':'武器','coat':'上衣','belt':'腰带','bracelet':'手镯','ring':'戒指'}.get(slot,slot)
        else:
            hp, mp, duration = 0, 0, 0
            for tag, resource in [('[hp recovery]','hp'),('[mp recovery]','mp')]:
                if tag in fields:
                    value = fields[tag]
                    if len(value)!=4 or value[0]!='+' or value[3]!='myself' or not all(type(v) is int and v>=0 for v in value[1:3]):
                        raise ValueError('Unsupported recovery syntax: '+path)
                    if resource=='hp':hp=value[1]
                    else:mp=value[1]
                    duration=max(duration,value[2])
            if not hp and not mp:
                raise ValueError('Unsupported consumable effect: '+path)
            cooldown = int(get('[cool time]',0))
            recovery['consumables'][id] = {'level':item['level'],'cooldown_ms':cooldown,
                'group':'original_%d' % int(get('[cooltime group]',0)), 'group_cooldown_ms':cooldown,
                'effect':{'kind':'restore','hp':hp,'mp':mp,'duration_ms':duration}}
            item['description'] = '恢复 HP %d / MP %d，持续 %.1f 秒；冷却 %.1f 秒' % (hp,mp,duration/1000,cooldown/1000)
            services['items'][id] = {'sell':int(get('[value]',max(0,item['price']//4)))}
        runtime['items'][id] = item
        runtime['source_text'][path] = texts[path]
    qdoc['revision'] = 4
    qdoc['dungeons']['sunderland'] = '雷鸣废墟'
    qdoc['monsters'].pop('monster/goblin/lightning_goblin.mob',None)
    qdoc['monsters']['monster/goblin/kinol.mob'] = '落雷凯诺'
    dungeons['dungeons']['sunderland'].update(name='雷鸣废墟', min_level=5, requires=['gran.meet_shylock'])
    for room in dungeons['dungeons']['sunderland']['rooms']:
        room['name'] = '雷鸣废墟'
    runtime['quest_text'] = {path:value for path,value in texts.items() if path.endswith('.qst')}
    # Presentation labels remain separate from ws1's monster registration/AI.
    mob_index=lib.listing('monster/monster.lst')
    zh_mob_index=zh.listing('monster/monster.lst')
    mob_ids={resolve('monster/monster.lst',path):number for number,path in mob_index.items()}
    labels={'schema':'dnf_monster_labels/1','labels':{},'sources':{}}
    for spec in load('combat')['monsters'].values():
        path=spec['mob'];number=mob_ids.get(path)
        local=native.fields(lib.raw(path)[0]).get('[name]',[])
        origin='111_t2s'
        if number is not None and resolve('monster/monster.lst',zh_mob_index.get(number,'__missing__'))==path:
            candidate=translated.fields(zh.raw(path)[0]).get('[name]',[])
            if candidate and candidate[0].get('text'):local=candidate;origin='1031'
        text=local[0].get('text','') if local else ''
        labels['labels'][path]=clean(text if origin=='1031' else simplify(text)) or ('未命名怪物 %s' % number)
        labels['sources'][path]={'id':number,'origin':origin,'script_sha256':lib.raw(path)[1]}
    try:
        for name,data in [('runtime_items',runtime),('monster_names_zh',labels),('numbers',numbers),('recovery',recovery),('services',services),('quests',qdoc),('dungeons',dungeons)]:
            write(name,data)
    finally:
        lib.close();zh.close()
    print('Compiled original items=%d original quests=%d' % (len(runtime['items']),len(ids_to_local)-1))


if __name__=='__main__':
    main()

"""Compile original combat content into a reproducible content pack (doc 29, F2).

Scope v1: the swordman character, every attack info and skill reachable from it, the
animations those reference, and the goblin-family monsters with their actions/attacks.
Output (git-ignored): game_dnf/assets_local/content/combat_content.json plus a field
coverage report covering the WHOLE archive for ATK/SKL/CHR/MOB, so the backlog of
unsupported fields is explicit.

Records follow docs/design/29_新版工程框架_接口契约.md section 5:
  id, kind, raw (ordered field tree), decoded (named fields), evidence, unsupported, source.
Decoded fields carry E-PARSE (structure read) or E-INFER (meaning/unit inferred). Runtime
semantics of a field become E-RUN only after in-game verification; nothing here claims that.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys

from dnf_pvf import Library, canonical, find, key_of, open_library, resolve
from dnf_asset_store import ROOT

OUT = ROOT / 'game_dnf/assets_local/content'
SCHEMA = 'dnf_combat_content/1'
COMPILER_VERSION = 1
HANDLED_FILE = ROOT / 'game_dnf/combat/fields/handled.json'

# Decoders: canonical tag -> (decoded key, shape, evidence, note). Shapes:
#   int|float|str = first value; list = all values; enum = canonical enum tag(s); flag = presence.
ATK_FIELDS = {
    '[damage bonus]': ('damage_bonus', 'number', 'E-PARSE', 'Percent-like bonus; formula unknown'),
    '[absolute damage]': ('absolute_damage', 'number', 'E-PARSE', ''),
    '[attack type]': ('attack_type', 'enum', 'E-PARSE', 'physic / magic / ignore defense'),
    '[weapon damage apply]': ('weapon_damage_apply', 'int', 'E-PARSE', ''),
    '[attack enemy]': ('attack_enemy', 'int', 'E-PARSE', ''),
    '[attack friend]': ('attack_friend', 'int', 'E-PARSE', ''),
    '[attack myself]': ('attack_myself', 'int', 'E-PARSE', ''),
    '[elemental property]': ('element', 'enum', 'E-PARSE', ''),
    '[damage reaction]': ('damage_reaction', 'enum', 'E-PARSE', 'damage (stagger) / down / none'),
    '[push aside]': ('push_aside', 'int', 'E-PARSE', 'Horizontal knockback; unit unknown'),
    '[lift up]': ('lift_up', 'int', 'E-PARSE', 'Vertical launch; unit unknown'),
    '[attack direction]': ('attack_direction', 'enum', 'E-PARSE', 'hit horizon / hit down / hit lift up'),
    '[hit info]': ('hit_info', 'enum', 'E-PARSE', '[kind][blood] then effect scale values'),
    '[hit wav]': ('hit_wav', 'str', 'E-PARSE', 'Sound key in the audio table'),
    '[knuck back]': ('knock_back', 'list', 'E-PARSE', ''),
    '[bounce]': ('bounce', 'int', 'E-PARSE', ''),
    '[stuck]': ('stuck', 'number', 'E-PARSE', 'Hit-stop related; unit unknown'),
    '[active status]': ('active_status', 'enum', 'E-PARSE', 'Status effect with its values'),
    '[hit direction]': ('hit_direction', 'enum', 'E-PARSE', ''),
    '[ignore super armor]': ('ignore_super_armor', 'int', 'E-PARSE', ''),
    '[ignore weight]': ('ignore_weight', 'int', 'E-PARSE', ''),
    '[ignore defense]': ('ignore_defense', 'list', 'E-PARSE', ''),
    '[critical hit]': ('critical_hit', 'int', 'E-PARSE', ''),
    '[max target hit number]': ('max_targets', 'int', 'E-PARSE', ''),
    '[is hit number increasing]': ('hit_number_increasing', 'int', 'E-PARSE', ''),
    '[monster damage rate]': ('monster_damage_rate', 'float', 'E-PARSE', ''),
    '[human damage rate]': ('human_damage_rate', 'float', 'E-PARSE', ''),
    '[pvp]': ('pvp', 'section', 'E-PARSE', 'PvP overrides; out of PvE scope'),
    '[damage]': ('damage', 'number', 'E-PARSE', 'Numeric form (enum form is consumed by [damage reaction])'),
    '[MP drain]': ('mp_drain', 'int', 'E-PARSE', ''),
    '[HP drain]': ('hp_drain', 'int', 'E-PARSE', ''),
}
SKL_FIELDS = {
    '[name]': ('name_ref', 'list', 'E-PARSE', 'Localized string link (type 9/10), unresolved'),
    '[type]': ('type', 'list', 'E-PARSE', ''),
    '[skill class]': ('skill_class', 'int', 'E-PARSE', ''),
    '[maximum level]': ('max_level', 'int', 'E-PARSE', ''),
    '[required level]': ('required_level', 'int', 'E-PARSE', ''),
    '[required level range]': ('required_level_range', 'int', 'E-PARSE', ''),
    '[purchase cost]': ('purchase_cost', 'list', 'E-PARSE', ''),
    '[growtype maximum level]': ('growtype_max_level', 'list', 'E-PARSE', ''),
    '[skill fitness growtype]': ('fitness_growtype', 'list', 'E-PARSE', ''),
    '[icon]': ('icon', 'list', 'E-PARSE', 'IMG path + frame, normal then disabled'),
    '[command]': ('command', 'list', 'E-PARSE', 'Out of scope: D006 shortcut only'),
    '[weapon effect type]': ('weapon_effect_type', 'list', 'E-PARSE', ''),
    '[auto cooltime apply]': ('auto_cooltime_apply', 'int', 'E-PARSE', ''),
    '[durability decrease rate]': ('durability_decrease_rate', 'int', 'E-PARSE', ''),
    '[dungeon]': ('dungeon', 'context', 'E-PARSE', 'PvE context: consume MP, cool time, static data, level info'),
    '[pvp]': ('pvp', 'section', 'E-PARSE', 'PvP context; out of scope'),
    '[death tower]': ('death_tower', 'section', 'E-PARSE', 'Mode context; out of scope'),
    '[warroom]': ('warroom', 'section', 'E-PARSE', 'Mode context; out of scope'),
    '[level property]': ('level_property', 'list', 'E-PARSE', 'Tooltip formula rows; unresolved'),
    '[feature skill index]': ('feature_skill_index', 'int', 'E-PARSE', ''),
    '[consume MP]': ('consume_mp', 'list', 'E-PARSE', 'Mode-less form; same layout as [dungeon] child'),
    '[cool time]': ('cool_time', 'list', 'E-PARSE', 'Milliseconds (E-INFER); mode-less form'),
    '[static data]': ('static_data', 'list', 'E-PARSE', 'Skill-specific constants; meaning per skill'),
    '[level info]': ('level_info', 'list', 'E-PARSE', 'First value = columns per level, then rows'),
    '[casting time]': ('casting_time', 'list', 'E-PARSE', ''),
    '[consume item]': ('consume_item', 'list', 'E-PARSE', ''),
    '[pre required skill]': ('pre_required_skill', 'list', 'E-PARSE', 'Skill index, level pairs'),
    '[shake screen]': ('shake_screen', 'list', 'E-PARSE', ''),
    '[skill command advantage]': ('command_advantage', 'list', 'E-PARSE', 'Out of scope: D006 shortcut only'),
    '[name2]': ('name2_ref', 'list', 'E-PARSE', 'Localized string link, unresolved'),
    '[explain]': ('explain_ref', 'list', 'E-PARSE', 'Localized string link, unresolved'),
    '[basic explain]': ('basic_explain_ref', 'list', 'E-PARSE', 'Localized string link, unresolved'),
    '[start cool time]': ('start_cool_time', 'list', 'E-PARSE', ''),
    '[executable states]': ('executable_states', 'list', 'E-PARSE', 'States from which the skill may start'),
}
CHR_FIELDS = {
    '[job]': ('job', 'list', 'E-PARSE', ''),
    '[width]': ('width', 'list', 'E-PARSE', 'Body width/depth; unit unknown'),
    '[initial value]': ('initial', 'stats', 'E-PARSE', 'Level-1 base stats until the next group tag'),
    '[skill]': ('base_skills', 'pairs', 'E-PARSE', 'Skill index, level'),
    '[attack motion]': ('attack_motions', 'paths', 'E-PARSE', ''),
    '[attack info]': ('attack_infos', 'paths', 'E-PARSE', 'Aligned with attack motion'),
    '[jumpattack info]': ('jumpattack_info', 'paths', 'E-PARSE', ''),
    '[dashattack info]': ('dashattack_info', 'paths', 'E-PARSE', ''),
    '[etc attack info]': ('etc_attack_infos', 'paths', 'E-PARSE', ''),
    '[etc motion]': ('etc_motions', 'paths', 'E-PARSE', ''),
    '[weapon wav]': ('weapon_wav', 'repeat_list', 'E-PARSE', 'Per weapon subtype: swing A, swing B, hit A, hit B'),
    '[weapon hit info]': ('weapon_hit_info', 'list', 'E-PARSE', 'Per weapon subtype: kind, blood, then 4 numbers'),
    '[weapon skill info]': ('weapon_skill_info', 'list', 'E-PARSE', ''),
    '[upgrade weapon attack power rate]': ('upgrade_weapon_attack_rate', 'list', 'E-PARSE', ''),
    '[growtype name]': ('growtype_name_refs', 'list', 'E-PARSE', 'Localized string links'),
    '[awakening name]': ('awakening_name_refs', 'list', 'E-PARSE', 'Localized string links'),
    '[ghost motion]': ('ghost_motions', 'paths', 'E-PARSE', ''),
    '[body image path]': ('body_image', 'list', 'E-PARSE', ''),
}
for motion in ['waiting', 'move', 'sit', 'damage motion 1', 'damage motion 2', 'down', 'overturn', 'jump',
               'jumpattack', 'rest', 'dash', 'dashattack', 'getitem', 'buff', 'back']:
    tag = f'[{motion} motion]' if 'motion' not in motion else f'[{motion}]'
    CHR_FIELDS[tag] = (key_of(tag), 'paths', 'E-PARSE', '')
STAT_TAGS = ['[HP MAX]', '[MP MAX]', '[physical attack]', '[physical defense]', '[magical attack]', '[magical defense]',
             '[dark resistance]', '[light resistance]', '[fire resistance]', '[water resistance]', '[inventory limit]',
             '[MP regen speed]', '[move speed]', '[attack speed]', '[cast speed]', '[hit recovery]', '[jump power]',
             '[weight]', '[jump speed]', '[HP regen speed]']
GROUP_EXTRAS = ['[module damage rate]', '[skill]', '[awakening skill]']
MOB_FIELDS = {
    '[width]': ('width', 'list', 'E-PARSE', ''),
    '[ability category]': ('ability_category', 'list', 'E-PARSE', 'Stat, operator, percent triples'),
    '[category]': ('category', 'list', 'E-PARSE', ''),
    '[level]': ('level', 'list', 'E-PARSE', 'min, max'),
    '[move speed]': ('move_speed', 'list', 'E-PARSE', 'min, max'),
    '[attack speed]': ('attack_speed', 'list', 'E-PARSE', ''),
    '[cast speed]': ('cast_speed', 'list', 'E-PARSE', ''),
    '[hit recovery]': ('hit_recovery', 'list', 'E-PARSE', ''),
    '[weight]': ('weight', 'list', 'E-PARSE', ''),
    '[sight]': ('sight', 'int', 'E-PARSE', ''),
    '[warlike]': ('warlike', 'int', 'E-PARSE', ''),
    '[attack delay]': ('attack_delay', 'int', 'E-PARSE', 'Milliseconds (E-INFER)'),
    '[targeting nearest]': ('targeting_nearest', 'int', 'E-PARSE', ''),
    '[attack kind]': ('attack_kind', 'list', 'E-PARSE', ''),
    '[item]': ('drop_items', 'list', 'E-PARSE', 'Item id, weight pairs; flow side'),
    '[die effect]': ('die_effect', 'list', 'E-PARSE', ''),
    '[face image]': ('face_image', 'list', 'E-PARSE', ''),
    '[attack motion]': ('attack_motions', 'paths', 'E-PARSE', ''),
    '[attack info]': ('attack_infos', 'paths', 'E-PARSE', ''),
    '[name]': ('name_ref', 'list', 'E-PARSE', 'Localized string link, unresolved'),
    '[etc motion]': ('etc_motions', 'paths', 'E-PARSE', ''),
    '[floating height]': ('floating_height', 'list', 'E-PARSE', ''),
    '[hp regen rate]': ('hp_regen_rate', 'list', 'E-PARSE', ''),
    '[stuckbonus on damage]': ('stuck_bonus_on_damage', 'list', 'E-PARSE', 'Hit-stop related; meaning unknown'),
    '[int data]': ('int_data', 'list', 'E-PARSE', 'Monster-specific constants'),
    '[throw attack]': ('throw_attack', 'tagged', 'E-PARSE', 'Inline [key] value pairs; passive object by index'),
}
for res in ['fire', 'water', 'dark', 'light', 'freeze', 'slow', 'stun', 'stone', 'hold', 'poison', 'bleeding',
            'burn', 'lightning', 'curse', 'blind', 'confuse', 'sleep']:
    MOB_FIELDS[f'[{res} resistance]'] = (f'{res}_resistance', 'number', 'E-PARSE', '')
for motion in ['waiting', 'move', 'sit', 'damage motion 1', 'damage motion 2', 'down', 'overturn']:
    tag = f'[{motion} motion]' if 'motion' not in motion else f'[{motion}]'
    MOB_FIELDS[tag] = (key_of(tag), 'paths', 'E-PARSE', '')
OBJ_FIELDS = {
    '[width]': ('width', 'list', 'E-PARSE', ''),
    '[floating height]': ('floating_height', 'number', 'E-PARSE', ''),
    '[layer]': ('layer', 'str', 'E-PARSE', ''),
    '[pass type]': ('pass_type', 'str', 'E-PARSE', ''),
    '[piercing power]': ('piercing_power', 'int', 'E-PARSE', ''),
    '[basic motion]': ('basic_motion', 'paths', 'E-PARSE', ''),
    '[attack info]': ('attack_infos', 'paths', 'E-PARSE', ''),
    '[etc motion]': ('etc_motions', 'paths', 'E-PARSE', ''),
    '[etc attack info]': ('etc_attack_infos', 'paths', 'E-PARSE', ''),
    '[add object effect]': ('add_object_effect', 'list', 'E-PARSE', 'ANI path, layer'),
    '[destroy particle]': ('destroy_particle', 'paths', 'E-PARSE', ''),
    '[object destroy condition]': ('destroy_condition', 'list', 'E-PARSE', ''),
    '[int data]': ('int_data', 'list', 'E-PARSE', ''),
    '[name]': ('name', 'list', 'E-PARSE', ''),
}
PTL_FIELDS = {
    '[x axis]': ('x_axis', 'section', 'E-PARSE', ''),
    '[move type]': ('move_type', 'str', 'E-PARSE', ''),
    '[move variable 1]': ('move_variable_1', 'list', 'E-PARSE', 'Speed min, max (px/s, E-INFER)'),
    '[life time]': ('life_time', 'int', 'E-PARSE', 'Milliseconds (E-INFER)'),
    '[landing type]': ('landing_type', 'str', 'E-PARSE', ''),
}
FIELD_TABLES = {'atk': ATK_FIELDS, 'skl': SKL_FIELDS, 'chr': CHR_FIELDS, 'mob': MOB_FIELDS, 'obj': OBJ_FIELDS, 'ptl': PTL_FIELDS}
# Passive objects spawned by the trial skills (engine code links them, not a script field).
SKILL_OBJECTS = ['passiveobject/character/swordman/gorecross.obj', 'passiveobject/character/swordman/momentaryslashwave.obj']


def first(node: dict):
    return node['values'][0] if node['values'] else None


def decode_value(node: dict, shape: str, base_path: str):
    if shape == 'enum':
        return [{'value': e['canonical'], 'raw': e['tag'], 'args': e['values']} for e in node.get('enum', [])] or None
    if shape in ('int', 'float', 'str', 'number'):
        return first(node)
    if shape == 'paths':
        return [resolve(base_path, v) if isinstance(v, str) and v else v for v in node['values']]
    if shape == 'pairs':
        v = node['values']
        return [[v[i], v[i + 1]] for i in range(0, len(v) - 1, 2)]
    if shape == 'section':
        return {'present': True}
    if shape == 'tagged':
        out, key = {}, None
        for value in node['values']:
            if isinstance(value, str) and value.startswith('[') and value.endswith(']'):
                key = key_of(value)
                out[key] = None
            elif key is not None:
                out[key] = value if out[key] is None else (out[key] if isinstance(out[key], list) else [out[key]]) + [value]
        return out
    return node['values']


def decode_fields(kind: str, fields: list, path: str) -> tuple[dict, dict, list]:
    table = FIELD_TABLES[kind]
    decoded, evidence, unsupported = {}, {}, []
    i = 0
    while i < len(fields):
        node = fields[i]
        tag = canonical(node['tag'])
        if kind == 'chr' and tag in ('[initial value]',) or (kind == 'chr' and tag.startswith('[growtype ') and tag != '[growtype name]') \
                or (kind == 'chr' and tag.startswith('[awakening ') and tag[-2].isdigit()):
            group, stats = key_of(tag), {}
            i += 1
            while i < len(fields) and canonical(fields[i]['tag']) in STAT_TAGS + GROUP_EXTRAS:
                f = fields[i]
                stats[key_of(f['tag'])] = first(f) if len(f['values']) == 1 else f['values']
                i += 1
            decoded.setdefault('stat_groups', {})[group] = stats
            evidence['stat_groups/' + group] = 'E-PARSE'
            continue
        if kind == 'chr' and tag in STAT_TAGS:
            unsupported.append({'tag': node['tag'], 'offset': node['offset'], 'reason': 'stat outside a group'})
            i += 1
            continue
        if tag not in table:
            unsupported.append({'tag': node['tag'], 'offset': node['offset'], 'reason': 'no decoder'})
            i += 1
            continue
        key, shape, ev, _ = table[tag]
        if shape == 'context':
            ctx = {}
            for child in node.get('children', []):
                ctx[key_of(child['tag'])] = child['values']
            decoded[key] = ctx
        elif shape == 'repeat_list':
            decoded.setdefault(key, []).append(node['values'])
        elif key in decoded and shape not in ('section',):
            decoded.setdefault(key + '_repeats', []).append(decode_value(node, shape, path))
        else:
            decoded[key] = decode_value(node, shape, path)
        evidence[key] = ev
        if canonical(node['tag']) != node['tag'] or any(e['canonical'] != e['tag'] for e in node.get('enum', [])):
            evidence[key] = 'E-INFER'
        i += 1
    return decoded, evidence, unsupported


def record(lib: Library, path: str, kind: str) -> dict | None:
    script = lib.script(path, kind)
    if script is None:
        return None
    decoded, evidence, unsupported = decode_fields(kind, script['fields'], path)
    return {'id': path, 'kind': kind, 'raw': script['fields'], 'decoded': decoded, 'evidence': evidence,
            'unsupported': unsupported, 'diagnostics': script['diagnostics'],
            'source': {'path': path, 'sha256': script['sha256'], 'asset_version': lib.asset_version}}


def animation_record(lib: Library, path: str) -> dict | None:
    found = lib.animation(path)
    if found is None:
        return None
    meta = found['metadata'] or {}
    clock, timeline = 0, []
    for frame in meta.get('frames', []):
        delay = frame.get('delay_ms') or 0
        attack = [b['box'] for b in frame.get('boxes', []) if b['kind'] == 'attack']
        hurt = [b['box'] for b in frame.get('boxes', []) if b['kind'] == 'damage']
        timeline.append({'frame': frame['frame'], 'start_ms': clock, 'end_ms': clock + delay,
                         'attack_boxes': attack, 'damage_boxes': hurt, 'items': frame.get('items', {})})
        clock += delay
    return {'id': path, 'kind': 'ani', 'status': found['status'], 'error': found['error'],
            'decoded': {'duration_ms': meta.get('duration_ms'), 'frame_count': meta.get('frame_count'),
                        'global_items': meta.get('global_items', {}), 'sound_events': meta.get('sound_events', []),
                        'timeline': timeline},
            'evidence': {'timeline': 'E-PARSE', 'attack_boxes': 'E-PARSE', 'box_axes': 'E-INFER'},
            'unsupported': [], 'source': {'path': path, 'sha256': found['sha256'], 'asset_version': lib.asset_version}}


def compile_scope(lib: Library) -> dict:
    records: dict[str, dict] = {}
    missing: list[dict] = []

    def add(path: str, kind: str, origin: str) -> dict | None:
        path = path.lower()
        if path in records:
            return records[path]
        rec = animation_record(lib, path) if kind == 'ani' else record(lib, path, kind)
        if rec is None:
            missing.append({'id': path, 'kind': kind, 'referenced_by': origin})
            return None
        records[path] = rec
        return rec

    chr_path = 'character/swordman/swordman.chr'
    swordman = add(chr_path, 'chr', 'scope')
    d = swordman['decoded']
    for key in ['attack_infos', 'jumpattack_info', 'dashattack_info', 'etc_attack_infos']:
        for p in d.get(key) or []:
            if p:add(p, 'atk', chr_path)
    for key, value in d.items():
        if 'motion' in key:
            for p in value or []:
                if isinstance(p, str) and p.endswith('.ani'):add(p, 'ani', chr_path)
    skills = lib.listing('skill/swordmanskill.lst')
    skill_index = {}
    for index, rel in sorted(skills.items()):
        p = ('skill/' + rel).lower()
        if add(p, 'skl', 'skill/swordmanskill.lst'):
            skill_index[str(index)] = p
    monsters = lib.listing('monster/monster.lst')
    monster_index = {}
    object_paths: list[str] = list(SKILL_OBJECTS)
    object_index: dict[str, str] = {}
    for index, rel in sorted(monsters.items()):
        p = ('monster/' + rel).lower()
        if not p.startswith('monster/goblin/') and p not in {
                'monster/tau/tauarmy.mob','monster/tau/taubeast.mob',
                'monster/lugaru/lugaru.mob','monster/lugaru/kurogaru.mob'}:
            continue
        mob = add(p, 'mob', 'monster/monster.lst')
        if not mob:
            continue
        monster_index[str(index)] = p
        md = mob['decoded']
        for p2 in md.get('attack_infos') or []:
            if p2:add(p2, 'atk', p)
        for key, value in md.items():
            if 'motion' in key:
                for p2 in value or []:
                    if isinstance(p2, str) and p2.endswith('.ani'):add(p2, 'ani', p)
        throw = md.get('throw_attack') or {}
        if throw.get('passive_object_filename'):
            name = str(throw['passive_object_filename'])
            # Some mobs write archive-root paths here; prefer the script-relative one when it exists.
            relative = resolve(p, name)
            add(relative if lib.exists(relative) else name.replace('\\', '/').lower(), 'ptl', p)
        if throw.get('passive_object_index') is not None:
            obj_rel = lib.listing('passiveobject/passiveobject.lst').get(int(throw['passive_object_index']))
            if obj_rel:
                object_paths.append(('passiveobject/' + obj_rel).lower())
                object_index[str(throw['passive_object_index'])] = object_paths[-1]
            else:
                missing.append({'id': str(throw['passive_object_index']), 'kind': 'obj_index', 'referenced_by': p})
    for p in object_paths:
        obj = add(p, 'obj', 'scope')
        if not obj:
            continue
        od = obj['decoded']
        for key in ['basic_motion', 'etc_motions', 'destroy_particle']:
            for p2 in od.get(key) or []:
                if isinstance(p2, str) and p2:add(p2, 'ani' if p2.endswith('.ani') else 'ptl', p)
        for key in ['attack_infos', 'etc_attack_infos']:
            for p2 in od.get(key) or []:
                if p2:add(p2, 'atk', p)
        effect = od.get('add_object_effect') or []
        if effect and isinstance(effect[0], str):add(resolve(p, effect[0]), 'ani', p)
    return {'records': records, 'missing': missing,
            'indexes': {'swordman_skills': skill_index, 'monsters_goblin': monster_index, 'passive_objects': object_index}}


def coverage(lib: Library, handled: dict) -> dict:
    """Whole-archive field census for ATK/SKL/CHR/MOB, with decoder and runtime handler status."""
    report = {}
    for kind in ['atk', 'skl', 'chr', 'mob']:
        counts, files_with = Counter(), Counter()
        files = 0
        for path, content in lib.files('.' + kind):
            from dnf_pvf import parse_script
            try:
                parsed = parse_script(content, lib.strings, kind)
            except ValueError:
                continue
            files += 1
            seen = set()
            stack = list(parsed['fields'])
            while stack:
                node = stack.pop()
                tag = canonical(node['tag'])
                counts[tag] += 1
                seen.add(tag)
                for e in node.get('enum', []):
                    counts[tag + ' = ' + e['canonical']] += 1
                stack.extend(node.get('children', []))
            for tag in seen:
                files_with[tag] += 1
        table = FIELD_TABLES[kind]
        rows = []
        for tag, n in counts.most_common():
            if ' = ' in tag:
                continue
            decoder = table.get(tag)
            key = decoder[0] if decoder else None
            if kind == 'chr' and not decoder and (tag in STAT_TAGS + GROUP_EXTRAS or tag == '[initial value]'
                                                  or tag.startswith(('[growtype ', '[awakening '))):
                key, decoder = 'stat_groups', (None, None, 'E-PARSE', '')
            rows.append({'tag': tag, 'occurrences': n, 'files': files_with[tag],
                         'decoded_as': key, 'evidence': decoder[2] if decoder else None,
                         'runtime': handled.get(kind, {}).get(key, 'none') if key else 'none'})
        enums = defaultdict(dict)
        for tag, n in counts.items():
            if ' = ' in tag:
                parent, value = tag.split(' = ', 1)
                enums[parent][value] = n
        report[kind] = {'files': files, 'distinct_tags': len(rows), 'fields': rows, 'enum_values': enums,
                        'decoded_tags': sum(1 for r in rows if r['decoded_as']),
                        'runtime_handled_tags': sum(1 for r in rows if r['runtime'] != 'none')}
    return report


def run(library: Path | None, output: Path) -> dict:
    lib = open_library(library)
    try:
        scope = compile_scope(lib)
        handled = json.loads(HANDLED_FILE.read_text(encoding='utf-8')) if HANDLED_FILE.is_file() else {}
        cov = coverage(lib, handled)
        compiler_sha = hashlib.sha256(Path(__file__).read_bytes() + (ROOT / 'tools/dnf_pvf.py').read_bytes()).hexdigest()
        pack = {'schema': SCHEMA, 'compiler_version': COMPILER_VERSION, 'compiler_sha256': compiler_sha,
                'asset_version': lib.asset_version,
                'scope': 'swordman chr + reachable atk/ani + swordman skills; goblin-family monsters',
                'config_provenance': '111Script.pvf backup archive; runtime-effective PVF unconfirmed (DNF-D001)',
                'indexes': scope['indexes'], 'missing_references': scope['missing'],
                'records': dict(sorted(scope['records'].items()))}
        output.mkdir(parents=True, exist_ok=True)
        body = json.dumps(pack, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
        (output / 'combat_content.json').write_text(body, encoding='utf-8')
        cov_doc = {'schema': 'dnf_field_coverage/1', 'asset_version': lib.asset_version, 'kinds': cov}
        (output / 'field_coverage.json').write_text(json.dumps(cov_doc, ensure_ascii=False, indent=1, sort_keys=True), encoding='utf-8')
        kinds = Counter(r['kind'] for r in scope['records'].values())
        summary = {'records': dict(kinds), 'missing_references': len(scope['missing']),
                   'pack_sha256': hashlib.sha256(body.encode('utf-8')).hexdigest(),
                   'unsupported_in_scope': sum(len(r['unsupported']) for r in scope['records'].values()),
                   'coverage': {k: {'files': v['files'], 'tags': v['distinct_tags'], 'decoded': v['decoded_tags'],
                                    'runtime': v['runtime_handled_tags']} for k, v in cov.items()}}
        (output / 'compile_summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding='utf-8')
        return summary
    finally:
        lib.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path, help='Full extraction library; defaults to the shared cache')
    parser.add_argument('--output', type=Path, default=OUT)
    args = parser.parse_args()
    summary = run(args.library, args.output.resolve())
    print(json.dumps(summary, ensure_ascii=True, indent=1))


if __name__ == '__main__':
    sys.exit(main())

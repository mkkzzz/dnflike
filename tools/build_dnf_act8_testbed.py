"""Build an isolated act8/newmonsters logic testbed from the original library.

The testbed does not add a town entrance or promote Arden into the main campaign. It writes
the ten-room route, nine newmonsters/haze definitions, their action/ATK timeline records, and
only the monster presentation banks needed by the independent test scene.

Usage:
  python tools/build_dnf_act8_testbed.py [--library DIR] [--base-ref HEAD]
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_dnf_combat_assets import Atlas, MONSTER_HP_IMG, Source, cropped, monster_bank
from compile_dnf_content import ACTION_KEYS, animation_record, record
from dnf_pvf import Library, open_library

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'assets_local/act8_testbed'
TEXTURE_ROOT = 'res://assets_local/act8_testbed'
DUNGEONS = GAME / 'data/dungeons.json'
CATALOG = GAME / 'data/monster_catalog.json'


def git_json(ref: str, path: str) -> dict:
    result = subprocess.run(
        ['git', 'show', f'{ref}:{path}'],
        cwd=ROOT,
        capture_output=True,
        check=True,
    )
    return json.loads(result.stdout.decode('utf-8'))


def route_context(ref: str) -> tuple[dict, list[str], dict[str, str]]:
    route = git_json(ref, 'game_dnf/data/dungeons.json')['dungeons']['arden']
    export_path = GAME / route['map_export'].replace('res://', '')
    export = json.loads(export_path.read_text(encoding='utf-8'))
    placements = {item['id']: item for item in export['dungeon']['placements']}
    mobs: list[str] = []
    mob_ids: dict[str, str] = {}
    for room in route['rooms']:
        placement = placements[room['placement']]
        source = export['dungeon']['rooms'][placement['map']]
        for monster in source.get('monsters') or []:
            mob = str(monster.get('mob', '')).lower()
            if mob and mob not in mobs:
                mobs.append(mob)
            if mob:
                mob_ids.setdefault(mob, str(monster.get('id', '')))
    return route, mobs, mob_ids


def add_record(records: dict, lib: Library, path: str, kind: str, force: bool = False) -> dict:
    path = path.lower()
    if path in records and not force:
        return records[path]
    item = animation_record(lib, path) if kind == 'ani' else record(lib, path, kind)
    if item is None:
        raise RuntimeError(f'missing {kind}: {path}')
    records[path] = item
    return item


def build_content(lib: Library, ref: str, mobs: list[str], mob_ids: dict[str, str]) -> tuple[dict, dict]:
    pack = git_json(ref, 'game_dnf/assets_local/content/combat_content.json')
    records = pack['records']
    indexes = pack.setdefault('indexes', {})
    monsters_index = indexes.setdefault('monsters_goblin', {})
    added = Counter()
    for mob_path in mobs:
        mob = add_record(records, lib, mob_path, 'mob', force=True)
        decoded = mob.get('decoded', {})
        for key in ACTION_KEYS:
            for act_path in decoded.get(key) or []:
                act = add_record(records, lib, str(act_path), 'act', force=True)
                base_ani = str(act.get('decoded', {}).get('base_ani', ''))
                if base_ani:
                    add_record(records, lib, base_ani, 'ani')
                sub_ani = str(act.get('decoded', {}).get('sub_ani', ''))
                if sub_ani:
                    add_record(records, lib, sub_ani, 'ani')
        for atk_path in decoded.get('attack_infos') or []:
            if atk_path:
                add_record(records, lib, str(atk_path), 'atk')
    for mob_path, index in sorted(mob_ids.items()):
        if index:
            monsters_index[index] = mob_path
    pack['scope'] = str(pack.get('scope', '')) + '; isolated act8/newmonsters testbed overlay'
    pack['act8_testbed'] = {
        'mobs': mobs,
        'route': 'arden',
        'evidence': '.mob [* action] -> .act [BASE ANI]; [attack action] aligned with [attack info]',
    }
    return pack, dict(added)


def build_adapt(lib: Library, ref: str, route: dict) -> dict:
    adapt = git_json(ref, 'game_dnf/data/combat.json')
    adapt['map_export'] = route['map_export']
    adapt['rooms'] = route['rooms']
    adapt['rooms_source'] = 'Isolated act8 testbed route from dungeon/act8/arden.dgn; hidden in main flow.'
    adapt['act8_testbed'] = True
    return adapt


def motion_map_for(catalog_entry: dict) -> dict:
    actions = catalog_entry.get('actions', {})
    anis = catalog_entry.get('action_anis', {})
    out = {}
    for slot, pose in {
        'waiting': 'stay', 'move': 'move', 'sit': 'sit', 'damage1': 'damage1',
        'damage2': 'damage2', 'down': 'down', 'overturn': 'overturn',
        'last': 'die', 'jump': 'jump',
    }.items():
        if anis.get(slot):
            out[pose] = anis[slot][0]
    attack_acts = actions.get('attack', [])
    attack_anis = anis.get('attack', [])
    for index, act_path in enumerate(attack_acts):
        if index >= len(attack_anis):
            continue
        clip = PurePosixPath(act_path).stem.lower()
        out[clip] = attack_anis[index]
        if index == 0:
            out['attack'] = attack_anis[index]
    return out


def build_assets(lib: Library, ref: str, mobs: list[str]) -> tuple[dict, dict]:
    base = git_json(ref, 'game_dnf/assets_local/combat/manifest.json')
    catalog = json.loads(CATALOG.read_text(encoding='utf-8'))['monsters']
    by_path = {str(item['path']).lower(): item for item in catalog.values()}
    src = Source(lib.path)
    output = OUT / 'combat'
    output.mkdir(parents=True, exist_ok=True)
    unresolved = []
    summary = {}
    missing_atlas = []
    try:
        for mob_path in mobs:
            entry = by_path.get(mob_path)
            if not entry:
                raise RuntimeError('catalog missing '+mob_path)
            key = mob_path.replace('monster/', '', 1).replace('.mob', '').replace('/', '_')
            moves = motion_map_for(entry)
            bank = monster_bank(
                src, key, mob_path, '', unresolved, motion_map=moves,
                atlas_root=TEXTURE_ROOT + '/combat/', output_dir=output,
            )
            if not bank:
                missing_atlas.append(key)
                summary[key] = {'clips': [], 'status': 'missing_source_image'}
                continue
            base['monsters'][key] = bank
            summary[key] = {'clips': sorted(bank.get('clips', {})), 'status': 'ready'}
        hp = Atlas('ui_monster_hp', TEXTURE_ROOT + '/combat/', output)
        for frame in range(19):
            image, meta = src.frame(MONSTER_HP_IMG, frame)
            hp.add(f'f{frame}', image, [meta['x'], meta['y']])
        for mob_path in mobs:
            script = lib.script(mob_path, 'mob')
            refs = [field['values'] for field in (script.get('fields') or []) if field['tag'] == '[face image]']
            if not refs or not isinstance(refs[0][0], str):
                unresolved.append({'kind': 'face_image', 'monster': mob_path})
                continue
            image, meta = src.frame(refs[0][0], int(refs[0][1]))
            image, offset = cropped(image, meta)
            hp.add('face:'+mob_path, image, offset)
        base['monster_hp'] = hp.save()
        base['act8_testbed'] = {
            'schema': 'dnf_act8_testbed_assets/1',
            'mobs': mobs,
            'unresolved': unresolved,
            'atlas_status': 'logic_only_missing_source_image' if missing_atlas else 'ready',
            'missing_atlas_kinds': missing_atlas,
        }
    finally:
        src.cat.close()
        src.lib.close()
    return base, summary


def nonblank_png(path: Path) -> bool:
    if not path.is_file():
        return False
    image = Image.open(path).convert('RGBA')
    return image.getbbox() is not None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path)
    parser.add_argument('--base-ref', default='HEAD')
    args = parser.parse_args()
    route, mobs, mob_ids = route_context(args.base_ref)
    lib = open_library(args.library)
    try:
        content, _ = build_content(lib, args.base_ref, mobs, mob_ids)
        adapt = build_adapt(lib, args.base_ref, route)
        assets, clips = build_assets(lib, args.base_ref, mobs)
    finally:
        lib.close()
    OUT.mkdir(parents=True, exist_ok=True)
    content_path = OUT / 'content.json'
    adapt_path = OUT / 'adapt.json'
    assets_path = OUT / 'combat_manifest.json'
    content_body = json.dumps(content, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    content_path.write_text(content_body, encoding='utf-8')
    adapt_path.write_text(json.dumps(adapt, ensure_ascii=False, indent=1)+'\n', encoding='utf-8')
    assets_path.write_text(json.dumps(assets, ensure_ascii=False, separators=(',', ':'))+'\n', encoding='utf-8')
    ready_keys = [key for key, item in clips.items() if item['status'] == 'ready']
    required_pngs = [OUT / 'combat' / f'mob_{key}.png' for key in ready_keys] + [OUT / 'combat' / 'ui_monster_hp.png']
    missing_pngs = [str(path.relative_to(ROOT)) for path in required_pngs if not nonblank_png(path)]
    summary = {
        'schema': 'dnf_act8_testbed_build/1',
        'base_ref': args.base_ref,
        'dungeon': 'arden',
        'rooms': len(route['rooms']),
        'route_mobs': mobs,
        'mob_count': len(mobs),
        'clips': clips,
        'unresolved': assets.get('act8_testbed', {}).get('unresolved', []),
        'atlas_status': assets.get('act8_testbed', {}).get('atlas_status'),
        'missing_atlas_kinds': assets.get('act8_testbed', {}).get('missing_atlas_kinds', []),
        'missing_pngs': missing_pngs,
        'content_sha256': hashlib.sha256(content_body.encode('utf-8')).hexdigest(),
        'content_records': len(content['records']),
    }
    (OUT / 'build_summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=1)+'\n', encoding='utf-8')
    if missing_pngs:
        raise RuntimeError('nonblank atlas check failed: '+', '.join(missing_pngs))
    print('[ACT8] rooms=%d mobs=%d content_records=%d unresolved=%d'
          % (len(route['rooms']), len(mobs), len(content['records']), len(summary['unresolved'])))
    for mob in mobs:
        key = mob.replace('monster/', '', 1).replace('.mob', '').replace('/', '_')
        item = clips[key]
        print('  %-64s %s' % (key, item['status'] + ':' + ','.join(item['clips'])))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

"""Compile original special passive-object item groups for native mazes."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from audit_dnf_reusable_data import TextResolver
from build_dnf_native_catalog import chinese
from dnf_pvf import open_library, resolve


ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / 'game_dnf'
OUTPUT = GAME / 'data/native_box_loot.json'
LISTING = 'stackable/stackable.lst'
SOURCES = {
    'outerwall': (
        'dungeon/act3/outerwall.dgn',
        '4bc1517d37fdefdd4288ff0766a0bdc52d4c03248ca5e8d395e02354f05b08b8',
    ),
    'jungle': (
        'dungeon/act3/jungle.dgn',
        'aaa68a88b6cea80c7749fe4b5dabcea5aca6b290f27ebf1de01dc880a9457291',
    ),
    'darkhell': (
        'dungeon/act3/darkhell.dgn',
        'fd954e4d7abc752b5ac7b6048a4099fa7bbfc7e752e3cefa37ecb7fe18639974',
    ),
    'whitenight': (
        'dungeon/act3/whitenight.dgn',
        'a50170f3734e0a88917e27a8b741834bb68e19fcd99ec25280228c8703f94a71',
    ),
    'secondbackbone': (
        'dungeon/act3/2ndbackbone.dgn',
        '0c5b269fe35d1699c652beb77ec946eb6e3b6c417fd70f18d24a9bfa10e417cc',
    ),
    'firstbackbone': (
        'dungeon/act3/1stbackbone.dgn',
        '005a1cba836b48bd1f56f2a6a6dd5e72ffa91786c701cc0b2a6791027176da85',
    ),
    'marpissalair': (
        'dungeon/act4/marpissalair.dgn',
        '10848752c082de15b0929fb171fc827165fe995009bff7ff5786658754a308c7',
    ),
    'shallowkeep': (
        'dungeon/act4/shallowkeep.dgn',
        '652be6d9a2d862210a92c767e5cb7c3cbb4d3f8e887868e0e98cc8fa9f9ab833',
    ),
    'darkelfcemetary': (
        'dungeon/act4/darkelfcemetary.dgn',
        'ee3566c5e528abf12e13edcd1721a18aaf4be8677e450222dccc113a472520b0',
    ),
    'magmacave': (
        'dungeon/act4/magmacave.dgn',
        '5b47aac76324fb52d63eedb834b5f32bb7cfd1cedba610ce9fccf12873d775e8',
    ),
    'bloodhell': (
        'dungeon/act3/bloodhell.dgn',
        '8b4d8a743b8b57bc3118575bab15c85f67277bc8991056dc82b3d1c4dcfc8a57',
    ),
    'gbl_laboratory': (
        'dungeon/village/gbl/gbl_laboratory.dgn',
        'ee701f2b6a72085033a4b8fe8430d1374e9ddd4dbd5c88dc88455fd00ee9e379',
    ),
    'gbl_hatchery': (
        'dungeon/village/gbl/gbl_hatchery.dgn',
        '266393055e4e3894218aa8f26b4ab35c1e7a416ec0b486b57cdfc1fe5b5b70ce',
    ),
}


def referenced_groups(route: dict) -> set[str]:
    export_path = route.get('map_export', '').removeprefix('res://')
    export = json.loads((GAME / export_path).read_text(encoding='utf-8'))
    groups: set[str] = set()
    for room in (export.get('dungeon', {}).get('rooms') or {}).values():
        for item in room.get('objects', []):
            raw = item.get('raw', [])
            if item.get('source_tag') != '[special passive object]' or len(raw) < 11:
                continue
            count = int(raw[4])
            if len(raw) != 5 + 6 * count:
                continue
            for at in range(5, len(raw), 6):
                if raw[at] != '[item]':
                    continue
                draws = int(raw[at + 2])
                if draws < 0 and at + 3 < len(raw):
                    draws = int(raw[at + 3])
                if draws > 0:
                    groups.add(str(int(raw[at + 1])))
    return groups


def compile_source(lib) -> dict:
    routes = json.loads((GAME / 'data/dungeons.json').read_text(encoding='utf-8'))['dungeons']
    index = lib.listing(LISTING)
    text = TextResolver(lib)
    item_cache: dict[str, dict] = {}
    item_ids: dict[str, int] = {}
    dungeons: dict[str, dict] = {}
    for dungeon_id, (path, expected_sha) in SOURCES.items():
        script = lib.script(path)
        if not script or script['sha256'] != expected_sha:
            raise ValueError(f'Source {path} changed')
        fields = {field['tag']: field['values'] for field in script['fields']}
        rows = fields.get('[special passive object item]') or []
        groups: dict[str, list[list]] = {}
        group_levels: dict[str, int] = {}
        at = 0
        while at < len(rows):
            if at + 3 > len(rows):
                raise ValueError(f'{path}: truncated box group')
            group_id, level, count = rows[at:at + 3]
            at += 3
            if not isinstance(level, int) or not isinstance(count, int) or count < 0 or at + count * 2 > len(rows):
                raise ValueError(f'{path}: unsupported box group')
            entries = []
            for cursor in range(at, at + count * 2, 2):
                item_id, weight = rows[cursor:cursor + 2]
                key = f'original_{int(item_id)}'
                entries.append([key, int(weight)])
                item_ids.setdefault(key, int(item_id))
            at += count * 2
            groups[str(int(group_id))] = entries
            group_levels[str(int(group_id))] = level
        used = referenced_groups(routes[dungeon_id])
        if not used.issubset(groups):
            raise ValueError(f'{path}: referenced box groups are not fully compiled')
        if not used:
            continue
        dungeons[expected_sha] = {
            'id': dungeon_id,
            'source': {'path': path, 'sha256': expected_sha},
            'groups': {group: groups[group] for group in sorted(used, key=int)},
            'group_levels': {group: group_levels[group] for group in sorted(used, key=int)},
        }
    used_items = {
        key
        for dungeon in dungeons.values()
        for entries in dungeon['groups'].values()
        for key, _ in entries
    }
    for key in sorted(used_items):
        item_id = item_ids[key]
        item_path = resolve(LISTING, index[item_id])
        item = lib.script(item_path)
        if not item:
            raise ValueError(f'Missing stackable {item_id}: {item_path}')
        item_fields = {field['tag']: field['values'] for field in item['fields']}
        name = text.fields(lib.raw(item_path)[0])['[name]'][0]
        stack_type = item_fields['[stackable type]'][0]
        kind = 'consumable' if stack_type == '[waste]' else 'throwable' if stack_type == '[throw]' else 'material'
        item_cache[key] = {
            'name': chinese(name['text']), 'kind': kind, 'description': '',
            'level': item_fields['[minimum level]'][0], 'rarity': item_fields['[rarity]'][0],
            'weight': item_fields['[weight]'][0] / 1000, 'price': item_fields['[price]'][0],
            'stack_limit': item_fields.get('[stack limit]', [1])[0],
            'icon': item_fields['[icon]'], 'field_image': item_fields['[field image]'],
            'source': {'id': item_id, 'path': item_path, 'list': LISTING,
                       'sha256': item['sha256'], 'name_table': name['table'], 'name_key': name['key']},
            'source_fields': {
                tag: item_fields[tag] for tag in
                ('[stackable type]', '[cool time]', '[cooltime group]', '[hp recovery]',
                 '[mp recovery]', '[stat change]', '[stat change duration]')
                if tag in item_fields
            },
        }
    return {
        'schema': 'dnf_native_box_loot/1',
        'evidence': 'Original DGN [special passive object item] groups and stackable sources',
        'dungeons': dungeons,
        'items': {key: item_cache[key] for key in sorted(used_items)},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    lib = open_library(args.library)
    try:
        output = json.dumps(compile_source(lib), ensure_ascii=False, indent=2) + '\n'
    finally:
        lib.close()
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text(encoding='utf-8') != output:
            raise ValueError('Native box loot differs from pinned source')
    else:
        OUTPUT.write_text(output, encoding='utf-8', newline='\n')
    print('NATIVE BOX LOOT VERIFIED')


if __name__ == '__main__':
    main()

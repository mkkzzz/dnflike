"""Compile the pinned DGN21 box table and its original stackable definitions."""
import argparse
import json
from pathlib import Path

from audit_dnf_reusable_data import TextResolver
from build_dnf_native_catalog import chinese
from dnf_pvf import open_library, resolve


ROOT = Path(__file__).resolve().parents[1]
DUNGEON = 'dungeon/act3/outerwall.dgn'
DUNGEON_SHA = '4bc1517d37fdefdd4288ff0766a0bdc52d4c03248ca5e8d395e02354f05b08b8'
LISTING = 'stackable/stackable.lst'
OUTPUT = ROOT / 'game_dnf/data/outerwall_box_loot.json'


def compile_source(lib):
    dungeon = lib.script(DUNGEON)
    if not dungeon or dungeon['sha256'] != DUNGEON_SHA:
        raise ValueError('Source DGN21 has changed')
    fields = {field['tag']: field['values'] for field in dungeon['fields']}
    raw = fields['[special passive object item]']
    groups = {}
    at = 0
    while at < len(raw):
        index, level, count = raw[at:at + 3]
        at += 3
        if level != -1 or not 0 <= count <= (len(raw) - at) // 2 or str(index) in groups:
            raise ValueError('Unsupported DGN21 box table row')
        groups[str(index)] = [[f'original_{raw[i]}', raw[i + 1]] for i in range(at, at + count * 2, 2)]
        at += count * 2
    if fields.get('[object drop item]') or set(groups) != {'0', '1'} or groups['1']:
        raise ValueError('DGN21 box tables differ from the audited scope')

    index = lib.listing(LISTING)
    text = TextResolver(lib)
    items = {}
    for key, _ in groups['0']:
        number = int(key.removeprefix('original_'))
        path = resolve(LISTING, index[number])
        item = lib.script(path)
        fields = {field['tag']: field['values'] for field in item['fields']}
        if fields['[stackable type]'] != ['[waste]', 4]:
            raise ValueError('Unexpected box item type: ' + path)
        name = text.fields(lib.raw(path)[0])['[name]'][0]
        items[key] = {
            'name': chinese(name['text']), 'kind': 'consumable', 'description': '',
            'level': fields['[minimum level]'][0], 'rarity': fields['[rarity]'][0],
            'weight': fields['[weight]'][0] / 1000, 'price': fields['[price]'][0],
            'stack_limit': fields['[stack limit]'][0], 'icon': fields['[icon]'],
            'field_image': fields['[field image]'],
            'source': {'id': number, 'path': path, 'list': LISTING, 'sha256': item['sha256'],
                       'name_table': name['table'], 'name_key': name['key']},
            'source_fields': {tag: fields[tag] for tag in ('[stackable type]', '[cool time]', '[cooltime group]',
                              '[hp recovery]', '[mp recovery]', '[stat change]', '[stat change duration]') if tag in fields},
        }
    return {'schema': 'dnf_outerwall_box_loot/1', 'source': {'path': DUNGEON, 'sha256': DUNGEON_SHA},
            'groups': groups, 'items': items}


def main():
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
        if OUTPUT.read_text(encoding='utf8') != output:
            raise ValueError('Box data differs from pinned source')
    else:
        OUTPUT.write_text(output, encoding='utf8', newline='\n')
    print('DGN21 BOX LOOT VERIFIED')


if __name__ == '__main__':
    main()

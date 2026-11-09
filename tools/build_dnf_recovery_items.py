"""Compile the original composite recovery items used by Soulbringer quest 981."""
import argparse
import gzip
import json
from pathlib import Path

from build_dnf_native_catalog import compile_item

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'game_dnf/assets_local/native_data_v1'
OUTPUT = ROOT / 'game_dnf/data/native_recovery_items.json'
RECOVERY_ITEMS = {
    1089: ('stackable/strawberry_mutant.stk', 'a809d926d556fd0ffb8f4c329ce293b510fa608e5df300bc84dff98ec70d84a6'),
    1090: ('stackable/lamihwa_mutant.stk', '99f3b2245a863ef77ee19a523f93e53292b61c012055b94d608a69cbc94f4604'),
}


def read(path):
    return json.loads(gzip.decompress(path.read_bytes()))


def build():
    index = read(SOURCE / 'index.json.gz')
    result = {'schema': 'dnf_native_recovery_items/1', 'items': {}, 'consumables': {}}
    for number, (path, sha) in RECOVERY_ITEMS.items():
        if index['indexes']['stackable'][str(number)] != path:
            raise ValueError(f'Unexpected original item path: {number}')
        record = read(SOURCE / index['locations'][path])['records'][path]
        if record['sha256'] != sha or not record['crc_ok'] or record['repeated_fields']:
            raise ValueError(f'Unexpected source record: {path}')
        fields = {row['tag']: row['values'] for row in record['fields'] if not row['tag'].startswith('[/')}
        tag = '[active status recovery]' if number == 1089 else '[my status]'
        source_effect = fields.pop(tag)
        if tag == '[active status recovery]' and source_effect == ['bleeding', -1, 'myself']:
            # ImportStackableScript 0x12774BA, self cure 0x7A83B7.
            status = {'cure': 'bleed'}
        elif tag == '[my status]' and source_effect == ['stun', 10, 5000, 50]:
            # 0x12775BD reads chance, duration and status level in that order.
            status = {'self_stun': dict(zip(('chance_percent', 'duration_ms', 'status_level'), source_effect[1:]))}
        else:
            raise ValueError(f'Unverified status payload: {path} {source_effect}')
        item, _, recovery, reasons = compile_item(
            number, 'stackable/stackable.lst', path, sha, fields, record['text'],
        )
        if reasons or recovery is None:
            raise ValueError(f'Uncompiled recovery item: {path} {reasons}')
        effect = recovery['effect']
        restore = f"恢复 {'HP' if effect['hp'] else 'MP'} {effect['hp'] or effect['mp']}"
        details = '解除出血' if 'cure' in status else item['description'].replace('%%', '%')
        item['description'] = f'{restore}\n{details}'
        item['source_fields'] = {tag: source_effect}
        effect.update(status)
        key = f'original_{number}'
        result['items'][key] = item
        result['consumables'][key] = recovery
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    expected = build()
    if args.check:
        if json.loads(OUTPUT.read_text(encoding='utf-8')) != expected:
            raise ValueError('Composite recovery items are stale')
    else:
        OUTPUT.write_text(json.dumps(expected, ensure_ascii=False, indent=1)+'\n', encoding='utf-8', newline='\n')
    print('NATIVE RECOVERY ITEMS', len(expected['items']))


if __name__ == '__main__':
    main()

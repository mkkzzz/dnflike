"""Export original icon/field frames for the compiled batch, without resampling."""
import argparse
import hashlib
import json
from pathlib import Path

from dnf_asset_store import ROOT, LOCK, cache_home
from export_dnf_map import Library


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--version', default='items_original_v1')
    parser.add_argument('--ids', help='Comma-separated stable item IDs for an additive batch')
    args = parser.parse_args()
    if not args.version.startswith('items_original_v') or not args.version.removeprefix('items_original_v').isdigit():
        raise ValueError('Expected an items_original_vN version')
    output = ROOT / 'game_dnf/assets_local' / args.version
    manifest = output / 'manifest.json'
    if args.check:
        data = json.loads(manifest.read_text(encoding='utf-8'))
        for path, sha in data['files'].items():
            if hashlib.sha256((output / path).read_bytes()).hexdigest() != sha:
                raise ValueError('Original frame changed: ' + path)
        print('ORIGINAL ITEM FRAMES VERIFIED', len(data['files']))
        return
    if output.exists() and any(output.iterdir()):
        raise ValueError('Immutable asset version exists; use --check or a new version directory')
    items = json.loads((ROOT/'game_dnf/data/runtime_items.json').read_text(encoding='utf-8'))['items']
    if args.ids:
        items = {key:items[key] for key in args.ids.split(',')}
    version = json.loads(LOCK.read_text(encoding='utf-8'))['version']
    lib = Library(args.library or cache_home()/version/'library_v1', output)
    result = {'schema':'dnf_original_item_images/1','revision':1,'items':{},'field_images':{},
              'pixel_policy':'Native source RGBA, unchanged size; no resize, repaint or separate preview assets'}
    try:
        for id, data in items.items():
            for field, target in [('icon','items'),('field_image','field_images')]:
                reference = data[field]
                if not reference:
                    raise ValueError('Missing original frame reference: '+id)
                image = lib.image(reference[0], int(reference[1]), id)
                if image is None:
                    raise ValueError('Missing original frame: '+id)
                result[target][id] = image
        result['images'] = lib.images
        result['diagnostics'] = lib.diags
        result['files'] = {path.relative_to(output).as_posix():hashlib.sha256(path.read_bytes()).hexdigest()
                           for path in sorted(output.rglob('*.png'))}
        manifest.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    finally:
        lib.close()
    print('ORIGINAL ITEM IMAGES', len(items), 'definitions', len(result['files']), 'unique frames')


if __name__=='__main__':
    main()

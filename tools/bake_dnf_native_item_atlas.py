"""Pack every bulk-compiled item frame at unchanged native pixel dimensions."""
import argparse
from collections import Counter
import hashlib
import json
import sqlite3
from pathlib import Path
from PIL import Image

from dnf_pvf import open_library
from export_dnf_map import Library

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--version', default='v1')
    args = parser.parse_args()
    output = ROOT / ('game_dnf/assets_local/items_native_' + args.version)
    manifest = output / 'manifest.json'
    if args.check:
        data = json.loads(manifest.read_text(encoding='utf8'))
        for file, sha in data['files'].items():
            if hashlib.sha256((output / file).read_bytes()).hexdigest() != sha:raise ValueError('Atlas hash: ' + file)
        pages = {}
        for key, info in data['images'].items():
            x, y, w, h = info['region']
            if info['file'] not in pages:
                with Image.open(output / info['file']) as atlas:pages[info['file']] = atlas.convert('RGBA')
            pixels = pages[info['file']].crop((x,y,x+w,y+h)).tobytes()
            if hashlib.sha256(pixels).hexdigest() != info['rgba_sha256']:raise ValueError('Native pixels: ' + key)
        print('NATIVE ATLAS VERIFIED', len(data['images']), 'frames', len(data['items']), 'items');return
    if manifest.exists():raise ValueError('Immutable version exists; use --check or create a new version')
    output.mkdir(parents=True, exist_ok=True)
    items = json.loads((ROOT / 'game_dnf/data/native_runtime.json').read_text(encoding='utf8'))['items']
    source = open_library(None)
    lib = Library(source.path, ROOT / 'temp/native_item_frames')
    # Thousands of references must not perform thousands of full SQLite scans.
    # The shared source catalog stays read-only; this index lives in RAM only.
    catalog = sqlite3.connect(':memory:')
    lib.catalog.backup(catalog)
    lib.catalog.close()
    catalog.row_factory = sqlite3.Row
    catalog.execute('create index if not exists native_image_lookup on assets(lower(original_path),validation)')
    lib.catalog = catalog
    source.close()
    doc = {'schema': 'dnf_native_item_atlas/1', 'items': {}, 'field_images': {}, 'images': {}, 'files': {},
           'pixel_policy': 'Native RGBA copied 1:1 into transparent atlas pages; no resizing or repainting'}
    try:
        for count, (key, item) in enumerate(items.items()):
            if count % 300 == 0:print('NATIVE ICONS', count, '/', len(items), flush=True)
            for field, group in [('icon', 'items'), ('field_image', 'field_images')]:
                ref = item[field]
                image = lib.image(ref[0], int(ref[1]), key)
                if image is None:raise ValueError('Unresolved active image: ' + key + ':' + field)
                doc[group][key] = image
        page = Image.new('RGBA', (1024, 1024))
        number = x = y = row_height = 0
        def save():
            file = 'page_%03d.png' % number
            page.save(output / file)
            doc['files'][file] = hashlib.sha256((output / file).read_bytes()).hexdigest()
        for key, info in sorted(lib.images.items()):
            with Image.open(lib.output / info['file']) as original:
                original = original.convert('RGBA')
                w, h = original.size
                if w > 1024 or h > 1024:raise ValueError('Native item exceeds atlas: ' + key)
                if x + w > 1024:x = 0;y += row_height + 2;row_height = 0
                if y + h > 1024:
                    save();number += 1;page = Image.new('RGBA', (1024, 1024));x = y = row_height = 0
                page.paste(original, (x, y))
                doc['images'][key] = {**info, 'file': 'page_%03d.png' % number, 'region': [x, y, w, h],
                                     'rgba_sha256': hashlib.sha256(original.tobytes()).hexdigest()}
                x += w + 2;row_height = max(row_height, h)
        if lib.images:save()
        doc['diagnostics'] = lib.diags
        doc['sizes'] = dict(Counter('%dx%d' % tuple(v['size']) for v in doc['images'].values()))
        manifest.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + '\n', encoding='utf8')
    finally:lib.close()
    print('NATIVE ICON ATLAS', len(items), 'items', len(doc['images']), 'unique native frames', len(doc['files']), 'pages')


if __name__ == '__main__':main()

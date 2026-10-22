"""Verify exported native UI pixels against the exact source IMG/frame, not screenshots."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
from PIL import Image
from dnf_asset_reader import parse, decode
from dnf_asset_store import ROOT, LOCK, cache_home


def audit(library: Path, output: Path) -> dict:
    manifest = json.loads((output/'manifest.json').read_text(encoding='utf8'))
    catalog = sqlite3.connect(f'{library.as_uri()}/catalog.sqlite?mode=ro', uri=True)
    cache, failures = {}, []
    try:
        for key, item in manifest['images'].items():
            sha = item['img_sha256']
            if sha not in cache:
                path = catalog.execute('select local_path from assets where sha256=?', (sha,)).fetchone()[0]
                raw = (library/path).read_bytes()
                if hashlib.sha256(raw).hexdigest() != sha:raise ValueError('Source hash mismatch: '+path)
                cache[sha] = raw, parse(raw)
            raw, parsed = cache[sha]
            source, _ = decode(raw, parsed, item['frame'])
            actual = Image.open(output/item['file']).convert('RGBA')
            if source.size != actual.size or source.tobytes() != actual.tobytes():failures.append(key)
        hud = manifest['images'][manifest['ui']['hud']['0']]
        assert hud['source_path'].lower() == 'sprite/interface2/hud/hud.img' and hud['size'] == [800, 92]
        inventory = manifest['images'][manifest['ui']['inventory']['0']]
        assert inventory['source_path'].lower().endswith('/inventory/fuck_1.img')
        assert manifest['images'][manifest['ui']['worldmap']['0']]['size'] == [800, 600]
        sources = {s['path']: s for s in manifest['ui_layout_sources']}
        controls = [[v.get('value') for v in span['values']] for span in sources['ui/hud/hud.ui']['spans'] if span['tag'] == '[ui controls]']
        button = next(c for c in controls if c[1] == 'inventory_button')
        assert button[2:4] == [299, 52] and button[5].lower() == 'interface2/hud/hud.img'
        result = {'schema': 'native_ui_source_audit/1', 'images_checked': len(manifest['images']),
                  'mismatched_frames': failures, 'hud_source_and_control_coordinates': 'pass',
                  'inventory_patched_client_family': 'pass', 'map_native_dimensions': 'pass',
                  'runtime_client_layout_certified': False,
                  'limits': 'Raw pixels/source tokens checked; window reconstruction is not an original-client runtime comparison.'}
        if failures:raise ValueError(json.dumps(result))
        return result
    finally:catalog.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT/'game_dnf/assets_local/flow_v1')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text(encoding='utf8'))
    result = audit((args.library or cache_home()/lock['version']/'library_v1').resolve(), args.output.resolve())
    text = json.dumps(result, ensure_ascii=False, indent=2)+'\n'
    if args.report:args.report.write_text(text, encoding='utf8')
    print(text)

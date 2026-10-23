"""Bake the first source quest chapter from the read-only original library.

Output uses native pixels. The classic Seria ANI is an explicit E-ADAPT selection
instead of the seasonal ANI referenced by this mixed backup's NPC definition.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from dnf_asset_store import ROOT, LOCK, cache_home
from export_dnf_map import (Library, export_map, run, COORDINATES, LAYERS,
                            TILE_W, TILE_H, CELL_W, CELL_H, GRID_COLS, GRID_ROWS)

OUTPUT = ROOT / 'game_dnf/assets_local/flow_v1/early_quests'


def build(library: Path, output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    lib = Library(library, output)
    try:
        path = 'map/elvengard/(r)gate.map'
        room = export_map(lib, path, {
            'objects': lib.listing('passiveobject/passiveobject.lst'),
            'monsters': lib.listing('monster/monster.lst')})
        sprite = lib.sprite('npc/animation/npc_se.ani', 'quest/seria')
        if not sprite:raise ValueError('Classic Seria animation is required')
        room['animations'].append({'layer': 'normal', 'anchor': [477, 160, 0],
                                   'space': 'map', 'sprite': sprite})
        portrait = lib.image('Interface/npc_dialog_face.img', 1, 'quest/seria/portrait')
        if not portrait:raise ValueError('Seria original dialogue illustration is required')
        cards = {name: lib.image('WorldMap/SelectDungeonSlot/elvengard.img', index, 'quest/dungeons')
                 for index, name in enumerate(['lorien', 'lorien_inside'])}
        if not all(cards.values()):raise ValueError('Original Elvengard dungeon cards required')
        result = {
            'schema': 'dnf_native_map/1', 'quest_art_schema': 'dnf_quest_art/1',
            'source': {'asset_version': json.loads(LOCK.read_text(encoding='utf-8'))['version'],
                       'exporter': 'tools/build_dnf_quest_assets.py',
                       'pixel_policy': 'Original IMG native RGBA; no resize, no painted substitutes',
                       'selection': 'E-ADAPT: (r)gate room and classic npc_se; effective client variant unconfirmed'},
            'coordinates': COORDINATES,
            'constants': {'tile_width': TILE_W, 'tile_height': TILE_H, 'grid_cols': GRID_COLS,
                          'grid_rows': GRID_ROWS, 'cell_width': CELL_W, 'cell_height': CELL_H,
                          'screen_y_offset': 120, 'viewport': [800, 600], 'layers': LAYERS},
            'dungeon': {'rooms': {path: room}, 'placements': [{'id': 'seria_room', 'map': path, 'gates': []}],
                        'gate_objects': {}},
            'ui': {'seria_portrait': portrait, 'dungeons': cards},
            'images': lib.images, 'diagnostics': lib.diags}
        # This backup overlays unavailable holiday decorations onto the classic
        # five Gate ANIs. Preserve those diagnostics; omit the holiday layers.
        expected_missing = ['sprite/', 'sprite/map/00far0.img', 'sprite/map/newgarlandlight01.img',
                            'sprite/map/newgarlandlight02.img', 'sprite/map/newgarlandlight03.img',
                            'sprite/map/newgarlandlight04.img', 'sprite/map/g1.img', 'sprite/map/g2.img',
                            'sprite/map/g3.img', 'sprite/map/g4.img', 'sprite/map/garlandlight.img']
        for d in lib.diags:
            if d['level'] == 'error' and ((d['code'] == 'image_missing' and any(
                    d['detail'].startswith(p+' has ') for p in expected_missing)) or d['code'] == 'pathgate_pos'):
                d['level'] = 'warning'
                d['selection'] = 'E-ADAPT: unused dummy tile/holiday overlay or town non-dungeon gate'
        if any(d['level'] == 'error' for d in lib.diags):raise ValueError(str(lib.diags))
        result['source']['omitted'] = 'Unresolved holiday overlays and dummy tiles retained in diagnostics; classic Gate ANIs retained'
        (output/'manifest.json').write_text(json.dumps(result, ensure_ascii=False, indent=1)+'\n', encoding='utf-8')
    finally:
        lib.close()
    run(library, 'dungeon/act1/lorieninside.dgn', output/'lorien_inside', [])
    return {'output': str(output), 'images': len(result['images']), 'room': path}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()
    output = args.output.resolve()
    if not any(output.is_relative_to(p.resolve()) for p in [ROOT/'temp', ROOT/'game_dnf/assets_local']):
        parser.error('Output must stay in ignored temp/ or assets_local/')
    version = json.loads(LOCK.read_text(encoding='utf-8'))['version']
    print(json.dumps(build(args.library or cache_home()/version/'library_v1', output)))
